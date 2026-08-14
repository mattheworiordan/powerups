#!/usr/bin/env bash
# Shared helpers for counsel scripts. Source only — do not execute.

counsel_agent_binary() {
  case "$1" in
    antigravity) echo "agy" ;;
    *)           echo "$1" ;;
  esac
}

# Expand a leading ~ the way config authors write it.
counsel_expand_path() {
  local p="$1"
  case "$p" in
    "~")   echo "$HOME" ;;
    "~/"*) echo "${HOME}/${p#~/}" ;;
    *)     echo "$p" ;;
  esac
}

# Read a dotted JSON path (e.g. effort.standard.claudeModel). Empty if missing.
counsel_json_get() {
  local config_file="$1" path="$2"
  [ -f "$config_file" ] || return 0
  python3 - "$config_file" "$path" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
cur = data
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        raise SystemExit(0)
if cur is None:
    raise SystemExit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
PY
}

# Back-compat: agents.<agent>.<key>
counsel_config_get() {
  counsel_json_get "$1" "agents.$2.$3"
}

# Map connector / server display names onto short ids.
# Generic: strip a "claude.ai" prefix and noise tokens (mcp, slim, mode).
# "claude.ai Foo MCP (Slim Mode)" → foo; "ably" → ably.
counsel_normalize_mcp_name() {
  python3 -c '
import re, sys
n = sys.argv[1].strip().lower()
n = re.sub(r"^claude\.ai\s+", "", n)
n = re.sub(r"^claude-ai-", "", n)
n = re.sub(r"[^a-z0-9]+", "-", n).strip("-")
noise = {"mcp", "slim", "mode"}
parts = [p for p in n.split("-") if p and p not in noise]
print("-".join(parts) if parts else n)
' "$1"
}

# Comma-separated list membership. Spaces around names are ignored.
counsel_list_contains() {
  local list="$1" needle="$2" item
  [ -z "$list" ] && return 1
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# Every Claude Code profile dir on this machine: ~/.claude and ~/.claude-*.
# A profile is a directory that contains .claude.json (or is ~/.claude).
counsel_detected_claude_dirs() {
  python3 <<'PY'
import os
from pathlib import Path
home = Path(os.environ["HOME"])

def json_key(p: Path):
    jf = p / ".claude.json"
    if jf.exists() or jf.is_symlink():
        try:
            return str(jf.resolve())
        except Exception:
            return str(p.resolve())
    return str(p.resolve())

SKIP_IDS = {"shared"}
SKIP_PREFIXES = ("backup", "bak", "old", "tmp", "copy")

def profile_id_of(p: Path) -> str:
    name = p.name
    if name == ".claude":
        return "default"
    if name.startswith(".claude-"):
        return name[len(".claude-"):]
    return name

def skip_profile(p: Path) -> bool:
    pid = profile_id_of(p)
    if pid in SKIP_IDS:
        return True
    for pref in SKIP_PREFIXES:
        if pid == pref or pid.startswith(pref + "-") or pid.endswith("-" + pref):
            return True
    return False

def is_profile(p: Path) -> bool:
    if skip_profile(p):
        return False
    return (p / ".claude.json").exists() or (p / ".claude.json").is_symlink()

candidates = []
default = home / ".claude"
if default.is_dir() and is_profile(default):
    candidates.append(default)
for p in sorted(home.glob(".claude-*")):
    if not p.is_dir() or p.name == ".claude-shared":
        continue
    if is_profile(p):
        candidates.append(p)

# Prefer ~/.claude-foo over the ~/.claude façade when they share a json file.
candidates.sort(key=lambda p: (0 if p.name.startswith(".claude-") else 1, p.name))
seen = set()
for p in candidates:
    key = json_key(p)
    if key in seen:
        continue
    seen.add(key)
    print(str(p.resolve() if p.exists() else p))
PY
}

# id from a config dir: ~/.claude-work → work, ~/.claude → default
counsel_claude_profile_id() {
  local dir="$1" base
  dir=$(counsel_expand_path "$dir")
  base=$(basename "$dir")
  case "$base" in
    .claude) echo "default" ;;
    .claude-*) echo "${base#.claude-}" ;;
    *) echo "$base" ;;
  esac
}

