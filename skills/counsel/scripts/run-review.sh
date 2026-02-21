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
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ -z "$PROMPT_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
  echo "Usage: run-review.sh --config <file> --prompt-file <file> --output-dir <dir>" >&2
  exit 1
fi

[ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 1; }
[ -f "$PROMPT_FILE" ] || { echo "Prompt file not found: $PROMPT_FILE" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

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
      run_with_timeout codex exec --full-auto - < "$PROMPT_FILE" > "$output_file" 2> "$error_file" || true
      ;;
    gemini)
      # -p for non-interactive mode; --allowed-mcp-server-names none disables MCP
      # servers (prevents off-script context pollution); without --yolo, Gemini cannot
      # auto-approve tool calls so it's effectively read-only
      run_with_timeout gemini -p "$(< "$PROMPT_FILE")" --allowed-mcp-server-names none > "$output_file" 2> "$error_file" || true
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

  # Check if agent CLI exists
  if ! command -v "$agent_name" &>/dev/null; then
    echo "  Skipping $agent_name (not installed)" >&2
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
