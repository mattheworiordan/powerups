---
name: worktree-cleanup
description: List and remove git worktrees interactively. Use when someone wants to clean up old worktrees, prune stale branches, or see worktree status.
version: 1.1.0
allowed-tools: Read, Bash, Grep, Glob, AskUserQuestion
---

# Git Worktree Cleanup

Interactively list and remove git worktrees.

## Step 1: Detect Worktree Directory

Determine which worktree directories exist:

```bash
# Check both possible locations
WORKTREE_DIRS=""
if [ -d ".git-worktree" ]; then
  WORKTREE_DIRS=".git-worktree"
fi
if [ -d ".claude/worktrees" ]; then
  WORKTREE_DIRS="$WORKTREE_DIRS .claude/worktrees"
fi
```

If both directories exist, scan both. If neither exists, report no worktrees found.

## Step 2: List All Worktrees

```bash
# Get all worktrees (git's own tracking)
git worktree list

# List contents of each detected worktree directory
for WORKTREE_DIR in $WORKTREE_DIRS; do
  echo "=== $WORKTREE_DIR ==="
  ls -la "$WORKTREE_DIR/" 2>/dev/null
done
```

## Step 3: Gather Worktree Details

For each worktree found in the detected directories:

```bash
# Get the branch name
cd "$WORKTREE_DIR/{name}"
BRANCH=$(git branch --show-current)

# Get last modified time
stat -f "%Sm" -t "%Y-%m-%d" "$WORKTREE_DIR/{name}" 2>/dev/null || \
  stat -c "%y" "$WORKTREE_DIR/{name}" 2>/dev/null | cut -d' ' -f1

# Check if branch is merged to main
git branch --merged main | grep -q "{branch}" && echo "MERGED" || echo "NOT_MERGED"

# Check if branch exists on remote
git branch -r | grep -q "origin/{branch}" && echo "REMOTE" || echo "LOCAL_ONLY"

# Check for uncommitted changes
cd "$WORKTREE_DIR/{name}"
git status --porcelain | head -5
```

## Step 4: Present Interactive List

Format the output clearly, noting which directory each worktree is in:

```
Found {N} worktrees:

1. security-fixes (in .git-worktree/)
   Branch: fix/security-fixes
   Last modified: 3 days ago
   Status: ✓ Merged to main

2. dashboard-quick-wins (in .claude/worktrees/)
   Branch: feature/dashboard-quick-wins
   Last modified: 10 days ago
   Status: ⚠ NOT merged to main
   Changes: 2 uncommitted files

3. v6-pricing-terminology (in .git-worktree/)
   Branch: feature/v6-pricing
   Last modified: 6 days ago
   Status: ✓ Merged to main

4. worktree-safe-dev (in .claude/worktrees/)
   Branch: feature/worktree-safe-dev
   Last modified: 3 days ago
   Status: ⚠ NOT merged to main
```

## Step 5: Ask User Which to Remove

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

## Step 6: Confirm Dangerous Removals

If user selects worktrees with uncommitted changes or unmerged branches:

```
⚠ Warning: You selected worktrees with potential data loss:

- dashboard-quick-wins: NOT merged, has uncommitted changes
- worktree-safe-dev: NOT merged

Type "confirm" to proceed, or "cancel" to go back.
```

## Step 7: Remove Selected Worktrees

For each selected worktree (using its detected `$WORKTREE_DIR`):

```bash
# Remove the worktree
git worktree remove "$WORKTREE_DIR/{name}" --force

# Optionally delete the branch if merged
git branch -d {branch-name} 2>/dev/null
```

**If branch not merged**, ask whether to delete:
```
Branch "feature/dashboard-quick-wins" is not merged.
Delete the branch anyway? [y/N]
```

Use `git branch -D` (force) only if user confirms.

## Step 8: Prune Stale References

```bash
# Clean up any stale worktree references
git worktree prune
```

## Step 9: Report Results

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
No worktrees found in .git-worktree/ or .claude/worktrees/

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
