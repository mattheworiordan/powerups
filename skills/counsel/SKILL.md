---
name: counsel
description: Multi-agent review using local coding agents (Codex, Antigravity, Grok CLI, Claude Code). Fan out review requests to multiple agents in parallel, then synthesize their findings. Use when you want a second (or third) opinion on code changes, plans, documents, or architecture decisions.
version: 1.7.0
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
  "$HOME/Projects/powerups/skills/counsel"; do
  if [ -f "$d/scripts/detect-agents.sh" ]; then
    COUNSEL_DIR=$(cd "$d" && pwd -P)
    break
  fi
done
echo "COUNSEL_DIR=$COUNSEL_DIR"
```

If empty, you can still run the Claude Code sub-agent review (step 5b). Tell the user external agents need the scripts directory.

Then check whether effort tiers still need a one-time ask:

```bash
bash "$COUNSEL_DIR/scripts/detect-setup.sh" --local-caller --config ~/.config/counsel/config.json
```

Use `.effort.needs_setup` to decide whether to configure effort. Profile chooser
metadata is legacy: local Claude calls always use the original personal profile.
Do not discover, inspect, select or ask about other Claude accounts for this path.

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

### 4b. Supply the Same Evidence

Put all necessary review evidence in the prompt. Claude's local caller disables
CLAUDE.md, skills, hooks, slash commands and MCP with safe mode; it does not use
MCP servers configured on disk. Grok exposes native shell, file and web tools,
with no MCP execution. Codex ignores user config by default; enabling
`agents.codex.useUserConfig` opts into its user MCP configuration. Antigravity retains its native context and receives MCP cache hints; those hints do not prove live connections. Do not claim runtime MCP parity from config files.

Claude's init event can inventory installed plugins. Treat those names as disk
inventory, not injected context, only after an isolation probe's answer reports
no custom instructions, skills, hooks or MCP. See [the caller contract](README.md#shared-cli-caller).

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

**Pick effort before 5a** (do not prompt if already decided):

- **Profile.** Local Claude calls use `~/.claude-personal` and the real OS home.
  Omit `--claude-config-dir` or pass that exact directory. Other explicit or
  legacy profile choices fail before launch. Never select the work profile.
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
  --effort EFFORT
```

Replace `HOST` and `EFFORT` (`standard` or `extra`). Optional: `--add-dir PATH`
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
- `$REVIEW_DIR/claude.md` (only when the host is not Claude Code)

All four agents retain `$REVIEW_DIR/<agent>.call/` with raw stdout,
stderr and `result.json`. Only completed successful answers count as responses.
Keep failure diagnostics until the failure has been understood.

