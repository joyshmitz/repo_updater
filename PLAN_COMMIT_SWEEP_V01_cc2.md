# Plan: `ru commit-sweep` v0.1 MVP (Claude Code Review v2)

> Цей документ — друга ітерація review з додатковими покращеннями надійності,
> безпеки та usability. Зміни CC-N з першої ітерації, CC2-N з другої.

## Context

AI-агенти кодери (працюють з br-задачами) зараз і кодують, і комітять. Це призводить до:
- Поганих commit messages (короткі, неінформативні)
- Випадкового захоплення змін інших агентів
- Заплутаної git history
- Відволікання від основної роботи — кодування

**Рішення:** спеціалізована команда `ru commit-sweep` — єдиний інструмент для комітів. Кодери тільки кодують, committer тільки комітить.

**Unix-філософія:** одна робота — перетворити брудне робоче дерево в чисті атомарні коміти. Все інше делегується існуючим інструментам:
- `ru` — repo discovery (`get_all_repos`, `resolve_repo_spec`)
- `br` — task metadata (`br show <id> --format json` → `.[0].title`)
- `bv` — (v0.2+) attribution через `--robot-history` + `pkg/correlation/extractor.go`
- `git` — staging, committing
- `agent-mail` — (v0.2+) `file_reservation_paths()` для атрибуції (хто володіє файлами)
- `DCG` — класифікація safe/destructive (commit=safe, push=needs flag)
- `SLB` — (v0.4+) two-person approval для `--force` операцій
- `NTM` — (v0.4+) `ConflictDetector.CheckPathConflict()` для lock перевірки

## Аудит екосистеми (60+ проєктів ~/projects/joyshmitz/)

**Результат: дублювання немає.** Жоден проєкт не реалізує commit grouping,
file classification для комітів, або conventional commit generation.

### Що перевикористовуємо з екосистеми

| Інструмент | Що дає | Версія | API/Команда |
|------------|--------|--------|-------------|
| **ru** | repo discovery, dirty detection, JSON envelope, logging, summary box | v0.1 | `repo_is_dirty()`, `build_json_envelope()`, `print_fork_op_summary()` |
| **br** (beads_rust) | Task title за bead ID | v0.1 | `br show bd-XXXX --format json` → парсити `.[0].title` |
| **DCG** | Принцип safe/destructive | v0.1 | commit=safe (Low), push=needs flag (High), force push=Critical |
| **agent-mail** | File ownership: хто володіє файлами | v0.2 | `file_reservation_paths(project_key, agent, paths, ttl, exclusive)` |
| **bv** (beads_viewer) | Commit-to-bead correlation | v0.2 | `bv --robot-history` → `BeadEvent{BeadID, CommitSHA, Author}` |
| **SLB** | Approval для destructive ops | v0.4 | `Request{min_approvals, require_different_model}` → approve/reject/escalate |
| **NTM** | Conflict detection між агентами | v0.4 | `CheckPathConflict(path, excludeAgent)` → `Conflict{holders}` |
| **CASS** | Навчання з минулих сесій | v0.5 | `cm context "commit patterns" --json` → правила та анти-паттерни |

### Що будуємо з нуля (не існує в екосистемі)

**Core functions:**
- `cs_classify_file()` — 4-bucket класифікатор (test/doc/config/source)
- `cs_detect_commit_type()` — bucket + git status codes → conventional commit type **[CC-1]**
- `cs_detect_scope()` — top-level directory як scope
- `cs_build_message()` — форматування conventional commit subject
- `cs_assess_confidence()` — scoring high/medium/low з explanation **[CC-7]**
- `cs_analyze_repo()` — оркестрація: git status → classify → group → JSON
- `cs_execute_group()` — safe git add + commit з per-group rollback

**Safety functions [CC-8, CC-9, CC2-7]:**
- `cs_is_binary()` — перевірка binary files
- `cs_is_submodule()` — перевірка submodules
- `cs_is_symlink()` — перевірка symlinks **[CC2-7]**
- `cs_should_exclude()` — glob matching для exclude patterns **[CC-3]**
- `cs_validate_path()` — security validation **[CC2-9]**

**Reliability functions [CC2-1, CC2-2, CC2-6]:**
- `cs_preflight_check()` — перевірка git state перед sweep **[CC2-1]**
- `cs_check_git_version()` — мінімальна версія git **[CC2-10]**
- `cs_acquire_lock()` / `cs_release_lock()` — concurrent protection **[CC2-2]**
- `cs_save_state()` / `cs_load_state()` — recovery state **[CC2-6]**

**Plan management [CC-4]:**
- `cs_save_plan()` — serialize plan to JSON
- `cs_load_plan()` — load and validate saved plan
- `cs_calculate_checksum()` — plan integrity check

**Checkpoint/Undo [CC-5, CC2-3]:**
- `cs_create_checkpoint()` — `git stash push` before execute
- `cs_restore_checkpoint()` — `git stash pop` on rollback
- `cs_undo_last_sweep()` — undo via sweep log **[CC2-3]**

**UX functions [CC2-4, CC2-5, CC2-12]:**
- `cs_progress_init/update/finish()` — progress bar **[CC2-4]**
- `cs_show_file_diff()` — diff preview **[CC2-5]**
- `cs_log()` — structured logging **[CC2-12]**

