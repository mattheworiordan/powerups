# Counsel

**Multi-agent code review using your local coding agents.**

Counsel fans out review requests to multiple AI coding agents running in parallel, then synthesizes their findings. Unlike API-based review tools, Counsel uses actual agent CLIs with full tool access — they can read files, check git history, and explore the codebase.

All agents receive a **read-only review task**. Enforcement varies: native sandboxes
for Codex and Grok, restricted tools for Claude CLI, and prompt instructions for Antigravity.

---

## Why Counsel?

Single-agent reviews miss things. Different AI agents have different strengths, different blind spots, and sometimes different underlying models. Counsel gives you a **panel of reviewers** instead of a single opinion.

- **Diversity of perspective** — Different agents catch different things
- **Grounded feedback** — Agents have full tool access (files, git, shell), not just the diff
- **Parallel execution** — All agents review simultaneously
- **Read-only reviews** — Each caller applies its supported sandbox, tool restrictions or prompt instructions
- **Zero API keys** — Uses locally installed CLI tools, not API calls

### Supported Agents

| Agent | Review Mode |
|-------|-------------|
| [Codex](https://github.com/openai/codex) | `codex exec` with a native read-only sandbox and typed stream output |
| [Antigravity CLI](https://antigravity.google/product/antigravity-cli) (`agy`) | Headless, from a throwaway workspace with the repo added for reading (read-only by prompt) |
| [Grok CLI](https://x.ai/news/grok-build-cli) | Headless `grok --prompt-file` with `--sandbox read-only` |
| [Claude Code](https://code.claude.com) | Sub-agent or personal-profile CLI in safe mode with explicit read tools |


---

## Installation

### Agent Skills (any agent)

```bash
npx skills add mattheworiordan/powerups --skill counsel
```

### Claude Code Plugin

Counsel is included with the powerups plugin:

```bash
/plugin marketplace add mattheworiordan/powerups
```

---

## Usage

```bash
/counsel                        # Review current changes (auto-detects context)
/counsel review the auth refactor
/counsel review this PR
/counsel review the plan in .working/
/counsel config                 # Configure which agents to use
```

### First Run

On first use, Counsel detects which agents are installed and walks you through setup:

1. **Agents** — which CLIs to enable
2. **Claude account** — local CLI calls require the original `~/.claude-personal` profile; no account chooser
3. **Effort** — `standard` vs `extra` (say "try hard" / "extra effort" on a later run). First run lists live CLI models; Claude is opus or fable only.

Configuration is saved to `~/.config/counsel/config.json`. Override per-project with `.counsel/config.json`.

---

## How It Works

1. **Context determination** — Analyzes your request to gather the right context (diff, files, PR, document)
2. **Prompt construction** — Builds a focused review prompt with the relevant context
3. **Fan-out** — Launches all enabled agents in parallel (read-only mode)
4. **Collection** — Waits for all agents to complete (5-minute timeout per agent)
5. **Synthesis** — Presents individual reviews, then synthesizes findings:
   - **Agreement** — Issues all agents flagged (high confidence)
   - **Majority** — Issues 2+ agents flagged
   - **Individual findings** — Unique insights from each agent

### Context Detection

| User Request | Context Gathered |
|--------------|-----------------|
| `/counsel` (no args) | `git diff` + `git diff --cached` |
| "review recent commits" | `git log -5` + `git diff HEAD~5..HEAD` |
| "review this PR" | `git diff main...HEAD` or `gh pr diff` |
| "review [file/plan]" | Reads the specified files |

---

## Cross-Agent Compatibility

Counsel works from any host agent:

| Running From | How the host reviews | How the other agents review |
|-------------|----------------------|-----------------------------|
| **Claude Code** | Task() sub-agent (richest review — can explore beyond the diff) | CLI processes via `run-review.sh` (includes Grok) |
| **Grok CLI** | spawn_subagent (read-only prompt) | CLI processes via `run-review.sh` (includes `claude -p ""` on stdin) |
| **Codex** | already in the CLI fan-out | CLI processes via `run-review.sh` |
| **Antigravity** | already in the CLI fan-out | CLI processes via `run-review.sh` |

When running from Claude Code, the Claude review uses a sub-agent (via the Task tool) instead of nesting CLI processes. This avoids the `CLAUDECODE` env var restriction while giving the reviewer full tool access. Grok does the same with `spawn_subagent` and `--exclude grok`.

---

## Tips

- `codex review --uncommitted` is particularly effective — it has a purpose-built review mode
- Supply the same evidence in the prompt for every reviewer. Antigravity still launches when remote MCP is unavailable; schema cache hints are not proof of live connections.
- Claude CLI always uses the original personal profile in safe mode. Pass `--exclude grok,antigravity` to skip more than one agent. `--effort extra` is "try hard".
- Claude Code sub-agent provides the richest review (full tool access to explore beyond the diff)
- The value comes from **diversity** — enable as many agents as you have installed
- Grok reported as `sandbox: … /var/run/docker.sock: endpoint is a symlink`? Grok (seen with 1.0.41–1.0.46) will not start its read-only sandbox while Docker Desktop's **Allow the default Docker socket to be used** setting (Settings → Advanced) is on. Turn that setting off; do not drop `--sandbox`. Tools that hard-code `/var/run/docker.sock` then need `DOCKER_HOST=unix://$HOME/.docker/run/docker.sock`. If the symlink is still there afterwards, see Error Handling in [SKILL.md](SKILL.md).

## Shared CLI caller

`run-review.sh` delegates Claude, Antigravity, Grok and Codex to `scripts/agent-call.py`.
Matt-OS local agents use the same file through `tools/scripts/agents/call.py`.
No shell functions, prompt interpolation or copied credentials are involved.

```bash
python3 "$COUNSEL_DIR/scripts/agent-call.py" \
  --agent claude --prompt-file "$PROMPT_FILE" --cwd "$PWD" \
  --output-dir "$NEW_CALL_DIR" --timeout 300
```

The default is read-only. Success prints only the final answer. Every launched
call saves raw `stdout.jsonl`, `stderr.txt` and `result.json` in a new output
directory; `answer.md` exists only on success. `--dry-run` prints a JSON launch
plan. `--model` and `--reasoning-effort` forward CLI-specific choices. Calls are
not retried automatically. Timeouts and cancellation reap only the caller's own
process group. A nonzero exit, error event, partial answer or missing completion
never counts as a review.

Claude uses `~/.local/bin/claude`, the real OS home and the original personal
config directory. Other explicit profiles are refused. It runs with safe mode,
verbose stream JSON, strict empty MCP, disabled slash commands and explicit
read tools. No Bash, Edit or Write is exposed. Supply diffs and history in the
prompt. Safe mode disables CLAUDE.md, skills, hooks and MCP. Installed plugin
names can still appear in init: treat them as uninjected inventory only when an
isolation probe's answer reports none of those customisations. Authentication
failure detection uses error events or stderr, never normal transcript content
that happens to say “not logged in”.

Grok keeps its read-only sandbox and exposes native shell, read and web tools,
with no MCP execution. It uses `--always-approve` from the installed CLI rather
than the removed `--yolo` alias. Codex defaults to `--ignore-user-config`; set
`agents.codex.useUserConfig: true` only when its user MCP is needed. Both retain
their native project instructions; supply the same evidence to all reviewers.

For authorised coding tasks, `--mode workspace-write` enables each CLI's write
capabilities. Codex and Grok keep their native workspace sandbox; Claude enables
Bash, Edit and Write without an OS workspace boundary. Counsel always requests
read-only mode.

Offline checks:

```bash
python3 -m unittest discover -s "$COUNSEL_DIR/scripts" -p test_agent_call.py
bash "$COUNSEL_DIR/scripts/test-run-review.sh"
```

Antigravity (`--agent antigravity`, binary `agy`) uses native stream JSON and the
same outcome, logs and timeout contract as the other agents. Its prompt is saved
as `workspace/REVIEW_PROMPT.md` inside the call directory and named by absolute
path in `-p`. The first `--add-dir` is the throwaway workspace for read-only
reviews, preserving compatibility with print-mode workspace selection. Successful
calls remove that workspace; failures retain it for inspection.

Antigravity has no hard read-only mode: the caller prepends a read-only instruction.
For writable tasks the requested repository becomes its first `--add-dir`.
Recorded process ancestry and start times identify orphaned MCP servers belonging
to the call; unrelated sessions and persistent native helpers are left alone on
normal completion. Cancellation and timeout terminate the owned process group
and reap recorded orphan servers. `~/.gemini` remains Antigravity's native storage
location. Standalone Gemini CLI support has been removed, and old `agents.gemini`
configuration entries are ignored.
