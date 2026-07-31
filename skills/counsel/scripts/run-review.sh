#!/usr/bin/env bash
# Orchestrate parallel agent reviews (external CLI agents only)
# When running from Claude Code, pass --exclude claude (it uses Task() sub-agent instead)
#
# All agents run in READ-ONLY mode — no writes, no state changes.
#
# Usage: run-review.sh --config <config-file> --prompt-file <prompt-file> --output-dir <output-dir>

set -euo pipefail

# Initialize arrays before trap (prevents bash 3.x set -u errors if signal arrives early)
PIDS=()
AGENTS=()

# Clean up background processes on exit/interrupt
cleanup() {
  if [ ${#PIDS[@]} -gt 0 ]; then
    for pid in "${PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT INT TERM

# Parse arguments
CONFIG_FILE=""
PROMPT_FILE=""
OUTPUT_DIR=""
TIMEOUT=300  # 5 minutes default
EXCLUDE_AGENT=""
ONLY_AGENTS=""  # comma-separated list of agents to run (empty = all enabled)

# Helper: assert that the current option has a value argument
require_value() {
  if [ $# -lt 2 ]; then
    echo "Error: $1 requires a value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --config)      require_value "$@"; CONFIG_FILE="$2"; shift 2 ;;
    --prompt-file) require_value "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --output-dir)  require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --timeout)     require_value "$@"; TIMEOUT="$2"; shift 2 ;;
    --exclude)     require_value "$@"; EXCLUDE_AGENT="$2"; shift 2 ;;
    --agents)      require_value "$@"; ONLY_AGENTS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$PROMPT_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: run-review.sh --config <file> --prompt-file <file> --output-dir <dir> [--agents codex,antigravity]" >&2
  exit 1
fi

[ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }
[ -f "$PROMPT_FILE" ] || { echo "Prompt file not found: $PROMPT_FILE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

# The directory under review — captured before any agent changes directory.
REPO_DIR="$PWD"

# macOS doesn't have `timeout` — use gtimeout from coreutils if available, otherwise fallback
TIMEOUT_CMD="timeout"
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
  else
    TIMEOUT_CMD=""
    echo "Warning: neither 'timeout' nor 'gtimeout' found — agents will run without time limits." >&2
  fi
fi

run_with_timeout() {
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Map an agent name to the binary that implements it. These differ: Google's
# Antigravity CLI installs as `agy`, not `antigravity`.
agent_binary() {
  case "$1" in
    antigravity) echo "agy" ;;
    *)           echo "$1" ;;
  esac
}

# Antigravity invocation strategy — verified 2026-07-31.
#
# `agy` runs from a throwaway workspace with the repo added read-only via
# --add-dir, so it can explore the codebase like the other agents while its own
# scratch output lands in a directory we delete.
#
# Read-only is enforced at the PROMPT level here, exactly as it is for Codex
# (`--full-auto` is a sandbox, not a read-only mode) and for the Claude
# sub-agent. Antigravity exposes no per-invocation read-only mode: --mode plan
# only steers tool selection, and permission `allow` rules in a workspace
# .agents/settings.json are ignored. Dropping --add-dir restores hard
# containment (the repo leaves scope entirely) at the cost of a much weaker
# review — that trade was made deliberately in favour of comparable agents.
#
# Tried and does NOT work — do not "fix" this back:
#   * Throwaway $HOME + permissions.deny write_file(*): auth is bound to the real
#     HOME, so the run dies with "authentication required". Copying
#     jetski_state.pbtxt / installation_id into the fake HOME does not help.
#   * Workspace .agents/settings.json permission rules: `allow` entries are NOT
#     honoured there — mcp(*) and even an exact mcp(matt-os/getMattContext)
#     target still get auto-denied.
#   * Workspace .agents/mcp_config.json with empty mcpServers: does not override
#     the global ~/.gemini/config/mcp_config.json.
#
# Why --dangerously-skip-permissions is correct HERE and only here: the user's
# global ~/.gemini/GEMINI.md mandates an MCP getMattContext call as the agent's
# first action. Headless mode cannot approve it interactively, so it is
# auto-denied — and the agent then STALLS and returns an EMPTY review. Allowing
# tool calls lets the run complete. The repo stays safe because it is outside the
# workspace, not because of a permission rule.

# Run a single agent review (always read-only)
# $1 = agent name
run_agent() {
  local agent="$1"
  local output_file="$OUTPUT_DIR/$agent.md"
  local error_file="$OUTPUT_DIR/$agent.err"

  case "$agent" in
    codex)
      # Use `codex exec` for custom prompt reviews (non-interactive, sandboxed).
      # Falls back to `codex exec review` for code-only reviews when no prompt is given.
      # --full-auto enables sandboxed auto-execution; prompt is passed via stdin to
      # avoid shell quoting issues with large prompts.
      # --skip-git-repo-check allows running in directories that aren't git repos
      # (e.g. monorepo subdirectories, non-git projects).
      # -c 'mcp_servers={}' strips MCP servers for this exec — counsel reviews
      # are self-contained, and CLAUDE.md-mandated MCP context-load (e.g. matt-os
      # getMattContext) burns tokens and can timeout the review.
      run_with_timeout codex exec --full-auto --skip-git-repo-check -c 'mcp_servers={}' - < "$PROMPT_FILE" > "$output_file" 2> "$error_file" || true
      ;;
    antigravity)
      # Google Antigravity CLI (binary `agy`) — successor to Gemini CLI.
      # Runs in a throwaway workspace (see the strategy note above); the prompt
      # file carries all review context, so the agent never needs the repo.
      # --disable-slash-commands stops the prompt expanding skills mid-review.
      # agy's own print-timeout is set just under ours so it exits cleanly with a
      # partial answer instead of being SIGTERMed (its default is 5m regardless).
      # --add-dir grants READ access to the repo so this agent can explore beyond
      # the diff, matching what Codex (repo cwd) and the Claude sub-agent can do.
      # Without it the review is materially weaker — it sees only the prompt.
      # cwd stays the throwaway workspace so incidental scratch files land there.
      local agy_ws="$OUTPUT_DIR/.agy-ws-$agent"
      local agy_pt=$(( TIMEOUT > 30 ? TIMEOUT - 15 : TIMEOUT ))
      mkdir -p "$agy_ws"
      ( cd "$agy_ws" && run_with_timeout agy \
          -p "$(< "$PROMPT_FILE")" \
          --add-dir "$REPO_DIR" \
          --dangerously-skip-permissions \
          --disable-slash-commands \
          --print-timeout "${agy_pt}s" \
      ) > "$output_file" 2> "$error_file" || true
      rm -rf "$agy_ws"
      ;;
    gemini)
      # LEGACY — Gemini CLI stopped serving personal/Pro/Ultra accounts on
      # 2026-06-18 (enterprise Code Assist licences excepted). Kept so machines
      # that still have a working install keep functioning; prefer antigravity.
      # -p for non-interactive mode; --allowed-mcp-server-names none disables MCP
      # servers (prevents off-script context pollution); without --yolo, Gemini cannot
      # auto-approve tool calls so it's effectively read-only.
      # --raw-output prevents output sanitization from truncating long responses.
      # Prompt is piped via stdin and -p "" triggers headless mode — avoids shell
      # ARG_MAX limits with large prompts.
      run_with_timeout gemini -p "" --allowed-mcp-server-names none --raw-output --accept-raw-output-risk < "$PROMPT_FILE" > "$output_file" 2> "$error_file" || true
      ;;
    claude)
      # -p for non-interactive mode; prompt includes read-only instructions
      run_with_timeout claude -p "$(< "$PROMPT_FILE")" > "$output_file" 2> "$error_file" || true
      ;;
    *)
      echo "Unknown agent: $agent" > "$error_file"
      ;;
  esac

  # Check if output is empty (agent likely failed)
  if [ ! -s "$output_file" ] && [ -s "$error_file" ]; then
    echo "Agent error:" > "$output_file"
    head -20 "$error_file" >> "$output_file"
  fi
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

