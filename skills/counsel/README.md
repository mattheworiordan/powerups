# Counsel

**Multi-agent code review using your local coding agents.**

Counsel fans out review requests to multiple AI coding agents running in parallel, then synthesizes their findings. Unlike API-based review tools, Counsel uses actual agent CLIs with full tool access — they can read files, check git history, and explore the codebase.

All agents run in **read-only mode** — they review without modifying your codebase.

---

## Why Counsel?

Single-agent reviews miss things. Different AI agents have different strengths, different blind spots, and sometimes different underlying models. Counsel gives you a **panel of reviewers** instead of a single opinion.

- **Diversity of perspective** — Different agents catch different things
- **Grounded feedback** — Agents have full tool access (files, git, shell), not just the diff
- **Parallel execution** — All agents review simultaneously
- **Read-only by design** — Agents cannot modify your codebase
- **Zero API keys** — Uses locally installed CLI tools, not API calls

### Supported Agents

| Agent | Review Mode |
|-------|-------------|
| [Codex](https://github.com/openai/codex) | Built-in `codex review` (inherently read-only) |
| [Antigravity CLI](https://antigravity.google/product/antigravity-cli) (`agy`) | Headless, from a throwaway workspace with the repo added for reading (read-only by prompt) |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) *(retired)* | Non-interactive, MCP disabled, no auto-approval (read-only) |
| [Claude Code](https://code.claude.com) | Sub-agent (via Task tool) or CLI (`claude -p`) |

> **Gemini CLI is retired.** Google stopped serving it for free, Google AI Pro, Ultra
> and individual Code Assist accounts on [18 June 2026](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals);
> only purchased enterprise Code Assist licences still work. Counsel detects both —
> install [Antigravity CLI](https://antigravity.google/docs/cli/install) (`brew install --cask antigravity-cli`,
> or `curl -fsSL https://antigravity.google/cli/install.sh | bash`) and Counsel picks it up
> automatically. Machines still running a working Gemini CLI keep functioning unchanged.

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

1. **Detection** — Scans for installed agent CLIs (codex, antigravity, gemini, claude)
2. **Selection** — Choose which agents to enable

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

| Running From | How Claude Code Reviews | How Codex/Antigravity Review |
|-------------|------------------------|------------------------|
| **Claude Code** | Task() sub-agent (richest review — can explore beyond the diff) | CLI processes via `run-review.sh` |
| **Codex** | CLI process (`claude -p`) | CLI processes via `run-review.sh` |
| **Antigravity** | CLI process (`claude -p`) | CLI processes via `run-review.sh` |

When running from Claude Code, the Claude review uses a sub-agent (via the Task tool) instead of nesting CLI processes. This avoids the `CLAUDECODE` env var restriction while giving the reviewer full tool access.

---

## Tips

- `codex review --uncommitted` is particularly effective — it has a purpose-built review mode
- Counsel checks **MCP parity** before fanning out — if one agent can't reach a server the others have, you're warned before spending a review on it
- Claude Code sub-agent provides the richest review (full tool access to explore beyond the diff)
- The value comes from **diversity** — enable as many agents as you have installed
