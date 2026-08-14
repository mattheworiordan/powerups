#!/usr/bin/env bash
# Probe installed agent CLIs for models, then recommend standard vs extra.
#
# Never run `claude models` — that starts a chat. Claude aliases come from --help.
# Codex: ~/.codex/models_cache.json (codex models needs a TTY).
# Grok: `grok models` (fast). Antigravity `agy models` often hangs — short kill.
#
# Usage: discover-models.sh [--quick]
#   --quick  skip live grok/agy probes (help + caches only)
#
# Output: JSON on stdout.

set -euo pipefail

QUICK=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --quick) QUICK=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

export COUNSEL_DISCOVER_QUICK="$QUICK"

python3 <<'PY'
import json, os, re, shutil, subprocess
from pathlib import Path

home = Path.home()
quick = os.environ.get("COUNSEL_DISCOVER_QUICK") == "1"
timeout_bin = shutil.which("timeout") or shutil.which("gtimeout")

def run(args, seconds=10):
    try:
        if timeout_bin:
            args = [timeout_bin, "--kill-after=2s", str(seconds), *args]
        return subprocess.run(
            args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=seconds + 3,
        ).stdout or ""
    except Exception:
        return ""

# --- skip classes: not review-quality ---------------------------------------
SKIP = re.compile(
    r"(sonnet|haiku|flash|mini|nano|lite|small|tiny|fast|haiku)",
    re.I,
)

def ok_name(name: str) -> bool:
    return bool(name) and not SKIP.search(name)

# --- Claude: aliases in `claude --help`. Do not invoke `claude models`. -----
def probe_claude():
    help_txt = run(["claude", "--help"], 8)
    aliases = re.findall(r"'([a-z0-9][a-z0-9.-]*)'", help_txt)
    # Keep only known-looking model aliases near the --model blurb
    blob = ""
    m = re.search(r"--model.*?(?:\n\s\s[A-Z-]|\n  -[a-z])", help_txt, re.S)
    if m:
        blob = m.group(0)
    found = re.findall(r"'([a-z][a-z0-9.-]+)'", blob)
    # Always consider the documented current aliases if help parsing is thin
    for extra in ("fable", "opus", "sonnet"):
        if extra in help_txt and extra not in found:
            found.append(extra)
    found = list(dict.fromkeys(found))
    reviewable = [n for n in found if ok_name(n)]
    extra = next((n for n in reviewable if re.search(r"fable", n, re.I)), None)
    standard = next((n for n in reviewable if re.search(r"opus", n, re.I)), None)
    if extra is None and reviewable:
        extra = reviewable[0]
    if standard is None:
        standard = extra
    return {
        "source": "claude --help",
        "available": found,
        "reviewable": reviewable,
        "standard": standard,
        "extra": extra,
        "note": "Counsel never recommends sonnet/haiku. standard=opus, extra=fable when those aliases exist.",
    }

# --- Codex: local models cache ----------------------------------------------
def probe_codex():
    cache = home / ".codex" / "models_cache.json"
    available, reviewable = [], []
    efforts_by_slug = {}
    flagship = None
    if cache.is_file():
        try:
            data = json.loads(cache.read_text())
        except Exception:
            data = {}
        models = data.get("models") or []
        listed = []
        for m in models:
            slug = m.get("slug") or ""
            vis = m.get("visibility") or "list"
            if not slug:
                continue
            available.append(slug)
            levels = [x.get("effort") for x in (m.get("supported_reasoning_levels") or []) if x.get("effort")]
            efforts_by_slug[slug] = levels
            if vis != "list":
                continue
            if not ok_name(slug):
                continue
            listed.append((m.get("priority") or 99, slug))
        listed.sort()
        reviewable = [s for _, s in listed]
        flagship = reviewable[0] if reviewable else None
    # Fallback: user config model
    cfg = home / ".codex" / "config.toml"
    if flagship is None and cfg.is_file():
        mm = re.search(r'^model\s*=\s*"([^"]+)"', cfg.read_text(), re.M)
        if mm and ok_name(mm.group(1)):
            flagship = mm.group(1)
            reviewable = [flagship]
    levels = efforts_by_slug.get(flagship or "", ["medium", "high", "xhigh"])
    # Reviews are not a cheap-tier job: never recommend low/medium.
    def pick_effort(prefer):
        for e in prefer:
            if e in levels:
                return e
        return levels[-1] if levels else "high"
    return {
        "source": str(cache) if cache.is_file() else "codex config",
        "available": available,
        "reviewable": reviewable,
        "standard": {"model": flagship, "effort": pick_effort(["high", "xhigh", "max"])},
        "extra": {"model": flagship, "effort": pick_effort(["xhigh", "max", "high"])},
        "note": "One frontier model; extra raises reasoning effort. medium/low are not used for counsel.",
    }

