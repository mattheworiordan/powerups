---
name: counsel
description: Multi-agent review using local coding agents (Codex, Antigravity/Gemini, Grok CLI, Claude Code). Fan out review requests to multiple agents in parallel, then synthesize their findings. Use when you want a second (or third) opinion on code changes, plans, documents, or architecture decisions.
version: 1.3.0
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

If `.parity` is `"mismatch"`, show the user each line of `.warnings` and ask
before proceeding:

```
⚠️  MCP capability mismatch between review agents:

  • {warning}

These agents will review with less context than the others. Proceed anyway? (yes/no)
```

Wait for an explicit yes. If they'd rather fix it first, the warning text names the
remedy (typically authenticating a server). If the script is missing or errors,
skip this step silently — it's a quality check, not a gate.

### 5. Fan Out to ALL Enabled Agents in Parallel

You MUST launch all enabled agents simultaneously. This is the core of the skill.

Detect the host agent first. Exclude the host from the CLI fan-out so it does not nest inside itself.

| You are | `--exclude` | Host review (5b) |
|---------|-------------|------------------|
| Claude Code | `claude` | Task() / general-purpose sub-agent |
| Grok CLI | `grok` | spawn_subagent (read-only prompt) |
| Codex / Antigravity / other | the host name if it is in the config | none — that agent is already in 5a via CLI, or skipped |

**5a. Launch external CLI agents** via the review script as a background Bash command:

```bash
rm -rf /tmp/counsel-reviews-*  # clean up stale review dirs
REVIEW_DIR=$(mktemp -d /tmp/counsel-reviews-XXXXXX)
bash "$COUNSEL_DIR/scripts/run-review.sh" \
  --config ~/.config/counsel/config.json \
  --prompt-file "$PROMPT_FILE" \
  --output-dir "$REVIEW_DIR" \
  --exclude HOST
```

Replace `HOST` with `claude` or `grok` as in the table. Run this as a **background** Bash command (run_in_background=true).

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

### Step 2: Ask User Which to Enable

List the detected agents and ask which to enable:

```
I detected the following agents: [list from Step 1]
Claude Code (sub-agent) is always available.

Which would you like to enable? Reply with the names, e.g. "codex, antigravity, grok" or "all".
```

### Step 3: Save Config

Write to `~/.config/counsel/config.json`:

```json
{
  "agents": {
    "codex": { "enabled": true },
    "antigravity": { "enabled": true },
    "gemini": { "enabled": true },
    "grok": { "enabled": true },
    "claude": { "enabled": true }
  }
}
```

Agent names are stable config keys, not binary names — `antigravity` runs the
`agy` binary. Leaving an agent enabled when its CLI isn't installed is harmless;
it is skipped with a message. Keep both `antigravity` and `gemini` enabled if you
work across machines that haven't all migrated.

Then return to step 2 of the Execution Flow.

---

## Agent Read-Only Modes

All agents run read-only:

| Agent | Invocation | Why It's Read-Only |
|-------|-----------|-------------------|
| Codex | `codex exec --full-auto - < prompt` | Non-interactive sandboxed execution. Prompt piped via stdin. `--full-auto` enables sandboxed auto-execution. |
| Antigravity | `agy -p "prompt" --add-dir <repo>` from a throwaway workspace | Prompt-based restriction. Repo is added for reading; scratch output lands in the workspace, which is deleted. |
| Grok | `grok --prompt-file … --sandbox read-only --yolo` | Kernel sandbox (read-only) plus write tools denied. `--yolo` auto-approves so a mandated MCP call cannot stall the run. |
| Gemini *(retired)* | `gemini -p "prompt" --allowed-mcp-server-names none` | Non-interactive, MCP disabled, no auto-approval for tool calls. |
| Claude Code | Task() sub-agent with read-only prompt | Prompt-based restriction. |

**Strength of each guarantee, honestly.** None of these is a hard read-only mode.
Codex's `--full-auto` is a *sandbox*, not a read-only flag — it can write within it.
The Claude sub-agent is restricted by its prompt. Antigravity exposes no
per-invocation read-only mode at all: `--mode plan` only steers tool selection, and
permission `allow` rules in a workspace `.agents/settings.json` are ignored. So the
real guarantee across all three is the prompt instruction plus each tool's sandbox.
Treat counsel as a review tool, not a security boundary — don't point it at a
working tree you can't afford to have touched.

Antigravity *can* be hard-contained by dropping `--add-dir`: the repo then leaves the
workspace entirely and is provably out of scope. That was rejected because it makes
that agent's review much weaker than its peers — it would see only the prompt. If you
want containment over comparability, remove that one flag in `run-review.sh`.

**Why Antigravity gets `--dangerously-skip-permissions` when the others don't.** A global
context file (`~/.gemini/GEMINI.md`) can mandate an MCP call as the agent's first action.
Headless mode cannot approve MCP interactively, so it is auto-denied — and the agent then
stalls and returns an **empty** review. Allowing tool calls is what makes the run complete.

## Error Handling

- Agent not installed: skip with message
- Agent times out: skip with message (5-minute default timeout)
- Agent errors: report error, continue with others
- No agents configured: tell user to run `/counsel config`
- Script not found: fall back to Claude Code sub-agent only
