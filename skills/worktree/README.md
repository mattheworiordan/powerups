# Worktree

**Create git worktrees with automatic project setup.**

---

## Why Worktree?

Git worktrees let you work on multiple branches simultaneously without stashing or switching. But setting up a worktree properly means copying env files, installing dependencies, and configuring the right branch name. This skill automates all of that.

- **Branch naming** — Prompts for type prefix (feature/, fix/, chore/) if missing
- **Env file handling** — Copies `.env`, `.env.local`, etc. with framework-aware conventions
- **Dependency installation** — Detects package manager and installs automatically
- **Framework detection** — Knows Next.js, Vite, Nuxt, Rails, Django, and more

---

## Installation

### Agent Skills (any agent)

```bash
npx skills add mattheworiordan/powerups --skill worktree
```

### Claude Code Plugin

Included with the powerups plugin:

```bash
/plugin marketplace add mattheworiordan/powerups
```

---

## Usage

```bash
/worktree fix-login-bug           # Creates worktree with branch type prompt
/worktree feature/dark-mode       # Already has prefix, used as-is
/worktree --quick auth-fix        # Skips type prefix prompt, uses name directly
/worktree --claude-dir my-task    # Forces .claude/worktrees/ directory
/worktree --git-dir my-task       # Forces .git-worktree/ directory
/worktree                         # Asks what you're working on
```

### What It Does

1. Detects worktree directory (`.git-worktree/` or `.claude/worktrees/`)
2. Parses your branch name (adds type prefix if needed, or skips with `--quick`)
3. Creates the worktree directory and a new git branch from your current branch
4. Copies environment files (framework-aware: `.env.local` for Next.js, `.env` for others)
5. Installs dependencies (detects npm/yarn/pnpm/bun/bundle/pip/cargo/go)
6. Reports success with the path to your new worktree

### Worktree Directory

By default, worktrees are stored in `.git-worktree/` within the project root. If `.claude/worktrees/` already exists (from Claude Code's native worktree feature), that location is used instead.

Add your preferred directory to your global gitignore:

```bash
echo '.git-worktree' >> ~/.gitignore_global
git config --global core.excludesfile ~/.gitignore_global
```

### Claude Code Native Worktrees vs /worktree

Claude Code has built-in worktree support via `claude --worktree`, which creates worktrees at `.claude/worktrees/<name>`. Here's when to use each:

| | `claude --worktree` | `/worktree` |
|---|---|---|
| **Use for** | Quick isolation for parallel Claude sessions | Full workspace setup with env files, deps, branch conventions |
| **Env files** | Not copied | Automatically copied (framework-aware) |
| **Dependencies** | Not installed | Automatically installed |
| **Branch naming** | Uses worktree name | Prompts for type prefix (feature/, fix/, etc.) |
| **Speed** | Instant | Takes a moment (installs deps) |

The two approaches coexist — `/worktree` auto-detects which directory format is in use and works with either location. You can use `--claude-dir` or `--git-dir` to explicitly choose.

---

## See Also

- [Worktree Cleanup](../worktree-cleanup/) — List and remove old worktrees
- [Full SKILL.md](./SKILL.md) — Detailed step-by-step instructions and edge cases
