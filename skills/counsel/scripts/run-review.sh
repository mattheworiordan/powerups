#!/usr/bin/env bash
# Orchestrate parallel agent reviews (external CLI agents only)
# When running from Claude Code, pass --exclude claude (it uses Task() sub-agent instead)
# When running from Grok, pass --exclude grok (it uses spawn_subagent instead)
#
# All agents run in READ-ONLY mode — no writes, no state changes.
#
# Usage: run-review.sh --config <file> --prompt-file <file> --output-dir <dir>
#          [--agents a,b] [--exclude a,b] [--timeout SECONDS]
#          [--model MODEL] [--claude-model MODEL] [--codex-model MODEL]
#          [--effort standard|extra] [--codex-effort LEVEL]
#          [--claude-config-dir DIR] [--add-dir DIR] [--dry-run]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PIDS=()
AGENTS=()

cleanup() {
  if [ ${#PIDS[@]} -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT INT TERM

CONFIG_FILE=""
PROMPT_FILE=""
OUTPUT_DIR=""
TIMEOUT=300
EXCLUDE_AGENTS=""
ONLY_AGENTS=""
CLAUDE_MODEL=""
CODEX_MODEL=""
CODEX_EFFORT=""
EFFORT="standard"
TIMEOUT_SET=0
CLAUDE_CONFIG_OVERRIDE=""
DRY_RUN=0
ADD_DIRS=()

require_value() {
  if [ $# -lt 2 ]; then
    echo "Error: $1 requires a value" >&2
    exit 1
  fi
}

usage() {
  echo "Usage: run-review.sh --config <file> --prompt-file <file> --output-dir <dir>" >&2
  echo "         [--agents a,b] [--exclude a,b] [--timeout SECONDS]" >&2
  echo "         [--model MODEL] [--claude-model MODEL] [--codex-model MODEL]" >&2
  echo "         [--effort standard|extra] [--codex-effort LEVEL]" >&2
  echo "         [--claude-config-dir DIR] [--add-dir DIR] [--dry-run]" >&2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)             require_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
    --prompt-file)        require_value "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --output-dir)         require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --timeout)            require_value "$@"; TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    --effort)             require_value "$@"; EFFORT="$2"; shift 2 ;;
    --codex-effort)       require_value "$@"; CODEX_EFFORT="$2"; shift 2 ;;
    --exclude)
      require_value "$@"
      if [ -n "$EXCLUDE_AGENTS" ]; then
        EXCLUDE_AGENTS="${EXCLUDE_AGENTS},$2"
      else
        EXCLUDE_AGENTS="$2"
      fi
      shift 2
      ;;
    --agents)             require_value "$@"; ONLY_AGENTS="$2"; shift 2 ;;
    --model|--claude-model) require_value "$@"; CLAUDE_MODEL="$2"; shift 2 ;;
    --codex-model)        require_value "$@"; CODEX_MODEL="$2"; shift 2 ;;
    --claude-config-dir)  require_value "$@"; CLAUDE_CONFIG_OVERRIDE="$2"; shift 2 ;;
    --add-dir)            require_value "$@"; ADD_DIRS+=("$2"); shift 2 ;;
    --dry-run)            DRY_RUN=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$PROMPT_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
  usage
  exit 1
fi

[ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }
[ -f "$PROMPT_FILE" ] || { echo "Prompt file not found: $PROMPT_FILE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

# Directory under review — captured before any agent changes directory.
REPO_DIR="$PWD"
LAUNCH_DIR="$OUTPUT_DIR/.launch"
mkdir -p "$LAUNCH_DIR"

# Drop extra-CA env whose file is missing (relative dummy certs from a repo cwd).
for _v in SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE; do
  eval "_val=\${${_v}-}"
  [ -z "$_val" ] && continue
  if [ ! -e "$_val" ]; then
    unset "$_v"
  fi
done
unset _v _val

CLAUDE_CONFIG_DIR_RESOLVED=$(counsel_claude_config_dir "$CONFIG_FILE" "$CLAUDE_CONFIG_OVERRIDE")
CLAUDE_BIN=$(command -v claude || true)

if [ -z "$CLAUDE_MODEL" ]; then
  CLAUDE_MODEL=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.claudeModel")
fi
if [ -z "$CLAUDE_MODEL" ]; then
  CLAUDE_MODEL=$(counsel_json_get "$CONFIG_FILE" agents.claude.model)
fi
if [ -z "$CODEX_MODEL" ]; then
  CODEX_MODEL=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.codexModel")
fi
if [ -z "$CODEX_MODEL" ]; then
  CODEX_MODEL=$(counsel_json_get "$CONFIG_FILE" agents.codex.model)
fi
if [ -z "$CODEX_MODEL" ] && [ -f "${HOME}/.codex/config.toml" ]; then
  CODEX_MODEL=$(sed -n 's/^model *= *"\(.*\)"/\1/p' "${HOME}/.codex/config.toml" | head -1)
fi
if [ -z "$CODEX_EFFORT" ]; then
  CODEX_EFFORT=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.codexEffort")
fi
[ -z "$CODEX_EFFORT" ] && CODEX_EFFORT="high"
GROK_MODEL=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.grokModel")
GROK_EFFORT=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.grokEffort")
AGY_MODEL=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.agyModel")
if [ "$TIMEOUT_SET" -eq 0 ]; then
  _t=$(counsel_json_get "$CONFIG_FILE" "effort.${EFFORT}.timeout")
  [ -n "$_t" ] && TIMEOUT="$_t"
  unset _t
fi
USE_USER_CONFIG=$(counsel_json_get "$CONFIG_FILE" agents.codex.useUserConfig)
[ -z "$USE_USER_CONFIG" ] && USE_USER_CONFIG="false"

TIMEOUT_CMD="timeout"
TIMEOUT_KILL_ARGS=()
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
  else
    TIMEOUT_CMD=""
    echo "Warning: neither 'timeout' nor 'gtimeout' found — agents will run without time limits." >&2
  fi
fi
if [ -n "$TIMEOUT_CMD" ] && "$TIMEOUT_CMD" --help 2>&1 | grep -q -- '--kill-after'; then
  # Codex can ignore SIGTERM and keep writing a 500KB transcript.
  TIMEOUT_KILL_ARGS=(--signal=TERM --kill-after=15s)
fi

run_with_timeout() {
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "${TIMEOUT_KILL_ARGS[@]}" "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

# agy can leave its stdio MCP servers running after it exits (seen on 1.1.x),
# and they pile up until agy's own /mcp reload fails. Matching their command
# lines across the whole machine missed `npx -y pkg` (pattern "-y") and could
# hit another tool's processes, so find them by ancestry: record agy's process
# tree while it runs, then reap only what this run started.
#
#   agy_tree watch ROOT_PID RECORD
#     Append ROOT's descendants to RECORD ("pid start ppid command") until
#     ROOT is gone.
#   agy_tree orphans RECORD CONFIG WORKSPACE
#     Print the PIDs to reap: each recorded process whose command names a
#     stdio server in CONFIG and whose recorded parent has exited, plus its
#     recorded descendants, if still running. Commands holding WORKSPACE are
#     our own launch chain (timeout, agy) and never count as servers, so the
#     walk cannot pass through agy to its own helpers such as --bg-updater.
#     A helper whose own command names a server still counts as one.
agy_tree() {
  python3 - "$@" <<'PY' 2>/dev/null || true
import json, os, subprocess, sys, time

def table():
    """pid -> (ppid, start, command). Start time tells a reused PID apart."""
    try:
        # -ww: procps cuts the command to $COLUMNS even into a pipe.
        out = subprocess.run(["ps", "-ww", "-A", "-o", "pid=,ppid=,lstart=,command="],
                             capture_output=True, text=True,
                             env=dict(os.environ, LC_ALL="C")).stdout
    except Exception:
        return {}
    rows = {}
    for line in out.splitlines():
        f = line.split(None, 7)
        if len(f) < 7 or not f[0].isdigit() or not f[1].isdigit():
            continue
        rows[int(f[0])] = (int(f[1]), " ".join(f[2:7]), f[7] if len(f) > 7 else "")
    return rows

def watch(root, record):
    seen, root_start = set(), None
    with open(record, "a") as out:
        while True:
            rows = table()
            if root not in rows:
                return
            # A new start time means ROOT's PID now belongs to another process.
            if root_start is None:
                root_start = rows[root][1]
            elif rows[root][1] != root_start:
                return
            kids = {}
            for pid, (ppid, _, _) in rows.items():
                kids.setdefault(ppid, []).append(pid)
            # Linux ps reads /proc one process at a time, so a snapshot can
            # hold a parent loop; visit each PID once.
            todo, tree, found = [root], [], {root}
            while todo:
                for kid in kids.get(todo.pop(), []):
                    if kid not in found:
                        found.add(kid)
                        tree.append(kid)
                        todo.append(kid)
            for pid in tree:
                ppid, start, cmd = rows[pid]
                if (pid, start, cmd) not in seen:
                    seen.add((pid, start, cmd))
                    out.write(f"{pid}\t{start}\t{ppid}\t{cmd}\n")
            out.flush()
            time.sleep(0.5)

def orphans(record, config, workspace):
    names = set()
    try:
        servers = (json.load(open(config)).get("mcpServers") or {}).values()
    except Exception:
        servers = []
    for s in servers:
        if not isinstance(s, dict) or not s.get("command"):
            continue
        names.add(os.path.basename(str(s["command"])))
        for arg in s.get("args") or []:
            # Flags such as -y say nothing about which server this is.
            names.update(t for t in str(arg).split() if not t.startswith("-"))
    procs = {}
    with open(record) as f:
        for line in f:
            p = line.rstrip("\n").split("\t", 3)
            if len(p) == 4 and p[0].isdigit() and p[2].isdigit():
                procs.setdefault((int(p[0]), p[1]), [int(p[2]), set()])[1].add(p[3])
    now = table()
    def running(key):
        return key[0] in now and now[key[0]][1] == key[1]
    def is_server(key):
        cmds = procs[key][1] | ({now[key[0]][2]} if running(key) else set())
        if any(workspace in cmd for cmd in cmds):
            return False
        return any(t in names or os.path.basename(t) in names
                   for cmd in cmds for t in cmd.split())
    kids = {}
    for key, (ppid, _) in procs.items():
        kids.setdefault(ppid, []).append(key)
    # A server whose parent is gone, even one that has exited itself: a
    # wrapper such as `npm exec` can die and leave the real server running.
    todo = [key for key, (ppid, _) in procs.items()
            if is_server(key) and not any(running(p) for p in procs if p[0] == ppid)]
    seen, reap = set(), []
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        if running(key):
            reap.append(key[0])
        todo.extend(kids.get(key[0], []))
    for pid in sorted(reap):
        print(pid)

if sys.argv[1] == "watch":
    watch(int(sys.argv[2]), sys.argv[3])
elif sys.argv[1] == "orphans":
    orphans(sys.argv[2], sys.argv[3], sys.argv[4])
PY
}

# SIGKILL: at least some MCP servers ignore SIGTERM.
# $1 = record written by `agy_tree watch`, $2 = this run's agy workspace
reap_agy_mcp_orphans() {
  local record="$1" workspace="$2" pid
  [ -s "$record" ] || return 0
  for pid in $(agy_tree orphans "$record" "$HOME/.gemini/config/mcp_config.json" "$workspace"); do
    kill -9 "$pid" 2>/dev/null || true
  done
}

write_plan() {
  local agent="$1"
  shift
  {
    printf 'cwd=%q\n' "$PWD"
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      printf 'CLAUDE_CONFIG_DIR=%q\n' "$CLAUDE_CONFIG_DIR"
    fi
    printf 'prompt_file=%q\n' "$PROMPT_FILE"
    printf 'stdin=prompt-file\n'
    printf 'argv='
    printf '%q ' "$@"
    printf '\n'
  } > "$OUTPUT_DIR/$agent.cmd"
}

# Short failure into $agent.md — never dump the user prompt.
write_failure() {
  local agent="$1" rc="$2" error_file="$3" output_file="$4"
  local msg="" line

  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    msg="timed out after ${TIMEOUT}s (no final review). Session log: ${agent}.err"
  else
    if [ -s "$error_file" ]; then
      line=""
      # Grok refusing to start without its sandbox reports "sandbox: <cause>".
      # The cause is on a warning line; the error line only says "see the
      # warning above", which a one-line summary loses. Grok only, and exact
      # line starts: other agents' logs hold the prompt and the commands they
      # ran, which can quote these phrases.
      if [ "$agent" = grok ]; then
        line=$(grep -E -m1 '^warning: sandbox could not be applied: ' "$error_file" | sed -E 's/^warning: sandbox could not be applied: //' || true)
        if [ -z "$line" ]; then
          line=$(grep -E -m1 "^error: could not apply the '[^']*' sandbox profile" "$error_file" || true)
        fi
      fi
      if [ -n "$line" ]; then
        line="sandbox: $line"
      else
        line=$(grep -E -m1 -i '^(error:|Error:|ERROR |You.ve hit|authentication required|unexpected argument)' "$error_file" || true)
      fi
      if [ -z "$line" ]; then
        line=$(grep -E -m1 -i 'weekly limit|rate limit|permission denied|authentication required' "$error_file" || true)
      fi
      if [ -n "$line" ]; then
        msg=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-240)
      fi
    fi
    if [ -z "$msg" ]; then
      if [ "$rc" != 0 ]; then
        msg="exited ${rc} with no review. See ${agent}.err"
      else
        msg="produced no review. See ${agent}.err"
      fi
    fi
  fi
  printf 'Skipped/failed: %s — %s\n' "$agent" "$msg" > "$output_file"
}

looks_like_review() {
  counsel_looks_like_review "$1" "$PROMPT_FILE"
}

finalize_output() {
  local agent="$1" rc="$2"
  local output_file="$OUTPUT_DIR/$agent.md"
  local error_file="$OUTPUT_DIR/$agent.err"

  if looks_like_review "$output_file"; then
    return 0
  fi
  write_failure "$agent" "$rc" "$error_file" "$output_file"
}

# Run a single agent review (always read-only).
# $1 = agent name
run_agent() {
  local agent="$1"
  local output_file="$OUTPUT_DIR/$agent.md"
  local error_file="$OUTPUT_DIR/$agent.err"
  local rc=0

  : > "$error_file"
  : > "$output_file"

  case "$agent" in
    codex)
      # `codex exec --full-auto` was removed in 0.147 (errors out).
      # -s read-only is enforced. Default --ignore-user-config drops the user's
      # MCP servers; -c mcp_servers={} MERGES and does not clear them.
      # --output-last-message writes the review; stdout/stderr is the session log.
      # Prompt via stdin (the trailing `-`), never as a quoted argv blob.
      local codex_cmd=(
        codex exec
        --ephemeral
        --color never
        --output-last-message "$output_file"
        -s read-only
        --skip-git-repo-check
        -c "model_reasoning_effort=\"${CODEX_EFFORT}\""
      )
      if [ "$USE_USER_CONFIG" != "true" ]; then
        codex_cmd+=(--ignore-user-config)
      fi
      if [ -n "$CODEX_MODEL" ]; then
        codex_cmd+=(-m "$CODEX_MODEL")
      fi
      codex_cmd+=(-)
      if [ "$DRY_RUN" -eq 1 ]; then
        ( cd "$REPO_DIR" && write_plan "$agent" "${codex_cmd[@]}" )
        echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        return 0
      fi
      ( cd "$REPO_DIR" && run_with_timeout "${codex_cmd[@]}" < "$PROMPT_FILE" > "$OUTPUT_DIR/$agent.stdout" 2> "$error_file" ) || rc=$?
      if [ -s "$OUTPUT_DIR/$agent.stdout" ]; then
        cat "$OUTPUT_DIR/$agent.stdout" >> "$error_file"
      fi
      ;;

    antigravity)
      # Google Antigravity CLI (binary `agy`). See the strategy note in git
      # history: do not "fix" this back to a fake HOME or workspace permission
      # files.
      #
      # Confirmed 2026-08-18 (agy 1.1.14): print mode ignores the launch cwd.
      # `--add-dir` is the workspace / tool cwd. Launching from a throwaway
      # dir with only `--add-dir $REPO` makes agy look for ./REVIEW_PROMPT.md
      # in the repo, miss it, and either ask the user (exit 0, empty stderr)
      # or search until --print-timeout.
      #
      # Prompt delivery that does not work:
      #   * `-p ""` + prompt on stdin — "Error: empty prompt".
      #   * bare stdin, no -p — interactive hang.
      #   * `-p "$(< file)"` — works, but risks ARG_MAX (1MB on macOS).
      # Durable handoff: write the prompt into the throwaway workspace, pass
      # that dir as the first --add-dir, name the file by absolute path in
      # -p, and --add-dir the repo (plus any extra --add-dir) so the review
      # can still read the tree.
      # Remote MCP often fails to connect. Still launch. Prepend connected vs
      # disconnected servers so the agent does not stall on a dead server.
      local agy_ws="$OUTPUT_DIR/.agy-ws-$agent"
      local agy_pt=$(( TIMEOUT > 30 ? TIMEOUT - 15 : TIMEOUT ))
      local agy_record="$OUTPUT_DIR/.agy-tree-$agent"
      local agy_prompt="$PROMPT_FILE"
      local agy_connected agy_missing extra agy_pid watch_pid
      mkdir -p "$agy_ws"
      agy_connected=$(counsel_antigravity_connected | paste -sd, -)
      agy_missing=$(counsel_antigravity_disconnected | paste -sd, -)
      if [ -n "$agy_missing" ] || [ -n "$agy_connected" ]; then
        agy_prompt="$OUTPUT_DIR/.agy-prompt.md"
        {
          echo "MCP availability for this agent (Antigravity remote servers often fail to connect):"
          echo "Connected: ${agy_connected:-none}"
          echo "Configured but not connected: ${agy_missing:-none}"
          echo "Do not call disconnected servers. Review with the prompt and connected tools only."
          echo
          echo "---"
          echo
          cat "$PROMPT_FILE"
        } > "$agy_prompt"
      fi
      cp "$agy_prompt" "$agy_ws/REVIEW_PROMPT.md"
      local agy_cmd=(
        agy
        -p "Read the file ${agy_ws}/REVIEW_PROMPT.md and follow its instructions exactly. Output only what it asks for. Do not mention the file itself."
        --add-dir "$agy_ws"
        --add-dir "$REPO_DIR"
        --dangerously-skip-permissions
        --disable-slash-commands
        --print-timeout "${agy_pt}s"
      )
      for extra in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
        agy_cmd+=(--add-dir "$extra")
      done
      if [ -n "$AGY_MODEL" ]; then
        agy_cmd+=(--model "$AGY_MODEL")
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        ( cd "$agy_ws" && write_plan "$agent" "${agy_cmd[@]}" )
        echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        [ -n "$agy_missing" ] && echo "  MCP not connected: $agy_missing (still launching)" >> "$output_file"
        return 0
      fi
      : > "$agy_record"
      ( cd "$agy_ws" && run_with_timeout "${agy_cmd[@]}" < /dev/null ) > "$output_file" 2> "$error_file" &
      agy_pid=$!
      # Own stdio: if run-review.sh is killed, the watcher must not hold the
      # caller's pipe open until agy exits.
      agy_tree watch "$agy_pid" "$agy_record" </dev/null >/dev/null 2>&1 &
      watch_pid=$!
      wait "$agy_pid" || rc=$?
      wait "$watch_pid" 2>/dev/null || true
      reap_agy_mcp_orphans "$agy_record" "$agy_ws"
      rm -f "$agy_record"
      if looks_like_review "$output_file"; then
        rm -rf "$agy_ws"
      else
        printf 'Kept throwaway workspace for inspection: %s\n' "$agy_ws" >> "$error_file"
      fi
      ;;

    grok)
      local grok_cmd=(
        grok
        --prompt-file "$PROMPT_FILE"
        --sandbox read-only
        --yolo
        --disallowed-tools "search_replace,write"
      )
      if [ -n "$GROK_MODEL" ]; then
        grok_cmd+=(--model "$GROK_MODEL")
      fi
      if [ -n "$GROK_EFFORT" ]; then
        grok_cmd+=(--reasoning-effort "$GROK_EFFORT")
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        write_plan "$agent" "${grok_cmd[@]}"
        echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        return 0
      fi
      ( cd "$REPO_DIR" && run_with_timeout "${grok_cmd[@]}" ) > "$output_file" 2> "$error_file" || rc=$?
      ;;

    gemini)
      # LEGACY — Gemini CLI stopped serving personal accounts on 2026-06-18.
      local gemini_cmd=(
        gemini -p "" --allowed-mcp-server-names none --raw-output --accept-raw-output-risk
      )
      if [ "$DRY_RUN" -eq 1 ]; then
        write_plan "$agent" "${gemini_cmd[@]}"
        echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        return 0
      fi
      run_with_timeout "${gemini_cmd[@]}" < "$PROMPT_FILE" > "$output_file" 2> "$error_file" || rc=$?
      ;;

    claude)
      # CLAUDE_CONFIG_DIR is the chosen profile (host skill + --claude-config-dir).
      # Never invoke a shell function named `claude` — use the resolved binary.
      # Prompt via stdin: `claude -p "$(< file)"` fails with
      # "Input must be provided either through stdin or as a prompt argument".
      # Launch from a neutral cwd so repo-relative extra CA files are not read.
      if [ -z "$CLAUDE_BIN" ]; then
        echo "claude binary not found on PATH" > "$error_file"
        finalize_output "$agent" 127
        return 0
      fi
      local claude_cmd=(
        "$CLAUDE_BIN"
        -p ""
        --permission-mode auto
      )
      if [ -n "$CLAUDE_MODEL" ]; then
        claude_cmd+=(--model "$CLAUDE_MODEL")
      fi
      claude_cmd+=(--add-dir "$REPO_DIR")
      local extra
      for extra in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
        claude_cmd+=(--add-dir "$extra")
      done
      claude_cmd+=(--disallowed-tools "Edit,Write,NotebookEdit")
      if [ "$DRY_RUN" -eq 1 ]; then
        CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_RESOLVED" write_plan "$agent" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_RESOLVED" "${claude_cmd[@]}"
        echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        return 0
      fi
      (
        cd "$LAUNCH_DIR"
        CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR_RESOLVED" \
          run_with_timeout "${claude_cmd[@]}" < "$PROMPT_FILE"
      ) > "$output_file" 2> "$error_file" || rc=$?
      ;;

    *)
      echo "Unknown agent: $agent" > "$error_file"
      rc=1
      ;;
  esac

  finalize_output "$agent" "$rc"
  return 0
}

