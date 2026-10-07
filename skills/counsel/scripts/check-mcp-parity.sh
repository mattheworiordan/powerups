#!/usr/bin/env bash
# Compare installed agents' MCP configuration and cached schema inventories.
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
# Claude: reads the selected profile's configuration inventory (override via
# CLAUDE_CONFIG_DIR_OVERRIDE or config). Connector display names are
# slugified so they compare with other agents' short ids.
#
# Antigravity: cached schemas are an inventory hint, not a live connection
# check. No agent's connectivity is verified by this script; the legacy
# `connected` JSON field contains configuration/cache inventory only.
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

names = {}          # normalised name -> endpoint ("" when unknown)
for k, v in (data.get("mcpServers") or {}).items():
    n = normalize(k)
    if not n:
        continue
    v = v if isinstance(v, dict) else {}
    ep = v.get("url") or v.get("serverUrl") or v.get("httpUrl") or ""
    if not ep and v.get("command"):
        ep = " ".join([v["command"]] + list(v.get("args") or []))
    names[n] = ep

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
        names.setdefault(n, "")   # a connector exposes no local endpoint

for n in sorted(names):
    print(f"{n}\t{names[n]}")
PY
}

# TOML agents (Codex, Grok): emit "<name>\t<endpoint>" per [mcp_servers.<name>]
# section. Names may be quoted ("Ably OS") — strip the quotes, or the quotes end
# up in the reported id. Endpoint is the url for a remote server, or command+args
# for a stdio one.
toml_servers_with_endpoints() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY' 2>/dev/null || true
import re, sys
name = None
endpoint = {}
order = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    m = re.match(r'^\[mcp_servers\.("?)([^\]]+?)\1\]$', line)
    if m:
        name = m.group(2).strip('"')
        if "." in name and not m.group(1):   # nested [mcp_servers.x.tools.y]
            name = None
            continue
        order.append(name)
        endpoint.setdefault(name, "")
        continue
    if name is None:
        continue
    if line.startswith("["):
        name = None
        continue
    m = re.match(r'^(url|serverUrl)\s*=\s*"([^"]+)"', line)
    if m and not endpoint[name]:
        endpoint[name] = m.group(2)
    m = re.match(r'^command\s*=\s*"([^"]+)"', line)
    if m and not endpoint[name]:
        endpoint[name] = m.group(1)
    m = re.match(r'^args\s*=\s*\[(.*)\]', line)
    if m:
        args = re.findall(r'"([^"]+)"', m.group(1))
        if args:
            endpoint[name] = (endpoint[name] + " " + " ".join(args)).strip()
seen = set()
for n in order:
    if n in seen:
        continue
    seen.add(n)
    print(f"{n}\t{endpoint.get(n,'')}")
PY
}

# Antigravity JSON configuration: same "<name>\t<endpoint>" shape.
json_servers_with_endpoints() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for k, v in (d.get("mcpServers") or {}).items():
    v = v if isinstance(v, dict) else {}
    ep = v.get("serverUrl") or v.get("url") or v.get("httpUrl") or ""
    if not ep and v.get("command"):
        ep = " ".join([v["command"]] + list(v.get("args") or []))
    print(f"{k}\t{ep}")
PY
}

servers_codex() {
  toml_servers_with_endpoints "$HOME/.codex/config.toml"
}

servers_antigravity() {
  json_servers_with_endpoints "$HOME/.gemini/config/mcp_config.json"
}

# Antigravity caches tool schemas per server. Presence or absence of a cache
# does not establish the current connection or authentication state.
connected_antigravity() {
  local d="$HOME/.gemini/antigravity-cli/mcp"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sort -u || true
}

servers_grok() {
  toml_servers_with_endpoints "$HOME/.grok/config.toml"
}

# --- gather ------------------------------------------------------------------
AGENTS="claude codex antigravity grok"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

