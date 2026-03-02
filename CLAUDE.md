# Powerups

Developer powerups for coding, automation, and AI effectiveness.

## Structure

```
powerups/
├── skills/                     # Cross-platform agent skills (Agent Skills standard)
│   ├── counsel/                # Multi-agent review (Codex, Gemini, OpenCode, Claude Code)
│   ├── domain-search/          # Domain name availability checking
│   ├── tldr/                   # Document condenser — critical read, observations, Pyramid Principle summary
│   ├── worktree/               # Git worktree creation with automatic setup
│   └── worktree-cleanup/       # Git worktree listing and cleanup
├── plugins/                    # Claude Code plugins (require sub-agents, CLI tools, etc.)
│   └── colony/                 # Parallel task execution with independent verification
│       ├── .claude-plugin/     # Plugin identity (plugin.json)
│       ├── commands/           # /colony-* slash commands
│       ├── agents/             # Sub-agents: worker, inspector, summarizer
│       └── bin/                # CLI tool (state management)
└── .claude-plugin/             # Marketplace manifest (marketplace.json + root plugin.json)
```

## Two Distribution Channels

1. **Skills** (`skills/`) — Cross-platform, installed via `npx skills add`. Each has a SKILL.md with YAML frontmatter.
2. **Plugins** (`plugins/`) — Claude Code only, installed via `/plugin install`. Contain commands, agents, and CLI tools.

## Development

- Skills must have `name` in frontmatter matching the directory name
- Every skill needs both SKILL.md (for agents) and README.md (for humans)
- Plugin commands/agents are scoped to their plugin directory via `source` in marketplace.json
- Test skills: `npx skills add . --list`
- Test plugins: restart Claude Code after changes

## Cross-Platform Skills

Skills in `skills/` are advertised as cross-platform (Claude Code, Codex, Gemini CLI, Cursor, etc.). Keep them that way:

- **Do not use `AskUserQuestion`** — it is Claude Code-specific and silently fails on other agents. Use natural conversation instead: present options as a numbered list in text and wait for the user's reply.
- **Do not use `Task`** — sub-agent spawning is Claude Code-specific. Skills that need it belong in `plugins/` instead.
- **Stick to portable tools**: `Read`, `Write`, `Bash`, `Grep`, `Glob` work everywhere.