## Scope v0.1

**Робить:**
1. Сканує репо (всі або конкретну) на dirty worktrees
2. Групує змінені файли: source / test / docs / config
3. Генерує conventional commit messages з евристик (не LLM)
4. Витягує task ID з назви гілки (`feature/bd-XXXX`)
5. Виводить план комітів (JSON або human-readable)
6. Виконує план з `--execute` (default = dry-run для безпеки)
7. **[CC-4]** Зберігає план у файл з `--save-plan=FILE`
8. **[CC-4]** Виконує збережений план з `--load-plan=FILE`
9. **[CC2-3]** Відкочує останній sweep з `--undo`

**НЕ робить:** LLM, agent-mail lookup, bv integration, push, parallel, conflict resolution.

## Зміни у файлах

### 1. `/Users/sd/projects/joyshmitz/repo_updater/ru`

**A. Dispatch — рядок ~23825, додати перед `*)`:**
```bash
commit-sweep) cmd_commit_sweep ;;
```

**B. Command recognition — рядок 8474, додати `commit-sweep` до списку:**
```
sync|status|...|fork-clean|commit-sweep)
```

**C. `--dry-run` routing — рядок 8241, додати `commit-sweep`:**
```bash
if [[ "$COMMAND" == "review" || ... || "$COMMAND" == "commit-sweep" ]]; then
```

**D. `--json` routing — рядок 8209, додати `commit-sweep`:**
```bash
if [[ "$COMMAND" == "agent-sweep" || "$COMMAND" == "commit-sweep" ]]; then
    ARGS+=("$1")
```

**E. Help text — після рядка 5643, додати команду:**
```
    commit-sweep    Analyze dirty repos and create logical commits
```
Та нову секцію опцій:
```
COMMIT-SWEEP OPTIONS:
    --execute            Actually create commits (default: dry-run/plan only)
    --dry-run            Show commit plan without changes (default)
    --show-diff          Show actual diffs in dry-run output [CC2-5]
    --diff-context=N     Number of context lines in diff (default: 3) [CC2-5]
    --respect-staging    Preserve manually staged files; only analyze unstaged/untracked
    --exclude=PATTERN    Exclude files matching glob pattern (repeatable) [CC-3]
    --exclude-from=FILE  Read exclude patterns from file (one per line) [CC-3]
    --no-default-excludes Skip default exclude patterns (*.orig, *.bak, etc.) [CC-3]
    --include-binary     Include binary files in commits (default: skip with warning) [CC-8]
    --include-submodules Include submodule pointer changes (default: skip with warning) [CC-9]
    --type=TYPE          Override commit type for all groups [CC-10]
    --scope=SCOPE        Override scope for all groups [CC-10]
    --message=MSG        Override entire commit message [CC-10]
    --no-task-id         Don't append task ID to commit messages [CC-10]
    --save-plan=FILE     Save commit plan to file for later execution [CC-4]
    --load-plan=FILE     Load and execute a saved commit plan [CC-4]
    --atomic             Rollback ALL commits if ANY group fails [CC-5]
    --undo               Undo the last commit-sweep (requires sweep-log) [CC2-3]
    --undo-interactive   Interactively select which commits to undo [CC2-3]
    --resume             Resume interrupted sweep from last checkpoint [CC2-6]
    --restart            Ignore saved state, start fresh [CC2-6]
    --log-format=FORMAT  Log format: text (default), json, logfmt [CC2-12]
```

**F. Нова секція перед SECTION 14 (~рядок 23783):**

`SECTION 13.11: COMMIT SWEEP` — ~800 рядків

---

## [CC2-1] Pre-flight Checks (P0 - Reliability)

**Проблема:** Sweep на repo з merge/rebase in progress призводить до хаосу.

**Перевірки перед початком:**

```bash
cs_preflight_check() {
    local repo_path="$1"
    local git_dir
    git_dir=$(git -C "$repo_path" rev-parse --git-dir 2>/dev/null) || return 1

    # Check for in-progress operations
    local -a blockers=()
    [[ -f "$git_dir/MERGE_HEAD" ]] && blockers+=("merge in progress")
    [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]] && blockers+=("rebase in progress")
    [[ -f "$git_dir/CHERRY_PICK_HEAD" ]] && blockers+=("cherry-pick in progress")
    [[ -f "$git_dir/BISECT_LOG" ]] && blockers+=("bisect in progress")
    [[ -f "$git_dir/REVERT_HEAD" ]] && blockers+=("revert in progress")

    # Check for detached HEAD (warning, not blocker)
    if ! git -C "$repo_path" symbolic-ref HEAD &>/dev/null; then
        log_warn "Detached HEAD state in $repo_path"
    fi

    if (( ${#blockers[@]} > 0 )); then
        log_error "Cannot sweep $repo_path: ${blockers[*]}"
        return 1
    fi

    return 0
}
```

**Exit code:** 2 (conflicts) якщо preflight fails.

**Вивід:**
```
✗ Cannot sweep owner/repo: merge in progress
  Resolve the merge first with: git merge --continue or git merge --abort
```

---

## [CC2-2] Lock File Protection (P0 - Reliability)

**Проблема:** Concurrent sweeps на одній репі = хаос.

**Lock file location:** `.git/commit-sweep.lock`

