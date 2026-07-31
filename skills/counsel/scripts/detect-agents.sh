#!/usr/bin/env bash
# Detect available coding agent CLIs and their capabilities
# Output: JSON object with detected agents
#
# Agent name != binary name. Google's Antigravity CLI ships the binary `agy`,
# and Gemini CLI (its predecessor) is retired for personal accounts as of
# 2026-06-18 — it is still detected so machines that haven't migrated keep
# working, but it will report installed:false once uninstalled.

set -euo pipefail

# Registry: <agent-name>|<binary>|<version-command>
AGENT_REGISTRY=(
  "codex|codex|codex --version"
  "antigravity|agy|agy --version"
  "gemini|gemini|gemini --version"
  "claude|claude|echo skipped"
)

detect_agent() {
  local name="$1"
  local cmd="$2"
  local version_cmd="$3"

  if command -v "$cmd" &>/dev/null; then
    local version
    version=$($version_cmd 2>/dev/null | head -1 || echo "unknown")
    echo "\"$name\": {\"installed\": true, \"binary\": \"$cmd\", \"version\": \"$version\", \"path\": \"$(command -v "$cmd")\"}"
  else
    echo "\"$name\": {\"installed\": false, \"binary\": \"$cmd\"}"
  fi
}

# Detect each agent
AGENTS=()
for entry in "${AGENT_REGISTRY[@]}"; do
  IFS='|' read -r name binary version_cmd <<< "$entry"
  AGENTS+=("$(detect_agent "$name" "$binary" "$version_cmd")")
done

# Build JSON with proper comma handling
echo "{"
for i in "${!AGENTS[@]}"; do
  if [ "$i" -lt $(( ${#AGENTS[@]} - 1 )) ]; then
    echo "  ${AGENTS[$i]},"
  else
    echo "  ${AGENTS[$i]}"
  fi
done
echo "}"
