#!/usr/bin/env bash
# Compare which MCP servers each installed agent can reach.
#
# WHY: counsel's value is independent agents reaching the SAME conclusion about
# the same material. If one agent silently lacks an MCP server the others have,
# its review is weaker for a reason the user can't see — it looks like a genuine
# difference of opinion when it's really a missing capability.
#
# This is deliberately generic: it discovers whatever servers each agent has
# configured and compares them. It hardcodes no server names, so it works for
# anyone's setup, not just the author's.
#
# Claude: reads the profile run-review.sh will launch (override via
# CLAUDE_CONFIG_DIR_OVERRIDE or config). Connector display names are
# slugified so they compare with other agents' short ids.
#
# Antigravity: remote MCP often fails to connect. That is an optional
# warning. The agent still runs; the review prompt lists connected servers.
#
# Output: JSON on stdout. Non-zero exit is NOT used for disagreement — read
# `.parity` ("ok" | "mismatch") and `.warnings`. Optional skips land in
# `.optional_warnings`.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

COUNSEL_CONFIG="${COUNSEL_CONFIG:-$HOME/.config/counsel/config.json}"
CLAUDE_CONFIG_OVERRIDE="${CLAUDE_CONFIG_DIR_OVERRIDE:-}"

# --- per-agent discovery -----------------------------------------------------
# Each function prints one server name per line (empty if agent absent).

servers_claude() {
  local json settings
  json=$(counsel_claude_json "$COUNSEL_CONFIG" "$CLAUDE_CONFIG_OVERRIDE")
  [ -n "$json" ] && [ -f "$json" ] || return 0
  settings="$(dirname "$json")/settings.json"
  python3 - "$json" "$settings" "$SCRIPT_DIR/lib.sh" <<'PY'
import json, os, re, subprocess, sys

json_path, settings_path, lib = sys.argv[1], sys.argv[2], sys.argv[3]

def normalize(name):
    env = os.environ.copy()
    # Reuse the shell helper so aliases live in one place.
    out = subprocess.check_output(
        ["bash", "-c", f'source "{lib}" && counsel_normalize_mcp_name "$1"', "_", name],
        text=True,
    )
    return out.strip()

try:
    data = json.load(open(json_path))
except Exception:
    raise SystemExit(0)

names = set()
for k in (data.get("mcpServers") or {}):
    n = normalize(k)
    if n:
        names.add(n)

denied = set()
if os.path.isfile(settings_path):
    try:
        settings = json.load(open(settings_path))
    except Exception:
        settings = {}
    for item in (settings.get("deniedMcpServers") or []):
        raw = item.get("serverName") if isinstance(item, dict) else item
        if raw:
            denied.add(normalize(str(raw)))

for c in (data.get("claudeAiMcpEverConnected") or []):
    n = normalize(str(c))
    if n and n not in denied:
        names.add(n)

for n in sorted(names):
    print(n)
PY
}

servers_codex() {
  # Codex uses config.toml with [mcp_servers.<name>] sections. Match only
  # top-level entries — skip nested [mcp_servers.<name>.tools.<x>] / .env.
  [ -f "$HOME/.codex/config.toml" ] || return 0
  sed -nE 's/^\[mcp_servers\.([^].]+)\]$/\1/p' "$HOME/.codex/config.toml" 2>/dev/null | sort -u || true
}

servers_antigravity() {
  local cfg="$HOME/.gemini/config/mcp_config.json"
  [ -f "$cfg" ] || return 0
  python3 -c "
import json,sys
try: d=json.load(open('$cfg'))
except Exception: sys.exit(0)
for k in (d.get('mcpServers') or {}): print(k)
" 2>/dev/null || true
}

# Antigravity caches a directory of tool schemas per server it has actually
# CONNECTED to. A server that is configured but missing here failed to come up.
connected_antigravity() {
  local d="$HOME/.gemini/antigravity-cli/mcp"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort -u || true
}

servers_gemini() {
  local cfg="$HOME/.gemini/settings.json"
  [ -f "$cfg" ] || return 0
  python3 -c "
import json,sys
try: d=json.load(open('$cfg'))
except Exception: sys.exit(0)
for k in (d.get('mcpServers') or {}): print(k)
" 2>/dev/null || true
}