```bash
cs_acquire_lock() {
    local repo_path="$1"
    local lock_file="$repo_path/.git/commit-sweep.lock"
    local timeout="${2:-30}"
    local pid=$$
    local start_time=$SECONDS

    while true; do
        # Try to create lock atomically
        if (set -o noclobber; echo "$pid $(date +%s)" > "$lock_file") 2>/dev/null; then
            trap "cs_release_lock '$repo_path'" EXIT
            return 0
        fi

        # Lock exists - check if stale
        if [[ -f "$lock_file" ]]; then
            local lock_pid lock_time
            read -r lock_pid lock_time < "$lock_file" 2>/dev/null || true

            # Check if holding process is still alive
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Removing stale lock from dead process $lock_pid"
                rm -f "$lock_file"
                continue
            fi

            # Check if lock is too old (5 minutes = stale)
            local now
            now=$(date +%s)
            if [[ -n "$lock_time" ]] && (( now - lock_time > 300 )); then
                log_warn "Removing stale lock (older than 5 minutes)"
                rm -f "$lock_file"
                continue
            fi
        fi

        # Check timeout
        if (( SECONDS - start_time > timeout )); then
            log_error "Cannot acquire lock for $repo_path after ${timeout}s"
            return 1
        fi

        log_verbose "Waiting for lock on $repo_path (held by PID $lock_pid)..."
        sleep 1
    done
}

cs_release_lock() {
    local repo_path="$1"
    local lock_file="$repo_path/.git/commit-sweep.lock"
    rm -f "$lock_file"
}
```

**Exit code:** 5 (interrupted) якщо lock timeout.

---

## [CC2-9] Security: Command Injection Prevention (P0 - Security)

**Принцип:** Завжди використовувати `--` separator та arrays, не string interpolation.

**WRONG:**
```bash
# VULNERABLE: command injection via filename
git add "$file"
git commit -m "fix: $description"
```

**CORRECT:**
```bash
# Safe: -- prevents flag injection, arrays prevent word splitting
git add -- "$file"
git commit -m "$message"  # $message already validated

# For multiple files:
local -a files=("lib/foo.sh" "lib/bar.sh")
git add -- "${files[@]}"
```

**Path validation:**
```bash
cs_validate_path() {
    local path="$1"

    # Reject paths with null bytes
    if [[ "$path" == *$'\0'* ]]; then
        log_error "Invalid path: contains null byte"
        return 1
    fi

    # Reject paths starting with -
    if [[ "$path" == -* ]]; then
        log_error "Invalid path: starts with dash"
        return 1
    fi

    # Reject absolute paths (should be relative to repo)
    if [[ "$path" == /* ]]; then
        log_error "Invalid path: absolute path not allowed"
        return 1
    fi

    return 0
}
```

**Commit message sanitization:**
```bash
cs_sanitize_message() {
    local msg="$1"
    # Remove control characters except newline
    msg=$(printf '%s' "$msg" | tr -d '\000-\010\013-\037')
    # Limit length
    msg="${msg:0:1000}"
    printf '%s' "$msg"
}
```

---

## [CC-1] Commit Type Detection: Bucket-First Logic

**Проблема з оригінальним планом:** `A→feat, M→fix, D→chore, R→refactor` ігнорує bucket.

**Нова логіка `cs_detect_commit_type(bucket, dominant_status)`:**
```
1. Якщо bucket == "test"   → return "test"
2. Якщо bucket == "doc"    → return "docs"
3. Якщо bucket == "config" → return "chore"
4. Якщо bucket == "source":
   - dominant_status == "A" (majority adds)     → "feat"
   - dominant_status == "D" (majority deletes)  → "chore"
   - dominant_status == "R" (majority renames)  → "refactor"
   - dominant_status == "M" (majority modifies) → "fix"  # default assumption
5. Fallback: "chore"
```

**Dominant status calculation:**
```bash
cs_get_dominant_status() {
    local -A counts=([A]=0 [M]=0 [D]=0 [R]=0)
    local statuses="$1"  # space-separated: "A M M D"
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
    # Tie-breaker: A > M > R > D (addition more significant than modification)
    echo "$dominant"
}
```

---

## [CC-2] Partial Staging Detection

**Проблема:** `git add -p` дозволяє staged частину файлу, unstaged іншу.

**Detection:**
```
git status --porcelain повертає 2-char prefix: XY
- X = staged status, Y = unstaged status
- Якщо обидва != ' ' і != '?' (e.g., "MM", "AM") → partial staging
```

**Алгоритм:**
```
0. Попередня перевірка partial staging:
   - Якщо є partial staged files І немає --respect-staging:
     - WARNING: "Partial staging detected in N files. Use --respect-staging to preserve."
     - Без --respect-staging: продовжити (весь файл піде в групу)

   - Якщо є partial staged files І є --respect-staging:
     - Staged частина → окрема група "pre-staged"
     - Unstaged частина → звичайна класифікація
```

---

## [CC-3] Exclude Patterns

**Default excludes (hard-coded):**
- `*.orig`, `*.bak`, `*.swp`, `*~`
- `.DS_Store`, `Thumbs.db`

