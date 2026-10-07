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

CLAUDE_CONFIG_DIR_RESOLVED=$(counsel_local_claude_config_dir "$CONFIG_FILE" "$CLAUDE_CONFIG_OVERRIDE")

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

  if [ "$rc" -eq 0 ] && looks_like_review "$output_file"; then
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
    codex|grok|claude|antigravity)
      local caller_cmd=(
        python3 "$(counsel_agent_caller)"
        --agent "$agent"
        --prompt-file "$PROMPT_FILE"
        --cwd "$REPO_DIR"
        --output-dir "$OUTPUT_DIR/$agent.call"
        --mode read-only
        --timeout "$TIMEOUT"
      )
      case "$agent" in
        codex)
          [ -n "$CODEX_MODEL" ] && caller_cmd+=(--model "$CODEX_MODEL")
          caller_cmd+=(--reasoning-effort "$CODEX_EFFORT")
          [ "$USE_USER_CONFIG" = true ] && caller_cmd+=(--use-user-config)
          ;;
        grok)
          [ -n "$GROK_MODEL" ] && caller_cmd+=(--model "$GROK_MODEL")
          [ -n "$GROK_EFFORT" ] && caller_cmd+=(--reasoning-effort "$GROK_EFFORT")
          ;;
        antigravity)
          [ -n "$AGY_MODEL" ] && caller_cmd+=(--model "$AGY_MODEL")
          ;;
        claude)
          caller_cmd+=(--claude-config-dir "$CLAUDE_CONFIG_DIR_RESOLVED")
          [ -n "$CLAUDE_MODEL" ] && caller_cmd+=(--model "$CLAUDE_MODEL")
          ;;
      esac
      if [ "$agent" = claude ] || [ "$agent" = antigravity ]; then
        local extra
        for extra in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
          caller_cmd+=(--add-dir "$extra")
        done
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        "${caller_cmd[@]}" --dry-run > "$OUTPUT_DIR/$agent.cmd" 2> "$error_file" || rc=$?
        if [ "$rc" -eq 0 ]; then
          echo "dry-run: would launch $agent (see ${agent}.cmd)" > "$output_file"
        else
          write_failure "$agent" "$rc" "$error_file" "$output_file"
        fi
        return 0
      fi
      local call_was_present=0
      [ -e "$OUTPUT_DIR/$agent.call" ] && call_was_present=1
      "${caller_cmd[@]}" > "$output_file" 2> "$OUTPUT_DIR/$agent.caller.err" &
      local caller_pid=$!
      # run_agent is a background shell. Forward cancellation to its caller,
      # which owns and reaps the native CLI process group.
      trap 'kill -TERM "$caller_pid" 2>/dev/null || true; wait "$caller_pid" 2>/dev/null || true; exit 130' INT TERM
      wait "$caller_pid" || rc=$?
      trap - INT TERM
      # Preserve native diagnostics before the caller's short error summary.
      if [ "$call_was_present" -eq 0 ] && [ -f "$OUTPUT_DIR/$agent.call/stderr.txt" ]; then
        cat "$OUTPUT_DIR/$agent.call/stderr.txt" > "$error_file"
      fi
      cat "$OUTPUT_DIR/$agent.caller.err" >> "$error_file"
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
  case "$agent_name" in
    claude|codex|grok|antigravity) ;;
    *) echo "  Ignoring unsupported agent: $agent_name" >&2; continue ;;
  esac

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
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  $agent: launch plan written" >&2
    elif looks_like_review "$output_file"; then
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
