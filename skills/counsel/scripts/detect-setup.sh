#!/usr/bin/env bash
# Compare detected Claude profiles + effort tiers against counsel config.
# The host skill uses this to decide whether to ask the user (once), then
# writes the answers back to config. Self-maintaining: a new ~/.claude-*
# dir shows up in .claude_profiles.new.
#
# Usage: detect-setup.sh [--config FILE]
# Output: JSON on stdout.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CONFIG_FILE="${HOME}/.config/counsel/config.json"
while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

DETECTED=$(counsel_detected_claude_dirs)
export DETECTED

python3 - "$CONFIG_FILE" "$HOME" <<'PY'
import json, os, re, sys
from pathlib import Path

config_path = Path(sys.argv[1])
home = Path(sys.argv[2])
detected_dirs = [Path(x) for x in os.environ.get("DETECTED", "").split("\n") if x]

cfg = {}
if config_path.is_file():
    try:
        cfg = json.loads(config_path.read_text())
    except Exception:
        cfg = {}

def profile_id(dir_path: Path) -> str:
    name = dir_path.name
    if name == ".claude":
        return "default"
    if name.startswith(".claude-"):
        return name[len(".claude-"):]
    return name

def account_hint(dir_path: Path) -> dict:
    out = {}
    jf = dir_path / ".claude.json"
    if not jf.is_file():
        return out
    try:
        data = json.loads(jf.read_text())
    except Exception:
        return out
    oa = data.get("oauthAccount") or {}
    if oa.get("emailAddress"):
        out["email"] = oa["emailAddress"]
    if oa.get("organizationName"):
        out["organization"] = oa["organizationName"]
    return out

detected = []
for d in detected_dirs:
    item = {"id": profile_id(d), "dir": str(d), "exists": True}
    item.update(account_hint(d))
    detected.append(item)

configured_profiles = []
raw_profiles = (cfg.get("claude") or {}).get("profiles") or []
for p in raw_profiles:
    if not isinstance(p, dict):
        continue
    d = p.get("dir") or ""
    if d.startswith("~/"):
        d = str(home / d[2:])
    configured_profiles.append({
        "id": p.get("id") or "",
        "dir": d,
        "useWhen": p.get("useWhen") or p.get("use_when") or "",
    })

configured_ids = {p["id"] for p in configured_profiles if p["id"]}
configured_dirs = {os.path.realpath(p["dir"]) for p in configured_profiles if p["dir"]}
detected_ids = {p["id"] for p in detected}
new_profiles = [p["id"] for p in detected if p["id"] not in configured_ids
                and os.path.realpath(p["dir"]) not in configured_dirs]
# A lone ~/.claude with no extra profiles is not "new" if config is empty —
# there is nothing to choose between.
if len(detected) <= 1:
    new_profiles = []

missing_profiles = [
    p["id"] for p in configured_profiles
    if p["dir"] and not Path(p["dir"]).is_dir()
]

chooser = ((cfg.get("claude") or {}).get("chooser") or "").strip()
needs_profile_setup = False
if len(detected) >= 2 and (not chooser or not configured_profiles or new_profiles):
    needs_profile_setup = True

effort = cfg.get("effort") or {}
standard = effort.get("standard") if isinstance(effort.get("standard"), dict) else {}
extra = effort.get("extra") if isinstance(effort.get("extra"), dict) else {}
needs_effort_setup = not (standard and extra)
for tier in (standard, extra):
    cm = str((tier or {}).get("claudeModel") or "")
    if re.search(r"sonnet|haiku", cm, re.I):
        needs_effort_setup = True

print(json.dumps({
    "config": str(config_path),
    "needs_setup": needs_profile_setup or needs_effort_setup,
    "claude_profiles": {
        "detected": detected,
        "configured": configured_profiles,
        "chooser": chooser,
        "new": new_profiles,
        "missing": missing_profiles,
        "needs_setup": needs_profile_setup,
    },
    "effort": {
        "configured": bool(standard and extra),
        "needs_setup": needs_effort_setup,
        "standard": standard,
        "extra": extra,
        "suggestions": {
            "standard": {
                "claudeModel": "opus",
                "codexEffort": "high",
                "timeout": 300,
            },
            "extra": {
                "claudeModel": "fable",
                "codexEffort": "xhigh",
                "timeout": 600,
            },
        },
        "discover": "Run scripts/discover-models.sh to list live CLI models and refresh these suggestions.",
        "phrases": {
            "extra": ["extra effort", "try hard", "think hard", "deep review", "thorough"],
            "standard": ["standard", "quick", "default"],
        },
    },
}, indent=2))
PY