**Implementation:**
```bash
cs_should_exclude() {
    local file="$1"
    shift
    local patterns=("$@")
    for pattern in "${patterns[@]}"; do
        # shellcheck disable=SC2053
        [[ "$file" == $pattern ]] && return 0
    done
    return 1
}
```

---

## [CC2-3] Undo Command (P1 - Usability)

**Механізм:** Кожен `--execute` записує sweep log у `.git/commit-sweep-log/`.

**Log format:**
```json
{
  "sweep_id": "cs-20260216-123456",
  "started_at": "2026-02-16T12:34:56Z",
  "finished_at": "2026-02-16T12:35:02Z",
  "pre_sweep_head": "abc123...",
  "commits": [
    {"sha": "def456...", "message": "fix(lib): ...", "files": ["lib/foo.sh"]},
    {"sha": "ghi789...", "message": "test(lib): ...", "files": ["lib/foo_test.sh"]}
  ],
  "status": "completed"
}
```

**`--undo` behavior:**
```bash
cs_undo_last_sweep() {
    local repo_path="$1"
    local log_dir="$repo_path/.git/commit-sweep-log"
    local latest_log
    latest_log=$(ls -t "$log_dir"/*.json 2>/dev/null | head -1)

    if [[ -z "$latest_log" ]]; then
        log_error "No sweep log found. Nothing to undo."
        return 1
    fi

    local pre_head commits_count
    pre_head=$(grep -o '"pre_sweep_head": "[^"]*"' "$latest_log" | cut -d'"' -f4)
    commits_count=$(grep -c '"sha":' "$latest_log")

    # Validate HEAD hasn't moved
    local current_head last_commit
    current_head=$(git -C "$repo_path" rev-parse HEAD)
    last_commit=$(grep -o '"sha": "[^"]*"' "$latest_log" | tail -1 | cut -d'"' -f4)

    if [[ "$current_head" != "$last_commit" ]]; then
        log_error "HEAD has moved since last sweep. Cannot safely undo."
        log_error "Expected: $last_commit, Got: $current_head"
        return 1
    fi

    log_warn "About to undo $commits_count commits from last sweep"
    log_warn "Resetting to: $pre_head"

    if [[ "$DRY_RUN" != "true" ]]; then
        git -C "$repo_path" reset --soft "$pre_head"
        mv "$latest_log" "${latest_log%.json}.undone.json"
        log_success "Undo complete. Changes are staged but uncommitted."
    fi
}
```

**Safety:**
- `--undo` does `reset --soft` — changes go back to staging, not lost
- Log file renamed to `.undone.json` to prevent double-undo
- Undo only works if HEAD hasn't moved since sweep

---

## [CC2-4] Progress Reporting (P1 - UX)

**Integration з gum (якщо доступний):**
```bash
cs_progress_init() {
    local total="$1"
    local title="$2"

    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        CS_PROGRESS_TOTAL="$total"
        CS_PROGRESS_CURRENT=0
        CS_PROGRESS_TITLE="$title"
        printf '\n'
    fi
}

cs_progress_update() {
    local current="$1"
    local item="$2"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        return
    fi

    CS_PROGRESS_CURRENT="$current"
    local pct=$((current * 100 / CS_PROGRESS_TOTAL))
    local bar_width=40
    local filled=$((pct * bar_width / 100))
    local empty=$((bar_width - filled))

    # ANSI escape: move cursor up, clear line, print progress
    printf '\033[1A\033[2K'
    printf '[%s%s] %3d%% (%d/%d) %s\n' \
        "$(printf '█%.0s' $(seq 1 $filled))" \
        "$(printf '░%.0s' $(seq 1 $empty))" \
        "$pct" "$current" "$CS_PROGRESS_TOTAL" \
        "$(basename "$item")"
}

cs_progress_finish() {
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
        printf '\033[1A\033[2K'
        log_success "$CS_PROGRESS_TITLE complete: $CS_PROGRESS_TOTAL items"
    fi
}
```

**Output:**
```
[████████████████░░░░░░░░░░░░░░░░░░░░░░░░] 42% (21/50) my-project
```

---

## [CC2-5] Diff Preview (P1 - Usability)

**`--show-diff` output:**
```
Group 1: source (1 file)
  fix(lib): update session handling (bd-4f2a)
  Confidence: high [+task_id, +single_file]

  lib/session.sh:
  ┌─────────────────────────────────────────────────────────
  │ @@ -42,7 +42,7 @@ function init_session() {
  │      local timeout="${1:-30}"
  │ -    local lock_file="/tmp/session.lock"
  │ +    local lock_file="${TMPDIR:-/tmp}/session.lock"
  │      [[ -f "$lock_file" ]] && return 1
  │  }
  └─────────────────────────────────────────────────────────
```

**Implementation:**
```bash
cs_show_file_diff() {
    local repo_path="$1"
    local file="$2"
    local context="${3:-3}"

    if [[ "$SHOW_DIFF" != "true" ]]; then
        return
    fi

    local diff_output
    diff_output=$(git -C "$repo_path" diff -U"$context" --color=always -- "$file" 2>/dev/null)

    if [[ -z "$diff_output" ]]; then
        # Maybe it's untracked - show entire file
        diff_output=$(git -C "$repo_path" diff -U"$context" --color=always \
            --no-index /dev/null "$file" 2>/dev/null || true)
    fi

    if [[ -n "$diff_output" ]]; then
        printf '  %s:\n' "$file"
        printf '  ┌─────────────────────────────────────────────────────────\n'
        echo "$diff_output" | head -50 | sed 's/^/  │ /'
        local total_lines
        total_lines=$(echo "$diff_output" | wc -l)
        if (( total_lines > 50 )); then
            printf '  │ ... (truncated, %d more lines)\n' "$((total_lines - 50))"
        fi
        printf '  └─────────────────────────────────────────────────────────\n'
    fi
}
```

