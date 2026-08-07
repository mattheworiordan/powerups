---
name: worktree
description: Set up and create git worktrees the durable way — scaffold a portable `.worktreeinclude` once, then create isolated, meaningfully-named worktrees that are immediately runnable. Stack-aware — one worktree per GitHub stacked-PR stack, never one per layer. Use when working on a feature/fix in isolation.
version: 2.1.0
allowed-tools: Read, Bash, Grep, Glob, Write, Edit
---

# Git Worktree

Set up and create git worktrees that are **immediately runnable** and **meaningfully named**, using the well-trodden native path instead of re-copying files by hand on every creation.

## Model (read first)

A worktree is a fresh checkout, so git-ignored local files (`.env`, `.envrc`, secrets) and installed
dependencies are absent. The durable fix is **declare once, apply automatically** — not "copy every time":

- **`.worktreeinclude`** (repo root, committed, `.gitignore` syntax) lists the git-ignored files a worktree
  needs. **Claude Code and Codex both copy these into new worktrees automatically.** This skill also honours
  it for manual creation, so the list is the single source of truth (filenames, not secrets — safe to commit).
- **Provisioning** (install deps, `direnv allow`, DB) runs in the **background** so creation stays fast.
- **Names** must be meaningful (`type/slug`), never the auto-generated `adjective-noun-hash` codename that
  Claude Code assigns when no name is supplied.
- **Stacked PRs: one worktree per STACK, not per layer.** A GitHub stacked-PR chain (`gh stack`) lives
  inside a single worktree; layers are branches you move between with `gh stack up`/`down` inside it.
  Never give each layer its own worktree — `gh stack rebase` fails on branches checked out elsewhere.

This skill's job: **scaffold that config once** (so every future worktree — native, agent, or manual — just
works), then **create** a well-named worktree on demand. Prefer `.claude/worktrees/` (Claude Code's native
location); an existing `.git-worktree/` is still supported.

## Step 1: Parse arguments

`/worktree [flags] [name]`
- `name` — e.g. `feature/dark-mode` or `dark-mode`. If omitted, ask what the work is (a name needs intent).
- `--init` — only scaffold repo config; do not create a worktree.
- `--quick` — use `name` as-is for branch + folder (it must still be meaningful, not a codename).

```bash
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "Not a git repo"; exit 1; }
ROOT=$(git rev-parse --show-toplevel); cd "$ROOT"
```

## Step 2: Ensure repo config (idempotent — run every time)

This is what makes worktrees durable for *all* creation paths, not just this skill.

### 2a. Respect an existing WorktreeCreate hook
```bash
grep -rlq "WorktreeCreate" .claude/settings*.json 2>/dev/null && echo "HAS_WORKTREE_CREATE_HOOK"
```
If present, the repo already owns worktree setup, and **Claude Code ignores `.worktreeinclude` when a
`WorktreeCreate` hook exists** — so that hook must copy env + provision itself. Do **not** add a competing
`.worktreeinclude`; instead verify the hook is correct and skip 2b–2d.

### 2b. Scaffold `.worktreeinclude` (the env declaration)
Discover candidate env files, then keep only the ones git actually ignores (so committed files like
`.env.example` are never copied):
```bash
find . -maxdepth 4 \( -name ".env" -o -name ".env.*" -o -name ".envrc" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" \
  -not -path "*/.claude/worktrees/*" -not -path "*/.git-worktree/*" \
  -not -path "*/.venv/*" -not -path "*/vendor/*" 2>/dev/null | sed 's|^\./||' \
  | while read -r f; do git check-ignore -q "$f" && echo "$f"; done
```
Write/merge these paths into `.worktreeinclude` at the repo root (don't duplicate existing lines; keep a short
header comment). Then **commit it** — every teammate and agent benefits, and it's read by Claude Code and Codex.

