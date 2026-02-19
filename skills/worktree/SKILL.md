---
name: worktree
description: Create a git worktree with proper setup (branch, env, dependencies). Use when someone wants to work on a feature/fix in isolation without switching branches.
version: 1.0.0
allowed-tools: Read, Bash, Grep, Glob, AskUserQuestion
---

# Create Git Worktree

Create an isolated git worktree with automatic project setup.

**Convention**: Worktrees are stored in `.git-worktree/` within the project root (gitignored).

## Step 1: Parse Arguments

The user provides a name: `/worktree <name>`

Examples:
- `/worktree fix-login-bug` - needs type prefix
- `/worktree feature/dark-mode` - already has prefix, use as-is
- `/worktree` (no args) - ask what they're working on

## Step 2: Determine Branch Name

Check if the name already has a type prefix:

```bash
# Check for existing prefix patterns
echo "$NAME" | grep -E "^(feature|fix|bugfix|hotfix|chore|refactor|docs|test)/"
```

**If prefix exists**: Use the name as-is for the branch.

**If no prefix**: Ask the user what type of work this is:

```
What type of work is this?
1. feature - New functionality
2. fix - Bug fix
3. chore - Maintenance/cleanup
4. refactor - Code restructuring
5. docs - Documentation
```

Then construct: `{type}/{name}` (e.g., `feature/dark-mode`)

**Worktree folder name**: Use the name without the prefix for cleaner paths.
- Branch: `feature/dark-mode` → Folder: `.git-worktree/dark-mode/`

## Step 3: Check Prerequisites

```bash
# Verify we're in a git repo
git rev-parse --git-dir

# Check if worktree already exists
ls -d .git-worktree/{folder-name} 2>/dev/null

# Check if branch already exists
git branch --list "{branch-name}"
git branch -r --list "origin/{branch-name}"
```

**If worktree exists**: Ask user - resume existing, or create with different name?

**If branch exists remotely but not locally**: Offer to track it instead of creating new.

## Step 4: Detect Project Type

```bash
# Check for project markers
ls package.json 2>/dev/null && echo "NODE"
ls Gemfile 2>/dev/null && echo "RUBY"
ls Cargo.toml 2>/dev/null && echo "RUST"
ls go.mod 2>/dev/null && echo "GO"
ls pyproject.toml setup.py requirements.txt 2>/dev/null && echo "PYTHON"
ls mix.exs 2>/dev/null && echo "ELIXIR"

# Check for framework-specific markers (affects env file handling)
ls next.config.* 2>/dev/null && echo "NEXTJS"
ls vite.config.* 2>/dev/null && echo "VITE"
ls nuxt.config.* 2>/dev/null && echo "NUXT"
```

Store detected types (can be multiple, e.g., Rails + Node).

**Framework markers** (NEXTJS, VITE, NUXT) affect env file conventions - see Step 5.

## Step 5: Identify Environment Files

Find env files across the entire project, not just the root:

```bash
# Find all env files recursively (untracked/gitignored files that need copying)
find . -maxdepth 4 \( -name ".env" -o -name ".env.*" -o -name ".envrc" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.git-worktree/*" \
  -not -path "*/.venv/*" -not -path "*/vendor/*" 2>/dev/null
```

This catches both root-level files (`.env`, `.env.local`) and subdirectory files (`packages/api/.env`, `config/.envrc`, `apps/web/.env.local`).

Store the full list of discovered files with their relative paths.

### Framework-Specific Conventions

Different frameworks have different conventions for env files:

| Framework | Local secrets file | Committed defaults | Notes |
|-----------|-------------------|-------------------|-------|
| **Next.js/Vite/Nuxt** | `.env.local` | `.env` | `.env.local` is gitignored, `.env` is committed |
| **Rails/Django/Generic** | `.env` | `.env.example` | `.env` is gitignored |
| **Docker Compose** | `.env` | `.env.example` | `.env` is gitignored |

### Priority for root-level files

**For Next.js/Vite/Nuxt projects** (detected in Step 4):
1. `.env` from source → copy as `.env.local` (the local secrets file convention)
2. `.env.local` from source → copy as `.env.local`
3. `.env.development` from source → copy as `.env.development`
4. `.env.example` → copy as `.env.local`

**For all other projects**:
1. `.env` - if exists, copy as `.env`
2. `.env.local` - if exists, copy as `.env.local`
3. `.env.development` - if exists, copy as `.env.development`
4. `.env.example` / `.env.sample` - copy as `.env` (ask if unclear)

### Subdirectory files

All env files found in subdirectories should be copied preserving their relative path. No framework-specific renaming is applied to subdirectory files — they are copied as-is to maintain the project's existing structure.

**Edge cases**: Some frameworks use different patterns (Rails 7+ `config/credentials.yml.enc`, Phoenix `config/runtime.exs`, Serverless `samconfig.toml`). If you detect these, use your judgment on what to copy.

## Step 6: Create Worktree

