---
name: counsel
description: Multi-agent review using local coding agents (Codex, Antigravity/Gemini, Grok CLI, Claude Code). Fan out review requests to multiple agents in parallel, then synthesize their findings. Use when you want a second (or third) opinion on code changes, plans, documents, or architecture decisions.
version: 1.5.1
allowed-tools: Read, Bash, Grep, Glob, Write, Task
argument-hint: "[review topic or 'config']"
---

# Counsel — Multi-Agent Review

**CRITICAL**: You MUST follow the execution flow below. Do NOT review the code yourself. Your job is to ORCHESTRATE reviews by multiple independent agents, then SYNTHESIZE their findings. If you skip the multi-agent flow and review the code directly, you have failed to execute this skill.

---

## Execution Flow

### 1. Check Configuration

If the user said `/counsel config`, jump to the **Configuration** section at the bottom.

Otherwise, check if config exists:

```bash
cat ~/.config/counsel/config.json 2>/dev/null || echo "NO_CONFIG"
```

If `NO_CONFIG`, jump to the **Configuration** section, then return here.

### 2. Locate Scripts

```bash
COUNSEL_DIR=""
for d in \
  "$HOME/.grok/skills/counsel" \
  "$HOME/.codex/skills/counsel" \
  "$HOME/.gemini/antigravity-cli/skills/counsel" \
  "$HOME/.claude/skills/counsel" \
  "$HOME/.claude-personal/skills/counsel" \
  "$HOME/.claude-work/skills/counsel" \
  "$HOME/Projects/powerups/skills/counsel"; do
  if [ -f "$d/scripts/detect-agents.sh" ]; then
    COUNSEL_DIR=$(cd "$d" && pwd -P)
    break
  fi
done
echo "COUNSEL_DIR=$COUNSEL_DIR"
```

If empty, you can still run the Claude Code sub-agent review (step 5b). Tell the user external agents need the scripts directory.

Then check whether profiles / effort still need a one-time ask:

```bash
bash "$COUNSEL_DIR/scripts/detect-setup.sh" --config ~/.config/counsel/config.json
```

If `.needs_setup` is true, jump to **Configuration** (it only asks what is missing), save, then continue. Do not ask on every run once `claude.chooser` and `effort.standard` + `effort.extra` exist. If `.claude_profiles.new` is non-empty, ask only about the new profile and merge it.

### 3. Gather Review Context

Based on the user's request, gather the content to review:

| User Request | What to Gather |
|--------------|----|
| `/counsel` (no topic) | `git diff` + `git diff --cached` |
| "review recent commits" | `git log -5 --oneline` + `git diff HEAD~5..HEAD` |
| "review this PR" / "review PR #123" | `gh pr diff`, or `BASE=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null \|\| echo main); git diff "$BASE"...HEAD` — resolve the PR's real base; a stacked PR targets a sibling branch, so `main...HEAD` would blame it for its parents' diff |
| "review [specific file/path]" | Read the specified file(s) |
| general topic | Gather relevant files |

### 4. Write the Review Prompt

Write the gathered context to a temp file with review instructions.

**IMPORTANT: Clean up stale files first.** Previous sessions may have left temp files that cause `mktemp` collisions or (worse) feed stale prompts to agents silently.

```bash
rm -f /tmp/counsel-prompt-*.md  # prevent stale file collisions
PROMPT_FILE=$(mktemp /tmp/counsel-prompt-XXXXXX.md)
```

After writing the prompt to `$PROMPT_FILE`, **verify it was written correctly**:
```bash
[ -s "$PROMPT_FILE" ] && echo "Prompt ready: $(wc -c < "$PROMPT_FILE") bytes" || echo "ERROR: Prompt file empty!"
```
If the file is empty or missing, do NOT proceed - rewrite it.

The prompt MUST include:
1. "You are an independent code reviewer. DO NOT modify, write, or create any files."
2. The gathered context (diff, file contents, etc.)
3. "Provide feedback by severity: critical, important, suggestion."
4. "Format as markdown: Summary, Critical Issues, Important Issues, Suggestions."

### 4b. Check MCP Parity (before fanning out)

Counsel's value depends on agents reasoning over the **same** material. If one
agent can't reach an MCP server the others have, its review is weaker for a
reason invisible in the output — it reads as disagreement when it's a missing
capability.

```bash
bash "$COUNSEL_DIR/scripts/check-mcp-parity.sh"
```

Read `.parity`, `.warnings`, and `.optional_warnings`.

- `.optional_warnings` are non-blocking (Antigravity remote MCP often fails
  to connect). Tell the user. Do **not** wait. Antigravity still launches; the
  script injects connected vs disconnected servers into its prompt.
- If `.parity` is `"mismatch"`, show each line of `.warnings` and ask before
  proceeding:

```
⚠️  MCP capability mismatch between review agents:

  • {warning}

These agents will review with less context than the others. Proceed anyway? (yes/no)
```

Wait for an explicit yes only on `.warnings`. Pass the same
`--claude-config-dir` you will use in 5a (parity reads that profile). If the
script is missing or errors, skip this step silently — it is a quality check,
not a gate.

