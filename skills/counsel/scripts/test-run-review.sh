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
# The Claude desktop app exports CLAUDE_CONFIG_DIR, which outranks ~/.claude.
got=$(unset CLAUDE_CONFIG_DIR; HOME="$FAKE" counsel_claude_config_dir)
[ "$got" = "$FAKE/.claude" ] && pass "no auto-pick of work profile" || fail "default dir → $got"
got=$(CLAUDE_CONFIG_DIR="$FAKE/.claude-personal" HOME="$FAKE" counsel_claude_config_dir)
if [ "$got" = "$FAKE/.claude-personal" ]; then
  pass "env CLAUDE_CONFIG_DIR is honoured"
else
  fail "env dir → $got"
fi

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
{"mcpServers":{"matt-os":{"command":"counsel-test-no-such-mcp-server"},"ably":{"url":"https://example"}}}
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

if [ -f "$OUT3/antigravity.cmd" ]; then
  grep -q -- "--add-dir $OUT3/.agy-ws-antigravity" "$OUT3/antigravity.cmd" \
    && pass "agy first --add-dir is throwaway workspace" \
    || fail "agy workspace add-dir: $(cat "$OUT3/antigravity.cmd")"
  grep -q -- "-p Read\\ the\\ file\\ $OUT3/.agy-ws-antigravity/REVIEW_PROMPT.md" "$OUT3/antigravity.cmd" \
    || grep -q "REVIEW_PROMPT.md" "$OUT3/antigravity.cmd" \
    && pass "agy -p names REVIEW_PROMPT.md by absolute path" \
    || fail "agy -p path: $(cat "$OUT3/antigravity.cmd")"
  if grep -q 'current working directory' "$OUT3/antigravity.cmd"; then
    fail "agy -p still depends on launch cwd"
  else
    pass "agy -p does not mention launch cwd"
  fi
else
  fail "antigravity.cmd missing for path checks"
fi

OUT4="$TMP/out4"
bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT4" \
  --agents antigravity \
  --add-dir /tmp \
  --dry-run >/dev/null
if [ -f "$OUT4/antigravity.cmd" ] && grep -q -- '--add-dir /tmp' "$OUT4/antigravity.cmd"; then
  pass "agy forwards extra --add-dir"
else
  fail "agy missing extra --add-dir: $(cat "$OUT4/antigravity.cmd" 2>/dev/null)"
fi

echo "looks_like_review"
STUB="$TMP/agy-stub.md"
cat > "$STUB" <<'STUB'
I have launched a search for REVIEW_PROMPT.md across the repository to locate the file. The requested file was not found in the current working directory (/Users/matthew.oriordan/Projects/matt-os).

Please check the file path or provide the instructions directly.
STUB
if counsel_looks_like_review "$STUB" "$PROMPT"; then
  fail "269-byte REVIEW_PROMPT stub counted as a review"
else
  pass "REVIEW_PROMPT stub is not a review"
fi

REAL="$TMP/real-review.md"
cat > "$REAL" <<'REV'
## Summary
Looks fine.

## Critical Issues
None.

## Important Issues
None.

## Suggestions
Ship it.
REV
if counsel_looks_like_review "$REAL" "$PROMPT"; then
  pass "structured review still counts"
else
  fail "structured review rejected"
fi

echo "run-review.sh stub must not count as responded"
FAKEBIN="$FAKE/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/agy" <<'EOF'
#!/usr/bin/env bash
# Always emit the historical stub (exit 0, no stderr) so detection is tested
# independently of the launch argv.
cat <<'STUB'
I have launched a search for REVIEW_PROMPT.md across the repository to locate the file. The requested file was not found in the current working directory (/Users/matthew.oriordan/Projects/matt-os).

Please check the file path or provide the instructions directly.
STUB
exit 0
EOF
chmod +x "$FAKEBIN/agy"

OUT5="$TMP/out5"
HOME="$FAKE" PATH="$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT5" \
  --agents antigravity \
  --timeout 15 >"$TMP/out5.json"
if grep -q '^Skipped/failed: antigravity' "$OUT5/antigravity.md"; then
  pass "stub output is marked Skipped/failed"
else
  fail "stub not failed: $(cat "$OUT5/antigravity.md")"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["agents_responded"]==0' "$TMP/out5.json"; then
  pass "stub does not increment agents_responded"