```bash
# Ensure .git-worktree directory exists
mkdir -p .git-worktree

# Check if .git-worktree is already covered by the global gitignore
GLOBAL_GITIGNORE=$(git config --global core.excludesfile 2>/dev/null)
GLOBAL_GITIGNORE="${GLOBAL_GITIGNORE/#\~/$HOME}"
if [ -n "$GLOBAL_GITIGNORE" ] && grep -q "^\.git-worktree" "$GLOBAL_GITIGNORE" 2>/dev/null; then
  # Already in global gitignore - no need to modify local .gitignore
  echo "✓ .git-worktree is already in your global gitignore ($GLOBAL_GITIGNORE)"
else
  # Not in global gitignore - recommend adding it globally, but add locally as fallback
  echo "💡 Tip: Add .git-worktree to your global gitignore so it applies to all repos:"
  echo "    echo '.git-worktree' >> $(git config --global core.excludesfile || echo '~/.gitignore')"
  grep -q "^\.git-worktree" .gitignore 2>/dev/null || echo ".git-worktree" >> .gitignore
  echo "  (Added to local .gitignore for now)"
fi

# Get current branch as base
BASE_BRANCH=$(git branch --show-current)

# Create the worktree with new branch
git worktree add -b "{branch-name}" ".git-worktree/{folder-name}" "$BASE_BRANCH"
```

## Step 7: Copy Environment Files

```bash
cd .git-worktree/{folder-name}
```

### Root-level env files

**For Next.js/Vite/Nuxt projects** (use `.env.local` convention):
```bash
# Copy .env as .env.local (the local secrets file in these frameworks)
cp ../../.env .env.local 2>/dev/null
# Also copy existing .env.local and .env.development
cp ../../.env.local .env.local 2>/dev/null  # Will overwrite above if exists
cp ../../.env.development .env.development 2>/dev/null
```

If only `.env.example` exists:
```bash
cp ../../.env.example .env.local
```

**For all other projects** (use `.env` convention):
```bash
# Copy each detected env file
cp ../../.env .env 2>/dev/null
cp ../../.env.local .env.local 2>/dev/null
cp ../../.env.development .env.development 2>/dev/null
```

If only `.env.example` exists:
```bash
cp ../../.env.example .env
```

### Subdirectory env files

For every env file found in a subdirectory during Step 5, copy it preserving its relative path:

```bash
# SOURCE_ROOT is the original project root (../../ relative to the worktree)
SOURCE_ROOT="../.."

# For each subdirectory env file discovered in Step 5 (excluding root-level ones already handled above)
for f in $SUBDIR_ENV_FILES; do
  mkdir -p "$(dirname "$f")"
  cp "$SOURCE_ROOT/$f" "$f" 2>/dev/null
done
```

For example, if Step 5 found `packages/api/.env` and `config/.envrc`, this creates the subdirectories and copies each file into the worktree at the same relative path.

## Step 8: Install Dependencies

Based on detected project types:

**Node (package.json)**:
```bash
# Check for lock files to determine package manager
if [ -f "yarn.lock" ]; then
  yarn install
elif [ -f "pnpm-lock.yaml" ]; then
  pnpm install
elif [ -f "bun.lockb" ]; then
  bun install
else
  npm install
fi
```

**Ruby (Gemfile)**:
```bash
bundle install
```

**Python (requirements.txt or pyproject.toml)**:
```bash
if [ -f "pyproject.toml" ]; then
  pip install -e .
elif [ -f "requirements.txt" ]; then
  pip install -r requirements.txt
fi
```

**Rust (Cargo.toml)**:
```bash
cargo build
```

**Go (go.mod)**:
```bash
go mod download
```

## Step 9: Simple Verification

Check that setup succeeded:

```bash
# Verify at least one env file exists (root or subdirectory)
find . -maxdepth 4 \( -name ".env" -o -name ".env.*" -o -name ".envrc" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" | head -1 | grep -q .

# Verify dependencies installed (check for node_modules, vendor, etc.)
[ -d "node_modules" ] || [ -d "vendor" ] || [ -d ".venv" ] || [ -d "target" ]
```

Just check exit codes - no test runs.

## Step 10: Report Success

```
Worktree created successfully!

  Branch: feature/dark-mode
  Path:   .git-worktree/dark-mode/
  Base:   main

Setup completed:
  ✓ Environment files copied (.env.local, packages/api/.env, config/.envrc)
  ✓ Dependencies installed (yarn)

To start working:
  cd .git-worktree/dark-mode/

Or open a new terminal/Claude session in that directory.
```

Report all env files that were copied - both root-level and subdirectory files. List the actual paths so the user can verify nothing was missed.

## Error Handling

**Git worktree add fails**:
- Check if branch name conflicts
- Check if path already exists
- Suggest `git worktree prune` if stale references

**Dependency install fails**:
- Report the error but don't fail completely
- Suggest user investigate manually

**No env files found**:
- Warn but continue
- Suggest checking if project needs environment setup

## Notes

- Always use `.git-worktree/` subfolder (gitignored, organized)
- Folder name = branch name without type prefix for cleaner paths
- Don't run tests or builds during setup - just dependency installation
- The user will open a new Claude session in the worktree directory
