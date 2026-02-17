# Plan: `ru commit-sweep` v0.1 MVP (Claude Code Review v3)

> Третя ітерація review. CC-N (перша), CC2-N (друга), CC3-N (третя).
> Фокус v3: signal handling, multi-repo atomicity, caching, configuration, debugging.

## Context

AI-агенти кодери (працюють з br-задачами) зараз і кодують, і комітять. Це призводить до:
- Поганих commit messages (короткі, неінформативні)
- Випадкового захоплення змін інших агентів
- Заплутаної git history
- Відволікання від основної роботи — кодування

**Рішення:** спеціалізована команда `ru commit-sweep` — єдиний інструмент для комітів.

**Unix-філософія:** одна робота — перетворити брудне робоче дерево в чисті атомарні коміти.

## Ecosystem Integration

| Інструмент | Що дає | API |
|------------|--------|-----|
| **ru** | repo discovery, JSON envelope, logging | `repo_is_dirty()`, `build_json_envelope()` |
| **br** | Task title за bead ID | `br show bd-XXXX --format json` |
| **DCG** | safe/destructive classification | commit=safe, push=needs flag |
| **agent-mail** | File ownership (v0.2+) | `file_reservation_paths()` |
| **bv** | Commit-to-bead correlation (v0.2+) | `bv --robot-history` |

## Function Inventory

### Core Functions
| Function | Purpose | Source |
|----------|---------|--------|
| `cmd_commit_sweep()` | Main command entry point | Original |
| `cs_analyze_repo()` | git status → classify → group → JSON | Original |
| `cs_classify_file()` | File → bucket (test/doc/config/source) | Original |
| `cs_detect_commit_type()` | Bucket-first type detection | CC-1 |
| `cs_detect_scope()` | Top-level directory as scope | Original |
| `cs_build_message()` | Conventional commit subject | Original |
| `cs_build_commit_body()` | Optional commit body | CC3-8 |
| `cs_assess_confidence()` | Scoring with factors | CC-7 |
| `cs_execute_group()` | git add + commit with rollback | Original |
| `cs_execute_plan()` | Iterate groups | Original |

### Safety Functions
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_validate_path()` | Security validation | CC2-9 |
| `cs_is_binary()` | Binary file detection | CC-8 |
| `cs_is_submodule()` | Submodule detection | CC-9 |
| `cs_is_symlink()` | Symlink detection | CC2-7 |
| `cs_should_exclude()` | Glob pattern matching | CC-3 |
| `cs_sanitize_message()` | Message sanitization | CC2-9 |

### Reliability Functions
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_preflight_check()` | Git state validation | CC2-1 |
| `cs_check_git_version()` | Minimum version check | CC2-10 |
| `cs_acquire_lock()` | Concurrent protection | CC2-2 |
| `cs_release_lock()` | Lock cleanup | CC2-2 |
| `cs_setup_signal_handlers()` | SIGINT/SIGTERM traps | CC3-1 |
| `cs_cleanup_on_interrupt()` | Graceful shutdown | CC3-1 |
| `cs_with_timeout()` | Operation timeouts | CC3-10 |
| `cs_save_state()` | Recovery state | CC2-6 |
| `cs_load_state()` | Resume support | CC2-6 |

### Plan Management
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_save_plan()` | Serialize to JSON | CC-4 |
| `cs_load_plan()` | Load and validate | CC-4 |
| `cs_calculate_checksum()` | Plan integrity | CC-4 |
| `cs_atomic_repos_execute()` | Multi-repo atomicity | CC3-2 |

### Checkpoint/Undo
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_create_checkpoint()` | git stash push | CC-5 |
| `cs_restore_checkpoint()` | git stash pop | CC-5 |
| `cs_undo_last_sweep()` | Undo via sweep log | CC2-3 |

### Performance
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_collect_files()` | Batch git status | CC-6 |
| `cs_get_task_title_cached()` | br API caching | CC3-3 |
| `cs_clear_task_cache()` | Cache management | CC3-3 |

### UX Functions
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_progress_init/update/finish()` | Progress bar | CC2-4 |
| `cs_show_file_diff()` | Diff preview | CC2-5 |
| `cs_log()` | Structured logging | CC2-12 |
| `cs_doctor()` | Environment diagnostics | CC3-4 |
| `cs_self_test()` | Internal tests | CC3-4 |
| `cs_load_config()` | Configuration file | CC3-5 |
| `cs_error_with_guidance()` | Actionable errors | CC3-7 |
| `cs_init_colors()` | NO_COLOR support | CC3-11 |

### Utility
| Function | Purpose | Source |
|----------|---------|--------|
| `cs_extract_task_id()` | Branch → task ID | Original |
| `cs_get_dominant_status()` | Status counting | CC-1 |
| `cs_decode_git_path()` | Quoted path handling | CC2-8 |
| `cs_safe_filename_json()` | Non-UTF8 handling | CC2-8 |