Only files that exist will be present — agents whose CLI isn't installed are skipped. Old unsupported configuration entries are ignored.

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
bash "$COUNSEL_DIR/scripts/detect-agents.sh" --local-caller
```

### Step 2: Ask only what is missing

Run `detect-setup.sh --local-caller` (and `detect-agents.sh --local-caller` if agents are unset). Ask **only**
the parts whose `needs_setup` is true.

**Agents** (if no `agents` map yet):

```
I detected: [list]. Which should Counsel enable? e.g. "codex, antigravity, grok" or "all".
```

Local Claude calls require the original `~/.claude-personal` profile. Do not
inspect other accounts or ask for a profile chooser. Existing `claude.profiles`
metadata can stay in config for legacy tooling; the local caller does not use it
to choose an account. Explicit non-personal overrides are rejected.

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

### Step 3: Save Config

Merge into `~/.config/counsel/config.json` (do not drop keys you did not ask about):

```json
{
  "agents": {
    "codex": { "enabled": true },
    "antigravity": { "enabled": true },
    "grok": { "enabled": true },
    "claude": { "enabled": true }
  },
  "effort": {
    "standard": { "claudeModel": "opus",  "codexEffort": "high",  "timeout": 300 },
    "extra":    { "claudeModel": "fable", "codexEffort": "xhigh", "timeout": 600 }
  }
}
```

Agent names are stable config keys, not binary names (`antigravity`
→ `agy`). An enabled agent whose CLI is missing is skipped.

Then return to step 3 of the Execution Flow.

---

## Agent Read-Only Modes

All agents run read-only:

| Agent | Invocation | Why It's Read-Only |
|-------|-----------|-------------------|
| Codex | `codex exec --ignore-user-config -s read-only --output-last-message … - < prompt` | Sandbox is read-only. User MCP is stripped by default so the review finishes (`agents.codex.useUserConfig: true` to keep it). |
| Antigravity | `agy -p "Read the file <abs>/REVIEW_PROMPT.md …" --add-dir <throwaway-ws> --add-dir <repo>` (print mode ignores launch cwd; `--add-dir` is the workspace) | Prompt-based restriction. Still runs when a remote MCP is down; the prompt includes cached MCP schema hints, which do not prove live connections. |
| Grok | `grok --prompt-file … --sandbox read-only --always-approve --tools …` | Kernel sandbox (read-only) plus write tools denied. `--always-approve` avoids unattended prompts; explicit native tools exclude MCP execution. |
| Claude (CLI) | Personal `claude --safe-mode -p --output-format stream-json --verbose` with prompt on stdin, strict empty MCP and no permission prompts | Explicit Read, Glob, Grep, WebSearch and WebFetch tools; no Bash, Edit or Write. No custom instructions, skills, hooks or MCP are injected. |

**Strength of each guarantee.** Codex and Grok enforce native read-only sandboxes.
Claude CLI removes shell and write tools. The Claude sub-agent is restricted by its prompt. Antigravity exposes no
per-invocation read-only mode at all: `--mode plan` only steers tool selection, and
permission `allow` rules in a workspace `.agents/settings.json` are ignored. So the
guarantee depends on the agent: native sandboxes, removed write tools, or a prompt restriction.
Treat counsel as a review tool, not a security boundary — don't point it at a
working tree you can't afford to have touched.

Antigravity's `--add-dir` controls workspace selection; it is not an OS sandbox.
The shared caller retains the repository as an added directory so the agent can
read the same files as the other reviewers.

**Why Antigravity gets `--dangerously-skip-permissions`.** A global
context file (`~/.gemini/GEMINI.md`) can mandate an MCP call as the agent's first action.
Headless mode cannot approve MCP interactively, so it is auto-denied — and the agent then
stalls and returns an **empty** review. Allowing tool calls is what makes the run complete.

## Error Handling

- Agent not installed: skip with message
- Agent times out: skip with a one-line reason (5-minute default timeout). Never paste the user prompt into the review file.
- Agent errors: one-line reason from stderr (limit / auth / unexpected argument). Continue with others.
- Grok sandbox could not be applied: the file reads `Skipped/failed: grok — sandbox: <cause>`. Report it as failed: sandbox with that cause. Grok refused to start without its protections, which is the right outcome. Never rerun it without `--sandbox`. Tell the user the cause and the fix below; do not change their Docker settings or run these commands yourself.
  - Known cause on macOS (seen with Grok 1.0.41–1.0.46): `could not resolve runtime-socket deny path /var/run/docker.sock: endpoint is a symlink`. Grok will not start its sandbox while a container runtime socket is a symlink. Docker Desktop makes that symlink when **Settings → Advanced → Allow the default Docker socket to be used** is on.
  - Fix for the user: turn that setting off. The `docker` CLI keeps working through its `desktop-linux` context; tools that hard-code `/var/run/docker.sock` need `DOCKER_HOST=unix://$HOME/.docker/run/docker.sock`. If `/var/run/docker.sock` is still a symlink afterwards: `sudo /Applications/Docker.app/Contents/MacOS/install remove-socket-symlink-on-startup` and `sudo rm /var/run/docker.sock`.
- Antigravity "file not found / where is REVIEW_PROMPT.md" reply (exit 0, empty stderr): failed review, not a response. The throwaway workspace is kept for inspection.
- Antigravity has no cached MCP schemas: still run it; report the cache inventory without inferring connectivity
- No agents configured: tell user to run `/counsel config`
- Script not found: fall back to Claude Code sub-agent only