### 5. Fan Out to ALL Enabled Agents in Parallel

You MUST launch all enabled agents simultaneously. This is the core of the skill.

Detect the host agent first. Exclude the host from the CLI fan-out so it does not nest inside itself.

| You are | `--exclude` | Host review (5b) |
|---------|-------------|------------------|
| Claude Code | `claude` | Task() / general-purpose sub-agent |
| Grok CLI | `grok` | spawn_subagent (read-only prompt) |
| Codex / Antigravity / other | the host name if it is in the config | none — that agent is already in 5a via CLI, or skipped |

`--exclude` accepts a **comma list** (and may be repeated): `--exclude grok` or
`--exclude grok,antigravity`. From Grok, exclude `grok` only — Claude still
runs as a CLI reviewer.

**Pick Claude profile and effort before 5a** (do not prompt if already decided):

- **Profile.** If `detect-setup.sh` reports 2+ profiles, apply `claude.chooser`
  + each profile's `useWhen` to the review topic. Pass that dir as
  `--claude-config-dir`. One profile → use it. None → omit the flag.
- **Effort.** `standard` unless the user said extra / try hard / think hard /
  deep / thorough (see `effort.phrases` in detect-setup). User-named models
  (`fable`, `opus`) win over the tier.

**5a. Launch external CLI agents** via the review script as a background Bash command:

```bash
rm -rf /tmp/counsel-reviews-*  # clean up stale review dirs
REVIEW_DIR=$(mktemp -d /tmp/counsel-reviews-XXXXXX)
bash "$COUNSEL_DIR/scripts/run-review.sh" \
  --config ~/.config/counsel/config.json \
  --prompt-file "$PROMPT_FILE" \
  --output-dir "$REVIEW_DIR" \
  --exclude HOST \
  --effort EFFORT \
  --claude-config-dir PROFILE_DIR
```

Replace `HOST`, `EFFORT` (`standard` or `extra`), and `PROFILE_DIR`. Omit
`--claude-config-dir` when there is only one profile. Optional: `--add-dir PATH`
(repeatable), `--dry-run` (writes `$REVIEW_DIR/*.cmd` without launching).
Run 5a as a **background** Bash command (run_in_background=true).

**5b. Launch the host's own reviewer** at the SAME TIME as 5a, with a read-only prompt:

```
You are an independent code reviewer performing a READ-ONLY review.
DO NOT modify, write, or create any files. DO NOT run commands that change state.
Analyze and report findings only.

{PASTE THE REVIEW CONTEXT HERE}

Provide specific, actionable feedback by severity (critical, important, suggestion).
Format as markdown with sections: Summary, Critical Issues, Important Issues, Suggestions.
```

Claude Code host → Task() general-purpose sub-agent. Grok CLI host → spawn_subagent. Other hosts skip 5b.

**IMPORTANT**: Launch BOTH 5a and 5b in the same message so they run in parallel.

### 6. Collect Results

Wait for both background tasks to complete.

Read the external agent output files from `$REVIEW_DIR/`:
- `$REVIEW_DIR/codex.md`
- `$REVIEW_DIR/antigravity.md`
- `$REVIEW_DIR/grok.md`
- `$REVIEW_DIR/gemini.md` (only on machines still running the retired Gemini CLI)
- `$REVIEW_DIR/claude.md` (only when the host is not Claude Code)

Only files that exist will be present — agents whose CLI isn't installed are skipped.

The host sub-agent (Claude Task() or Grok spawn_subagent) returns its review directly.

Then clean up:
```bash
rm -f "$PROMPT_FILE"
rm -rf "$REVIEW_DIR"
```

### 7. Present Results and Synthesize

Present ALL agent reviews, then YOUR synthesis. Use this EXACT format:

```markdown
## Counsel Review — {N} agents responded

### Codex
{codex review output, or "Skipped/failed: {reason}"}

### Antigravity
{antigravity review output, or "Skipped/failed: {reason}"}

### Grok
{grok review output, or "Skipped/failed: {reason}"}

### Claude Code (sub-agent)
{claude code review output}

---

### Synthesis

**Agreement** (multiple agents flagged):
- {issue}

**Individual findings**:
- {agent}: {unique finding}

**Recommended actions**:
1. {prioritized action}
```

Focus the synthesis on:
- Points where multiple agents agree (high confidence)
- Unique findings worth investigating
- Prioritized actionable next steps

---

## Configuration

Run this on first use or when the user says `/counsel config`.

### Step 1: Detect Agents

```bash
bash "$COUNSEL_DIR/scripts/detect-agents.sh"
```

### Step 2: Ask only what is missing

Run `detect-setup.sh` (and `detect-agents.sh` if agents are unset). Ask **only**
the parts whose `needs_setup` is true.

**Agents** (if no `agents` map yet):

```
I detected: [list]. Which should Counsel enable? e.g. "codex, antigravity, grok" or "all".
```

**Claude profiles** (if 2+ dirs and no `claude.chooser`, or `.claude_profiles.new`):