---

## Scope v0.1

**Робить:**
1. Сканує репо на dirty worktrees
2. Групує файли: source / test / docs / config
3. Генерує conventional commit messages (евристики, не LLM)
4. Витягує task ID з назви гілки
5. Виводить план (JSON або human-readable)
6. Виконує з `--execute` (default = dry-run)
7. Зберігає/завантажує план [CC-4]
8. Undo останній sweep [CC2-3]
9. Діагностика з `--doctor` [CC3-4]

**НЕ робить:** LLM, agent-mail, bv integration, push, parallel.

---

## CLI Options

```
COMMIT-SWEEP OPTIONS:

Execution:
    --execute            Actually create commits (default: dry-run)
    --dry-run            Show plan without changes (default)
    --atomic             Rollback ALL commits if ANY group fails [CC-5]
    --atomic-repos       Rollback ALL repos if ANY repo fails [CC3-2]

Display:
    --show-diff          Show diffs in dry-run output [CC2-5]
    --diff-context=N     Context lines in diff (default: 3) [CC2-5]
    -v, --verbose        Increase verbosity (-v, -vv, -vvv) [CC3-6]
    -q, --quiet          Suppress non-error output [CC3-6]
    --color=WHEN         Color: auto|always|never [CC3-11]
    --log-format=FORMAT  Log: text|json|logfmt [CC2-12]

Filtering:
    --respect-staging    Preserve manually staged files
    --exclude=PATTERN    Exclude files (repeatable) [CC-3]
    --exclude-from=FILE  Read patterns from file [CC-3]
    --no-default-excludes Skip default excludes [CC-3]
    --include-binary     Include binary files [CC-8]
    --include-submodules Include submodule changes [CC-9]

Overrides:
    --type=TYPE          Override commit type [CC-10]
    --scope=SCOPE        Override scope [CC-10]
    --message=MSG        Override message [CC-10]
    --no-task-id         Don't append task ID [CC-10]
    --body               Include commit body [CC3-8]
    --body-template=TPL  Custom body template [CC3-8]

Plan Management:
    --save-plan=FILE     Save plan to file [CC-4]
    --load-plan=FILE     Execute saved plan [CC-4]
    --resume             Resume interrupted sweep [CC2-6]
    --restart            Ignore state, start fresh [CC2-6]
    --undo               Undo last sweep [CC2-3]
    --undo-interactive   Select commits to undo [CC2-3]

Configuration:
    --config=FILE        Use config file [CC3-5]
    --no-config          Ignore config files [CC3-5]

Diagnostics:
    --doctor             Run diagnostics [CC3-4]
    --self-test          Run internal tests [CC3-4]
```

---

## [CC3-1] Signal Handling (P0)

**Проблема:** Ctrl+C mid-sweep залишає undefined state.

```bash
declare -g CS_CURRENT_REPO=""
declare -g CS_CHECKPOINT_CREATED=false
declare -g CS_LOCK_ACQUIRED=false
declare -g CS_INTERRUPTED=false

cs_setup_signal_handlers() {
    trap 'cs_cleanup_on_interrupt' SIGINT SIGTERM SIGHUP
}

cs_cleanup_on_interrupt() {
    CS_INTERRUPTED=true
    trap '' SIGINT SIGTERM SIGHUP  # Prevent recursive

    log_warn "Interrupt received, cleaning up..."

    if [[ -n "$CS_CURRENT_REPO" ]]; then
        # Unstage partial changes
        git -C "$CS_CURRENT_REPO" reset HEAD -- . 2>/dev/null || true

        # Restore checkpoint
        if [[ "$CS_CHECKPOINT_CREATED" == "true" ]]; then
            log_info "Restoring from checkpoint..."
            git -C "$CS_CURRENT_REPO" stash pop 2>/dev/null || true
        fi

        # Release lock
        if [[ "$CS_LOCK_ACQUIRED" == "true" ]]; then
            cs_release_lock "$CS_CURRENT_REPO"
        fi

        # Update state file
        local state_file="$CS_CURRENT_REPO/.git/commit-sweep-state.json"
        if [[ -f "$state_file" ]]; then
            sed -i 's/"status": "in_progress"/"status": "interrupted"/' "$state_file"
        fi
    fi

    log_warn "Cleanup complete. Use --resume to continue."
    exit 5
}
```

**Exit code:** 5 (interrupted)

---

## [CC3-2] Multi-Repo Atomicity (P0)

**`--atomic-repos` behavior:**

```
Phase 1: Preflight ALL repos
  - If any fails → exit before changes

Phase 2: Create ALL checkpoints upfront

Phase 3: Execute repo by repo
  - Track completed repos

Phase 4: On ANY failure
  - Rollback ALL repos (including successful)
```