---

## [CC2-6] Recovery State File (P1 - Reliability)

**State file location:** `.git/commit-sweep-state.json`

**State schema:**
```json
{
  "sweep_id": "cs-20260216-123456",
  "started_at": "2026-02-16T12:34:56Z",
  "plan_checksum": "sha256:abc123...",
  "total_groups": 5,
  "completed_groups": 2,
  "current_group_index": 2,
  "completed_commits": [
    {"group_index": 0, "sha": "abc...", "status": "success"},
    {"group_index": 1, "sha": "def...", "status": "success"}
  ],
  "checkpoint_stash": "stash@{0}"
}
```

**`--resume` behavior:**
```bash
cs_resume_sweep() {
    local repo_path="$1"
    local state_file="$repo_path/.git/commit-sweep-state.json"

    if [[ ! -f "$state_file" ]]; then
        log_error "No interrupted sweep to resume"
        return 1
    fi

    local completed current_index
    completed=$(grep -o '"completed_groups": [0-9]*' "$state_file" | grep -o '[0-9]*')
    current_index=$(grep -o '"current_group_index": [0-9]*' "$state_file" | grep -o '[0-9]*')

    log_info "Resuming sweep from group $((current_index + 1))"
    log_info "Already completed: $completed groups"

    # Load original plan and skip completed groups
    # ... continue execution ...
}
```

**Cleanup:**
- Success: `rm -f "$state_file"`
- Failure: state file preserved for `--resume`
- `--restart`: force fresh start, ignore state file

---

## [CC2-10] Git Version Compatibility (P1)

**Мінімальна версія:** git 2.13+ (released April 2017)

**Required features:**
- `git stash push -m` (2.13)
- `git status --porcelain=v1` (2.11, but v1 is default)

```bash
cs_check_git_version() {
    local min_major=2
    local min_minor=13

    local version
    version=$(git --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
    local major minor
    IFS='.' read -r major minor <<< "$version"

    if (( major < min_major || (major == min_major && minor < min_minor) )); then
        log_error "Git version $version is too old. Minimum required: $min_major.$min_minor"
        log_error "Please upgrade git: https://git-scm.com/downloads"
        return 1
    fi

    return 0
}
```

**Fallback для старих версій:**
```bash
cs_stash_push() {
    local repo_path="$1"
    local message="$2"

    if cs_git_version_ge 2 13; then
        git -C "$repo_path" stash push -m "$message"
    else
        git -C "$repo_path" stash save "$message"
    fi
}
```

---

## [CC2-11] Empty Group Handling (P1)

**Проблема:** Після filtering група може стати порожньою.

```
4a. Якщо група стала порожньою після filtering:
    - Log: "Group 'source' empty after exclusions, skipping"
    - НЕ створювати commit для порожньої групи
    - Продовжити до наступної групи

4b. Якщо ВСІ групи порожні:
    - Summary: "No changes to commit after filtering"
    - Exit code: 0 (success, not error)
    - JSON: "planned_commits": 0
```

**Execution check:**
```bash
cs_execute_group() {
    local -a files=("${@}")

    if (( ${#files[@]} == 0 )); then
        log_verbose "Empty group, skipping"
        return 0
    fi

    # Verify files still exist (for non-deleted)
    local -a valid_files=()
    for file in "${files[@]}"; do
        local status="${file_statuses[$file]}"
        if [[ "$status" != D* && ! -e "$repo_path/$file" ]]; then
            log_warn "File no longer exists: $file (skipping)"
            continue
        fi
        valid_files+=("$file")
    done

    if (( ${#valid_files[@]} == 0 )); then
        log_verbose "No valid files remain, skipping group"
        return 0
    fi

    # ... proceed with valid files ...
}
```

---

## [CC-4] Serializable Plan

**Workflow:**
```bash
# Згенерувати та зберегти план
ru commit-sweep owner/repo --save-plan=/tmp/plan.json

# Переглянути/відредагувати план вручну
$EDITOR /tmp/plan.json

# Виконати збережений план
ru commit-sweep --load-plan=/tmp/plan.json --execute
```

**Extended JSON schema:**
```json
{
  "plan_version": "1",
  "created_at": "2026-02-16T12:34:56Z",
  "created_by": "ru commit-sweep v0.15.0",
  "checksum": "sha256:abc123...",
  "data": {
    "repos": [...]
  }
}
```

**Validation при `--load-plan`:**
1. Перевірити `plan_version` сумісність
2. Перевірити `checksum` — якщо repo state змінився, warning
3. Перевірити що всі файли ще існують (для non-deleted)
4. Якщо validation fails: exit з error, не виконувати

---

## [CC-5] Atomicity via Stash Checkpoint

**Execute flow з checkpoint:**