# --- Grok: `grok models` ----------------------------------------------------
def probe_grok():
    available, default = [], None
    source = "grok --help"
    if not quick:
        out = run(["grok", "models"], 15)
        if "Available models" in out or "grok-" in out:
            source = "grok models"
            for line in out.splitlines():
                mm = re.search(r"(grok-[0-9][0-9.]*\w*)", line)
                if not mm:
                    continue
                slug = mm.group(1)
                available.append(slug)
                if "default" in line.lower() or line.strip().startswith("*"):
                    default = slug
            available = list(dict.fromkeys(available))
    if not available:
        help_txt = run(["grok", "--help"], 8)
        available = list(dict.fromkeys(re.findall(r"grok-[0-9][0-9.\w-]*", help_txt)))
    reviewable = [n for n in available if ok_name(n)]
    extra = default if default in reviewable else (reviewable[0] if reviewable else default)
    standard = extra  # Grok has a generation ladder, not a mid-tier review model
    return {
        "source": source,
        "available": available,
        "reviewable": reviewable,
        "standard": extra,
        "extra": extra,
        "note": "Use the current default for both tiers unless a stronger variant appears.",
    }

# --- Antigravity: listing often hangs; best-effort --------------------------
def probe_agy():
    available = []
    source = "skipped"
    if not quick:
        out = run(["agy", "models"], 6)
        if out.strip():
            source = "agy models"
            available = list(dict.fromkeys(re.findall(r"[A-Za-z0-9._:-]{3,}", out)))[:40]
    reviewable = [n for n in available if ok_name(n)]
    extra = next((n for n in reviewable if re.search(r"(pro|ultra|opus|fable)", n, re.I)), None)
    if extra is None and reviewable:
        extra = reviewable[0]
    return {
        "source": source,
        "available": available,
        "reviewable": reviewable,
        "standard": extra,
        "extra": extra,
        "note": "agy models often hangs; skipped or partial.",
    }

claude = probe_claude()
codex = probe_codex()
grok = probe_grok()
agy = probe_agy()

suggestions = {
    "standard": {
        "claudeModel": claude.get("standard") or "opus",
        "codexModel": (codex.get("standard") or {}).get("model"),
        "codexEffort": (codex.get("standard") or {}).get("effort") or "high",
        "grokModel": grok.get("standard"),
        "timeout": 300,
    },
    "extra": {
        "claudeModel": claude.get("extra") or "fable",
        "codexModel": (codex.get("extra") or {}).get("model"),
        "codexEffort": (codex.get("extra") or {}).get("effort") or "xhigh",
        "grokModel": grok.get("extra"),
        "timeout": 600,
    },
}

print(json.dumps({
    "agents": {
        "claude": claude,
        "codex": codex,
        "grok": grok,
        "antigravity": agy,
    },
    "suggestions": suggestions,
    "logic": (
        "Skip cheap/fast classes (sonnet, haiku, flash, mini). "
        "Claude: extra=fable, standard=opus. "
        "Codex: one frontier model; extra raises reasoning (xhigh vs high). "
        "Grok: current default for both tiers."
    ),
}, indent=2))
PY