else
  fail "stub counted as responded: $(cat "$TMP/out5.json")"
fi
if [ -d "$OUT5/.agy-ws-antigravity" ]; then
  pass "failed run keeps throwaway workspace"
else
  fail "workspace deleted after stub"
fi

echo "run-review.sh delivers REVIEW_PROMPT.md via first --add-dir"
cat > "$FAKEBIN/agy" <<'EOF'
#!/usr/bin/env bash
# Print-mode stand-in: first --add-dir becomes cwd (confirmed agy 1.1.14).
add=""
prev=""
ptext=""
for a in "$@"; do
  if [ "$prev" = "--add-dir" ] && [ -z "$add" ]; then
    add="$a"
  fi
  if [ "$prev" = "-p" ] || [ "$prev" = "--print" ]; then
    ptext="$a"
  fi
  prev="$a"
done
if [ -n "$add" ]; then
  cd "$add" || true
fi
abs=""
# Last existing path in -p that ends in REVIEW_PROMPT.md
for word in $ptext; do
  case "$word" in
    */REVIEW_PROMPT.md)
      [ -f "$word" ] && abs="$word"
      ;;
  esac
done
if [ -n "$abs" ]; then
  echo PONG
  exit 0
fi
if [ -f ./REVIEW_PROMPT.md ]; then
  echo PONG
  exit 0
fi
echo "I have launched a search for REVIEW_PROMPT.md across the repository to locate the file. The requested file was not found in the current working directory ($(pwd))."
exit 0
EOF
chmod +x "$FAKEBIN/agy"

OUT6="$TMP/out6"
HOME="$FAKE" PATH="$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT6" \
  --agents antigravity \
  --timeout 15 >"$TMP/out6.json"
got6=$(tr -d '[:space:]' < "$OUT6/antigravity.md")
if [ "$got6" = "PONG" ]; then
  pass "agy receives REVIEW_PROMPT.md and follows it"
else
  fail "agy handoff: $(cat "$OUT6/antigravity.md")"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["agents_responded"]==1' "$TMP/out6.json"; then
  pass "successful PONG counts as responded"
else
  fail "PONG not counted: $(cat "$TMP/out6.json")"
fi
if [ ! -d "$OUT6/.agy-ws-antigravity" ]; then
  pass "successful run deletes throwaway workspace"
else
  fail "workspace left after PONG"
fi

echo "run-review.sh names the cause when an agent's sandbox fails"
# Grok's real output (1.0.46) when Docker Desktop makes /var/run/docker.sock a
# symlink. The cause is on the warning line; the error line only points at it.
cat > "$FAKEBIN/grok" <<'EOF'
#!/usr/bin/env bash
echo "warning: sandbox could not be applied: socket deny resolution failed: could not resolve runtime-socket deny path /var/run/docker.sock: endpoint is a symlink" >&2
echo "error: could not apply the 'read-only' sandbox profile; see the warning above for the cause. Refusing to start with its protections missing." >&2
exit 1
EOF
chmod +x "$FAKEBIN/grok"

OUT7="$TMP/out7"
HOME="$FAKE" PATH="$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT7" \
  --agents grok \
  --timeout 15 >"$TMP/out7.json"
want7="Skipped/failed: grok — sandbox: socket deny resolution failed: could not resolve runtime-socket deny path /var/run/docker.sock: endpoint is a symlink"
if [ "$(cat "$OUT7/grok.md")" = "$want7" ]; then
  pass "sandbox failure reports 'sandbox:' and its cause"
else
  fail "sandbox failure: $(cat "$OUT7/grok.md")"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["agents_responded"]==0' "$TMP/out7.json"; then
  pass "sandbox failure does not count as responded"
else
  fail "sandbox failure counted: $(cat "$TMP/out7.json")"
fi

# A sandbox refusal with no warning line still says it was the sandbox.
cat > "$FAKEBIN/grok" <<'EOF'
#!/usr/bin/env bash
echo "error: could not apply the 'counsel-ro' sandbox profile: unknown profile" >&2
exit 1
EOF
OUT8="$TMP/out8"
HOME="$FAKE" PATH="$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT8" \
  --agents grok \
  --timeout 15 >"$TMP/out8.json"
want8="Skipped/failed: grok — sandbox: error: could not apply the 'counsel-ro' sandbox profile: unknown profile"
if [ "$(cat "$OUT8/grok.md")" = "$want8" ]; then
  pass "sandbox error line alone still reports 'sandbox:'"