```bash
cs_atomic_repos_execute() {
    local -a repos=("$@")
    local -a checkpoints=()

    # Phase 1: Preflight all
    for repo in "${repos[@]}"; do
        if ! cs_preflight_check "$repo"; then
            log_error "Preflight failed for $repo, aborting"
            return 2
        fi
    done

    # Phase 2: Create all checkpoints
    for repo in "${repos[@]}"; do
        local checkpoint_id
        checkpoint_id=$(cs_create_checkpoint "$repo")
        checkpoints+=("$repo:$checkpoint_id")
    done

    # Phase 3: Execute
    local failed=false
    for repo in "${repos[@]}"; do
        if ! cs_execute_repo "$repo"; then
            failed=true
            break
        fi
    done

    # Phase 4: Rollback if failed
    if [[ "$failed" == "true" ]]; then
        log_warn "Rolling back all repos..."
        for entry in "${checkpoints[@]}"; do
            local repo="${entry%:*}"
            cs_restore_checkpoint "$repo"
        done
        return 1
    fi

    # Success: cleanup checkpoints
    for entry in "${checkpoints[@]}"; do
        local repo="${entry%:*}"
        cs_drop_checkpoint "$repo"
    done
}
```

---

## [CC2-1] Pre-flight Checks (P0)

```bash
cs_preflight_check() {
    local repo_path="$1"
    local git_dir
    git_dir=$(git -C "$repo_path" rev-parse --git-dir 2>/dev/null) || return 1

    local -a blockers=()
    [[ -f "$git_dir/MERGE_HEAD" ]] && blockers+=("merge in progress")
    [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] && blockers+=("rebase in progress")
    [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && blockers+=("cherry-pick in progress")
    [[ -f "$git_dir/BISECT_LOG" ]] && blockers+=("bisect in progress")
    [[ -f "$git_dir/REVERT_HEAD" ]] && blockers+=("revert in progress")

    if ! git -C "$repo_path" symbolic-ref HEAD &>/dev/null; then
        log_warn "Detached HEAD state in $repo_path"
    fi

    if (( ${#blockers[@]} > 0 )); then
        cs_error_with_guidance "preflight_blocked" "$repo_path" "${blockers[*]}"
        return 1
    fi

    return 0
}
```

---

## [CC2-2] Lock File Protection (P0)

**Location:** `.git/commit-sweep.lock`

```bash
cs_acquire_lock() {
    local repo_path="$1"
    local lock_file="$repo_path/.git/commit-sweep.lock"
    local timeout="${2:-${CS_CONFIG_LOCK_TIMEOUT:-30}}"
    local pid=$$
    local start_time=$SECONDS

    while true; do
        if (set -o noclobber; echo "$pid $(date +%s)" > "$lock_file") 2>/dev/null; then
            trap "cs_release_lock '$repo_path'" EXIT
            return 0
        fi

        if [[ -f "$lock_file" ]]; then
            local lock_pid lock_time
            read -r lock_pid lock_time < "$lock_file" 2>/dev/null || true

            # Stale: process dead
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Removing stale lock from dead process $lock_pid"
                rm -f "$lock_file"
                continue
            fi

            # Stale: too old (5 minutes)
            local now
            now=$(date +%s)
            if [[ -n "$lock_time" ]] && (( now - lock_time > 300 )); then
                log_warn "Removing stale lock (older than 5 minutes)"
                rm -f "$lock_file"
                continue
            fi
        fi

        if (( SECONDS - start_time > timeout )); then
            cs_error_with_guidance "lock_timeout" "$repo_path"
            return 1
        fi

        cs_log_debug "Waiting for lock on $repo_path (held by PID $lock_pid)..."
        sleep 1
    done
}

cs_release_lock() {
    local repo_path="$1"
    rm -f "$repo_path/.git/commit-sweep.lock"
}
```

---

## [CC2-9] Security: Command Injection Prevention (P0)

```bash
cs_validate_path() {
    local path="$1"

    # Null bytes
    if [[ "$path" == *$'\0'* ]]; then
        log_error "Invalid path: contains null byte"
        return 1
    fi

    # Dash prefix (flag injection)
    if [[ "$path" == -* ]]; then
        log_error "Invalid path: starts with dash"
        return 1
    fi

    # Absolute path
    if [[ "$path" == /* ]]; then
        log_error "Invalid path: absolute path not allowed"
        return 1
    fi

    return 0
}

cs_sanitize_message() {
    local msg="$1"
    msg=$(printf '%s' "$msg" | tr -d '\000-\010\013-\037')
    msg="${msg:0:1000}"
    printf '%s' "$msg"
}
```

**Always use `--` separator:**
```bash
git add -- "${files[@]}"
git commit -m "$message"
```

---

## [CC-1] Commit Type Detection: Bucket-First