```
1. Checkpoint: `git stash push -m "commit-sweep-$(date +%s)"` якщо dirty
2. Аналіз як у dry-run → groups array
3. Для кожної групи через `cs_execute_group()`:
   - `git add -- <file1> <file2>...`
   - Для deleted files: `git rm -- <file>`
   - Перевірити staging: `git diff --cached --quiet && skip`
   - `git commit -m "<message>"`
   - При помилці:
     a. `git reset HEAD -- <files>` (unstage this group only)
     b. `git checkout -- <files>` (restore if hook modified)
     c. Mark group as failed, continue
4. Summary:
   - All success → `git stash drop` (remove checkpoint)
   - Any failure → WARNING + keep checkpoint
   - --atomic + failure → `git reset --soft` + `git stash pop`
```

---

## [CC-6] Batch Git Operations

**Оптимізація: один git status виклик**

```bash
cs_collect_files() {
    local repo_path="$1"
    local -n out_files=$2
    local -n out_statuses=$3

    while IFS= read -r -d '' entry; do
        [[ -z "$entry" ]] && continue
        local status_code="${entry:0:2}"
        local file_path="${entry:3}"

        # Decode quoted paths [CC2-8]
        file_path=$(cs_decode_git_path "$file_path")

        # Validate path [CC2-9]
        cs_validate_path "$file_path" || continue

        out_files+=("$file_path")
        out_statuses["$file_path"]="$status_code"
    done < <(git -C "$repo_path" status --porcelain -z 2>/dev/null)
}
```

`-z` використовує NUL separator — безпечно для файлів з пробілами/newlines.

---

## [CC-7] Confidence Explanation

**Розширений JSON output:**
```json
{
  "confidence": "high",
  "confidence_score": 4,
  "confidence_factors": ["+task_id", "+single_file", "+single_bucket", "-no_tests"]
}
```

**Confidence factors:**

| Factor | Weight | Description |
|--------|--------|-------------|
| `+task_id` | +2 | Branch має task ID |
| `+single_file` | +1 | Група має 1 файл |
| `+few_files` | +1 | Група має 2-3 файли |
| `+single_bucket` | +1 | Всі файли в одному bucket |
| `+clear_status` | +1 | Всі файли мають однаковий git status |
| `-many_files` | -1 | Група має >5 файлів |
| `-mixed_statuses` | -1 | Файли мають різні git statuses |
| `-no_tests` | -1 | Source зміни без відповідних test змін |
| `-broad_scope` | -1 | Файли з >2 різних директорій |

**Scoring:** sum >= 3: high, sum >= 1: medium, sum < 1: low

---

## [CC-8] Binary File Handling

**Detection:**
```bash
cs_is_binary() {
    local repo_path="$1"
    local file="$2"
    local numstat
    numstat=$(git -C "$repo_path" diff --numstat -- "$file" 2>/dev/null)
    [[ "$numstat" == -$'\t'-$'\t'* ]]
}
```

**Behavior:**
1. Default: **skip** binary files з WARNING
2. `--include-binary`: включити binary в групу "chore"

---

## [CC-9] Submodule Handling

**Detection:**
```bash
cs_is_submodule() {
    local repo_path="$1"
    local path="$2"
    git -C "$repo_path" ls-files --stage -- "$path" 2>/dev/null | grep -q '^160000'
}
```

**Behavior:**
1. Default: **skip** submodule pointer changes з WARNING
2. `--include-submodules`: включити як `chore(deps): update submodule X`

---

## [CC2-7] Symlink Handling (P2)

**Detection:**
```bash
cs_is_symlink() {
    local repo_path="$1"
    local path="$2"
    # mode 120000 = symlink
    git -C "$repo_path" ls-files --stage -- "$path" 2>/dev/null | grep -q '^120000'
}

cs_is_broken_symlink() {
    local repo_path="$1"
    local path="$2"
    local full_path="$repo_path/$path"
    [[ -L "$full_path" && ! -e "$full_path" ]]
}
```

**Behavior:**
1. Valid symlinks: включати нормально
2. Broken symlinks: WARNING + include
3. Symlinks pointing outside repo: WARNING

**Classification:** За target filename, не за link name.

---

## [CC2-8] Non-UTF8 Filename Handling (P2)

**Git quotes non-ASCII filenames:**
```bash
$ git status --porcelain
M  "file-with-\303\251.txt"   # é encoded as octal
```

**Decoding:**
```bash
cs_decode_git_path() {
    local path="$1"

    # If path starts and ends with quotes, it's quoted
    if [[ "$path" == \"*\" ]]; then
        path="${path:1:-1}"
        printf '%b' "$path"
    else
        printf '%s' "$path"
    fi
}
```

**JSON encoding для broken UTF-8:**
```bash
cs_safe_filename_json() {
    local file="$1"
    if printf '%s' "$file" | iconv -f UTF-8 -t UTF-8 &>/dev/null; then
        json_escape "$file"
    else
        printf '{"base64": true, "value": "%s"}' "$(printf '%s' "$file" | base64)"
    fi
}
```

---

## [CC2-12] Structured Logging (P2)

**Formats:**

**text (default):**
```
[12:34:56] INFO  Analyzing repo: owner/project
```

**json:**
```json
{"ts":"2026-02-16T12:34:56Z","level":"info","msg":"Analyzing repo","repo":"owner/project"}
```