```
I found these Claude Code profiles:

  • {id}  {dir}  ({email or "unknown account"})

What is each one for, and when should Counsel use it for a review?
I will save that as a chooser instruction and reuse it.
```

**Effort tiers** (if `effort.standard` or `effort.extra` is missing, or a
tier still names sonnet/haiku):

```bash
bash "$COUNSEL_DIR/scripts/discover-models.sh"
```

Present `.suggestions` and each agent's `.available` list:

```
I listed the models each CLI currently exposes.

  standard — {suggestions.standard}
  extra    — {suggestions.extra}
             (say "extra effort" / "try hard" on a later run)

Claude reviews use opus or fable only — never sonnet/haiku.
Use these recommendations, or name a model for each tier?
```

Do not invent product-specific profile names. Use the user's words.

### Step 3: Save Config

Merge into `~/.config/counsel/config.json` (do not drop keys you did not ask about):

```json
{
  "agents": {
    "codex": { "enabled": true },
    "antigravity": { "enabled": true },
    "gemini": { "enabled": true },
    "grok": { "enabled": true },
    "claude": { "enabled": true }
  },
  "claude": {
    "chooser": "one short instruction: when to pick which profile",
    "profiles": [
      { "id": "work", "dir": "~/.claude-work", "useWhen": "…" },
      { "id": "personal", "dir": "~/.claude-personal", "useWhen": "…" }
    ]
  },
  "effort": {
    "standard": { "claudeModel": "opus",  "codexEffort": "high",  "timeout": 300 },
    "extra":    { "claudeModel": "fable", "codexEffort": "xhigh", "timeout": 600 }
  }
}
```

The `profiles` example ids are placeholders — use the ids `detect-setup.sh`
reported. Agent names are stable config keys, not binary names (`antigravity`
→ `agy`). An enabled agent whose CLI is missing is skipped.

Then return to step 3 of the Execution Flow.

---

## Agent Read-Only Modes

All agents run read-only:

| Agent | Invocation | Why It's Read-Only |
|-------|-----------|-------------------|
| Codex | `codex exec --ignore-user-config -s read-only --output-last-message … - < prompt` | Sandbox is read-only. User MCP is stripped by default so the review finishes (`agents.codex.useUserConfig: true` to keep it). |
| Antigravity | `agy -p "Read the file <abs>/REVIEW_PROMPT.md …" --add-dir <throwaway-ws> --add-dir <repo>` (print mode ignores launch cwd; `--add-dir` is the workspace) | Prompt-based restriction. Still runs when a remote MCP is down; the prompt lists connected servers. |
| Grok | `grok --prompt-file … --sandbox read-only --yolo` | Kernel sandbox (read-only) plus write tools denied. `--yolo` auto-approves so a mandated MCP call cannot stall the run. |
| Gemini *(retired)* | `gemini -p "" … < prompt` | Non-interactive, MCP disabled, no auto-approval for tool calls. |
| Claude Code | Host: Task() / spawn_subagent. CLI: `CLAUDE_CONFIG_DIR=<chosen profile> claude -p "" --model <tier> --permission-mode auto --add-dir <repo> < prompt` | Prompt-based restriction. Profile comes from `claude.chooser`. Prompt is stdin, never `claude -p "$(< file)"`. |

**Strength of each guarantee, honestly.** None of these is a hard read-only mode
except Codex `-s read-only`. The Claude sub-agent is restricted by its prompt. Antigravity exposes no
per-invocation read-only mode at all: `--mode plan` only steers tool selection, and
permission `allow` rules in a workspace `.agents/settings.json` are ignored. So the
real guarantee across all three is the prompt instruction plus each tool's sandbox.
Treat counsel as a review tool, not a security boundary — don't point it at a
working tree you can't afford to have touched.

Antigravity *can* be hard-contained by dropping the repo `--add-dir`: the repo then
leaves the workspace entirely and is provably out of scope. The throwaway workspace
`--add-dir` must stay — print mode treats `--add-dir` as cwd, and that is how the
prompt file is delivered. Dropping the repo flag was rejected because it makes that
agent's review much weaker than its peers — it would see only the prompt. If you want
containment over comparability, remove the repo `--add-dir` in `run-review.sh`.

**Why Antigravity gets `--dangerously-skip-permissions` when the others don't.** A global
context file (`~/.gemini/GEMINI.md`) can mandate an MCP call as the agent's first action.
Headless mode cannot approve MCP interactively, so it is auto-denied — and the agent then
stalls and returns an **empty** review. Allowing tool calls is what makes the run complete.

## Error Handling

- Agent not installed: skip with message
- Agent times out: skip with a one-line reason (5-minute default timeout). Never paste the user prompt into the review file.
- Agent errors: one-line reason from stderr (limit / auth / unexpected argument). Continue with others.
- Antigravity "file not found / where is REVIEW_PROMPT.md" reply (exit 0, empty stderr): failed review, not a response. The throwaway workspace is kept for inspection.
- Antigravity MCP disconnected: still run Antigravity; note the caveat
- No agents configured: tell user to run `/counsel config`
- Script not found: fall back to Claude Code sub-agent only
