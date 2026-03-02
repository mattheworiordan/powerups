---
name: counsel
description: Multi-agent review using local coding agents (Codex, Gemini, Claude Code). Fan out review requests to multiple agents in parallel, then synthesize their findings. Use when you want a second (or third) opinion on code changes, plans, documents, or architecture decisions.
version: 1.1.0
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
COUNSEL_DIR=$(find ~/.claude ~/.claude-personal ~/.claude-work ~/Projects -path "*/counsel/scripts/detect-agents.sh" -print -quit 2>/dev/null | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
echo "COUNSEL_DIR=$COUNSEL_DIR"
```

If empty, you can still run the Claude Code sub-agent review (step 5b). Tell the user external agents need the scripts directory.

### 3. Gather Review Context

Based on the user's request, gather the content to review:

| User Request | What to Gather |
|--------------|----|
| `/counsel` (no topic) | `git diff` + `git diff --cached` |
| "review recent commits" | `git log -5 --oneline` + `git diff HEAD~5..HEAD` |
| "review this PR" / "review PR #123" | `git diff main...HEAD` or `gh pr diff` |
| "review [specific file/path]" | Read the specified file(s) |
| general topic | Gather relevant files |

### 4. Write the Review Prompt

Write the gathered context to a temp file with review instructions:

```bash
PROMPT_FILE=$(mktemp /tmp/counsel-prompt-XXXXXX.md)
```

The prompt MUST include:
1. "You are an independent code reviewer. DO NOT modify, write, or create any files."
2. The gathered context (diff, file contents, etc.)
3. "Provide feedback by severity: critical, important, suggestion."
4. "Format as markdown: Summary, Critical Issues, Important Issues, Suggestions."

### 5. Fan Out to ALL Enabled Agents in Parallel

You MUST launch all enabled agents simultaneously. This is the core of the skill.

**5a. Launch external CLI agents** (Codex, Gemini) via the review script as a background Bash command:

```bash
REVIEW_DIR=$(mktemp -d /tmp/counsel-reviews-XXXXXX)
bash "$COUNSEL_DIR/scripts/run-review.sh" \
  --config ~/.config/counsel/config.json \
  --prompt-file "$PROMPT_FILE" \
  --output-dir "$REVIEW_DIR" \
  --exclude claude
```

Run this as a **background** Bash command (run_in_background=true).

**5b. Launch Claude Code sub-agent** via the Task tool at the SAME TIME as 5a:

```
Task(
  subagent_type="general-purpose",
  description="Counsel review",
  prompt="You are an independent code reviewer performing a READ-ONLY review.
DO NOT modify, write, or create any files. DO NOT run commands that change state.
Analyze and report findings only.

{PASTE THE REVIEW CONTEXT HERE}

Provide specific, actionable feedback by severity (critical, important, suggestion).
Format as markdown with sections: Summary, Critical Issues, Important Issues, Suggestions.",
  run_in_background=true
)
```

**IMPORTANT**: Launch BOTH 5a and 5b in the same message so they run in parallel.

### 6. Collect Results

Wait for both background tasks to complete.

Read the external agent output files from `$REVIEW_DIR/`:
- `$REVIEW_DIR/codex.md`
- `$REVIEW_DIR/gemini.md`

The Claude Code sub-agent returns its review directly.

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

### Gemini
{gemini review output, or "Skipped/failed: {reason}"}

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

Which would you like to enable? Reply with the names, e.g. "codex, gemini" or "all".
```

### Step 3: Save Config

Write to `~/.config/counsel/config.json`:

```json
{
  "agents": {
    "codex": { "enabled": true },
    "gemini": { "enabled": true },
    "claude": { "enabled": true }
  }
}
```

Then return to step 2 of the Execution Flow.

---

## Agent Read-Only Modes

All agents run read-only:

| Agent | Invocation | Why It's Read-Only |
|-------|-----------|-------------------|
| Codex | `codex exec --full-auto - < prompt` | Non-interactive sandboxed execution. Prompt piped via stdin. `--full-auto` enables sandboxed auto-execution. |
| Gemini | `gemini -p "prompt" --allowed-mcp-server-names none` | Non-interactive, MCP disabled, no auto-approval for tool calls. |
| Claude Code | Task() sub-agent with read-only prompt | Prompt-based restriction. |

## Error Handling

- Agent not installed: skip with message
- Agent times out: skip with message (5-minute default timeout)
- Agent errors: report error, continue with others
- No agents configured: tell user to run `/counsel config`
- Script not found: fall back to Claude Code sub-agent only