servers_grok() {
  [ -f "$HOME/.grok/config.toml" ] || return 0
  sed -nE 's/^\[mcp_servers\.([^].]+)\]$/\1/p' "$HOME/.grok/config.toml" 2>/dev/null | sort -u || true
}

# --- gather ------------------------------------------------------------------
AGENTS="claude codex antigravity gemini grok"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

CLAUDE_DIR=$(counsel_claude_config_dir "$COUNSEL_CONFIG" "$CLAUDE_CONFIG_OVERRIDE")
CLAUDE_JSON=$(counsel_claude_json "$COUNSEL_CONFIG" "$CLAUDE_CONFIG_OVERRIDE")
printf '%s\n' "$CLAUDE_DIR" > "$TMP/claude.config_dir"
printf '%s\n' "${CLAUDE_JSON:-}" > "$TMP/claude.config_file"

INSTALLED=()
for a in $AGENTS; do
  command -v "$(counsel_agent_binary "$a")" &>/dev/null || continue
  INSTALLED+=("$a")
  "servers_$a" | sed '/^$/d' | sort -u > "$TMP/$a.configured"
  if [ "$a" = "antigravity" ]; then
    connected_antigravity | sed '/^$/d' | sort -u > "$TMP/$a.connected"
  else
    cp "$TMP/$a.configured" "$TMP/$a.connected"
  fi
done

# Reference set = servers SHARED by at least two agents (or, with a single agent
# installed, its own set). Deliberately not the union: agents accumulate private
# utility servers (a REPL, a browser driver) that say nothing about review
# quality, and warning about those trains the user to ignore the warning.
: > "$TMP/all"
for a in "${INSTALLED[@]:-}"; do
  [ -n "$a" ] && cat "$TMP/$a.configured" >> "$TMP/all"
done
if [ "${#INSTALLED[@]}" -ge 3 ]; then
  sort "$TMP/all" | uniq -d | sort -u > "$TMP/reference"
else
  sort -u "$TMP/all" -o "$TMP/reference"
fi

# --- report ------------------------------------------------------------------
python3 - "$TMP" "${INSTALLED[@]:-}" <<'PY'
import json, os, sys

tmp = sys.argv[1]
agents = [a for a in sys.argv[2:] if a]

def read(p):
    try:
        return sorted(x for x in open(p).read().split("\n") if x)
    except OSError:
        return []

def read1(p):
    lines = read(p)
    return lines[0] if lines else ""

reference = read(os.path.join(tmp, "reference"))
out, warnings, optional = {}, [], []

for a in agents:
    configured = read(os.path.join(tmp, f"{a}.configured"))
    connected  = read(os.path.join(tmp, f"{a}.connected"))
    missing    = [s for s in reference if s not in connected]
    unreachable = [s for s in configured if s not in connected]
    out[a] = {
        "configured": configured,
        "connected": connected,
        "missing_vs_peers": missing,
        "configured_but_not_connected": unreachable,
    }
    for s in unreachable:
        text = (
            f"{a}: MCP server '{s}' is configured but did not connect — "
            f"it likely needs authenticating (run `agy` then /mcp)."
            if a == "antigravity" else
            f"{a}: MCP server '{s}' is configured but did not connect."
        )
        if a == "antigravity":
            optional.append(
                text + " Antigravity still runs; the prompt lists connected servers only."
            )
        else:
            warnings.append(text)
    for s in missing:
        if s not in unreachable:
            warnings.append(
                f"{a}: missing MCP server '{s}' that other agents have — "
                f"its review will be less informed."
            )

claude_dir = read1(os.path.join(tmp, "claude.config_dir"))
claude_json = read1(os.path.join(tmp, "claude.config_file"))
base = os.path.basename(claude_dir.rstrip("/"))
if base == ".claude":
    profile = "default"
elif base.startswith(".claude-"):
    profile = base[len(".claude-"):]
else:
    profile = base or "default"

print(json.dumps({
    "reference_servers": reference,
    "agents": out,
    "parity": "ok" if not warnings else "mismatch",
    "warnings": warnings,
    "optional_warnings": optional,
    "claude_launch": {
        "profile": profile,
        "config_dir": claude_dir,
        "config_file": claude_json,
    },
}, indent=2))
PY