```
1. bucket == "test"   → "test"
2. bucket == "doc"    → "docs"
3. bucket == "config" → "chore"
4. bucket == "source":
   - dominant_status == "A" → "feat"
   - dominant_status == "D" → "chore"
   - dominant_status == "R" → "refactor"
   - dominant_status == "M" → "fix"
5. Fallback: "chore"
```

```bash
cs_get_dominant_status() {
    local -A counts=([A]=0 [M]=0 [D]=0 [R]=0)
    local statuses="$1"
    for s in $statuses; do
        ((counts[$s]++)) || true
    done
    local max_count=0 dominant="M"
    for s in A M D R; do
        if (( counts[$s] > max_count )); then
            max_count=${counts[$s]}
            dominant=$s
        fi
    done
    echo "$dominant"
}
```

---

## [CC3-3] Task Title Caching (P1)

```bash
declare -gA CS_TASK_TITLE_CACHE=()
declare -g CS_CACHE_HITS=0
declare -g CS_CACHE_MISSES=0

cs_get_task_title_cached() {
    local task_id="$1"

    [[ -z "$task_id" ]] && { echo ""; return 0; }

    # Cache hit
    if [[ -v CS_TASK_TITLE_CACHE["$task_id"] ]]; then
        ((CS_CACHE_HITS++))
        echo "${CS_TASK_TITLE_CACHE[$task_id]}"
        return 0
    fi

    # Cache miss
    ((CS_CACHE_MISSES++))
    local title=""
    if command -v br &>/dev/null; then
        title=$(cs_with_timeout "${CS_CONFIG_BR_TIMEOUT:-3}s" "br show" \
            br show "$task_id" --format json 2>/dev/null |
            grep -o '"title": *"[^"]*"' | head -1 | cut -d'"' -f4) || true
    fi

    CS_TASK_TITLE_CACHE["$task_id"]="$title"
    echo "$title"
}

cs_clear_task_cache() {
    CS_TASK_TITLE_CACHE=()
    CS_CACHE_HITS=0
    CS_CACHE_MISSES=0
}
```

---

## [CC3-4] Doctor Command (P1)

```bash
cs_doctor() {
    local exit_code=0

    printf "Environment:\n"
    printf "  %-18s %s\n" "ru version:" "$VERSION"

    # Git version
    local git_ver
    git_ver=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if cs_check_git_version &>/dev/null; then
        printf "  %-18s %s ✓ (minimum: 2.13)\n" "git version:" "$git_ver"
    else
        printf "  %-18s %s ✗ (minimum: 2.13)\n" "git version:" "$git_ver"
        exit_code=1
    fi

    printf "  %-18s %s\n" "bash version:" "${BASH_VERSION}"

    # Optional deps
    if command -v br &>/dev/null; then
        printf "  %-18s yes\n" "br available:"
    else
        printf "  %-18s no (task titles unavailable)\n" "br available:"
    fi

    if command -v gum &>/dev/null; then
        printf "  %-18s yes\n" "gum available:"
    else
        printf "  %-18s no (fallback formatting)\n" "gum available:"
    fi

    # Current repo
    if is_git_repo "."; then
        printf "\nCurrent repo:\n"
        printf "  %-18s %s\n" "Path:" "$(pwd)"
        printf "  %-18s %s\n" "Branch:" "$(git branch --show-current)"

        local task_id
        task_id=$(cs_extract_task_id "$(git branch --show-current)")
        printf "  %-18s %s\n" "Task ID:" "${task_id:-none}"
        printf "  %-18s %d\n" "Dirty files:" "$(git status --porcelain | wc -l)"

        printf "\nPreflight checks:\n"
        if cs_preflight_check "." 2>/dev/null; then
            printf "  ✓ All checks passed\n"
        else
            exit_code=2
        fi
    fi

    if (( exit_code == 0 )); then
        printf "\n${CS_GREEN}Ready to sweep.${CS_RESET}\n"
    else
        printf "\n${CS_RED}Fix issues above.${CS_RESET}\n"
    fi

    return $exit_code
}
```

---

## [CC3-5] Configuration File (P1)

**Locations (precedence order):**
1. `--config=FILE`
2. `.commit-sweep.yaml` (repo-local)
3. `~/.config/ru/commit-sweep.yaml` (global)

```yaml
# ~/.config/ru/commit-sweep.yaml

exclude:
  - "*.generated.go"
  - "vendor/**"
  - "node_modules/**"

timeouts:
  br: 5
  lock: 60
  git_status: 10
  git_commit: 60

defaults:
  show_diff: true
  respect_staging: false
  include_binary: false
  log_format: text
  verbosity: 1

message:
  max_length: 72
  include_task_id: true
  include_body: false

confidence:
  high_threshold: 3
  medium_threshold: 1
```