while IFS= read -r agent_name; do
  [ -z "$agent_name" ] && continue

  # Skip excluded agent (e.g., claude when running from Claude Code)
  if [ -n "$EXCLUDE_AGENT" ] && [ "$agent_name" = "$EXCLUDE_AGENT" ]; then
    echo "  Skipping $agent_name (handled by host agent)" >&2
    continue
  fi

  # If --agents filter is set, only run agents in the list
  if [ -n "$ONLY_AGENTS" ] && [[ ",$ONLY_AGENTS," != *",$agent_name,"* ]]; then
    continue
  fi

  # Check if agent CLI exists (name != binary for some agents, e.g. antigravity → agy)
  agent_bin=$(agent_binary "$agent_name")
  if ! command -v "$agent_bin" &>/dev/null; then
    echo "  Skipping $agent_name ($agent_bin not installed)" >&2
    continue
  fi

  echo "  Starting $agent_name (read-only)..." >&2

  run_agent "$agent_name" &
  PIDS+=($!)
  AGENTS+=("$agent_name")
done <<< "$ENABLED_AGENTS"

# Wait for all agents
if [ ${#PIDS[@]} -gt 0 ]; then
  echo "  Waiting for ${#PIDS[@]} agent(s)..." >&2
  RESULTS=()
  for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" 2>/dev/null || true
    agent="${AGENTS[$i]}"
    output_file="$OUTPUT_DIR/$agent.md"
    if [ -s "$output_file" ]; then
      RESULTS+=("$agent")
      echo "  $agent: done" >&2
    else
      echo "  $agent: no output" >&2
    fi
  done
else
  echo "  No agents launched (all skipped or not installed)." >&2
  RESULTS=()
fi

# Report results
echo "" >&2
echo "Reviews complete. ${#RESULTS[@]}/${#AGENTS[@]} agents responded." >&2
echo "Output directory: $OUTPUT_DIR" >&2

# Output results as JSON
echo "{"
echo "  \"output_dir\": \"$OUTPUT_DIR\","
echo "  \"agents_requested\": ${#AGENTS[@]},"
echo "  \"agents_responded\": ${#RESULTS[@]},"
echo "  \"reviews\": ["
for i in "${!RESULTS[@]}"; do
  [ "$i" -gt 0 ] && echo ","
  echo -n "    {\"agent\": \"${RESULTS[$i]}\", \"file\": \"$OUTPUT_DIR/${RESULTS[$i]}.md\"}"
done
echo ""
echo "  ]"
echo "}"