CLAUDE_DIR=$(counsel_claude_config_dir "$COUNSEL_CONFIG" "$CLAUDE_CONFIG_OVERRIDE")
CLAUDE_JSON=$(counsel_claude_json "$COUNSEL_CONFIG" "$CLAUDE_CONFIG_OVERRIDE")
printf '%s\n' "$CLAUDE_DIR" > "$TMP/claude.config_dir"
printf '%s\n' "${CLAUDE_JSON:-}" > "$TMP/claude.config_file"

INSTALLED=()
for a in $AGENTS; do
  command -v "$(counsel_agent_binary "$a")" &>/dev/null || continue
  INSTALLED+=("$a")
  # TSV: "<raw name>\t<endpoint>"
  "servers_$a" | sed '/^$/d' | sort -u > "$TMP/$a.tsv"
  if [ "$a" = "antigravity" ]; then
    connected_antigravity | sed '/^$/d' | sort -u > "$TMP/$a.connected_names"
  else
    cut -f1 "$TMP/$a.tsv" > "$TMP/$a.connected_names"
  fi
done

# Canonicalise identity by ENDPOINT, not by name. The same server is routinely
# registered under different names per agent — Grok calls the Ably MCP
# "Ably OS", Claude reaches it as a connector, Codex calls it "ably" — all on
# one URL. Comparing names reports phantom gaps and trains the user to ignore
# the warning. Two entries with the same endpoint are one server; a name is
# only the identity when no endpoint is discoverable (e.g. a claude.ai
# connector). The shortest normalised name wins as the display id.
python3 - "$TMP" "$SCRIPT_DIR/lib.sh" "${INSTALLED[@]:-}" <<'PY'
import os, subprocess, sys

tmp, lib = sys.argv[1], sys.argv[2]
agents = [a for a in sys.argv[3:] if a]

def normalize(name):
    return subprocess.check_output(
        ["bash", "-c", f'source "{lib}" && counsel_normalize_mcp_name "$1"', "_", name],
        text=True,
    ).strip()

def norm_endpoint(ep):
    ep = (ep or "").strip()
    if not ep:
        return ""
    if "://" in ep:                       # remote: origin+path, ignore query
        from urllib.parse import urlsplit
        u = urlsplit(ep)
        return f"{u.scheme}://{u.netloc}{u.path.rstrip('/')}"
    return " ".join(ep.split())           # stdio: command + args

# name -> endpoint, per agent
per_agent = {}
for a in agents:
    rows = {}
    try:
        for line in open(os.path.join(tmp, f"{a}.tsv")):
            if not line.strip():
                continue
            raw, _, ep = line.rstrip("\n").partition("\t")
            rows[normalize(raw)] = norm_endpoint(ep)
    except OSError:
        pass
    per_agent[a] = rows

# endpoint -> canonical display id (shortest, then alphabetical)
canon = {}
for rows in per_agent.values():
    for n, ep in rows.items():
        if not ep:
            continue
        cur = canon.get(ep)
        if cur is None or (len(n), n) < (len(cur), cur):
            canon[ep] = n

def ident(agent, name):
    ep = per_agent[agent].get(name, "")
    return canon.get(ep, name) if ep else name

for a in agents:
    with open(os.path.join(tmp, f"{a}.configured"), "w") as f:
        f.write("\n".join(sorted({ident(a, n) for n in per_agent[a]})) + "\n")
    names = [x for x in open(os.path.join(tmp, f"{a}.connected_names")).read().split("\n") if x]
    with open(os.path.join(tmp, f"{a}.connected"), "w") as f:
        f.write("\n".join(sorted({ident(a, normalize(n)) for n in names})) + "\n")
PY

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
        "connectivity_verified": False,
        "inventory_source": "schema_cache" if a == "antigravity" else "configuration",
    }
    for s in unreachable:
        text = (
            f"{a}: MCP server '{s}' is configured but has no cached schemas; "
            f"its current connection and authentication state are unknown."
            if a == "antigravity" else
            f"{a}: MCP server '{s}' is configured but did not connect."
        )
        if a == "antigravity":
            optional.append(
                text + " Antigravity still runs with a cache inventory in the prompt."
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
