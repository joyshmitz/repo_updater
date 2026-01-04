# Extending ru for Automated Reviews of GitHub Issues and PRs Using Claude Code

## Executive Summary

This proposal outlines a system for automating the review of GitHub issues and pull requests across multiple repositories using Claude Code as the AI agent. The goal is to transform a manual, time-consuming process into an orchestrated workflow that only surfaces decisions requiring human judgment.

---

## Table of Contents

1. [Background: What is ru?](#1-background-what-is-ru)
2. [The Problem We're Solving](#2-the-problem-were-solving)
3. [Current Manual Workflow](#3-current-manual-workflow)
4. [Desired Automated Workflow](#4-desired-automated-workflow)
5. [Architecture Options Analysis](#5-architecture-options-analysis)
6. [Recommended Architecture](#6-recommended-architecture)
7. [Implementation Plan](#7-implementation-plan)
8. [Technical Deep Dive](#8-technical-deep-dive)
9. [TUI Design](#9-tui-design)
10. [Integration with ntm](#10-integration-with-ntm)
11. [Risk Mitigation](#11-risk-mitigation)
12. [Future Enhancements](#12-future-enhancements)

---

## 1. Background: What is ru?

### 1.1 Overview

**ru (Repo Updater)** is a pure Bash CLI tool (~3,800 lines) for synchronizing GitHub repositories. It provides a beautiful, automation-friendly interface for managing collections of repositories - cloning new ones, pulling updates, checking status, and maintaining configuration.

### 1.2 Core Capabilities

- **Sync**: Clone missing repos and pull updates for existing ones
- **Status**: Show repository status without making changes
- **Import**: Import repos from files with automatic visibility detection
- **Prune**: Find and manage orphan repositories
- **Self-Update**: Update ru to the latest version with checksum verification

### 1.3 Technical Implementation

ru is implemented as a single Bash script (`ru`) that:

- Targets Bash 4.0+ with `#!/usr/bin/env bash`
- Uses `set -uo pipefail` for robust error handling (not `set -e` to allow explicit error handling)
- Follows XDG Base Directory Specification for configuration
- Uses git plumbing commands for reliable status detection
- Supports parallel sync with flock-based work queue
- Outputs NDJSON for results tracking
- Integrates with `gum` for beautiful TUI elements (with ANSI fallback)

### 1.4 Configuration Structure

```
~/.config/ru/
├── config                 # Main configuration (PROJECTS_DIR, LAYOUT, etc.)
└── repos.d/
    └── repos.txt          # Repository list (owner/repo format)
```

### 1.5 Repository Specification Format

ru supports flexible repo specifications:

```
owner/repo                      # Basic format
owner/repo@develop              # Branch pinning
owner/repo as myname            # Custom local name
owner/repo@main as custom       # Combined
https://github.com/owner/repo   # Full HTTPS URL
git@github.com:owner/repo       # SSH URL
```

---

## 2. The Problem We're Solving

### 2.1 The Maintainer's Dilemma

Developers who create many open-source projects face an impossible scaling problem:

1. **Volume**: Dozens or hundreds of repositories across different domains
2. **Bandwidth**: No time to manually review issues and PRs
3. **Quality**: Still want to maintain project quality and respond to users
4. **Risk**: External contributions carry responsibility - "my name is on it"
5. **Context Switching**: Each repo requires understanding before addressing issues

### 2.2 The Contribution Policy

The maintainer has adopted this policy (disclosed to users):

> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

### 2.3 Key Principles

1. **No Direct PR Merges**: External code is never merged directly
2. **Independent Verification**: AI reviews issues/PRs but validates independently
3. **AI as Implementation**: If an idea is good, AI implements it from scratch
4. **Human Judgment for Direction**: Maintainer decides what features/directions to pursue
5. **AI as Communicator**: AI responds on behalf of maintainer via `gh`

---

## 3. Current Manual Workflow

### 3.1 Step-by-Step Process

For each repository with open issues or PRs, the maintainer currently:

```bash
# 1. Navigate to project
cd ~/projects/myproject

# 2. Update the codebase
git pull

# 3. Launch Claude Code
cc    # alias for claude-code CLI

# 4. Send first prompt (codebase understanding)
```

**First Prompt (Codebase Understanding):**
```
First read ALL of the AGENTS.md file and README.md file super carefully
and understand ALL of both! Then use your code investigation agent mode
to fully understand the code, and technical architecture and purpose of
the project. Use ultrathink.
```

```bash
# 5. Wait for completion (up to 5 minutes)
# 6. Send second prompt (issue/PR review)
```

**Second Prompt (Issue/PR Review):**
```
We don't allow PRs or outside contributions to this project as a matter
of policy; here is the policy disclosed to users:

> *About Contributions:* Please don't take this the wrong way, but I do
not accept outside contributions for any of my projects. I simply don't
have the mental bandwidth to review anything, and it's my name on the
thing, so I'm responsible for any problems it causes; thus, the
risk-reward is highly asymmetric from my perspective. I'd also have to
worry about other "stakeholders," which seems unwise for tools I mostly
make for myself for free. Feel free to submit issues, and even PRs if
you want to illustrate a proposed fix, but know I won't merge them
directly. Instead, I'll have Claude or Codex review submissions via `gh`
and independently decide whether and how to address them. Bug reports in
particular are welcome. Sorry if this offends, but I want to avoid
wasted time and hurt feelings. I understand this isn't in sync with the
prevailing open-source ethos that seeks community contributions, but
it's the only way I can move at this velocity and keep my sanity.

But I want you to now use the `gh` utility to review all open issues and
PRs and to independently read and review each of these carefully; without
trusting or relying on any of the user reports being correct, or their
suggested/proposed changes or "fixes" being correct, I want you to do
your own totally separate and independent verification and validation.
You can use the stuff from users as possible inspiration, but everything
has to come from your own mind and/or official documentation and the
actual code and empirical, independent evidence. Note that MANY of these
are likely out of date because I made tons of fixes and changes already;
it's important to look at the dates and subsequent commits. Use ultrathink.
After you have reviewed things carefully and taken actions in response
(including implementing possible fixes or new features), you can respond
on my behalf using `gh`.

Just a reminder: we do NOT accept ANY PRs. You can look at them to see if
they contain good ideas but even then you must check with me first before
integrating even ideas because they could take the project into another
direction I don't like or introduce scope creep. Use ultrathink.
```

```bash
# 7. Handle questions from Claude (decisions, confirmations)
# 8. Wait for completion (10+ minutes typical)
# 9. Repeat for next project
```

### 3.2 Pain Points

1. **Time**: 10-20+ minutes per repository, fully attended
2. **Context Switching**: Must mentally switch between projects
3. **Interruption-Driven**: Claude asks questions requiring immediate attention
4. **No Aggregation**: Questions from different repos aren't consolidated
5. **No Prioritization**: Can't prioritize which repos need attention first
6. **No Persistence**: If interrupted, must restart the process

---

## 4. Desired Automated Workflow

### 4.1 High-Level Vision

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ru review                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. Scan all repos for open issues/PRs                              │
│  2. Skip repos with no activity since last review                   │
│  3. For each repo needing review:                                   │
│     a. Launch Claude Code session                                   │
│     b. Send codebase understanding prompt                           │
│     c. Wait for completion                                          │
│     d. Send issue/PR review prompt                                  │
│     e. Capture questions requiring human input                      │
│  4. Aggregate all questions into unified TUI                        │
│  5. Present questions with context for efficient decision-making    │
│  6. Route answers back to appropriate sessions                      │
│  7. Let sessions complete, then move to next batch                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 Key Requirements

| Requirement | Description |
|-------------|-------------|
| **Selective Processing** | Only process repos with new/open issues or PRs |
| **Parallel Execution** | Run multiple reviews concurrently (resource-permitting) |
| **Question Aggregation** | Collect questions from all sessions into one place |
| **Context Preservation** | Show enough context to make informed decisions |
| **Drill-Down** | Allow viewing full session for more detail |
| **State Persistence** | Resume after interruption |
| **Progress Tracking** | Show overall progress across all repos |
| **Prioritization** | Handle high-priority issues first |

### 4.3 User Experience Goal

```
$ ru review

Scanning 47 repositories for open issues and PRs...

Found activity in 8 repositories:
  - project-alpha: 3 issues, 1 PR
  - project-beta: 1 issue
  - project-gamma: 2 PRs
  - ... (5 more)

Starting review sessions...

┌─────────────────────────────────────────────────────────────────────┐
│  ru review - 3 questions pending                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [1] project-alpha (issue #42)                                      │
│      User reports authentication failing on Windows. I found        │
│      the issue is related to path handling. Should I:               │
│      a) Fix for Windows only                                        │
│      b) Refactor path handling for all platforms                    │
│      c) Skip - not a priority                                       │
│                                                                      │
│  [2] project-beta (PR #15)                                          │
│      PR proposes adding Redis caching. The idea has merit but       │
│      would add a dependency. Do you want me to:                     │
│      a) Implement caching with Redis                                │
│      b) Implement caching with in-memory approach instead           │
│      c) Skip - out of scope                                         │
│                                                                      │
│  [3] project-gamma (issue #7)                                       │
│      Feature request for dark mode. This would require...           │
│      [Press Enter to expand]                                        │
│                                                                      │
├─────────────────────────────────────────────────────────────────────┤
│  Progress: 5/8 repos complete │ 12 issues resolved │ 2 PRs closed  │
└─────────────────────────────────────────────────────────────────────┘

Select question [1-3] or [d]rill-down, [s]kip all, [q]uit:
```

---

## 5. Architecture Options Analysis

### 5.1 Option A: Pure Bash Extension

**Approach**: Extend `ru` with a new `review` subcommand entirely in Bash.

```bash
# Implementation sketch
cmd_review() {
    local repos_with_issues=()

    # Scan repos for open issues/PRs
    while IFS= read -r repo_spec; do
        local issue_count pr_count
        issue_count=$(gh issue list -R "$repo" --state open --json number | jq length)
        pr_count=$(gh pr list -R "$repo" --state open --json number | jq length)

        if [[ $((issue_count + pr_count)) -gt 0 ]]; then
            repos_with_issues+=("$repo_spec")
        fi
    done < <(get_all_repos)

    # Process each repo sequentially
    for repo in "${repos_with_issues[@]}"; do
        # Launch tmux session with Claude Code
        # Send prompts via tmux send-keys
        # Poll for questions using output pattern matching
        # Show questions via gum
    done
}
```

**Pros**:
- Keeps ru as pure Bash (consistent with existing codebase)
- No new dependencies beyond what ru already uses
- Simple deployment (single script)

**Cons**:
- Bash is awkward for complex TUI interactions
- Limited concurrency control
- Output parsing is fragile
- No real-time monitoring
- Would reinvent functionality that exists elsewhere (ntm)
- Hard to maintain as complexity grows

**Verdict**: Not recommended for full implementation, but useful for basic functionality.

### 5.2 Option B: Standalone Go/Rust Helper Binary

**Approach**: Create `ru-review` as a separate binary that ru calls.

```go
// ru-review/main.go sketch
func main() {
    repos := scanForActivity()
    sessions := make(map[string]*Session)

    for _, repo := range repos {
        session := launchClaudeSession(repo)
        sessions[repo] = session
        go monitorSession(session)
    }

    runTUI(sessions)
}
```

**Pros**:
- Proper TUI support (using tview, bubbletea, etc.)
- Better output parsing and state management
- Good concurrency primitives
- Type safety and better error handling

**Cons**:
- New codebase to maintain
- Duplicates functionality from ntm
- More complex build and installation
- Different language from ru (coordination overhead)

**Verdict**: Reasonable but suboptimal given ntm exists.

### 5.3 Option C: Deep ntm Integration

**Approach**: Use ntm as the orchestration engine, ru as the repo management layer.

```
┌─────────────────────────────────────────────────────────────────────┐
│                           ru review                                  │
│                              │                                       │
│                    ┌─────────┴─────────┐                            │
│                    ▼                   ▼                            │
│              ┌──────────┐       ┌──────────────┐                    │
│              │  ru      │       │  ntm         │                    │
│              │  (Bash)  │       │  (Go)        │                    │
│              └────┬─────┘       └──────┬───────┘                    │
│                   │                    │                            │
│    Repo config    │                    │  Session mgmt              │
│    Issue scanning │                    │  Activity detection        │
│    Git operations │                    │  TUI/Dashboard             │
│                   │                    │  Robot mode API            │
│                   └────────┬───────────┘                            │
│                            │                                        │
│                            ▼                                        │
│                    ┌───────────────┐                                │
│                    │ Claude Code   │                                │
│                    │ (tmux panes)  │                                │
│                    └───────────────┘                                │
└─────────────────────────────────────────────────────────────────────┘
```

**Pros**:
- Leverages mature, tested orchestration code (~29K lines of Go)
- Beautiful TUI already exists (command palette, dashboard)
- Health monitoring, auto-restart, activity detection
- Robot mode enables Bash → Go communication
- Workflow pipelines for complex sequences
- Session persistence across disconnections

**Cons**:
- Adds ntm as a dependency
- Requires ntm installation and configuration
- More complex initial setup
- Two-language coordination (Bash + Go)

**Verdict**: **Recommended** - leverages existing sophisticated tooling.

### 5.4 Option D: Hybrid with Graceful Degradation

**Approach**: Create a system that works with or without ntm.

- **Without ntm**: Basic sequential processing with gum-based TUI
- **With ntm**: Full parallel processing with rich dashboard

**Pros**:
- Works for users who don't have ntm
- Enhanced experience with ntm
- Gradual adoption path

**Cons**:
- Must maintain two code paths
- More testing required
- Potentially confusing for users

**Verdict**: Good compromise for broader adoption.

---

## 6. Recommended Architecture

### 6.1 Primary Recommendation: Option D (Hybrid)

Implement a hybrid system with:

1. **Core `ru review` command** (Bash): Handles repo scanning, issue detection, basic orchestration
2. **Enhanced mode with ntm** (when available): Full parallel processing and TUI
3. **Fallback mode** (without ntm): Sequential processing with gum-based prompts

### 6.2 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              ru review                                   │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Phase 1: Discovery                               │ │
│  │                                                                     │ │
│  │  • Load repos from ru config                                       │ │
│  │  • Check each repo for open issues/PRs via gh                      │ │
│  │  • Filter by last-review timestamp                                 │ │
│  │  • Build work queue of repos needing review                        │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                  │                                       │
│                                  ▼                                       │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Phase 2: Orchestration                           │ │
│  │                                                                     │ │
│  │   ┌──────────────────┐          ┌──────────────────┐               │ │
│  │   │  ntm Available?  │──Yes────▶│  ntm Mode        │               │ │
│  │   └────────┬─────────┘          │                  │               │ │
│  │            │                    │  • Spawn sessions│               │ │
│  │            No                   │  • Parallel exec │               │ │
│  │            │                    │  • Robot API     │               │ │
│  │            ▼                    │  • Rich TUI      │               │ │
│  │   ┌──────────────────┐          └──────────────────┘               │ │
│  │   │  Fallback Mode   │                                             │ │
│  │   │                  │                                             │ │
│  │   │  • Sequential    │                                             │ │
│  │   │  • tmux basic    │                                             │ │
│  │   │  • gum prompts   │                                             │ │
│  │   └──────────────────┘                                             │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                  │                                       │
│                                  ▼                                       │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Phase 3: Question Handling                       │ │
│  │                                                                     │ │
│  │  • Detect when Claude asks questions (activity detection)          │ │
│  │  • Extract question context from output                            │ │
│  │  • Queue questions with repo/session metadata                      │ │
│  │  • Present aggregated questions in TUI                             │ │
│  │  • Route answers back to sessions                                  │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                  │                                       │
│                                  ▼                                       │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                    Phase 4: Completion                              │ │
│  │                                                                     │ │
│  │  • Track session completion                                        │ │
│  │  • Update last-review timestamps                                   │ │
│  │  • Generate summary report                                         │ │
│  │  • Clean up sessions                                               │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| **ru (Bash)** | Repo configuration, git operations, gh queries, basic orchestration |
| **ntm (Go)** | Session management, TUI, activity detection, robot API |
| **Claude Code** | AI agent running in tmux panes |
| **gh CLI** | GitHub API access (issues, PRs, comments) |
| **tmux** | Session persistence and pane management |

---

## 7. Implementation Plan

### 7.1 Phase 1: Core Infrastructure (Week 1-2)

#### 7.1.1 Add `ru review` Command (Bash)

```bash
# New command in ru script
cmd_review() {
    local mode="auto"  # auto, ntm, basic
    local parallel=4
    local dry_run="false"

    # Parse arguments
    for arg in "${ARGS[@]}"; do
        case "$arg" in
            --mode=*) mode="${arg#--mode=}" ;;
            --parallel=*) parallel="${arg#--parallel=}" ;;
            --dry-run) dry_run="true" ;;
        esac
    done

    # Auto-detect ntm
    if [[ "$mode" == "auto" ]]; then
        if command -v ntm &>/dev/null; then
            mode="ntm"
        else
            mode="basic"
        fi
    fi

    # Discovery phase
    local repos_needing_review=()
    discover_repos_needing_review repos_needing_review

    if [[ ${#repos_needing_review[@]} -eq 0 ]]; then
        log_success "No repositories need review"
        return 0
    fi

    # Dispatch to appropriate mode
    case "$mode" in
        ntm)   run_review_ntm_mode "${repos_needing_review[@]}" ;;
        basic) run_review_basic_mode "${repos_needing_review[@]}" ;;
    esac
}
```

#### 7.1.2 GitHub Activity Detection

```bash
# Check if repo has open issues or PRs
repo_has_activity() {
    local repo="$1"  # owner/repo format

    # Get issue and PR counts
    local issues prs
    issues=$(gh issue list -R "$repo" --state open --json number --jq 'length' 2>/dev/null || echo "0")
    prs=$(gh pr list -R "$repo" --state open --json number --jq 'length' 2>/dev/null || echo "0")

    [[ $((issues + prs)) -gt 0 ]]
}

# Get detailed activity info
get_repo_activity() {
    local repo="$1"

    local issues_json prs_json
    issues_json=$(gh issue list -R "$repo" --state open --json number,title,createdAt,author --jq '.')
    prs_json=$(gh pr list -R "$repo" --state open --json number,title,createdAt,author --jq '.')

    echo "{\"repo\":\"$repo\",\"issues\":$issues_json,\"prs\":$prs_json}"
}
```

#### 7.1.3 Review State Tracking

```bash
# State file location
get_review_state_file() {
    echo "$RU_STATE_DIR/review-state.json"
}

# Check if repo was reviewed recently
needs_review() {
    local repo="$1"
    local state_file
    state_file=$(get_review_state_file)

    if [[ ! -f "$state_file" ]]; then
        return 0  # No state = needs review
    fi

    local last_review
    last_review=$(jq -r --arg repo "$repo" '.[$repo].last_review // "1970-01-01"' "$state_file")

    # Check if any issues/PRs are newer than last review
    local newest_activity
    newest_activity=$(gh issue list -R "$repo" --state open --json createdAt --jq 'max_by(.createdAt).createdAt // "1970-01-01"')

    [[ "$newest_activity" > "$last_review" ]]
}
```

### 7.2 Phase 2: ntm Integration (Week 2-3)

#### 7.2.1 ntm Workflow Template

Create `~/.config/ntm/workflows/github-review.yaml`:

```yaml
schema_version: "2.0"
name: github-review
description: Review GitHub issues and PRs for a repository

inputs:
  repo_path:
    description: Path to local repository
    required: true
  repo_name:
    description: GitHub repo identifier (owner/repo)
    required: true

steps:
  - id: understand_codebase
    agent: claude
    prompt: |
      First read ALL of the AGENTS.md file and README.md file super carefully
      and understand ALL of both! Then use your code investigation agent mode
      to fully understand the code, and technical architecture and purpose of
      the project. Use ultrathink.
    working_dir: ${inputs.repo_path}
    wait: completion
    timeout: 10m

  - id: review_issues_prs
    agent: claude
    depends_on: [understand_codebase]
    prompt: |
      We don't allow PRs or outside contributions to this project as a matter
      of policy; here is the policy disclosed to users:

      > *About Contributions:* Please don't take this the wrong way, but I do
      not accept outside contributions for any of my projects. I simply don't
      have the mental bandwidth to review anything, and it's my name on the
      thing, so I'm responsible for any problems it causes; thus, the
      risk-reward is highly asymmetric from my perspective. I'd also have to
      worry about other "stakeholders," which seems unwise for tools I mostly
      make for myself for free. Feel free to submit issues, and even PRs if
      you want to illustrate a proposed fix, but know I won't merge them
      directly. Instead, I'll have Claude or Codex review submissions via `gh`
      and independently decide whether and how to address them. Bug reports in
      particular are welcome. Sorry if this offends, but I want to avoid
      wasted time and hurt feelings. I understand this isn't in sync with the
      prevailing open-source ethos that seeks community contributions, but
      it's the only way I can move at this velocity and keep my sanity.

      But I want you to now use the `gh` utility to review all open issues and
      PRs and to independently read and review each of these carefully; without
      trusting or relying on any of the user reports being correct, or their
      suggested/proposed changes or "fixes" being correct, I want you to do
      your own totally separate and independent verification and validation.
      You can use the stuff from users as possible inspiration, but everything
      has to come from your own mind and/or official documentation and the
      actual code and empirical, independent evidence. Note that MANY of these
      are likely out of date because I made tons of fixes and changes already;
      it's important to look at the dates and subsequent commits. Use ultrathink.
      After you have reviewed things carefully and taken actions in response
      (including implementing possible fixes or new features), you can respond
      on my behalf using `gh`.

      Just a reminder: we do NOT accept ANY PRs. You can look at them to see if
      they contain good ideas but even then you must check with me first before
      integrating even ideas because they could take the project into another
      direction I don't like or introduce scope creep. Use ultrathink.
    working_dir: ${inputs.repo_path}
    wait: user_interaction
    timeout: 30m
    on_question:
      action: queue
      priority: normal
```

#### 7.2.2 ntm Robot Mode Integration

```bash
# Run review using ntm orchestration
run_review_ntm_mode() {
    local repos=("$@")
    local session_name="ru-review-$$"

    # Create ntm session for reviews
    ntm spawn "$session_name" --cc="${#repos[@]}" --working-dir="$PROJECTS_DIR"

    # Queue reviews for each repo
    local pane_index=1
    for repo_spec in "${repos[@]}"; do
        local url branch custom_name local_path repo_id
        resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
            url branch custom_name local_path repo_id

        # Start workflow in this pane
        ntm workflow run github-review \
            --session="$session_name" \
            --pane="$pane_index" \
            --input repo_path="$local_path" \
            --input repo_name="$repo_id" &

        ((pane_index++))
    done

    # Launch interactive TUI for question handling
    ntm review-dashboard "$session_name"
}
```

#### 7.2.3 Question Detection and Aggregation

ntm's activity detection already identifies when Claude is waiting for input. We extend this:

```go
// internal/review/question_detector.go (new file in ntm)
type Question struct {
    SessionID   string
    PaneID      string
    RepoName    string
    Context     string    // Last N lines of output
    DetectedAt  time.Time
    Priority    string
}

func DetectQuestion(pane *tmux.Pane) (*Question, error) {
    // Check if pane is in WAITING state
    activity := pane.GetActivity()
    if activity.State != "WAITING" {
        return nil, nil
    }

    // Extract context from recent output
    output := pane.CaptureOutput(100) // Last 100 lines

    // Look for question patterns
    if hasQuestionPattern(output) {
        return &Question{
            SessionID:  pane.SessionName,
            PaneID:     pane.ID,
            RepoName:   extractRepoName(pane),
            Context:    extractQuestionContext(output),
            DetectedAt: time.Now(),
            Priority:   determinePriority(output),
        }, nil
    }

    return nil, nil
}
```

### 7.3 Phase 3: TUI Implementation (Week 3-4)

#### 7.3.1 Review Dashboard (ntm mode)

New ntm command: `ntm review-dashboard`

```go
// internal/cli/review_dashboard.go
func ReviewDashboardCmd() *cobra.Command {
    return &cobra.Command{
        Use:   "review-dashboard [session]",
        Short: "Interactive dashboard for reviewing questions from Claude",
        RunE: func(cmd *cobra.Command, args []string) error {
            session := args[0]
            return runReviewDashboard(session)
        },
    }
}

func runReviewDashboard(session string) error {
    // Initialize Bubble Tea program
    p := tea.NewProgram(
        newReviewDashboardModel(session),
        tea.WithAltScreen(),
    )

    // Start background goroutine to poll for questions
    go pollForQuestions(session, questionChan)

    return p.Run()
}
```

#### 7.3.2 Basic Mode TUI (gum-based)

```bash
# Simple TUI for basic mode using gum
show_question_prompt() {
    local repo="$1"
    local context="$2"
    local options=("$@")
    shift 2

    echo ""
    gum style --border rounded --padding "1 2" \
        "Question from: $repo"
    echo ""
    echo "$context"
    echo ""

    gum choose "${options[@]}"
}

# Main loop for basic mode
run_review_basic_mode() {
    local repos=("$@")

    for repo_spec in "${repos[@]}"; do
        local url branch custom_name local_path repo_id
        resolve_repo_spec "$repo_spec" "$PROJECTS_DIR" "$LAYOUT" \
            url branch custom_name local_path repo_id

        log_step "Reviewing: $repo_id"

        # Create tmux session for this repo
        local session="ru-review-${repo_id//\//-}"
        tmux new-session -d -s "$session" -c "$local_path"

        # Send to Claude Code
        tmux send-keys -t "$session" "cc" Enter
        sleep 2

        # Send first prompt
        tmux send-keys -t "$session" "$UNDERSTAND_PROMPT" Enter

        # Wait for completion (poll activity)
        wait_for_claude_ready "$session"

        # Send review prompt
        tmux send-keys -t "$session" "$REVIEW_PROMPT" Enter

        # Interactive loop for questions
        while true; do
            local state
            state=$(detect_claude_state "$session")

            case "$state" in
                waiting)
                    local context
                    context=$(get_question_context "$session")
                    handle_question "$repo_id" "$context" "$session"
                    ;;
                complete)
                    break
                    ;;
                working)
                    sleep 5
                    ;;
            esac
        done

        # Update review timestamp
        update_review_timestamp "$repo_id"

        # Cleanup session
        tmux kill-session -t "$session"
    done
}
```

### 7.4 Phase 4: Polish and Integration (Week 4-5)

#### 7.4.1 Configuration

Add to `~/.config/ru/config`:

```bash
# Review settings
REVIEW_PARALLEL=4                    # Number of parallel reviews (ntm mode)
REVIEW_SKIP_DAYS=7                   # Skip repos reviewed within N days
REVIEW_PROMPTS_DIR="$RU_CONFIG_DIR/review-prompts"  # Custom prompts
REVIEW_MODE="auto"                   # auto, ntm, basic
```

#### 7.4.2 Custom Prompts Support

Allow per-repo or per-category prompt customization:

```
~/.config/ru/review-prompts/
├── default-understand.txt           # Default codebase prompt
├── default-review.txt               # Default review prompt
├── python-understand.txt            # Python-specific
└── repos/
    └── myorg-myrepo-review.txt      # Repo-specific override
```

#### 7.4.3 Reporting

```bash
# Generate review summary
generate_review_report() {
    local session="$1"
    local output_file="$RU_STATE_DIR/reports/review-$(date +%Y%m%d-%H%M%S).md"

    cat > "$output_file" << EOF
# Review Report - $(date)

## Repositories Reviewed

$(for repo in "${REVIEWED_REPOS[@]}"; do
    echo "### $repo"
    echo "- Issues addressed: ${ISSUES_RESOLVED[$repo]:-0}"
    echo "- PRs closed: ${PRS_CLOSED[$repo]:-0}"
    echo "- Comments posted: ${COMMENTS_POSTED[$repo]:-0}"
    echo ""
done)

## Summary

- Total repositories: ${#REVIEWED_REPOS[@]}
- Total issues resolved: $TOTAL_ISSUES
- Total PRs handled: $TOTAL_PRS
- Duration: $DURATION
EOF

    log_success "Report saved: $output_file"
}
```

---

## 8. Technical Deep Dive

### 8.1 Claude Code Activity Detection

Detecting when Claude Code is waiting for input vs. working:

```go
// Activity states for Claude Code
const (
    StateGenerating = "GENERATING"  // High output velocity (>10 chars/sec)
    StateWaiting    = "WAITING"     // Idle at prompt, ready for input
    StateThinking   = "THINKING"    // Low velocity, processing
    StateError      = "ERROR"       // Error patterns detected
)

// Detection heuristics
func DetectClaudeState(pane *Pane) string {
    output := pane.CaptureLastN(50)  // Last 50 lines
    velocity := pane.OutputVelocity()

    // Check for error patterns
    if containsErrorPattern(output) {
        return StateError
    }

    // Check for waiting patterns (prompt visible, no activity)
    if velocity < 1.0 && containsPromptPattern(output) {
        return StateWaiting
    }

    // Check for active generation
    if velocity > 10.0 {
        return StateGenerating
    }

    return StateThinking
}

// Patterns indicating Claude is waiting for input
var waitingPatterns = []string{
    `^\s*>\s*$`,                    // Empty prompt
    `\[y/N\]`,                      // Yes/No prompt
    `\[Y/n\]`,                      // Yes/No prompt
    `Select.*:`,                    // Selection prompt
    `Enter.*:`,                     // Input prompt
    `Press Enter to continue`,     // Continuation prompt
}

// Patterns indicating a question
var questionPatterns = []string{
    `Should I`,
    `Do you want`,
    `Would you like`,
    `Please confirm`,
    `Choose.*:`,
    `Which.*\?`,
    `What.*\?`,
    `How should`,
}
```

### 8.2 Question Context Extraction

```go
// Extract relevant context around a question
func ExtractQuestionContext(output string, maxLines int) string {
    lines := strings.Split(output, "\n")

    // Find the question line
    questionIdx := -1
    for i := len(lines) - 1; i >= 0; i-- {
        if isQuestionLine(lines[i]) {
            questionIdx = i
            break
        }
    }

    if questionIdx == -1 {
        // No question found, return last N lines
        start := max(0, len(lines)-maxLines)
        return strings.Join(lines[start:], "\n")
    }

    // Get context before and after question
    start := max(0, questionIdx-10)
    end := min(len(lines), questionIdx+5)

    return strings.Join(lines[start:end], "\n")
}
```

### 8.3 Answer Routing

```go
// Route answer back to appropriate session
func RouteAnswer(question *Question, answer string) error {
    // Get the tmux pane
    pane, err := tmux.GetPane(question.SessionID, question.PaneID)
    if err != nil {
        return err
    }

    // Send the answer
    return pane.SendKeys(answer + "\n")
}
```

### 8.4 State Persistence

```json
// ~/.local/state/ru/review-state.json
{
  "owner/repo1": {
    "last_review": "2025-01-04T10:30:00Z",
    "issues_at_review": 3,
    "prs_at_review": 1,
    "outcome": "completed"
  },
  "owner/repo2": {
    "last_review": "2025-01-03T15:45:00Z",
    "issues_at_review": 0,
    "prs_at_review": 2,
    "outcome": "partial",
    "pending_questions": [
      {
        "context": "Should I refactor the auth module?",
        "timestamp": "2025-01-03T16:00:00Z"
      }
    ]
  }
}
```

---

## 9. TUI Design

### 9.1 Main Dashboard Layout

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  ru review                                               Progress: 5/12     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  PENDING QUESTIONS (3)                                                       │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  [1] ● project-alpha                                           HIGH         │
│      Issue #42: Authentication failing on Windows                           │
│      ┌─────────────────────────────────────────────────────────────────┐   │
│      │ I found the root cause is path handling with backslashes.       │   │
│      │ Should I:                                                        │   │
│      │   a) Fix for Windows only (minimal change)                      │   │
│      │   b) Refactor path handling for all platforms                   │   │
│      │   c) Skip this issue for now                                    │   │
│      └─────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  [2] ○ project-beta                                            NORMAL       │
│      PR #15: Add Redis caching                                              │
│      ┌─────────────────────────────────────────────────────────────────┐   │
│      │ The PR adds Redis caching but I verified the approach is sound. │   │
│      │ However, it adds a new dependency. Implement caching with:       │   │
│      │   a) Redis (as proposed)                                        │   │
│      │   b) In-memory cache (no new deps)                              │   │
│      │   c) Skip caching entirely                                      │   │
│      └─────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  [3] ○ project-gamma                                           LOW          │
│      Issue #7: Feature request for dark mode                                │
│      [Press Enter to expand]                                                │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  ACTIVE SESSIONS (4)                                                         │
│  ─────────────────────────────────────────────────────────────────────────  │
│  project-delta    ████████░░ 80%  Reviewing issue #3...                     │
│  project-epsilon  ██████░░░░ 60%  Understanding codebase...                 │
│  project-zeta     ████░░░░░░ 40%  Cloning repository...                     │
│  project-eta      ██░░░░░░░░ 20%  Waiting to start...                       │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│  [1-9] Answer  [d] Drill-down  [s] Skip  [p] Pause  [r] Refresh  [q] Quit  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 Drill-Down View

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  project-alpha - Session Details                              [ESC] Back    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Repository: https://github.com/owner/project-alpha                         │
│  Local Path: ~/projects/project-alpha                                       │
│  Session:    ru-review-project-alpha                                        │
│  Duration:   12m 34s                                                         │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────  │
│  RECENT OUTPUT                                                               │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  > I've analyzed the issue #42 about authentication failing on Windows.     │
│  > The user reports that login fails with "path not found" error.           │
│  >                                                                          │
│  > After investigating, I found the root cause:                             │
│  > - Line 234 in auth.py uses forward slashes for paths                     │
│  > - Windows requires backslashes for certain operations                    │
│  > - The pathlib migration in commit abc123 didn't fully address this       │
│  >                                                                          │
│  > I can fix this in two ways:                                              │
│  >                                                                          │
│  > Option A: Minimal fix (Windows only)                                     │
│  > - Add os.path.normpath() call on line 234                                │
│  > - Estimated: 5 lines changed                                             │
│  >                                                                          │
│  > Option B: Full refactor                                                  │
│  > - Convert all path handling to use pathlib consistently                  │
│  > - Estimated: 45 lines changed across 3 files                             │
│  >                                                                          │
│  > Should I proceed with option A or B?                                     │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  [a] Option A  [b] Option B  [c] Skip  [v] View full session  [ESC] Back   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.3 Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `1-9` | Select and answer question by number |
| `Enter` | Expand/collapse question details |
| `d` | Drill-down to full session view |
| `s` | Skip current question |
| `S` | Skip all pending questions |
| `p` | Pause new reviews |
| `r` | Refresh display |
| `a` | Switch to active sessions view |
| `h` | Show help overlay |
| `q` | Quit (confirms if sessions active) |
| `Esc` | Back / Cancel |

---

## 10. Integration with ntm

### 10.1 Why ntm is Ideal

ntm already provides:

1. **Session Management**: Create, manage, and persist tmux sessions
2. **Activity Detection**: Know when Claude is waiting, working, or errored
3. **Robot Mode**: Programmatic JSON API for Bash integration
4. **TUI Framework**: Beautiful Bubble Tea-based interfaces
5. **Health Monitoring**: Auto-restart crashed sessions
6. **Workflow Pipelines**: YAML-based orchestration

### 10.2 New ntm Components Needed

```
internal/
├── review/
│   ├── detector.go      # Question detection logic
│   ├── aggregator.go    # Question queue management
│   ├── router.go        # Answer routing
│   └── state.go         # Review state persistence
├── cli/
│   ├── review_dashboard.go  # TUI dashboard command
│   └── review_start.go      # Start review sessions
└── workflows/
    └── templates/
        └── github-review.yaml  # Built-in review workflow
```

### 10.3 Communication Protocol

```
ru (Bash) ←──────────────────────→ ntm (Go)
    │                                  │
    │  ntm --robot-spawn               │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"status":"ok","session":"..."}│
    │◀──────────────────────────────── │
    │                                  │
    │  ntm --robot-status              │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"sessions":[...],"questions":[...]}
    │◀──────────────────────────────── │
    │                                  │
    │  ntm --robot-answer              │
    │  --question-id=123               │
    │  --answer="a"                    │
    │  ──────────────────────────────▶│
    │                                  │
    │  {"status":"ok","routed":true}  │
    │◀──────────────────────────────── │
```

### 10.4 Fallback When ntm Unavailable

```bash
# Check for ntm and gracefully degrade
check_review_prerequisites() {
    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI (gh) is required for reviews"
        log_info "Install: https://cli.github.com/"
        return 3
    fi

    if ! gh auth status &>/dev/null; then
        log_error "GitHub CLI is not authenticated"
        log_info "Run: gh auth login"
        return 3
    fi

    # ntm is optional but recommended
    if ! command -v ntm &>/dev/null; then
        log_warn "ntm not found - using basic mode (sequential, limited TUI)"
        log_info "For enhanced experience, install ntm: https://github.com/..."
        return 0
    fi

    return 0
}
```

---

## 11. Risk Mitigation

### 11.1 Technical Risks

| Risk | Mitigation |
|------|------------|
| Claude Code API changes | Abstract interaction layer; version detection |
| tmux compatibility | Test on multiple tmux versions; document requirements |
| gh CLI rate limits | Implement backoff; cache API responses |
| Long-running sessions | Checkpoint state; resume capability |
| Output parsing fragility | Use multiple detection signals; graceful degradation |

### 11.2 User Experience Risks

| Risk | Mitigation |
|------|------------|
| Information overload | Prioritization; progressive disclosure |
| Lost context | Full session drill-down; output logging |
| Accidental answers | Confirmation for destructive actions |
| Interrupted sessions | State persistence; resume from checkpoint |

### 11.3 Security Considerations

| Consideration | Approach |
|---------------|----------|
| GitHub token exposure | Use gh CLI (handles auth securely) |
| Arbitrary code execution | Claude operates in sandboxed repos |
| Sensitive data in logs | Configurable log verbosity; no secrets in state files |

---

## 12. Future Enhancements

### 12.1 Short-term (v1.1)

- **Batch answers**: Answer multiple similar questions at once
- **Answer templates**: Pre-configured responses for common situations
- **Priority rules**: Auto-prioritize based on issue labels, age, author
- **Notification integration**: Desktop/webhook alerts for questions

### 12.2 Medium-term (v1.5)

- **Learning from decisions**: Track patterns in answers for suggestions
- **Multi-agent support**: Use different AI models for different repo types
- **Scheduled reviews**: Cron-based automatic review runs
- **Team support**: Multiple maintainers with role-based access

### 12.3 Long-term (v2.0)

- **Fully autonomous mode**: AI handles routine issues without human input
- **Cross-repo intelligence**: Learn patterns across all repositories
- **Community interaction**: Auto-respond to common questions
- **Analytics dashboard**: Insights into issue/PR trends and resolution times

---

## Appendix A: Command Reference

### A.1 `ru review`

```
ru review - Review GitHub issues and PRs using Claude Code

USAGE:
    ru review [options]

OPTIONS:
    --mode=MODE         Orchestration mode: auto, ntm, basic (default: auto)
    --parallel=N        Number of parallel reviews in ntm mode (default: 4)
    --repos=PATTERN     Only review repos matching pattern
    --skip-days=N       Skip repos reviewed within N days (default: 7)
    --dry-run           Show what would be reviewed without starting
    --resume            Resume interrupted review session
    --priority=LEVEL    Minimum priority to review: all, normal, high (default: all)
    --json              Output progress as JSON

EXAMPLES:
    ru review                           # Review all repos with activity
    ru review --dry-run                 # Preview repos needing review
    ru review --repos="myorg/*"         # Only repos in myorg
    ru review --mode=basic              # Force basic mode (no ntm)
    ru review --parallel=8              # More parallel sessions
```

### A.2 `ru review-status`

```
ru review-status - Show status of ongoing or past reviews

USAGE:
    ru review-status [options]

OPTIONS:
    --active            Show only active review sessions
    --history           Show review history
    --repo=REPO         Show status for specific repo
    --json              Output as JSON
```

---

## Appendix B: Configuration Reference

```bash
# ~/.config/ru/config

#==============================================================================
# Review Settings
#==============================================================================

# Orchestration mode: auto (detect ntm), ntm (require ntm), basic (no ntm)
REVIEW_MODE="auto"

# Number of parallel review sessions (ntm mode only)
REVIEW_PARALLEL=4

# Skip repos reviewed within this many days
REVIEW_SKIP_DAYS=7

# Directory for custom prompts
REVIEW_PROMPTS_DIR="$RU_CONFIG_DIR/review-prompts"

# Timeout for codebase understanding phase (seconds)
REVIEW_UNDERSTAND_TIMEOUT=600

# Timeout for issue/PR review phase (seconds)
REVIEW_PHASE_TIMEOUT=1800

# Auto-skip repos with only low-priority issues
REVIEW_SKIP_LOW_PRIORITY="false"

# Desktop notifications for questions
REVIEW_NOTIFY="true"
```

---

## Appendix C: State File Formats

### C.1 Review State (`~/.local/state/ru/review-state.json`)

```json
{
  "version": 1,
  "repos": {
    "owner/repo": {
      "last_review": "2025-01-04T10:30:00Z",
      "last_review_run_id": "abc123",
      "issues_reviewed": 3,
      "prs_reviewed": 1,
      "issues_resolved": 2,
      "prs_closed": 0,
      "outcome": "completed",
      "duration_seconds": 847
    }
  },
  "runs": {
    "abc123": {
      "started_at": "2025-01-04T10:00:00Z",
      "completed_at": "2025-01-04T11:30:00Z",
      "repos_processed": 8,
      "questions_answered": 12,
      "mode": "ntm"
    }
  }
}
```

### C.2 Question Queue (`~/.local/state/ru/review-questions.json`)

```json
{
  "version": 1,
  "questions": [
    {
      "id": "q_abc123",
      "run_id": "run_xyz",
      "repo": "owner/repo",
      "session_id": "ru-review-owner-repo",
      "pane_id": "1",
      "context": "Should I refactor...",
      "options": ["a) Minimal fix", "b) Full refactor", "c) Skip"],
      "priority": "normal",
      "detected_at": "2025-01-04T10:45:00Z",
      "status": "pending"
    }
  ]
}
```

---

## Appendix D: Workflow Template

Full `github-review.yaml` workflow for ntm:

```yaml
schema_version: "2.0"
name: github-review
description: |
  Automated GitHub issue and PR review workflow.
  Uses Claude Code to understand codebase, review issues/PRs,
  implement fixes, and respond via gh CLI.

inputs:
  repo_path:
    description: Absolute path to local repository
    required: true
  repo_name:
    description: GitHub repository identifier (owner/repo)
    required: true
  understand_prompt:
    description: Custom codebase understanding prompt
    required: false
  review_prompt:
    description: Custom review prompt
    required: false

defaults:
  working_dir: ${inputs.repo_path}
  agent: claude

steps:
  - id: verify_prerequisites
    type: shell
    command: |
      # Verify gh is authenticated
      gh auth status || exit 1

      # Verify repo has issues or PRs
      issues=$(gh issue list -R ${inputs.repo_name} --state open --json number --jq 'length')
      prs=$(gh pr list -R ${inputs.repo_name} --state open --json number --jq 'length')

      if [ "$((issues + prs))" -eq 0 ]; then
        echo "No open issues or PRs"
        exit 0
      fi

      echo "Found $issues issues and $prs PRs"
    on_failure: abort

  - id: update_repo
    type: shell
    command: git pull --ff-only || true
    depends_on: [verify_prerequisites]

  - id: understand_codebase
    agent: claude
    depends_on: [update_repo]
    prompt: |
      ${inputs.understand_prompt:-
      First read ALL of the AGENTS.md file and README.md file super carefully
      and understand ALL of both! Then use your code investigation agent mode
      to fully understand the code, and technical architecture and purpose of
      the project. Use ultrathink.
      }
    wait: completion
    timeout: 10m
    health_check:
      interval: 30s
      max_stalls: 3

  - id: review_issues_prs
    agent: claude
    depends_on: [understand_codebase]
    prompt: |
      ${inputs.review_prompt:-
      We don't allow PRs or outside contributions to this project as a matter
      of policy; here is the policy disclosed to users:

      > *About Contributions:* Please don't take this the wrong way, but I do
      not accept outside contributions for any of my projects. I simply don't
      have the mental bandwidth to review anything, and it's my name on the
      thing, so I'm responsible for any problems it causes; thus, the
      risk-reward is highly asymmetric from my perspective. I'd also have to
      worry about other "stakeholders," which seems unwise for tools I mostly
      make for myself for free. Feel free to submit issues, and even PRs if
      you want to illustrate a proposed fix, but know I won't merge them
      directly. Instead, I'll have Claude or Codex review submissions via `gh`
      and independently decide whether and how to address them. Bug reports in
      particular are welcome. Sorry if this offends, but I want to avoid
      wasted time and hurt feelings. I understand this isn't in sync with the
      prevailing open-source ethos that seeks community contributions, but
      it's the only way I can move at this velocity and keep my sanity.

      But I want you to now use the `gh` utility to review all open issues and
      PRs and to independently read and review each of these carefully; without
      trusting or relying on any of the user reports being correct, or their
      suggested/proposed changes or "fixes" being correct, I want you to do
      your own totally separate and independent verification and validation.
      You can use the stuff from users as possible inspiration, but everything
      has to come from your own mind and/or official documentation and the
      actual code and empirical, independent evidence. Note that MANY of these
      are likely out of date because I made tons of fixes and changes already;
      it's important to look at the dates and subsequent commits. Use ultrathink.
      After you have reviewed things carefully and taken actions in response
      (including implementing possible fixes or new features), you can respond
      on my behalf using `gh`.

      Just a reminder: we do NOT accept ANY PRs. You can look at them to see if
      they contain good ideas but even then you must check with me first before
      integrating even ideas because they could take the project into another
      direction I don't like or introduce scope creep. Use ultrathink.
      }
    wait: user_interaction
    timeout: 30m
    on_question:
      action: queue
      priority: ${question.urgency:-normal}
      metadata:
        repo: ${inputs.repo_name}
        issue_context: true

  - id: finalize
    type: shell
    depends_on: [review_issues_prs]
    command: |
      # Push any commits made
      git push || true

      # Log completion
      echo "Review completed for ${inputs.repo_name}"
    on_failure: warn

outputs:
  issues_addressed:
    description: Number of issues that were addressed
    value: ${steps.review_issues_prs.issues_count:-0}
  prs_reviewed:
    description: Number of PRs that were reviewed
    value: ${steps.review_issues_prs.prs_count:-0}
  commits_made:
    description: Number of commits created
    value: ${steps.finalize.commit_count:-0}
```

---

*Document Version: 1.0*
*Last Updated: January 2025*
*Author: Claude (Opus 4.5)*