# Extract enabled agents from config using jq (preferred) or python3 (fallback)
if command -v jq &>/dev/null; then
  ENABLED_AGENTS=$(jq -r '.agents | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" 2>/dev/null)
elif command -v python3 &>/dev/null; then
  ENABLED_AGENTS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    config = json.load(f)
agents = config.get('agents', {})
for name, settings in agents.items():
    if settings.get('enabled', False):
        print(name)
" "$CONFIG_FILE" 2>/dev/null)
else
  echo "Error: neither 'jq' nor 'python3' found — cannot parse config file." >&2
  echo '{"output_dir": "'"$OUTPUT_DIR"'", "agents_requested": 0, "agents_responded": 0, "reviews": []}'
  exit 1
fi

if [ -z "$ENABLED_AGENTS" ]; then
  echo "No agents enabled in config." >&2
  echo '{"output_dir": "'"$OUTPUT_DIR"'", "agents_requested": 0, "agents_responded": 0, "reviews": []}'
  exit 0
fi

echo "Counsel: Starting parallel reviews..." >&2
echo "  Effort: $EFFORT" >&2
echo "  Claude profile: $CLAUDE_CONFIG_DIR_RESOLVED" >&2
[ -n "$CLAUDE_MODEL" ] && echo "  Claude model: $CLAUDE_MODEL" >&2
echo "  Codex effort: $CODEX_EFFORT" >&2
[ "$DRY_RUN" -eq 1 ] && echo "  Mode: dry-run" >&2

while IFS= read -r agent_name; do
  [ -z "$agent_name" ] && continue

  if counsel_list_contains "$EXCLUDE_AGENTS" "$agent_name"; then
    echo "  Skipping $agent_name (handled by host agent)" >&2
    continue
  fi

  if [ -n "$ONLY_AGENTS" ] && ! counsel_list_contains "$ONLY_AGENTS" "$agent_name"; then
    continue
  fi

  agent_bin=$(counsel_agent_binary "$agent_name")
  if ! command -v "$agent_bin" &>/dev/null; then
    echo "  Skipping $agent_name ($agent_bin not installed)" >&2
    continue
  fi

  if [ "$agent_name" = "antigravity" ]; then
    agy_missing=$(counsel_antigravity_disconnected | paste -sd, -)
    if [ -n "$agy_missing" ]; then
      echo "  antigravity: MCP not connected (${agy_missing}); launching anyway" >&2
    fi
  fi

  echo "  Starting $agent_name (read-only)..." >&2

  run_agent "$agent_name" &
  PIDS+=($!)
  AGENTS+=("$agent_name")
done <<< "$ENABLED_AGENTS"

if [ ${#PIDS[@]} -gt 0 ]; then
  echo "  Waiting for ${#PIDS[@]} agent(s)..." >&2
  RESULTS=()
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" 2>/dev/null || true
    agent="${AGENTS[$i]}"
    output_file="$OUTPUT_DIR/$agent.md"
    if looks_like_review "$output_file"; then
      RESULTS+=("$agent")
      echo "  $agent: done" >&2
    else
      echo "  $agent: no review" >&2
    fi
  done
else
  echo "  No agents launched (all skipped or not installed)." >&2
  RESULTS=()
fi

echo "" >&2
echo "Reviews complete. ${#RESULTS[@]}/${#AGENTS[@]} agents responded." >&2
echo "Output directory: $OUTPUT_DIR" >&2

echo "{"
echo "  \"output_dir\": \"$OUTPUT_DIR\","
echo "  \"agents_requested\": ${#AGENTS[@]},"
echo "  \"agents_responded\": ${#RESULTS[@]},"
echo "  \"effort\": \"$EFFORT\","
echo "  \"claude_config_dir\": \"$CLAUDE_CONFIG_DIR_RESOLVED\","
echo "  \"reviews\": ["
for i in "${!RESULTS[@]}"; do
  [ "$i" -gt 0 ] && echo ","
  echo -n "    {\"agent\": \"${RESULTS[$i]}\", \"file\": \"$OUTPUT_DIR/${RESULTS[$i]}.md\"}"
done
echo ""
echo "  ]"
echo "}"
