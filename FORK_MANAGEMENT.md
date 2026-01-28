# Fork Management in ru

> **Keep your forks in sync with upstream, detect pollution, and maintain clean main branches.**

This document describes ru's fork management capabilities — a set of commands and utilities for working with GitHub forks.

---

## Table of Contents

- [The Problem](#the-problem)
- [Fork Workflow Overview](#fork-workflow-overview)
- [Quick Start](#quick-start)
- [Commands](#commands)
  - [fork-status](#fork-status)
  - [fork-sync](#fork-sync)
  - [fork-clean](#fork-clean)
- [Configuration](#configuration)
- [Concepts](#concepts)
  - [What is Pollution?](#what-is-pollution)
  - [Rescue Branches](#rescue-branches)
  - [Sync Strategies](#sync-strategies)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)

---

## The Problem

When working with forked repositories, several issues commonly arise:

| Problem | Symptoms | Impact |
|---------|----------|--------|
| **Upstream drift** | Your fork's main falls behind the original | PRs have merge conflicts, miss new features |
| **Main pollution** | Accidental commits on main instead of feature branch | Can't sync with upstream, messy history |
| **Agent accidents** | AI agents commit tests/debug code to main | Fork becomes diverged, hard to clean up |
| **Manual overhead** | Need to run `git fetch upstream && git merge` for each repo | Time-consuming with many forks |

**ru's fork management solves these problems** by providing automated detection, synchronization, and cleanup tools.

---

## Fork Workflow Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Recommended Fork Workflow                            │
└─────────────────────────────────────────────────────────────────────────────┘

  GitHub (upstream)                 GitHub (origin)                Local
  ┌─────────────┐                  ┌─────────────┐              ┌─────────────┐
  │ original/   │    fork on       │ you/        │   clone      │ ~/projects/ │
  │ awesome-    │───────────────▶  │ awesome-    │─────────────▶│ awesome-    │
  │ project     │    GitHub        │ project     │              │ project     │
  └──────┬──────┘                  └──────┬──────┘              └──────┬──────┘
         │                                │                            │
         │ upstream remote                │ origin remote              │
         └────────────────────────────────┴────────────────────────────┘
                                          │
                                          ▼
                              ┌─────────────────────┐
                              │  main branch        │ ◀── NEVER commit here!
                              │  (mirror upstream)  │     Only sync from upstream
                              └──────────┬──────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
           ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
           │ feature/     │     │ feature/     │     │ fix/         │
           │ new-thing    │     │ improvement  │     │ bug-123      │
           └──────────────┘     └──────────────┘     └──────────────┘
                  │                    │                    │
                  └────────────────────┴────────────────────┘
                                       │
                                       ▼
                              ┌─────────────────────┐
                              │  Pull Request       │
                              │  to upstream        │
                              └─────────────────────┘
```

**Golden Rule:** Never commit directly to `main` in a fork. Keep it as a clean mirror of upstream.

---

## Quick Start

```bash
# 1. Check fork status across all repos
ru fork-status

# 2. See which forks have pollution (unauthorized commits on main)
ru fork-status --forks-only

# 3. Sync all forks with upstream (dry-run first!)
ru fork-sync --dry-run

# 4. Actually sync
ru fork-sync

# 5. Clean polluted main branches (saves commits to rescue branch)
ru fork-clean
```

---

## Commands

### fork-status

Show synchronization status of forked repositories relative to their upstream.

```bash
ru fork-status [options] [repo...]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format for scripting |
| `--check` | Exit with code 2 if any repo is polluted (CI mode) |
| `--fetch` | Fetch from remotes before checking (default) |
| `--no-fetch` | Skip fetching (faster but may show stale data) |
| `--forks-only` | Only show repos detected as forks |

**Output columns:**

| Column | Description |
|--------|-------------|
| Repository | Repo identifier |
| Fork Status | `current`, `behind`, `ahead`, `diverged`, `no_upstream` |
| Upstream Δ | Commits ahead/behind upstream (local/upstream) |
| Origin Δ | Commits ahead/behind origin (unpushed/unpulled) |
| Polluted | YES if main has local commits not in upstream |

**Examples:**

```bash
# Check all repos
ru fork-status

# Output:
# Repository          Fork Status   Upstream Δ  Origin Δ   Polluted
# joyshmitz/ntm       ahead         3/0         3/97       YES
# joyshmitz/meta_skill behind       0/7         0/0        no

# Check specific repos
ru fork-status joyshmitz/ntm joyshmitz/repo_updater

# CI mode: fail if pollution detected
ru fork-status --check || echo "ERROR: Pollution detected!"

# JSON for scripting
ru fork-status --json | jq '.[] | select(.polluted == true) | .repo'
```

**JSON output schema:**

```json
{
  "repo": "joyshmitz/ntm",
  "path": "/data/projects/ntm",
  "is_fork": true,
  "fork_status": "ahead_upstream",
  "ahead_origin": 3,
  "behind_origin": 97,
  "ahead_upstream": 3,
  "behind_upstream": 0,
  "polluted": true,
  "upstream_url": "https://github.com/original/ntm.git"
}
```

---

### fork-sync

Synchronize fork branches with upstream.

```bash
ru fork-sync [options] [repo...]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--branches=LIST` | Branches to sync, comma-separated (default: from config) |
| `--strategy=STR` | Sync strategy: `reset`, `ff-only`, `rebase`, `merge` |
| `--push` | Push synced branches to origin after sync |
| `--no-push` | Don't push (default) |
| `--rescue` | Save local commits to rescue branch before reset (default) |
| `--no-rescue` | Don't save local commits (dangerous!) |
| `--dry-run` | Show what would be done without making changes |
| `--force` | Don't prompt for confirmation |

**Examples:**

```bash
# Sync main branch for all forks (using config defaults)
ru fork-sync

# Preview changes first
ru fork-sync --dry-run

# Sync specific branches
ru fork-sync --branches "main,develop"

# Sync and push to origin
ru fork-sync --push

# Force reset to upstream (with rescue)
ru fork-sync --strategy reset

# Sync specific repo
ru fork-sync joyshmitz/ntm

# Aggressive sync: reset + push + no prompts
ru fork-sync --strategy reset --push --force
```

**Sync strategies explained:**

| Strategy | Command | Use Case |
|----------|---------|----------|
| `ff-only` | `git merge --ff-only` | Safe default, fails if local has commits |
| `reset` | `git reset --hard` | Force sync, discards local commits |
| `rebase` | `git rebase upstream/main` | Keep local commits on top of upstream |
| `merge` | `git merge upstream/main` | Preserve both histories |

---

### fork-clean

Clean pollution (unauthorized local commits) from main branch.

```bash
ru fork-clean [options] [repo...]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--rescue` | Save polluted commits to rescue branch (default) |
| `--no-rescue` | Discard polluted commits (dangerous!) |
| `--push` | Push cleaned main to origin |
| `--dry-run` | Show what would be done without making changes |
| `--force` | Don't prompt for confirmation |

**Examples:**

```bash
# Clean all polluted forks (with rescue)
ru fork-clean

# Preview what would be cleaned
ru fork-clean --dry-run

# Clean specific repo
ru fork-clean joyshmitz/ntm

# Clean and push (with confirmation)
ru fork-clean --push

# Clean without rescue (discard commits!)
ru fork-clean --no-rescue --force

# Full automation: clean + push + no prompts
ru fork-clean --push --force
```

**What happens during cleanup:**

1. Detects commits on main that don't exist in upstream/main
2. Creates rescue branch: `rescue/2025-01-28-143052`
3. Resets main to match upstream: `git reset --hard upstream/main`
4. Optionally pushes to origin: `git push origin main --force-with-lease`

---

## Configuration

Add to `~/.config/ru/config`:

```bash
#------------------------------------------------------------------------------
# FORK MANAGEMENT CONFIGURATION
#------------------------------------------------------------------------------

# Auto-detect and configure upstream remote when syncing
# Values: true | false
# Default: false
FORK_AUTO_UPSTREAM=true

# Branches to synchronize from upstream (comma-separated)
# Examples:
#   main                    - Only main branch (safest)
#   main,develop            - Main and develop branches
#   main,release/v1,docs    - Multiple specific branches
# Default: main
FORK_SYNC_BRANCHES=main

# How to synchronize branches with upstream
# Values:
#   ff-only  - Fast-forward only, fails if local has commits (safe)
#   reset    - Hard reset to upstream (discards local commits!)
#   rebase   - Rebase local commits on top of upstream
#   merge    - Merge upstream into local
# Default: ff-only
FORK_SYNC_STRATEGY=ff-only

# Block direct commits to main branch in forks
# When true, ru fork-protect installs a pre-commit hook
# Values: true | false
# Default: false
FORK_PROTECT_MAIN=false

# Save polluted commits before cleanup
# Creates rescue/YYYY-MM-DD-HHMMSS branch with your commits
# Values: true | false
# Default: true
FORK_RESCUE_POLLUTED=true

# Push to origin after syncing with upstream
# Values: true | false
# Default: false
FORK_PUSH_AFTER_SYNC=false
```

**Environment variables:**

All config options can be overridden via environment:

```bash
RU_FORK_SYNC_STRATEGY=reset ru fork-sync
RU_FORK_PUSH_AFTER_SYNC=true ru fork-sync
```

**Priority:** CLI args > Environment > Config file > Defaults

---

## Concepts

### What is Pollution?

**Pollution** refers to commits on your fork's `main` branch that don't exist in `upstream/main`.

```
upstream/main:    A ── B ── C ── D
                              ╲
your main:        A ── B ── C ── X ── Y    ◀── X, Y are "pollution"
```

**Common causes:**

| Cause | How it happens |
|-------|----------------|
| AI agent mistake | Agent forgets to create branch, commits to main |
| Developer error | Accidentally commit to main instead of feature branch |
| Merged PR locally | Merged a PR locally but forgot to reset main |
| Stale fork | Made commits long ago, forgot about them |

**Why it's a problem:**

- Can't fast-forward sync with upstream
- PRs from your fork may include unwanted commits
- Confusing git history
- `ru sync` shows "diverged" status

### Rescue Branches

When `ru fork-clean` removes pollution, it first saves your commits to a **rescue branch**:

```
Before cleanup:
  main:           A ── B ── C ── X ── Y    (X, Y are pollution)

After cleanup:
  main:           A ── B ── C ── D ── E    (matches upstream)
  rescue/2025-01-28-143052:  X ── Y        (your commits saved)
```

**Finding your rescued commits:**

```bash
# List rescue branches
git branch | grep rescue/

# View commits in rescue branch
git log rescue/2025-01-28-143052 --oneline

# Cherry-pick a commit to a feature branch
git checkout -b feature/my-work
git cherry-pick <commit-hash>
```

### Sync Strategies

| Strategy | Safe? | Preserves local commits? | When to use |
|----------|-------|-------------------------|-------------|
| `ff-only` | Yes | N/A (fails if any exist) | Default, detect pollution |
| `reset` | No | Only with `--rescue` | Force clean sync |
| `rebase` | Somewhat | Yes (rebased on top) | Keep local work updated |
| `merge` | Yes | Yes (merge commit) | Intentional divergence |

**Decision tree:**

```
Do you have commits on main?
├── No  → Any strategy works, use ff-only
└── Yes → Are they intentional?
          ├── No (pollution)  → Use reset --rescue, then cherry-pick if needed
          └── Yes (intentional) → Use merge or rebase
```

---

## Common Workflows

### Daily sync routine

```bash
# Morning: check status of all forks
ru fork-status --no-fetch

# If behind upstream, sync
ru fork-sync

# If polluted, investigate
git log upstream/main..main --oneline

# Clean if needed
ru fork-clean
```

### CI/CD pollution check

```yaml
# GitHub Actions example
- name: Check for fork pollution
  run: |
    ru fork-status --check --forks-only
  continue-on-error: false
```

### Cleaning up after an agent accident

```bash
# 1. See the damage
ru fork-status joyshmitz/my-repo
git -C /data/projects/my-repo log upstream/main..main --oneline

# 2. Preview cleanup
ru fork-clean --dry-run joyshmitz/my-repo

# 3. Clean with rescue
ru fork-clean joyshmitz/my-repo

# 4. If needed, recover commits
git -C /data/projects/my-repo branch | grep rescue
git -C /data/projects/my-repo log rescue/2025-01-28-143052 --oneline
```

### Setting up a new fork

```bash
# 1. Clone your fork
gh repo clone joyshmitz/awesome-project

# 2. ru will auto-detect it's a fork and can configure upstream
ru fork-status joyshmitz/awesome-project

# 3. Or manually add upstream
cd /data/projects/awesome-project
git remote add upstream https://github.com/original/awesome-project.git
git fetch upstream
```

### Keeping multiple branches in sync

```bash
# Configure branches to sync
ru config --set FORK_SYNC_BRANCHES="main,develop,release/v2"

# Or one-time sync
ru fork-sync --branches "main,develop,release/v2"
```

---

## Troubleshooting

### "No upstream remote" for a fork

```bash
# Check if it's detected as a fork
ru fork-status --json my-repo | jq '.is_fork'

# Manually add upstream
cd /data/projects/my-repo
git remote add upstream https://github.com/original-owner/repo.git
git fetch upstream
```

### "Cannot fast-forward" error

This means your local main has commits not in upstream (pollution).

```bash
# See the pollution
git log upstream/main..main --oneline

# Option 1: Clean with rescue
ru fork-clean

# Option 2: Force sync with reset
ru fork-sync --strategy reset

# Option 3: Manual rebase
git rebase upstream/main
```

### gh CLI not available

Fork detection uses the GitHub API via `gh`. Without it:

```bash
# Install gh
brew install gh  # or: apt install gh

# Authenticate
gh auth login

# Or manually configure upstream remotes
git remote add upstream <url>
```

### Rescue branch already exists

If a rescue branch with the same timestamp exists (rare):

```bash
# The command will use a slightly different timestamp
# Or manually create the rescue branch first:
git branch rescue/manual-backup main
ru fork-clean --no-rescue  # safe now, you have a backup
```

---

## See Also

- [README.md](README.md) — Main documentation
- [AGENTS.md](AGENTS.md) — Guidelines for AI agents
- [ru sync](README.md#sync) — General repository synchronization
