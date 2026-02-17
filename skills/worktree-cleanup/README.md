# Worktree Cleanup

**Interactively list and remove git worktrees.**

---

## Why Worktree Cleanup?

After working with multiple worktrees, your `.git-worktree/` directory accumulates old branches. Cleanup shows you the status of each one — merged or not, uncommitted changes, age — and lets you selectively remove them.

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

1. Lists all worktrees in `.git-worktree/` with status details
2. Shows branch name, merge status, uncommitted changes, last modified date
3. Asks which to remove (by number, "merged" for all merged, or "none")
4. Requires explicit confirmation for worktrees with uncommitted changes or unmerged branches
5. Removes selected worktrees and optionally deletes their branches
6. Prunes stale git worktree references

---

## See Also

- [Worktree](../worktree/) — Create new worktrees with automatic setup
- [Full SKILL.md](./SKILL.md) — Detailed step-by-step instructions and safety rules
