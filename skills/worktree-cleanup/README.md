# Worktree Cleanup

**Interactively list and remove git worktrees.**

---

## Why Worktree Cleanup?

After working with multiple worktrees, your worktree directories accumulate old branches. Cleanup shows you the status of each one — merged or not, uncommitted changes, age — and lets you selectively remove them. Works with both `.git-worktree/` and `.claude/worktrees/` directories.

- **Status overview** — See merged/unmerged status, uncommitted changes, last modified date
- **Safe removal** — Warns before deleting unmerged branches or worktrees with uncommitted changes
- **Batch operations** — Remove all merged worktrees with one command
- **Branch cleanup** — Optionally deletes the associated git branch after removing the worktree

---

## Installation

### Agent Skills (any agent)

```bash
npx skills add mattheworiordan/powerups --skill worktree-cleanup
```

### Claude Code Plugin

Included with the powerups plugin:

```bash
/plugin marketplace add mattheworiordan/powerups
```

---

## Usage

```bash
/worktree-cleanup           # Interactive cleanup of worktrees
```

### What It Does

1. Detects worktree directories (`.git-worktree/` and/or `.claude/worktrees/`)
2. Lists all worktrees with status details (branch, merge status, uncommitted changes, age)
3. Asks which to remove (by number, "merged" for all merged, or "none")
4. Requires explicit confirmation for worktrees with uncommitted changes or unmerged branches
5. Removes selected worktrees and optionally deletes their branches
6. Prunes stale git worktree references

### Claude Code Native Worktrees

Claude Code has built-in worktree support (`claude --worktree`) that stores worktrees at `.claude/worktrees/`. This cleanup skill automatically scans both `.git-worktree/` and `.claude/worktrees/`, so it works regardless of which approach you used to create worktrees.

---

## See Also

- [Worktree](../worktree/) — Create new worktrees with automatic setup
- [Full SKILL.md](./SKILL.md) — Detailed step-by-step instructions and safety rules