```bash
cs_load_config() {
    local config_file=""

    if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
        config_file="$CONFIG_FILE_OVERRIDE"
    elif [[ -f ".commit-sweep.yaml" ]]; then
        config_file=".commit-sweep.yaml"
    elif [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/ru/commit-sweep.yaml" ]]; then
        config_file="${XDG_CONFIG_HOME:-$HOME/.config}/ru/commit-sweep.yaml"
    fi

    [[ -z "$config_file" || ! -f "$config_file" ]] && return 0

    cs_log_debug "Loading config from: $config_file"

    # Simple YAML parsing (key: value)
    while IFS=': ' read -r key value; do
        [[ "$key" == "#"* || -z "$key" ]] && continue
        value="${value%\"}"
        value="${value#\"}"

        case "$key" in
            br) CS_CONFIG_BR_TIMEOUT="$value" ;;
            lock) CS_CONFIG_LOCK_TIMEOUT="$value" ;;
            show_diff) [[ "$value" == "true" ]] && SHOW_DIFF=true ;;
            log_format) LOG_FORMAT="$value" ;;
            verbosity) VERBOSITY="$value" ;;
        esac
    done < "$config_file"
}
```

---

## [CC3-6] Verbose Levels (P1)

| Level | Flag | Description |
|-------|------|-------------|
| 0 | `-q` | Errors only |
| 1 | default | Errors + warnings + summary |
| 2 | `-v` | + Info |
| 3 | `-vv` | + Debug |
| 4 | `-vvv` | + Trace |

```bash
declare -g VERBOSITY=1

cs_log_error()   { (( VERBOSITY >= 0 )) && log_error "$@"; }
cs_log_warn()    { (( VERBOSITY >= 1 )) && log_warn "$@"; }
cs_log_info()    { (( VERBOSITY >= 2 )) && log_info "$@"; }
cs_log_debug()   { (( VERBOSITY >= 3 )) && log_verbose "DEBUG: $*"; }
cs_log_trace()   { (( VERBOSITY >= 4 )) && log_verbose "TRACE: $*"; }
```

**Debug output (-vv):**
```
[12:34:56] DEBUG   git status --porcelain -z (took 0.023s)
[12:34:56] DEBUG   Collected 15 files
```

**Trace output (-vvv):**
```
[12:34:56] TRACE   -> cs_analyze_repo(repo_path=/path)
[12:34:56] TRACE   cs_classify_file(file=lib/foo.sh) = source
```

---

## [CC3-7] Actionable Error Messages (P1)

```bash
cs_error_with_guidance() {
    local error_code="$1"
    local context="$2"
    shift 2

    case "$error_code" in
        preflight_blocked)
            cat >&2 <<EOF
${CS_RED}✗ Cannot sweep $context: $*${CS_RESET}

What happened:
  A git operation is in progress that must be completed first.

How to fix:
  Option 1: Complete the operation
    git merge --continue  OR  git rebase --continue

  Option 2: Abort the operation
    git merge --abort  OR  git rebase --abort

  Option 3: Check status
    git status
EOF
            ;;

        lock_timeout)
            cat >&2 <<EOF
${CS_RED}✗ Cannot acquire lock for $context${CS_RESET}

What happened:
  Another commit-sweep process is running on this repo.

How to fix:
  Option 1: Wait for other process to finish

  Option 2: If stuck/dead, remove lock:
    rm $context/.git/commit-sweep.lock

  Option 3: Check lock owner:
    cat $context/.git/commit-sweep.lock
EOF
            ;;

        git_too_old)
            cat >&2 <<EOF
${CS_RED}✗ Git version too old${CS_RESET}

What happened:
  commit-sweep requires git 2.13+, found $context

How to fix:
  Upgrade git: https://git-scm.com/downloads

  macOS: brew install git
  Ubuntu: sudo apt install git
  Windows: Download from git-scm.com
EOF
            ;;
    esac
}
```

---

## [CC3-9] Idempotency Guarantees (P1)

**Guarantees:**
1. Same files → same classification
2. Same branch → same task_id
3. Same dominant_status → same commit type
4. Same inputs → same confidence score
5. Clean repo → no changes, exit 0

**State detection:**
```bash
cs_check_idempotency() {
    local repo_path="$1"

    # Clean repo?
    if ! repo_is_dirty "$repo_path"; then
        cs_log_info "Repo is clean, nothing to sweep"
        return 0
    fi

    # Incomplete sweep?
    local state_file="$repo_path/.git/commit-sweep-state.json"
    if [[ -f "$state_file" ]]; then
        local status
        status=$(grep -o '"status": "[^"]*"' "$state_file" | cut -d'"' -f4)
        if [[ "$status" == "in_progress" || "$status" == "interrupted" ]]; then
            cs_log_warn "Detected incomplete sweep."
            cs_log_warn "Use --resume to continue or --restart to start fresh."
            return 1
        fi
    fi

    return 0
}
```

---

## [CC3-10] Operation Timeouts (P1)