### 2c. Gitignore the worktree directory
Ensure `.claude/worktrees/` is ignored — prefer the user's global gitignore (`git config --global core.excludesfile`),
falling back to the repo `.gitignore`.

### 2d. Note provisioning
If the repo has dependencies (package.json / Gemfile / go.mod / …) or a `.envrc`, the worktree also needs
`install` + `direnv allow`. This skill runs that in the background at create time (Step 5). For worktrees created
*outside* this skill (native `claude --worktree`, agents), add a repo `SessionStart` hook that does the same;
offer to scaffold one if the user wants that and none exists.

## Step 3: Determine a meaningful branch name

Never accept a random codename. If `name` matches `^[a-z]+-[a-z]+-[0-9a-f]{4,}$` (an auto-generated codename),
reject it and ask for a real one.

If `--quick`, use `name` as-is. Otherwise, if it already has a `feature|fix|bugfix|hotfix|chore|refactor|docs|test/`
prefix use it; else ask the type and construct `{type}/{slug}`. Folder name = slug without the prefix.

## Step 4: Create the worktree

```bash
WT_DIR=".claude/worktrees"; [ -d ".git-worktree" ] && [ ! -d ".claude/worktrees" ] && WT_DIR=".git-worktree"
mkdir -p "$WT_DIR"
BASE=$(git branch --show-current)
git worktree add -b "{branch}" "$WT_DIR/{folder}" "$BASE"   # LEFTHOOK=0 prefix if the repo's post-checkout is heavy
```

**Stacked-PR handling** (GitHub native stacks via `gh stack`):
- **New layer on an existing stack?** Do NOT create a worktree. Go to the stack's worktree and run
  `gh stack add {type}/{slug}` from its top branch — the layer belongs in that worktree.
- **Starting a stack deliberately?** Create the worktree as above, then adopt its branch as the first
  layer from inside it: `gh stack init {branch}`. Add later layers with `gh stack add`.
- A plain worktree branch can be adopted into a stack later (`gh stack init {branch}`), so starting
  plain loses nothing.

## Step 5: Apply `.worktreeinclude` + provision (background)

Plain `git worktree add` does not honour `.worktreeinclude` (only Claude Code's own creation does), so the skill
applies it — reusing the same declared list rather than re-discovering:
```bash
cd "$WT_DIR/{folder}"
if [ -f "$ROOT/.worktreeinclude" ]; then
  grep -vE '^\s*#|^\s*$' "$ROOT/.worktreeinclude" | while read -r pat; do
    for f in $(cd "$ROOT" && ls -d $pat 2>/dev/null); do
      mkdir -p "$(dirname "$f")"; cp "$ROOT/$f" "$f" 2>/dev/null
    done
  done
fi
[ -f .envrc ] && command -v direnv >/dev/null && direnv allow . 2>/dev/null   # unblock copied .envrc
```
Then install dependencies **in the background** (idempotent; don't block): pick the package manager by lockfile
(`yarn`/`pnpm`/`bun`/`npm ci`), `bundle install`, `go mod download`, etc. Log to `.worktree-setup.log`. Never
symlink `node_modules` from the main checkout (breaks when lockfiles diverge — pnpm's store / `npm ci` are cheap).

## Step 6: Report
```
Worktree ready:  {branch}  →  $WT_DIR/{folder}/
  ✓ env from .worktreeinclude: <files>        ✓ direnv allowed
  … deps installing in background (tail .worktree-setup.log)
Open a new Claude session there:  cd $WT_DIR/{folder}
```
List the files that were copied so nothing silently missing.

## Notes
- **Declare once, not copy-every-time.** The value here is scaffolding `.worktreeinclude` (portable across Claude
  Code and Codex) and enforcing good names — not the copying itself.
- `git check-ignore` is the guard that stops committed files being treated as secrets to copy.
- Cleanup is a separate skill: `/worktree-cleanup`.
- Don't run tests/builds during setup — just dependency install, in the background.