**logfmt:**
```
ts=2026-02-16T12:34:56Z level=info msg="Analyzing repo" repo=owner/project
```

**Implementation:**
```bash
cs_log() {
    local level="$1"
    local msg="$2"
    shift 2
    local -a fields=("$@")

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    case "$LOG_FORMAT" in
        json)
            local json="{\"ts\":\"$ts\",\"level\":\"$level\",\"msg\":\"$(json_escape "$msg")\""
            for field in "${fields[@]}"; do
                local key="${field%%=*}"
                local val="${field#*=}"
                json+=",\"$key\":\"$(json_escape "$val")\""
            done
            json+="}"
            echo "$json" >&2
            ;;
        logfmt)
            printf 'ts=%s level=%s msg="%s"' "$ts" "$level" "$msg" >&2
            for field in "${fields[@]}"; do
                printf ' %s' "$field" >&2
            done
            printf '\n' >&2
            ;;
        *)  # text
            printf '[%s] %-7s %s' "$(date +%H:%M:%S)" "${level^^}" "$msg" >&2
            (( ${#fields[@]} > 0 )) && printf ' (%s)' "${fields[*]}" >&2
            printf '\n' >&2
            ;;
    esac
}
```

---

## [CC-10] Type/Scope Override

**Validation:**
- `--type`: feat, fix, docs, test, chore, refactor, perf, style, build, ci
- `--scope`: alphanumeric + hyphens, max 20 chars
- `--message`: requires confirmation if >1 group

---

## Алгоритм групування (updated)

```
0. Pre-flight [CC2-1, CC2-2, CC2-10]:
   - cs_check_git_version() || exit 3
   - cs_preflight_check() || exit 2
   - cs_acquire_lock() || exit 5

1. Попередня перевірка:
   - Detect partial staging (XY where both != ' ') [CC-2]
   - Warn if detected and no --respect-staging

2. Зібрати файли (batch operation) [CC-6]:
   - `git status --porcelain -z` → parse all at once
   - Decode quoted paths [CC2-8]
   - Validate paths [CC2-9]

3. Для кожного файлу:
   - Check exclude patterns [CC-3] → skip if matched
   - Check if binary [CC-8] → skip with warning
   - Check if submodule [CC-9] → skip with warning
   - Check if broken symlink [CC2-7] → warn but include
   - Classify → test / doc / config / source

4. Для кожної непорожньої групи [CC2-11]:
   - Skip if empty after filtering
   - Визначити dominant_status
   - Визначити type з bucket + dominant_status [CC-1]
   - Apply overrides [CC-10]
   - Оцінити confidence з factors [CC-7]

5. Вивести JSON array of groups

6. Release lock [CC2-2]
```

---

## JSON output schema (updated)

```json
{
  "generated_at": "2026-02-16T12:34:56Z",
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
        "files": ["lib/session.sh"],
        "file_statuses": {"lib/session.sh": "M"},
        "confidence": "high",
        "confidence_score": 4,
        "confidence_factors": ["+task_id", "+single_file", "+single_bucket", "+clear_status"],
        "diffs": {"lib/session.sh": "@@ -42,7 +42,7 @@ ..."}
      }],
      "skipped": {
        "binary": ["images/logo.png"],
        "submodules": ["vendor/libfoo"],
        "excluded": ["lib/foo.orig"],
        "broken_symlinks": ["config/local.yml"]
      }
    }],
    "summary": {
      "repos_scanned": 10,
      "repos_dirty": 2,
      "repos_clean": 8,
      "planned_commits": 3,
      "skipped_binary": 1,
      "skipped_submodules": 1,
      "skipped_excluded": 1
    }
  },
  "_meta": {
    "duration_seconds": 5,
    "exit_code": 0,
    "git_version": "2.39.0"
  }
}
```

---

## `--execute` flow (updated)

```
1. [CC2-1] Preflight check
2. [CC2-2] Acquire lock
3. [CC2-10] Check git version
4. [CC-5] Checkpoint: git stash push
5. [CC2-6] Initialize state file
6. [CC2-4] Initialize progress bar

7. For each group:
   a. [CC2-4] Update progress
   b. [CC2-11] Skip if empty
   c. [CC2-9] Validate paths
   d. git add -- files...
   e. git commit -m "message"
   f. [CC2-6] Update state file
   g. On error: rollback group, continue

8. Summary:
   - All success → git stash drop, clear state
   - Any failure → keep checkpoint + state
   - --atomic + failure → full rollback

9. [CC2-3] Write sweep log for --undo
10. [CC2-2] Release lock
11. [CC2-4] Finish progress
```

---

## Exit Codes

| Code | Meaning | Example |
|------|---------|---------|
| 0 | Success | All commits created |
| 1 | Partial failure | 3/5 groups committed |
| 2 | Conflicts | Merge in progress, preflight failed |
| 3 | Dependencies | Git too old, br not found |
| 4 | Bad arguments | Invalid --type value |
| 5 | Interrupted | Lock timeout, SIGINT |

---

## Concrete Examples

