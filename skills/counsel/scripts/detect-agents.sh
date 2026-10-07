#!/usr/bin/env bash
# Detect available coding agent CLIs and their capabilities
# Output: JSON object with detected agents
# --local-caller omits profile inventories and uses only the personal Claude binary.
#
# Antigravity CLI uses the binary `agy`.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

LOCAL_CALLER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-caller) LOCAL_CALLER=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Registry: <agent-name>|<binary>|<version-command>
AGENT_REGISTRY=(
  "codex|codex|codex --version"
  "antigravity|agy|agy --version"
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
  if [ "$name" = claude ] && [ "$LOCAL_CALLER" -eq 1 ]; then
    cmd=$(counsel_agent_binary claude)
  fi

  if command -v "$cmd" &>/dev/null; then
    local version
    if [ "$name" = claude ] && [ "$LOCAL_CALLER" -eq 1 ]; then
      local auth_home
      auth_home=$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
      version=$(HOME="$auth_home" CLAUDE_CONFIG_DIR="$auth_home/.claude-personal" "$cmd" --safe-mode --version 2>/dev/null | head -1 || echo "unknown")
    else
      version=$($version_cmd 2>/dev/null | head -1 || echo "unknown")
    fi
    version=${version//$'\n'/ }
    printf '"%s": {"installed": true, "binary": "%s", "version": %s, "path": %s' \
      "$name" "$cmd" "$(json_escape "$version")" "$(json_escape "$(command -v "$cmd")")"
    if [ "$name" = "claude" ] && [ "$LOCAL_CALLER" -eq 0 ]; then
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