| Operation | Default | Config |
|-----------|---------|--------|
| `br show` | 3s | `timeouts.br` |
| `git status` | 10s | `timeouts.git_status` |
| `git add` | 30s | `timeouts.git_add` |
| `git commit` | 60s | `timeouts.git_commit` |
| Lock | 30s | `timeouts.lock` |

```bash
cs_with_timeout() {
    local timeout="$1"
    local description="$2"
    shift 2

    if command -v timeout &>/dev/null; then
        local output exit_code
        output=$(timeout "$timeout" "$@" 2>&1)
        exit_code=$?

        if (( exit_code == 124 )); then
            cs_log_error "Timed out after ${timeout}: $description"
            return 124
        fi

        echo "$output"
        return $exit_code
    else
        cs_log_warn "timeout command unavailable"
        "$@"
    fi
}
```

---

## [CC3-8] Commit Message Body (P2)

```bash
cs_build_commit_body() {
    local -n files_ref=$1
    local -n statuses_ref=$2
    local task_id="$3"
    local task_title="$4"
    local confidence="$5"

    [[ "$INCLUDE_BODY" != "true" ]] && return

    local body="Files changed:\n"
    for file in "${files_ref[@]}"; do
        local status="${statuses_ref[$file]}"
        local word
        case "$status" in
            A*) word="added" ;;
            M*) word="modified" ;;
            D*) word="deleted" ;;
            R*) word="renamed" ;;
            *) word="changed" ;;
        esac
        body+="- $file ($word)\n"
    done

    if [[ -n "$task_id" ]]; then
        body+="\nTask: $task_id"
        [[ -n "$task_title" ]] && body+=" - $task_title"
        body+="\n"
    fi

    body+="Confidence: $confidence\n"
    printf '%b' "$body"
}
```

---

## [CC3-11] NO_COLOR Support (P2)

```bash
cs_init_colors() {
    # NO_COLOR env var (highest priority)
    if [[ -n "${NO_COLOR:-}" ]]; then
        CS_COLOR_ENABLED=false
    elif [[ "${COLOR_MODE:-auto}" == "never" ]]; then
        CS_COLOR_ENABLED=false
    elif [[ "${COLOR_MODE:-auto}" == "always" ]]; then
        CS_COLOR_ENABLED=true
    elif [[ -t 1 ]]; then
        CS_COLOR_ENABLED=true
    else
        CS_COLOR_ENABLED=false
    fi

    if [[ "$CS_COLOR_ENABLED" == "true" ]]; then
        CS_RED='\033[0;31m'
        CS_GREEN='\033[0;32m'
        CS_YELLOW='\033[0;33m'
        CS_BLUE='\033[0;34m'
        CS_RESET='\033[0m'
    else
        CS_RED='' CS_GREEN='' CS_YELLOW='' CS_BLUE='' CS_RESET=''
    fi
}
```

---

## [CC-6] Batch Git Operations

```bash
cs_collect_files() {
    local repo_path="$1"
    local -n out_files=$2
    local -n out_statuses=$3

    while IFS= read -r -d '' entry; do
        [[ -z "$entry" ]] && continue
        local status_code="${entry:0:2}"
        local file_path="${entry:3}"

        file_path=$(cs_decode_git_path "$file_path")
        cs_validate_path "$file_path" || continue

        out_files+=("$file_path")
        out_statuses["$file_path"]="$status_code"
    done < <(cs_with_timeout "${CS_CONFIG_GIT_STATUS_TIMEOUT:-10}s" "git status" \
        git -C "$repo_path" status --porcelain -z 2>/dev/null)
}
```

---

## [CC-7] Confidence Explanation

| Factor | Weight | Description |
|--------|--------|-------------|
| `+task_id` | +2 | Branch has task ID |
| `+single_file` | +1 | 1 file |
| `+few_files` | +1 | 2-3 files |
| `+single_bucket` | +1 | Same bucket |
| `+clear_status` | +1 | Same git status |
| `-many_files` | -1 | >5 files |
| `-mixed_statuses` | -1 | Different statuses |
| `-no_tests` | -1 | Source without tests |
| `-broad_scope` | -1 | >2 directories |

**Scoring:** >= 3: high, >= 1: medium, < 1: low

---

## Algorithm (Complete)

