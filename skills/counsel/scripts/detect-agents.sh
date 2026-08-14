#!/usr/bin/env bash
# Detect available coding agent CLIs and their capabilities
# Output: JSON object with detected agents
#
# Agent name != binary name. Google's Antigravity CLI ships the binary `agy`,
# and Gemini CLI (its predecessor) is retired for personal accounts as of
# 2026-06-18 — it is still detected so machines that haven't migrated keep
# working, but it will report installed:false once uninstalled.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Registry: <agent-name>|<binary>|<version-command>
AGENT_REGISTRY=(
  "codex|codex|codex --version"
  "antigravity|agy|agy --version"
  "gemini|gemini|gemini --version"
  "grok|grok|grok --version"
  "claude|claude|command claude --version"
)

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

detect_agent() {
  local name="$1"
  local cmd="$2"
  local version_cmd="$3"

  if command -v "$cmd" &>/dev/null; then
    local version
    version=$($version_cmd 2>/dev/null | head -1 || echo "unknown")
    version=${version//$'\n'/ }
    printf '"%s": {"installed": true, "binary": "%s", "version": %s, "path": %s' \
      "$name" "$cmd" "$(json_escape "$version")" "$(json_escape "$(command -v "$cmd")")"
    if [ "$name" = "claude" ]; then
      local dir id first=1
      printf ', "profiles": ['
      while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        id=$(counsel_claude_profile_id "$dir")
        [ "$first" -eq 1 ] || printf ', '
        first=0
        printf '{"id": %s, "dir": %s}' "$(json_escape "$id")" "$(json_escape "$dir")"
      done < <(counsel_detected_claude_dirs)
      printf ']'
    fi
    printf '}'
    echo
  else
    echo "\"$name\": {\"installed\": false, \"binary\": \"$cmd\"}"
  fi
}

AGENTS=()
for entry in "${AGENT_REGISTRY[@]}"; do
  IFS='|' read -r name binary version_cmd <<< "$entry"
  AGENTS+=("$(detect_agent "$name" "$binary" "$version_cmd")")
done

echo "{"
for i in "${!AGENTS[@]}"; do
  if [ "$i" -lt $(( ${#AGENTS[@]} - 1 )) ]; then
    echo "  ${AGENTS[$i]},"
  else
    echo "  ${AGENTS[$i]}"
  fi
done
echo "}"
