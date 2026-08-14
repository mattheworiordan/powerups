#!/usr/bin/env bash
# Offline checks for counsel launch helpers. No live agent calls.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

FAILS=0
pass() { echo "  ok  $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }

echo "lib.sh"

got=$(counsel_normalize_mcp_name "claude.ai Ably MCP (Slim Mode)")
[ "$got" = "ably" ] && pass "normalize strips claude.ai + mcp/slim/mode" || fail "normalize slim → $got"

got=$(counsel_normalize_mcp_name "claude.ai Matt OS")
[ "$got" = "matt-os" ] && pass "normalize matt-os" || fail "normalize matt-os → $got"

got=$(counsel_normalize_mcp_name "ably")
[ "$got" = "ably" ] && pass "normalize short id" || fail "normalize short → $got"

counsel_list_contains "grok,claude" grok && pass "list contains grok" || fail "list contains grok"
counsel_list_contains "grok, claude" claude && pass "list contains spaced claude" || fail "list contains spaced claude"
counsel_list_contains "grok" antigravity && fail "list should not contain antigravity" || pass "list rejects missing"

FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/.claude-work" "$FAKE/.claude-personal" "$FAKE/.claude"
echo '{}' > "$FAKE/.claude-work/.claude.json"
echo '{}' > "$FAKE/.claude-personal/.claude.json"
got=$(HOME="$FAKE" counsel_claude_config_dir)
[ "$got" = "$FAKE/.claude" ] && pass "no auto-pick of work profile" || fail "default dir → $got"

CFG="$FAKE/config.json"
cat > "$CFG" <<'JSON'
{
  "agents": {
    "claude": { "enabled": true, "profile": "personal" },
    "codex": { "enabled": true },
    "antigravity": { "enabled": true },
    "grok": { "enabled": true }
  },
  "claude": {
    "chooser": "use personal unless company",
    "profiles": [
      { "id": "work", "dir": "~/.claude-work", "useWhen": "company" },
      { "id": "personal", "dir": "~/.claude-personal", "useWhen": "home" }
    ]
  },
  "effort": {
    "standard": { "claudeModel": "opus", "codexEffort": "high", "timeout": 300 },
    "extra": { "claudeModel": "fable", "codexEffort": "xhigh", "timeout": 600 }
  }
}
JSON
got=$(HOME="$FAKE" counsel_claude_config_dir "$CFG")
[ "$got" = "$FAKE/.claude-personal" ] && pass "legacy agents.claude.profile" || fail "legacy profile → $got"

got=$(HOME="$FAKE" counsel_claude_config_dir "$CFG" work)
[ "$got" = "$FAKE/.claude-work" ] && pass "override id work" || fail "override work → $got"

got=$(counsel_json_get "$CFG" effort.extra.claudeModel)
[ "$got" = "fable" ] && pass "json get effort.extra.claudeModel" || fail "json get → $got"

mkdir -p "$FAKE/.gemini/config" "$FAKE/.gemini/antigravity-cli/mcp/matt-os"
cat > "$FAKE/.gemini/config/mcp_config.json" <<'JSON'
{"mcpServers":{"matt-os":{"command":"x"},"ably":{"url":"https://example"}}}
JSON
got=$(HOME="$FAKE" counsel_antigravity_disconnected | tr '\n' ',')
[ "$got" = "ably," ] && pass "agy disconnected lists ably" || fail "agy disconnected → $got"

echo "detect-setup.sh"
SETUP=$(HOME="$FAKE" bash "$SCRIPT_DIR/detect-setup.sh" --config "$CFG")
echo "$SETUP" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["needs_setup"] is False, d
assert d["effort"]["configured"] is True
ids=sorted(p["id"] for p in d["claude_profiles"]["detected"])
assert "work" in ids and "personal" in ids, ids
print("  ok  detect-setup: configured machine needs no ask")
'
EMPTY="$FAKE/empty.json"
echo '{}' > "$EMPTY"
SETUP2=$(HOME="$FAKE" bash "$SCRIPT_DIR/detect-setup.sh" --config "$EMPTY")
echo "$SETUP2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["needs_setup"] is True, d
assert d["claude_profiles"]["needs_setup"] is True
assert d["effort"]["needs_setup"] is True
print("  ok  detect-setup: empty config needs profile + effort ask")
'

echo "discover-models.sh --quick"
DISC=$(bash "$SCRIPT_DIR/discover-models.sh" --quick)
echo "$DISC" | python3 -c '
import json,sys
d=json.load(sys.stdin)
s=d["suggestions"]["standard"]
e=d["suggestions"]["extra"]
assert s["claudeModel"] == "opus", s
assert e["claudeModel"] == "fable", e
assert "sonnet" not in (s["claudeModel"]+e["claudeModel"])
assert s.get("codexEffort") in {"high","xhigh","max"}
assert e.get("codexEffort") in {"xhigh","max","high"}
print("  ok  discover recommends opus/fable, not sonnet")
'

echo "run-review.sh dry-run"
TMP=$(mktemp -d)
PROMPT="$TMP/prompt.md"
OUT="$TMP/out"
cat > "$PROMPT" <<'P'
You are an independent code reviewer. DO NOT modify, write, or create any files.
Reply with the single word PONG and nothing else.
P

bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT" \
  --exclude grok \
  --effort extra \
  --claude-config-dir work \
  --add-dir /tmp \
  --dry-run >/tmp/counsel-dry-run.json

if [ -f "$OUT/claude.cmd" ]; then
  grep -q 'claude-work' "$OUT/claude.cmd" && pass "claude.cmd uses chosen work dir" || fail "claude.cmd dir"
  grep -q -- '--model fable' "$OUT/claude.cmd" && pass "extra effort → fable" || fail "extra model"
  grep -q 'stdin=prompt-file' "$OUT/claude.cmd" && pass "claude.cmd stdin" || fail "claude.cmd stdin"
  if grep -q '\$(' "$OUT/claude.cmd"; then
    fail "claude.cmd still interpolates prompt with \$("
  else
    pass "claude.cmd does not use \$(< file)"
  fi
else
  fail "claude.cmd not written"
fi

if [ -f "$OUT/codex.cmd" ]; then
  grep -q -- '--output-last-message' "$OUT/codex.cmd" && pass "codex.cmd last-message" || fail "codex.cmd last-message"
  grep -q -- '--ignore-user-config' "$OUT/codex.cmd" && pass "codex.cmd ignore-user-config" || fail "codex.cmd ignore-user-config"
  grep -q 'model_reasoning_effort=\\"xhigh\\"' "$OUT/codex.cmd" || grep -q 'model_reasoning_effort="xhigh"' "$OUT/codex.cmd" && pass "extra effort → codex xhigh" || fail "codex effort: $(cat "$OUT/codex.cmd")"
else
  fail "codex.cmd not written"
fi

if [ -f "$OUT/grok.cmd" ] || [ -f "$OUT/grok.md" ]; then
  fail "grok should be excluded"
else
  pass "exclude grok drops grok"
fi

OUT2="$TMP/out2"
bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT2" \
  --exclude grok,claude \
  --dry-run >/dev/null
[ ! -f "$OUT2/claude.cmd" ] && [ ! -f "$OUT2/grok.cmd" ] && pass "exclude grok,claude" || fail "comma exclude left a cmd file"
[ -f "$OUT2/codex.cmd" ] && pass "comma exclude still plans codex" || fail "comma exclude dropped codex"

# Antigravity still launches when a server is disconnected
OUT3="$TMP/out3"
HOME="$FAKE" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT3" \
  --agents antigravity \
  --dry-run >/dev/null || true
if [ -f "$OUT3/antigravity.cmd" ] || { [ -f "$OUT3/antigravity.md" ] && grep -q 'would launch' "$OUT3/antigravity.md"; }; then
  pass "antigravity still launches when MCP disconnected"
else
  fail "antigravity should launch: $(ls -la "$OUT3" 2>/dev/null; cat "$OUT3/antigravity.md" 2>/dev/null)"
fi
if [ -f "$OUT3/antigravity.md" ] && grep -q 'MCP not connected' "$OUT3/antigravity.md"; then
  pass "antigravity dry-run notes disconnected MCP"
else
  fail "antigravity missing MCP caveat"
fi

echo "check-mcp-parity.sh"
if [ -d "$HOME/.claude-work" ]; then
  PARITY=$(COUNSEL_CONFIG="$HOME/.config/counsel/config.json" \
    CLAUDE_CONFIG_DIR_OVERRIDE=work \
    bash "$SCRIPT_DIR/check-mcp-parity.sh")
  echo "$PARITY" | python3 -c '
import json,sys
d=json.load(sys.stdin)
cl = d.get("claude_launch") or {}
assert cl.get("profile") == "work", cl
claude = (d.get("agents") or {}).get("claude") or {}
connected = set(claude.get("connected") or [])
warn = d.get("warnings") or []
if "ably" in connected or "ably" in set(claude.get("configured") or []):
    assert "ably" in connected, ("claude connected", connected)
    assert not any("claude: missing MCP server '\''ably'\''" in w for w in warn), warn
    print("  ok  parity maps connector → ably without a hard-coded product list")
opt = d.get("optional_warnings") or []
if any("antigravity" in w for w in opt):
    assert not any("skip" in w.lower() and "will skip" in w.lower() for w in opt)
    print("  ok  antigravity disconnect is optional, not a skip")
'
else
  echo "  skip live parity checks (no ~/.claude-work)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "All counsel launch checks passed."
  exit 0
fi
echo "$FAILS check(s) failed."
exit 1