```
0. Initialize:
   - cs_init_colors()
   - cs_load_config()
   - cs_setup_signal_handlers()

1. Pre-flight [CC2-1, CC2-2, CC2-10, CC3-9]:
   - cs_check_git_version() || exit 3
   - cs_check_idempotency() || prompt
   - cs_preflight_check() || exit 2
   - cs_acquire_lock() || exit 5

2. Partial staging check [CC-2]:
   - Detect XY where both != ' '
   - Warn if detected and no --respect-staging

3. Collect files [CC-6]:
   - cs_with_timeout() + git status --porcelain -z
   - cs_decode_git_path() [CC2-8]
   - cs_validate_path() [CC2-9]

4. Filter files:
   - cs_should_exclude() [CC-3]
   - cs_is_binary() [CC-8] → skip/warn
   - cs_is_submodule() [CC-9] → skip/warn
   - cs_is_broken_symlink() [CC2-7] → warn

5. Classify:
   - cs_classify_file() → test/doc/config/source

6. Build groups [CC2-11]:
   - Skip empty groups
   - cs_get_dominant_status() [CC-1]
   - cs_detect_commit_type() [CC-1]
   - cs_detect_scope()
   - cs_get_task_title_cached() [CC3-3]
   - cs_assess_confidence() [CC-7]

7. Output plan

8. If --execute:
   - cs_create_checkpoint() [CC-5]
   - cs_save_state() [CC2-6]
   - cs_progress_init() [CC2-4]

   For each group:
     - cs_progress_update()
     - cs_validate_path() for each file
     - git add -- files...
     - git commit -m "subject" [-m "body"]
     - cs_save_state()
     - On error: rollback group, continue

   Summary:
     - All success → drop checkpoint, clear state
     - Failure → keep checkpoint + state
     - --atomic → full rollback

   - Write sweep log [CC2-3]

9. Cleanup:
   - cs_release_lock()
   - cs_progress_finish()
```

---

## JSON Output Schema

```json
{
  "generated_at": "2026-02-17T12:34:56Z",
  "version": "0.15.0",
  "output_format": "json",
  "command": "commit-sweep",
  "data": {
    "repos": [{
      "repo": "owner/project",
      "path": "/abs/path",
      "branch": "feature/bd-4f2a",
      "task_id": "bd-4f2a",
      "task_title": "Fix session lock",
      "groups": [{
        "type": "fix",
        "scope": "session",
        "message": "fix(session): fix session lock (bd-4f2a)",
        "body": "Files changed:\n- lib/session.sh (modified)\n\nTask: bd-4f2a",
        "files": ["lib/session.sh"],
        "file_statuses": {"lib/session.sh": "M"},
        "confidence": "high",
        "confidence_score": 4,
        "confidence_factors": ["+task_id", "+single_file", "+single_bucket", "+clear_status"]
      }],
      "skipped": {
        "binary": [],
        "submodules": [],
        "excluded": [],
        "broken_symlinks": []
      }
    }],
    "summary": {
      "repos_scanned": 10,
      "repos_dirty": 2,
      "repos_clean": 8,
      "planned_commits": 3
    }
  },
  "_meta": {
    "duration_seconds": 5,
    "exit_code": 0,
    "git_version": "2.39.0",
    "task_cache_hits": 18,
    "task_cache_misses": 2
  }
}
```

---

## Exit Codes

| Code | Meaning | Example |
|------|---------|---------|
| 0 | Success | All commits created |
| 1 | Partial failure | 3/5 groups committed |
| 2 | Conflicts | Merge in progress |
| 3 | Dependencies | Git too old |
| 4 | Bad arguments | Invalid --type |
| 5 | Interrupted | SIGINT, lock timeout |

---

## Examples

### Doctor
```
$ ru commit-sweep --doctor

Environment:
  ru version:       0.15.0
  git version:      2.39.0 ✓
  bash version:     5.2.15
  br available:     yes
  gum available:    yes

Current repo:
  Path:             /data/projects/repo_updater
  Branch:           feature/bd-4f2a
  Task ID:          bd-4f2a
  Dirty files:      3

Preflight checks:
  ✓ All checks passed

Ready to sweep.
```

### Full Execute
```
$ ru commit-sweep owner/repo --execute -v
[12:34:56] INFO    Loading config from ~/.config/ru/commit-sweep.yaml
[12:34:56] INFO    Checking git version... 2.39.0 ✓
[12:34:56] INFO    Pre-flight check... ✓
[12:34:56] INFO    Acquiring lock... ✓
[12:34:56] INFO    Creating checkpoint...
[████████████████████████████████████████] 100% (3/3)

Sweep complete:
  ✓ fix(lib): update session handling (bd-4f2a)
  ✓ test(lib): update session tests (bd-4f2a)
  ✓ docs: update README

3 commits created. Use --undo to rollback.
```

### Interrupt Recovery
```
$ ru commit-sweep owner/repo --execute
[████████████████............................] 40% (2/5)
^C
⚠ Interrupt received, cleaning up...
⚠ Restoring from checkpoint...
⚠ Cleanup complete. Use --resume to continue.

$ ru commit-sweep owner/repo --resume
[12:35:00] INFO    Resuming from group 3
[████████████████████████████████████████] 100% (3/3)

Sweep resumed. 5 total commits.
```

---

## Test Files

### `scripts/test_unit_commit_sweep.sh` (~75 tests)

