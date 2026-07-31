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
# Output: JSON on stdout. Non-zero exit is NOT used for disagreement — read
# `.parity` ("ok" | "mismatch") and `.warnings`.

set -euo pipefail

# --- per-agent discovery -----------------------------------------------------
# Each function prints one server name per line (empty if agent absent).

servers_claude() {
  # Claude Code keeps global MCP servers in ~/.claude.json
  [ -f "$HOME/.claude.json" ] || return 0
  python3 -c "
import json,sys
try: d=json.load(open('$HOME/.claude.json'))
except Exception: sys.exit(0)
for k in (d.get('mcpServers') or {}): print(k)
" 2>/dev/null || true
}

servers_codex() {
  # Codex uses config.toml with [mcp_servers.<name>] sections. Match only
  # top-level entries — skip nested [mcp_servers.<name>.tools.<x>] / .env.
  [ -f "$HOME/.codex/config.toml" ] || return 0
  sed -nE 's/^\[mcp_servers\.([^].]+)\]$/\1/p' "$HOME/.codex/config.toml" 2>/dev/null | sort -u || true
}

servers_antigravity() {
  # Antigravity: standalone mcp_config.json (global scope)
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
# CONNECTED to. A server that is configured but missing here failed to come up —
# usually an unauthenticated remote/OAuth server. This is a real connection
# signal, not just config, so it catches the case config parsing cannot.
connected_antigravity() {
  local d="$HOME/.gemini/antigravity-cli/mcp"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort -u || true
}

servers_gemini() {
  # Legacy Gemini CLI nested servers inside settings.json
  local cfg="$HOME/.gemini/settings.json"
  [ -f "$cfg" ] || return 0
  python3 -c "
import json,sys
try: d=json.load(open('$cfg'))
except Exception: sys.exit(0)
for k in (d.get('mcpServers') or {}): print(k)
" 2>/dev/null || true
}

agent_binary() {
  case "$1" in
    antigravity) echo "agy" ;;
    *)           echo "$1" ;;
  esac
}

# --- gather ------------------------------------------------------------------
AGENTS="claude codex antigravity gemini"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

INSTALLED=()
for a in $AGENTS; do
  command -v "$(agent_binary "$a")" &>/dev/null || continue
  INSTALLED+=("$a")
  "servers_$a" | sed '/^$/d' | sort -u > "$TMP/$a.configured"
  if [ "$a" = "antigravity" ]; then
    connected_antigravity | sed '/^$/d' | sort -u > "$TMP/$a.connected"
  else
    # No connection signal available for other agents — assume configured==reachable
    cp "$TMP/$a.configured" "$TMP/$a.connected"
  fi
done

# Reference set = servers SHARED by at least two agents (or, with a single agent
# installed, its own set). Deliberately not the union: agents accumulate private
# utility servers (a REPL, a browser driver) that say nothing about review
# quality, and warning about those trains the user to ignore the warning. A
# server two agents share is a context source the third is genuinely missing.
: > "$TMP/all"
for a in "${INSTALLED[@]:-}"; do
  [ -n "$a" ] && cat "$TMP/$a.configured" >> "$TMP/all"
done
# With three or more agents, "shared by >=2" separates real context servers from
# one-off utilities. With only two, that test is degenerate — a server one agent
# lacks appears exactly once and would be filtered out, so NO gap could ever be
# reported. Fall back to the union there: a difference between two agents is more
# likely material than not, and a dismissable warning beats silent blindness.
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

reference = read(os.path.join(tmp, "reference"))
out, warnings = {}, []

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
        warnings.append(
            f"{a}: MCP server '{s}' is configured but did not connect — "
            f"it likely needs authenticating (run `agy` then /mcp)."
            if a == "antigravity" else
            f"{a}: MCP server '{s}' is configured but did not connect."
        )
    for s in missing:
        if s not in unreachable:
            warnings.append(
                f"{a}: missing MCP server '{s}' that other agents have — "
                f"its review will be less informed."
            )

print(json.dumps({
    "reference_servers": reference,
    "agents": out,
    "parity": "ok" if not warnings else "mismatch",
    "warnings": warnings,
}, indent=2))
PY
