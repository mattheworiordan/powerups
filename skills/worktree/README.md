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
/worktree                         # Asks what you're working on
```

### What It Does

1. Parses your branch name (adds type prefix if needed)
2. Creates `.git-worktree/{name}/` directory
3. Creates a new git branch from your current branch
4. Copies environment files (framework-aware: `.env.local` for Next.js, `.env` for others)
5. Installs dependencies (detects npm/yarn/pnpm/bun/bundle/pip/cargo/go)
6. Reports success with the path to your new worktree

### Convention

Worktrees are stored in `.git-worktree/` within the project root. Add this to your global gitignore:

```bash
echo '.git-worktree' >> ~/.gitignore_global
git config --global core.excludesfile ~/.gitignore_global
```

---

## See Also

- [Worktree Cleanup](../worktree-cleanup/) — List and remove old worktrees
- [Full SKILL.md](./SKILL.md) — Detailed step-by-step instructions and edge cases