### Example 1: Full workflow with preflight
```
$ ru commit-sweep owner/repo --execute
[12:34:56] INFO    Checking git version... 2.39.0 ✓
[12:34:56] INFO    Pre-flight check... ✓
[12:34:56] INFO    Acquiring lock... ✓
[12:34:56] INFO    Creating checkpoint...
[████████████████████████████████████████] 100% (3/3) Groups

Sweep complete:
  ✓ fix(lib): update session handling (bd-4f2a)
  ✓ test(lib): update session tests (bd-4f2a)
  ✓ docs: update README

3 commits created. Use --undo to rollback.
```

### Example 2: Preflight failure
```
$ ru commit-sweep owner/repo
✗ Cannot sweep owner/repo: rebase in progress
  Resolve the rebase first with: git rebase --continue or git rebase --abort
```

### Example 3: Undo
```
$ ru commit-sweep owner/repo --undo
⚠ About to undo 3 commits from last sweep
  Resetting to: abc123...

✓ Undo complete. Changes are staged but uncommitted.
```

### Example 4: Resume interrupted sweep
```
$ ru commit-sweep owner/repo --resume
[12:34:56] INFO    Resuming sweep from group 3
[12:34:56] INFO    Already completed: 2 groups
[████████████████████████████████████████] 100% (1/1) Remaining

Sweep resumed and completed. 3 total commits.
```

---

## Test files

### 2. `scripts/test_unit_commit_sweep.sh` (~60 тестів)

**Existing tests from CC:** 45 tests

**New tests [CC2]:**
- `cs_preflight_check`: 5 cases (merge, rebase, cherry-pick, bisect, clean)
- `cs_acquire_lock/cs_release_lock`: 4 cases (success, timeout, stale, concurrent)
- `cs_validate_path`: 4 cases (null byte, dash, absolute, valid)
- `cs_check_git_version`: 3 cases (too old, minimum, newer)
- `cs_decode_git_path`: 3 cases (plain, quoted, octal)

### 3. `scripts/test_e2e_commit_sweep.sh` (~20 сценаріїв)

**Existing tests from CC:** 15 tests

**New tests [CC2]:**
1. Preflight blocks on merge in progress
2. Lock prevents concurrent sweeps
3. `--undo` restores previous state
4. `--resume` continues from checkpoint
5. Progress bar displays correctly (non-json)

---

## Roadmap (unchanged from CC)

### v0.2: Attribution та bv інтеграція
### v0.3: LLM та розумне групування
### v0.4: Parallel, push та conflict detection
### v0.5: Ecosystem інтеграція
### v0.6: Hook system

---

## Change Summary

### CC (First Review)

| ID | Category | Change | Priority |
|----|----------|--------|----------|
| CC-1 | Correctness | Bucket-first commit type detection | P0 |
| CC-2 | Correctness | Partial staging detection & handling | P0 |
| CC-3 | Usability | `--exclude` patterns with defaults | P0 |
| CC-4 | Architecture | Serializable plan (`--save-plan/--load-plan`) | P2 |
| CC-5 | Reliability | Atomicity via stash checkpoint | P1 |
| CC-6 | Performance | Batch git operations (`git status -z`) | P1 |
| CC-7 | Usability | Confidence explanation with factors | P1 |
| CC-8 | Edge case | Binary file detection & skip | P1 |
| CC-9 | Edge case | Submodule detection & skip | P2 |
| CC-10 | Usability | `--type/--scope/--message` overrides | P2 |

### CC2 (Second Review)

| ID | Category | Change | Priority |
|----|----------|--------|----------|
| CC2-1 | Reliability | Pre-flight checks (merge/rebase in progress) | P0 |
| CC2-2 | Reliability | Lock file for concurrent protection | P0 |
| CC2-9 | Security | Command injection prevention | P0 |
| CC2-3 | Usability | Undo command (`--undo`) | P1 |
| CC2-4 | UX | Progress reporting | P1 |
| CC2-5 | Usability | Diff preview (`--show-diff`) | P1 |
| CC2-6 | Reliability | Recovery state file (`--resume`) | P1 |
| CC2-10 | Compatibility | Git version check (2.13+) | P1 |
| CC2-11 | Edge case | Empty group handling | P1 |
| CC2-7 | Edge case | Symlink handling | P2 |
| CC2-8 | Edge case | Non-UTF8 filename handling | P2 |
| CC2-12 | Observability | Structured logging (`--log-format`) | P2 |

---

## Implementation Order (recommended)

**Phase 1: Foundation (P0)**
1. CC2-9 Security validation
2. CC2-1 Pre-flight checks
3. CC2-2 Lock file
4. CC-1 Bucket-first type detection
5. CC-2 Partial staging detection
6. CC-3 Exclude patterns

**Phase 2: Core Features (P1)**
7. CC-5 Stash checkpoint
8. CC-6 Batch operations
9. CC2-10 Git version check
10. CC2-11 Empty group handling
11. CC-7 Confidence factors
12. CC-8 Binary handling

**Phase 3: UX (P1-P2)**
13. CC2-4 Progress bar
14. CC2-5 Diff preview
15. CC2-3 Undo command
16. CC2-6 Resume/state file

**Phase 4: Polish (P2)**
17. CC-4 Save/load plan
18. CC-9 Submodule handling
19. CC-10 Type/scope override
20. CC2-7 Symlink handling
21. CC2-8 Non-UTF8 filenames
22. CC2-12 Structured logging