**CC Tests:** 45
**CC2 Tests:** 19
**CC3 Tests:** 11
- `cs_setup_signal_handlers`: 2 cases
- `cs_get_task_title_cached`: 4 cases (hit, miss, timeout, empty)
- `cs_load_config`: 3 cases
- `cs_init_colors`: 2 cases (NO_COLOR, tty)

### `scripts/test_e2e_commit_sweep.sh` (~25 scenarios)

**CC Tests:** 15
**CC2 Tests:** 5
**CC3 Tests:** 5
1. SIGINT triggers cleanup
2. `--atomic-repos` rollback
3. `--doctor` output format
4. Config file loading
5. Cache statistics in _meta

---

## Change Summary

### CC (First Review) - 10 changes
| ID | Category | Change | P |
|----|----------|--------|---|
| CC-1 | Correctness | Bucket-first type detection | P0 |
| CC-2 | Correctness | Partial staging detection | P0 |
| CC-3 | Usability | Exclude patterns | P0 |
| CC-4 | Architecture | Save/load plan | P2 |
| CC-5 | Reliability | Stash checkpoint | P1 |
| CC-6 | Performance | Batch git ops | P1 |
| CC-7 | Usability | Confidence factors | P1 |
| CC-8 | Edge case | Binary handling | P1 |
| CC-9 | Edge case | Submodule handling | P2 |
| CC-10 | Usability | Type/scope override | P2 |

### CC2 (Second Review) - 12 changes
| ID | Category | Change | P |
|----|----------|--------|---|
| CC2-1 | Reliability | Pre-flight checks | P0 |
| CC2-2 | Reliability | Lock file | P0 |
| CC2-9 | Security | Injection prevention | P0 |
| CC2-3 | Usability | Undo command | P1 |
| CC2-4 | UX | Progress bar | P1 |
| CC2-5 | Usability | Diff preview | P1 |
| CC2-6 | Reliability | Resume/state | P1 |
| CC2-10 | Compat | Git version check | P1 |
| CC2-11 | Edge case | Empty groups | P1 |
| CC2-7 | Edge case | Symlinks | P2 |
| CC2-8 | Edge case | Non-UTF8 | P2 |
| CC2-12 | Observe | Structured logging | P2 |

### CC3 (Third Review) - 12 changes
| ID | Category | Change | P |
|----|----------|--------|---|
| CC3-1 | Reliability | Signal handling | P0 |
| CC3-2 | Reliability | Multi-repo atomicity | P0 |
| CC3-3 | Performance | Task title caching | P1 |
| CC3-4 | Debugging | Doctor command | P1 |
| CC3-5 | Usability | Config file | P1 |
| CC3-6 | Debugging | Verbose levels | P1 |
| CC3-7 | UX | Actionable errors | P1 |
| CC3-9 | Reliability | Idempotency | P1 |
| CC3-10 | Reliability | Timeouts | P1 |
| CC3-8 | Feature | Commit body | P2 |
| CC3-11 | Access | NO_COLOR | P2 |
| CC3-12 | Testing | Dry-run fidelity | P2 |

---

## Implementation Order

**Phase 1: Security & Reliability (P0)**
1. CC2-9 Security validation
2. CC3-1 Signal handling
3. CC2-1 Pre-flight checks
4. CC2-2 Lock file
5. CC3-2 Multi-repo atomicity
6. CC-1 Bucket-first type
7. CC-2 Partial staging
8. CC-3 Exclude patterns

**Phase 2: Core Features (P1)**
9. CC-5 Stash checkpoint
10. CC-6 Batch operations
11. CC3-10 Timeouts
12. CC2-10 Git version check
13. CC3-9 Idempotency
14. CC2-11 Empty groups
15. CC-7 Confidence factors
16. CC-8 Binary handling
17. CC3-3 Task caching

**Phase 3: UX (P1)**
18. CC3-5 Config file
19. CC3-6 Verbose levels
20. CC3-7 Actionable errors
21. CC2-4 Progress bar
22. CC2-5 Diff preview
23. CC2-3 Undo command
24. CC2-6 Resume/state
25. CC3-4 Doctor command

**Phase 4: Polish (P2)**
26. CC-4 Save/load plan
27. CC-9 Submodule handling
28. CC-10 Type/scope override
29. CC2-7 Symlink handling
30. CC2-8 Non-UTF8
31. CC2-12 Structured logging
32. CC3-8 Commit body
33. CC3-11 NO_COLOR
34. CC3-12 Dry-run fidelity

---

## Statistics

| Metric | Value |
|--------|-------|
| Total changes | 34 |
| P0 (Critical) | 8 |
| P1 (Important) | 18 |
| P2 (Polish) | 8 |
| Functions | 45+ |
| Unit tests | ~75 |
| E2E tests | ~25 |
| Est. LOC | ~800 |