# Resolve a profile id or path to an absolute config dir.
# Looks up claude.profiles[] in config, then ~/.claude-<id>, then the path itself.
counsel_claude_profile_dir() {
  local spec="$1" config_file="${2:-}"
  local from_config=""
  [ -z "$spec" ] && return 0
  if [ -n "$config_file" ] && [ -f "$config_file" ]; then
    from_config=$(python3 - "$config_file" "$spec" <<'PY'
import json, sys
from pathlib import Path
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
want = sys.argv[2]
home = Path.home()
profiles = (data.get("claude") or {}).get("profiles") or []
for p in profiles:
    if not isinstance(p, dict):
        continue
    if p.get("id") == want or p.get("dir") == want:
        d = p.get("dir") or ""
        if d.startswith("~/"):
            d = str(home / d[2:])
        elif d == "~":
            d = str(home)
        print(d)
        raise SystemExit(0)
PY
)
  fi
  if [ -n "$from_config" ]; then
    echo "$from_config"
    return
  fi
  case "$spec" in
    default) echo "${HOME}/.claude" ;;
    /*|./*|~/*) counsel_expand_path "$spec" ;;
    *)
      if [ -d "${HOME}/.claude-${spec}" ]; then
        echo "${HOME}/.claude-${spec}"
      else
        counsel_expand_path "$spec"
      fi
      ;;
  esac
}

# Directory Counsel will pass as CLAUDE_CONFIG_DIR.
#
# Priority:
#   1. explicit override (profile id or path)
#   2. agents.claude.configDir / agents.claude.profile (legacy)
#   3. $CLAUDE_CONFIG_DIR already in the environment
#   4. ~/.claude
#
# Does NOT auto-pick a "work" profile. The host skill chooses using
# claude.chooser + claude.profiles[] and passes --claude-config-dir.
counsel_claude_config_dir() {
  local config_file="${1:-}"
  local override="${2:-}"
  local from_config="" resolved=""

  if [ -n "$override" ]; then
    counsel_claude_profile_dir "$override" "$config_file"
    return
  fi

  if [ -n "$config_file" ]; then
    from_config=$(counsel_json_get "$config_file" agents.claude.configDir)
    [ -z "$from_config" ] && from_config=$(counsel_json_get "$config_file" agents.claude.config_dir)
    [ -z "$from_config" ] && from_config=$(counsel_json_get "$config_file" agents.claude.profile)
  fi

  if [ -n "$from_config" ]; then
    counsel_claude_profile_dir "$from_config" "$config_file"
    return
  fi

  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    echo "$CLAUDE_CONFIG_DIR"
    return
  fi

  echo "${HOME}/.claude"
}

counsel_claude_json() {
  local dir
  dir=$(counsel_claude_config_dir "${1:-}" "${2:-}")
  if [ -f "${dir}/.claude.json" ]; then
    echo "${dir}/.claude.json"
  elif [ -f "${HOME}/.claude.json" ]; then
    echo "${HOME}/.claude.json"
  fi
}

# Configured Antigravity MCP servers that have no connection cache.
counsel_antigravity_disconnected() {
  python3 <<'PY'
import json, os
from pathlib import Path

home = Path(os.environ["HOME"])
cfg = home / ".gemini/config/mcp_config.json"
cache = home / ".gemini/antigravity-cli/mcp"
if not cfg.is_file():
    raise SystemExit(0)
try:
    data = json.loads(cfg.read_text())
except Exception:
    raise SystemExit(0)
configured = list((data.get("mcpServers") or {}))
connected = set()
if cache.is_dir():
    connected = {p.name for p in cache.iterdir() if p.is_dir()}
for name in configured:
    if name not in connected:
        print(name)
PY
}

counsel_antigravity_connected() {
  python3 <<'PY'
import json, os
from pathlib import Path
home = Path(os.environ["HOME"])
cfg = home / ".gemini/config/mcp_config.json"
cache = home / ".gemini/antigravity-cli/mcp"
configured = []
if cfg.is_file():
    try:
        configured = list((json.loads(cfg.read_text()).get("mcpServers") or {}))
    except Exception:
        configured = []
connected = set()
if cache.is_dir():
    connected = {p.name for p in cache.iterdir() if p.is_dir()}
for name in configured:
    if name in connected:
        print(name)
PY
}
