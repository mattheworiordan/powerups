#!/usr/bin/env bash
# Detect available coding agent CLIs and their capabilities
# Output: JSON object with detected agents

set -euo pipefail

detect_agent() {
  local name="$1"
  local cmd="$2"
  local version_cmd="$3"

  if command -v "$cmd" &>/dev/null; then
    local version
    version=$($version_cmd 2>/dev/null | head -1 || echo "unknown")
    echo "\"$name\": {\"installed\": true, \"version\": \"$version\", \"path\": \"$(command -v "$cmd")\"}"
  else
    echo "\"$name\": {\"installed\": false}"
  fi
}

# Detect each agent
AGENTS=()
AGENTS+=("$(detect_agent "codex" "codex" "codex --version")")
AGENTS+=("$(detect_agent "gemini" "gemini" "gemini --version")")
AGENTS+=("$(detect_agent "claude" "claude" "echo skipped")")

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