else
  fail "sandbox error only: $(cat "$OUT8/grok.md")"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["agents_responded"]==0' "$TMP/out8.json"; then
  pass "sandbox error does not count as responded"
else
  fail "sandbox error counted: $(cat "$TMP/out8.json")"
fi

# Codex's log holds the prompt and the commands it ran, so it can quote the
# Grok phrases (here: reviewing this very script). Its real error must win.
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "+        line=\$(grep -E -m1 '^warning: sandbox could not be applied: ' \"\$error_file\")" >&2
echo "warning: sandbox could not be applied: quoted from a file Codex read" >&2
echo "ERROR: You've hit your usage limit. Try again in 3 hours." >&2
exit 1
EOF
chmod +x "$FAKEBIN/codex"
OUT9="$TMP/out9"
HOME="$FAKE" PATH="$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT9" \
  --agents codex \
  --timeout 15 >"$TMP/out9.json"
want9="Skipped/failed: codex — ERROR: You've hit your usage limit. Try again in 3 hours."
if [ "$(cat "$OUT9/codex.md")" = "$want9" ]; then
  pass "sandbox phrases in another agent's log do not hide its error"
else
  fail "codex mislabelled: $(cat "$OUT9/codex.md")"
fi

echo "run-review.sh reaps the MCP servers agy leaves behind"
# npx-shaped config: args[0] is "-y", which the old pgrep pattern turned into
# an option, so nothing was ever reaped.
REAPBIN="$FAKE/reapbin"
PIDS="$FAKE/pids"
TOKEN="counsel-test-mcp-$$-$RANDOM"
mkdir -p "$REAPBIN" "$PIDS"
# Every process these tests start carries $TOKEN in its argv, so cleanup can
# check a PID is still ours before it kills it. Also on an aborted run.
kill_test_procs() {
  local f pid
  for f in "$PIDS"/*.pid "$PIDS"/*.child; do
    [ -s "$f" ] || continue
    pid=$(cat "$f")
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in
      *"$TOKEN"*) kill -9 "$pid" 2>/dev/null || true ;;
    esac
  done
}
trap 'kill_test_procs; rm -rf "$FAKE"' EXIT
cat > "$FAKE/.gemini/config/mcp_config.json" <<JSON
{"mcpServers":{"npx-server":{"command":"npx","args":["-y","$TOKEN"]}}}
JSON
# Stand-in server. It ignores SIGTERM like the servers that leaked, and runs
# a child the way `npm exec` runs the real server. The child's argv names no
# server, so only the walk from its parent reaches it.
cat > "$REAPBIN/counsel-test-mcp" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
( exec -a "child-of-$COUNSEL_TEST_TOKEN" sleep 300 ) &
echo $! > "$COUNSEL_TEST_PIDS/$COUNSEL_TEST_ROLE.child"
echo $$ > "$COUNSEL_TEST_PIDS/$COUNSEL_TEST_ROLE.pid"
wait
EOF
# Stand-in agy: starts its server, then exits without stopping it. Before it
# exits it waits for the decoy, and for run-review.sh to record the server
# and its child (in .agy-tree-antigravity next to the --add-dir workspace),
# so the result does not depend on the poll interval.
cat > "$REAPBIN/agy" <<'EOF'
#!/usr/bin/env bash
prev="" ws=""
for a in "$@"; do
  if [ "$prev" = "--add-dir" ] && [ -z "$ws" ]; then ws="$a"; fi
  prev="$a"
done
record="$(dirname "$ws")/.agy-tree-antigravity"
COUNSEL_TEST_ROLE=server counsel-test-mcp exec "$COUNSEL_TEST_TOKEN" </dev/null >/dev/null 2>&1 &
: > "$COUNSEL_TEST_PIDS/agy-started"
# Each stand-in server writes its .pid file last.
for _ in $(seq 200); do
  if [ -s "$COUNSEL_TEST_PIDS/server.pid" ] && [ -s "$COUNSEL_TEST_PIDS/decoy.pid" ] \
    && grep -q "^$(cat "$COUNSEL_TEST_PIDS/server.pid")"$'\t' "$record" \
    && grep -q "^$(cat "$COUNSEL_TEST_PIDS/server.child")"$'\t' "$record"; then
    break
  fi
  sleep 0.05
done
echo PONG
EOF
chmod +x "$REAPBIN/counsel-test-mcp" "$REAPBIN/agy"
# Decoy: the same command, started during the run by something other than
# agy, and orphaned too. Only ancestry tells it apart, and it must survive.
(
  for _ in $(seq 200); do
    [ -f "$PIDS/agy-started" ] && break
    sleep 0.05
  done
  ( COUNSEL_TEST_PIDS="$PIDS" COUNSEL_TEST_TOKEN="$TOKEN" COUNSEL_TEST_ROLE=decoy \
      "$REAPBIN/counsel-test-mcp" exec "$TOKEN" </dev/null >/dev/null 2>&1 & )
) &
OUT10="$TMP/out10"
HOME="$FAKE" PATH="$REAPBIN:$FAKEBIN:$PATH" COUNSEL_TEST_PIDS="$PIDS" COUNSEL_TEST_TOKEN="$TOKEN" \
  bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT10" \
  --agents antigravity \
  --timeout 15 >"$TMP/out10.json"
wait
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
if [ -s "$PIDS/server.pid" ] && ! alive "$PIDS/server.pid" && ! alive "$PIDS/server.child"; then
  pass "orphaned MCP server and its child are reaped"
else
  fail "agy's MCP server left running (server $(cat "$PIDS/server.pid" 2>/dev/null), child $(cat "$PIDS/server.child" 2>/dev/null))"
fi
if alive "$PIDS/decoy.pid" && alive "$PIDS/decoy.child"; then
  pass "a matching process agy did not start is left alone"
else
  fail "decoy MCP server was killed"
fi
kill_test_procs

echo "run-review.sh finalizes when a reaped process is already gone"
# A server can exit between the ps snapshot and kill -9. The kill then fails,
# and under set -e that would end run_agent before finalize_output: a stub
# would stay in antigravity.md as raw text. This ps also lists a server whose
# PID is above every pid_max (99999 on macOS, 4194304 on Linux), so it is
# selected for reaping and the kill always fails.
RACEBIN="$FAKE/racebin"
mkdir -p "$RACEBIN"
REALPS=$(command -v ps)
cat > "$RACEBIN/ps" <<EOF
#!/usr/bin/env bash
"$REALPS" "\$@"
if [ -s "\$COUNSEL_TEST_PIDS/agy.pid" ]; then
  printf ' 99999999 %s Mon Jan  1 00:00:00 2024 counsel-test-mcp exec %s\n' \\
    "\$(cat "\$COUNSEL_TEST_PIDS/agy.pid")" "\$COUNSEL_TEST_TOKEN"
fi
EOF
cat > "$RACEBIN/agy" <<'EOF'
#!/usr/bin/env bash
prev="" ws=""
for a in "$@"; do
  if [ "$prev" = "--add-dir" ] && [ -z "$ws" ]; then ws="$a"; fi
  prev="$a"
done
record="$(dirname "$ws")/.agy-tree-antigravity"
echo $$ > "$COUNSEL_TEST_PIDS/agy.pid"
for _ in $(seq 200); do
  grep -q '^99999999'$'\t' "$record" 2>/dev/null && break
  sleep 0.05
done
echo "I have launched a search for REVIEW_PROMPT.md across the repository to locate the file. The requested file was not found in the current working directory ($(pwd))."
EOF
chmod +x "$RACEBIN/ps" "$RACEBIN/agy"
OUT11="$TMP/out11"
HOME="$FAKE" PATH="$RACEBIN:$FAKEBIN:$PATH" COUNSEL_TEST_PIDS="$PIDS" COUNSEL_TEST_TOKEN="$TOKEN" \
  bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT11" \
  --agents antigravity \
  --timeout 15 >"$TMP/out11.json"
if grep -q '^Skipped/failed: antigravity' "$OUT11/antigravity.md"; then
  pass "a failed kill does not skip finalize"
else
  fail "finalize skipped: $(cat "$OUT11/antigravity.md")"
fi

echo "run-review.sh finalizes when ps fails"
mkdir -p "$FAKE/psfail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/psfail/ps"
cat > "$FAKE/psfail/agy" <<'EOF'
#!/usr/bin/env bash
echo "I have launched a search for REVIEW_PROMPT.md across the repository to locate the file. The requested file was not found in the current working directory ($(pwd))."
exit 0
EOF
chmod +x "$FAKE/psfail/ps" "$FAKE/psfail/agy"
OUT12="$TMP/out12"
HOME="$FAKE" PATH="$FAKE/psfail:$FAKEBIN:$PATH" bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT12" \
  --agents antigravity \
  --timeout 15 >"$TMP/out12.json"
if grep -q '^Skipped/failed: antigravity' "$OUT12/antigravity.md"; then
  pass "a failing ps does not skip finalize"
else
  fail "finalize skipped: $(cat "$OUT12/antigravity.md")"
fi

echo "run-review.sh never reaps agy's own helpers"
# A filesystem server rooted at the repo is a common config. Its arg is the
# repo path, which agy's own argv also holds (--add-dir). Only the launch
# chain exclusion stops agy counting as a server, and so stops the walk
# reaching a helper such as --bg-updater.
# A server whose parent outlives agy (here, hosted by a long-lived helper) is
# not an orphan, so it must survive too.
CHAINBIN="$FAKE/chainbin"
CHAINREPO="$FAKE/chain-repo"
mkdir -p "$CHAINBIN" "$CHAINREPO"
cat > "$FAKE/.gemini/config/mcp_config.json" <<JSON
{"mcpServers":{"fs":{"command":"counsel-test-fs","args":["$CHAINREPO"]}}}
JSON
cat > "$CHAINBIN/agy-helper" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$COUNSEL_TEST_PIDS/helper.pid"
exec -a "agy-helper-$COUNSEL_TEST_TOKEN" sleep 300
EOF
cat > "$CHAINBIN/agy-host" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$COUNSEL_TEST_PIDS/host.pid"
counsel-test-fs "$COUNSEL_TEST_REPO" "$COUNSEL_TEST_TOKEN" </dev/null >/dev/null 2>&1 &
wait
EOF
# Keeps its argv (no exec), so it names the fs server for the whole run.
cat > "$CHAINBIN/counsel-test-fs" <<'EOF'
#!/usr/bin/env bash
( exec -a "child-of-$2" sleep 300 ) &
echo $! > "$COUNSEL_TEST_PIDS/hosted.child"
echo $$ > "$COUNSEL_TEST_PIDS/hosted.pid"
wait
EOF
cat > "$CHAINBIN/agy" <<'EOF'
#!/usr/bin/env bash
prev="" ws=""
for a in "$@"; do
  if [ "$prev" = "--add-dir" ] && [ -z "$ws" ]; then ws="$a"; fi
  prev="$a"
done
record="$(dirname "$ws")/.agy-tree-antigravity"
agy-helper --bg-updater </dev/null >/dev/null 2>&1 &
agy-host "$COUNSEL_TEST_TOKEN" </dev/null >/dev/null 2>&1 &
for _ in $(seq 200); do
  if [ -s "$COUNSEL_TEST_PIDS/helper.pid" ] && [ -s "$COUNSEL_TEST_PIDS/hosted.pid" ] \
    && grep -q "^$(cat "$COUNSEL_TEST_PIDS/helper.pid")"$'\t' "$record" \
    && grep -q "^$(cat "$COUNSEL_TEST_PIDS/hosted.pid")"$'\t' "$record"; then
    break
  fi
  sleep 0.05
done
echo PONG
EOF
chmod +x "$CHAINBIN/agy-helper" "$CHAINBIN/agy-host" "$CHAINBIN/counsel-test-fs" "$CHAINBIN/agy"
OUT13="$TMP/out13"
( cd "$CHAINREPO" && HOME="$FAKE" PATH="$CHAINBIN:$FAKEBIN:$PATH" COUNSEL_TEST_PIDS="$PIDS" COUNSEL_TEST_TOKEN="$TOKEN" \
  COUNSEL_TEST_REPO="$CHAINREPO" \
  bash "$SCRIPT_DIR/run-review.sh" \
  --config "$CFG" \
  --prompt-file "$PROMPT" \
  --output-dir "$OUT13" \
  --agents antigravity \
  --timeout 15 >"$TMP/out13.json" )
if alive "$PIDS/helper.pid"; then
  pass "agy's helper survives a server arg that agy's argv also holds"
else
  fail "agy's helper was killed"
fi
if alive "$PIDS/hosted.pid"; then
  pass "a server whose parent is still running is left alone"
else
  fail "a server hosted by a running parent was killed"
fi
kill_test_procs

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
