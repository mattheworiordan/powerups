---
name: worktree-cleanup
description: List and remove git worktrees interactively. Use when someone wants to clean up old worktrees, prune stale branches, or see worktree status.
version: 1.0.0
allowed-tools: Read, Bash, Grep, Glob, AskUserQuestion
---

# Git Worktree Cleanup

Interactively list and remove git worktrees.

## Step 1: List All Worktrees

```bash
# Get all worktrees
git worktree list

# List contents of .git-worktree directory
ls -la .git-worktree/ 2>/dev/null
```

## Step 2: Gather Worktree Details

For each worktree in `.git-worktree/`:

```bash
# Get the branch name
cd .git-worktree/{name}
BRANCH=$(git branch --show-current)

# Get last modified time
stat -f "%Sm" -t "%Y-%m-%d" .git-worktree/{name} 2>/dev/null || \
  stat -c "%y" .git-worktree/{name} 2>/dev/null | cut -d' ' -f1

# Check if branch is merged to main
git branch --merged main | grep -q "{branch}" && echo "MERGED" || echo "NOT_MERGED"

# Check if branch exists on remote
git branch -r | grep -q "origin/{branch}" && echo "REMOTE" || echo "LOCAL_ONLY"

# Check for uncommitted changes
cd .git-worktree/{name}
git status --porcelain | head -5
```

## Step 3: Present Interactive List

Format the output clearly:

```
Found {N} worktrees in .git-worktree/:

1. security-fixes
   Branch: fix/security-fixes
   Last modified: 3 days ago
   Status: ✓ Merged to main

2. dashboard-quick-wins
   Branch: feature/dashboard-quick-wins
   Last modified: 10 days ago
   Status: ⚠ NOT merged to main
   Changes: 2 uncommitted files

3. v6-pricing-terminology
   Branch: feature/v6-pricing
   Last modified: 6 days ago
   Status: ✓ Merged to main

4. worktree-safe-dev
   Branch: feature/worktree-safe-dev
   Last modified: 3 days ago
   Status: ⚠ NOT merged to main
```

## Step 4: Ask User Which to Remove

Use AskUserQuestion with options:

```
Which worktrees should I remove?

Options:
- Specific numbers (e.g., "1, 3")
- "merged" - Remove all that are merged to main
- "none" - Cancel, don't remove any
```

**Important warnings to show**:
- If worktree has uncommitted changes: "⚠ Has uncommitted changes - will be lost!"
- If branch not merged: "⚠ Branch not merged - work may be lost!"

## Step 5: Confirm Dangerous Removals

If user selects worktrees with uncommitted changes or unmerged branches:

```
⚠ Warning: You selected worktrees with potential data loss:

- dashboard-quick-wins: NOT merged, has uncommitted changes
- worktree-safe-dev: NOT merged

Type "confirm" to proceed, or "cancel" to go back.
```

## Step 6: Remove Selected Worktrees

For each selected worktree:

```bash
# Remove the worktree
git worktree remove .git-worktree/{name} --force

# Optionally delete the branch if merged
git branch -d {branch-name} 2>/dev/null
```

**If branch not merged**, ask whether to delete:
```
Branch "feature/dashboard-quick-wins" is not merged.
Delete the branch anyway? [y/N]
```

Use `git branch -D` (force) only if user confirms.

## Step 7: Prune Stale References

```bash
# Clean up any stale worktree references
git worktree prune
```

## Step 8: Report Results

```
Cleanup complete!

Removed:
  ✓ security-fixes (branch fix/security-fixes deleted)
  ✓ v6-pricing-terminology (branch feature/v6-pricing deleted)

Kept:
  - dashboard-quick-wins
  - worktree-safe-dev

Remaining worktrees: 2
```

## Edge Cases

**No worktrees found**:
```
No worktrees found in .git-worktree/

Your working directory is clean. Use /worktree <name> to create one.
```

**Worktree removal fails**:
- Check if worktree is currently checked out elsewhere
- Check for file permission issues
- Suggest manual investigation

**Stale worktree references**:
```bash
# If git worktree list shows worktrees that don't exist
git worktree prune
```

## Safety Rules

1. **Always show status before removal** - merged/unmerged, uncommitted changes
2. **Require explicit confirmation** for unmerged or dirty worktrees
3. **Never auto-delete branches** that aren't merged
4. **Keep a record** of what was removed in the output
5. **Run git worktree prune** at the end to clean up stale refs
