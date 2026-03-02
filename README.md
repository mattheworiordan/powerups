# Powerups

Developer powerups for coding, automation, and AI effectiveness.

---

## Cross-Platform Skills

These skills work with any agent that supports the [Agent Skills](https://agentskills.io) standard — [Claude Code](https://code.claude.com), [Codex](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli), [OpenCode](https://github.com/opencode-ai/opencode), [Cursor](https://cursor.com), and more.

```bash
# Install all skills
npx skills add mattheworiordan/powerups

# Install a specific skill
npx skills add mattheworiordan/powerups --skill counsel
npx skills add mattheworiordan/powerups --skill domain-search
npx skills add mattheworiordan/powerups --skill tldr
npx skills add mattheworiordan/powerups --skill worktree
npx skills add mattheworiordan/powerups --skill worktree-cleanup
```

| Skill | Description | Docs |
|-------|-------------|------|
| [**Counsel**](skills/counsel/) | Multi-agent code review — fans out to Codex, Gemini, OpenCode, and Claude Code in parallel, then synthesizes findings | [README](skills/counsel/README.md) |
| [**Domain Search**](skills/domain-search/) | Domain name availability checking with RDAP/WHOIS verification and AI-generated alternatives | [README](skills/domain-search/README.md) |
| [**TL;DR**](skills/tldr/) | Condense long AI-generated documents for sharing — acts as a critical first reader, surfaces issues, then creates a concise summary using the Pyramid Principle | [README](skills/tldr/README.md) |
| [**Worktree**](skills/worktree/) | Git worktree creation with automatic branch naming, env files, and dependency installation | [README](skills/worktree/README.md) |
| [**Worktree Cleanup**](skills/worktree-cleanup/) | Interactive listing and removal of git worktrees with safety checks | [README](skills/worktree-cleanup/README.md) |

---

## Claude Code Plugins

These require [Claude Code](https://code.claude.com) — they use sub-agents, slash commands, and other Claude Code-specific features that aren't available in other agents.

### Installing the marketplace

First, add the powerups marketplace to Claude Code:

```bash
/plugin marketplace add mattheworiordan/powerups
```

Then install the plugins you want:

```bash
/plugin install colony@powerups-marketplace
```

You can also install the cross-platform skills as a Claude Code plugin (if you prefer plugin install over `npx skills`):

```bash
/plugin install powerups@powerups-marketplace
```

### Colony

<img src="plugins/colony/assets/colony-logo.jpg" alt="Colony" width="200">

**Your AI swarm for serious software engineering.**

Colony turns Claude Code into a parallel task execution engine with independent verification. Give it a complex task, and it spawns a colony of specialized workers — each with fresh context, each verified by an independent inspector.

| Command | Purpose |
|---------|---------|
| `/colony-quick` | Quick execution from a simple prompt |
| `/colony-mobilize` | Prepare a brief with parallelized tasks |
| `/colony-deploy` | Deploy workers with smart parallelization |
| `/colony-status` | Show project status |
| `/colony-projects` | List all projects |

**Same speed as sequential approaches, dramatically better quality.** Benchmarked: 0 lint errors vs 419, 3.3x less code, PR-ready output.

> Previously at [mattheworiordan/colony](https://github.com/mattheworiordan/colony) (now archived).

[Full Colony documentation](plugins/colony/README.md) | [Benchmarks](plugins/colony/benchmarks/)

---

## Repo Structure

```
powerups/
├── skills/                     # Cross-platform skills (Agent Skills standard)
│   ├── counsel/                # Multi-agent review
│   ├── domain-search/          # Domain availability checking
│   ├── tldr/                   # Document condenser for sharing
│   ├── worktree/               # Git worktree creation
│   └── worktree-cleanup/       # Git worktree cleanup
├── plugins/                    # Claude Code plugins
│   └── colony/                 # Parallel task execution
│       ├── commands/           # /colony-* slash commands
│       ├── agents/             # Sub-agents (worker, inspector, summarizer)
│       ├── bin/                # CLI tool for state management
│       ├── assets/             # Screenshots and images
│       └── benchmarks/         # Performance comparisons
└── .claude-plugin/             # Marketplace manifest
```

## License

MIT
