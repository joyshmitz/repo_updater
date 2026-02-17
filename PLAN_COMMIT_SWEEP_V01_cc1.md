# Plan: `ru commit-sweep` v0.1 MVP (Claude Code Review)

> Цей документ — розширена версія оригінального плану з покращеннями архітектури,
> надійності та usability. Зміни позначені як `[CC-N]` для трасування.

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

- `cs_classify_file()` — 4-bucket класифікатор (test/doc/config/source)
- `cs_detect_commit_type()` — bucket + git status codes → conventional commit type **[CC-1]**
- `cs_detect_scope()` — top-level directory як scope
- `cs_build_message()` — форматування conventional commit subject
- `cs_assess_confidence()` — scoring high/medium/low з explanation **[CC-7]**
- `cs_analyze_repo()` — оркестрація: git status → classify → group → JSON
- `cs_execute_group()` — safe git add + commit з per-group rollback
- `cs_is_binary()` — перевірка binary files **[CC-8]**
- `cs_is_submodule()` — перевірка submodules **[CC-9]**
- `cs_should_exclude()` — glob matching для exclude patterns **[CC-3]**

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
Це перенаправляє `--dry-run` в `ARGS` замість глобального `DRY_RUN`, бо `commit-sweep`
сам обробляє dry-run як default поведінку.

**D. `--json` routing — рядок 8209, додати `commit-sweep`:**
```bash
if [[ "$COMMAND" == "agent-sweep" || "$COMMAND" == "commit-sweep" ]]; then
    ARGS+=("$1")
```
Це дозволить `commit-sweep` отримати `--json` через `ARGS`, як роблять інші команди.

**E. Help text — після рядка 5643, додати команду:**
```
    commit-sweep    Analyze dirty repos and create logical commits
```
Та нову секцію опцій:
```
COMMIT-SWEEP OPTIONS:
    --execute            Actually create commits (default: dry-run/plan only)
    --dry-run            Show commit plan without changes (default)
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
```

**F. Нова секція перед SECTION 14 (~рядок 23783):**

`SECTION 13.11: COMMIT SWEEP` — ~600 рядків з такими функціями:

| Функція | Призначення |
|---------|-------------|
| `cmd_commit_sweep()` | Головна команда: parse args → load repos → iterate → plan/execute |
| `cs_extract_task_id()` | Branch name → task ID (`feature/bd-4f2a` → `bd-4f2a`) |
| `cs_get_task_title()` | Task ID → title через `br show <id> --format json` з 3s timeout (graceful degradation). br повертає `[{title, status, priority, ...}]` — парсимо title через grep/sed (без jq) |
| `cs_analyze_repo()` | Ядро: git status → classify files → build groups |
| `cs_classify_file()` | Один файл → bucket (test/doc/config/source) |
| `cs_detect_commit_type()` | **[CC-1]** Bucket-first логіка + git status codes → feat/fix/test/docs/chore |
| `cs_detect_scope()` | Найчастіша top-level директорія серед файлів |
| `cs_build_message()` | type + scope + task_id → conventional commit subject |
| `cs_assess_confidence()` | **[CC-7]** task_id + file_count + mixed_statuses → high/medium/low + factors array |
| `cs_files_to_json_array()` | File list → JSON array (uses `json_escape`) |
| `cs_build_group_json()` | Group data → JSON object |
| `cs_print_repo_plan()` | Human-readable план для однієї репи |
| `cs_execute_group()` | Одна група: git add → git commit (з rollback per-group) |
| `cs_execute_plan()` | Ітерація по групах → `cs_execute_group()` для кожної |
| `cs_is_binary()` | **[CC-8]** Перевірка binary через `git diff --numstat` |
| `cs_is_submodule()` | **[CC-9]** Перевірка через `git ls-files --stage` (mode 160000) |
| `cs_should_exclude()` | **[CC-3]** Glob matching для exclude patterns |
| `cs_save_plan()` | **[CC-4]** Serialize plan to JSON file |
| `cs_load_plan()` | **[CC-4]** Load and validate saved plan |
| `cs_create_checkpoint()` | **[CC-5]** `git stash push` before execute |
| `cs_restore_checkpoint()` | **[CC-5]** `git stash pop` on atomic rollback |

Видалені/замінені функції з оригінального плану:
- ~~`cs_is_test_file/doc/config()`~~ → замінені на одну `cs_classify_file()`
- ~~`cs_count_json_array()`~~ → видалена (лічильники під час побудови)
- ~~`cs_print_summary()`~~ → використовується існуюча `print_fork_op_summary()`

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

**Проблема:** `git add -p` дозволяє staged частину файлу, unstaged іншу. Git показує:
```
MM lib/foo.sh   # X=staged status, Y=unstaged status
AM lib/bar.sh   # Added to index, modified in worktree
```

**Алгоритм:**
```
0. Попередня перевірка partial staging:
   - `git status --porcelain` повертає 2-char prefix: XY
   - X = staged status, Y = unstaged status
   - Якщо обидва != ' ' і != '?' (e.g., "MM", "AM") → файл має partial staging

   - Якщо є partial staged files І немає --respect-staging:
     - WARNING: "Partial staging detected in N files. Use --respect-staging to preserve."
     - Без --respect-staging: продовжити (весь файл піде в групу)

   - Якщо є partial staged files І є --respect-staging:
     - Staged частина → окрема група "pre-staged"
     - Unstaged частина → звичайна класифікація

   - Для визначення:
     - `git diff --cached --name-only` (staged files)
     - `git diff --name-only` (unstaged files)
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

# Usage in cs_analyze_repo():
local -a exclude_patterns=("*.orig" "*.bak" "*.swp" "*~" ".DS_Store" "Thumbs.db")
exclude_patterns+=("${USER_EXCLUDE_PATTERNS[@]}")

for file in "${all_files[@]}"; do
    if cs_should_exclude "$file" "${exclude_patterns[@]}"; then
        ((excluded_count++))
        continue
    fi
    # ... classify and group
done
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

**Extended JSON schema для збереженого плану:**
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

**Checksum calculation:**
```bash
cs_calculate_checksum() {
    local repo_path="$1"
    # Hash of: branch name + file list + file mtimes
    {
        git -C "$repo_path" branch --show-current
        git -C "$repo_path" status --porcelain -z
    } | sha256sum | cut -d' ' -f1
}
```

---

## [CC-5] Atomicity via Stash Checkpoint

**Execute flow з checkpoint:**

```
1. **Checkpoint:** `git stash push -m "commit-sweep-checkpoint-$(date +%s)"` (якщо є зміни)
2. Аналіз як у dry-run → groups array
3. Для кожної групи по порядку через `cs_execute_group()`:
   - `git add -- <file1> <file2>...` (конкретні файли, не `git add .`)
   - Для deleted files: `git rm --cached -- <file>` (якщо не staged)
   - Перевірити що staging не порожній: `git diff --cached --quiet && skip`
   - `git commit -m "<message>"`
   - При помилці:
     a. `git reset HEAD -- <file1> <file2>...` (unstage)
     b. Якщо pre-commit hook змінив файли: `git checkout -- <file1> <file2>...` (restore)
     c. Log error, mark group as failed, continue to next group
   - Лог результату, продовжити до наступної групи
4. **Summary:**
   - Якщо всі групи успішні: `git stash drop` (видалити checkpoint)
   - Якщо є failed groups:
     - WARNING: "N groups failed. Checkpoint preserved in stash."
     - Користувач може `git stash pop` для повного rollback
```

**`--atomic` mode:**
```bash
if [[ "$ATOMIC_MODE" == "true" ]] && (( failed_groups > 0 )); then
    log_warn "Atomic mode: rolling back all commits"
    # Reset to pre-sweep state
    git reset --soft "$checkpoint_commit"
    git stash pop
    exit 1
fi
```

---

## [CC-6] Batch Git Operations

**Оптимізація: один git status виклик**

Замість:
```bash
for file in $(find ...); do
    status=$(git status --porcelain -- "$file")
done
```

Використовувати:
```bash
# Один виклик, парсинг в пам'яті
cs_collect_files() {
    local repo_path="$1"
    local -n out_files=$2
    local -n out_statuses=$3

    while IFS= read -r -d '' entry; do
        [[ -z "$entry" ]] && continue
        local status_code="${entry:0:2}"
        local file_path="${entry:3}"
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

**Confidence factors (prefix: + positive, - negative):**

| Factor | Weight | Description |
|--------|--------|-------------|
| `+task_id` | +2 | Branch має task ID |
| `+single_file` | +1 | Група має 1 файл |
| `+few_files` | +1 | Група має 2-3 файли |
| `+single_bucket` | +1 | Всі файли в одному bucket |
| `+clear_status` | +1 | Всі файли мають однаковий git status |
| `-many_files` | -1 | Група має >5 файлів |
| `-mixed_statuses` | -1 | Файли мають різні git statuses (A, M, D) |
| `-no_tests` | -1 | Source зміни без відповідних test змін |
| `-broad_scope` | -1 | Файли з >2 різних директорій |

**Scoring:**
- sum >= 3: high
- sum >= 1: medium
- sum < 1: low

**Implementation:**
```bash
cs_assess_confidence() {
    local task_id="$1"
    local file_count="$2"
    local bucket_count="$3"
    local status_count="$4"
    local has_tests="$5"
    local dir_count="$6"

    local score=0
    local -a factors=()

    if [[ -n "$task_id" ]]; then
        ((score += 2)); factors+=("+task_id")
    fi
    if (( file_count == 1 )); then
        ((score += 1)); factors+=("+single_file")
    elif (( file_count <= 3 )); then
        ((score += 1)); factors+=("+few_files")
    elif (( file_count > 5 )); then
        ((score -= 1)); factors+=("-many_files")
    fi
    if (( bucket_count == 1 )); then
        ((score += 1)); factors+=("+single_bucket")
    fi
    if (( status_count == 1 )); then
        ((score += 1)); factors+=("+clear_status")
    else
        ((score -= 1)); factors+=("-mixed_statuses")
    fi
    if [[ "$has_tests" == "false" ]]; then
        ((score -= 1)); factors+=("-no_tests")
    fi
    if (( dir_count > 2 )); then
        ((score -= 1)); factors+=("-broad_scope")
    fi

    local level="low"
    if (( score >= 3 )); then level="high"
    elif (( score >= 1 )); then level="medium"
    fi

    echo "$level"
    echo "$score"
    printf '%s\n' "${factors[@]}"
}
```

---

## [CC-8] Binary File Handling

**Detection:**
```bash
cs_is_binary() {
    local repo_path="$1"
    local file="$2"
    # git diff --numstat shows "-\t-\t<path>" for binary files
    local numstat
    numstat=$(git -C "$repo_path" diff --numstat -- "$file" 2>/dev/null)
    [[ "$numstat" == -$'\t'-$'\t'* ]]
}
```

**Behavior:**
1. Default: **skip** binary files з WARNING
2. `--include-binary` flag: включити binary в групу "chore"
3. JSON output: `"binary": true` field для binary файлів

**Warning output:**
```
⚠ Skipped 3 binary files: images/logo.png, data/model.bin, ...
  Use --include-binary to include them in commits
```

---

## [CC-9] Submodule Handling

**Detection:**
```bash
cs_is_submodule() {
    local repo_path="$1"
    local path="$2"
    # mode 160000 = gitlink (submodule)
    git -C "$repo_path" ls-files --stage -- "$path" 2>/dev/null | grep -q '^160000'
}
```

**Behavior:**
1. Default: **skip** submodule pointer changes з WARNING
2. `--include-submodules`: включити як окрему групу `chore(deps): update submodule X`
3. НЕ рекурсивно заходити в submodule — це окремий repo

**Warning output:**
```
⚠ Skipped submodule pointer change: vendor/libfoo (160000)
  Use --include-submodules to commit submodule updates
```

---

## [CC-10] Type/Scope Override

**Validation:**
- `--type` must be one of: `feat`, `fix`, `docs`, `test`, `chore`, `refactor`, `perf`, `style`, `build`, `ci`
- `--scope` must be alphanumeric + hyphens, max 20 chars
- `--message` requires confirmation if >1 group (all groups get same message = suspicious)

**Implementation:**
```bash
# In cmd_commit_sweep() argument parsing:
--type=*)
    TYPE_OVERRIDE="${1#--type=}"
    if ! [[ "$TYPE_OVERRIDE" =~ ^(feat|fix|docs|test|chore|refactor|perf|style|build|ci)$ ]]; then
        log_error "Invalid commit type: $TYPE_OVERRIDE"
        exit 4
    fi
    ;;
--scope=*)
    SCOPE_OVERRIDE="${1#--scope=}"
    if ! [[ "$SCOPE_OVERRIDE" =~ ^[a-zA-Z0-9-]{1,20}$ ]]; then
        log_error "Invalid scope: must be alphanumeric+hyphens, max 20 chars"
        exit 4
    fi
    ;;
--message=*)
    MESSAGE_OVERRIDE="${1#--message=}"
    ;;
```

---

## Алгоритм групування (updated)

```
0. Попередня перевірка:
   - Detect partial staging (XY where both != ' ') [CC-2]
   - Warn if detected and no --respect-staging

1. Зібрати файли (batch operation) [CC-6]:
   - `git status --porcelain -z` → parse all at once
   - Якщо --respect-staging: тільки unstaged + untracked
   - Інакше: staged + unstaged + untracked (дедупліковано)

2. Для кожного файлу:
   - Check exclude patterns [CC-3] → skip if matched
   - Check if binary [CC-8] → skip with warning (unless --include-binary)
   - Check if submodule [CC-9] → skip with warning (unless --include-submodules)
   - Для deleted files (D): зберегти шлях, позначити status=D
   - Для renamed files (R): використовувати NEW path, позначити status=R
   - Classify → test / doc / config / source через cs_classify_file()

3. Для кожної непорожньої групи:
   - Визначити dominant_status з файлів групи
   - Визначити type з bucket + dominant_status [CC-1]
   - Apply --type override if set [CC-10]
   - Визначити scope (top-level directory)
   - Apply --scope override if set [CC-10]
   - Згенерувати message (з task_id якщо є)
   - Apply --message override if set [CC-10]
   - Оцінити confidence з factors [CC-7]

4. Якщо є manually staged files + --respect-staging:
   - Додати окрему групу "pre-staged" з цими файлами

5. Вивести JSON array of groups
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
        "confidence_factors": ["+task_id", "+single_file", "+single_bucket", "+clear_status"]
      }],
      "skipped": {
        "binary": ["images/logo.png"],
        "submodules": ["vendor/libfoo"],
        "excluded": ["lib/foo.orig"]
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
    "exit_code": 0
  }
}
```

**Saved plan schema (--save-plan):**
```json
{
  "plan_version": "1",
  "created_at": "2026-02-16T12:34:56Z",
  "created_by": "ru commit-sweep v0.15.0",
  "checksum": "sha256:abc123...",
  "generated_at": "...",
  "version": "...",
  "data": { ... }
}
```

---

## `--execute` flow (updated)

```
1. [CC-5] Checkpoint: `git stash push -m "commit-sweep-$(date +%s)"` якщо dirty
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
   - [CC-5] --atomic + failure → `git reset --soft` + `git stash pop`
```

---

## Ключові рішення

- **Default dry-run** — безпека; `--execute` явний opt-in. Це свідоме відхилення від
  паттерну `ru` (де команди одразу виконуються, а `--dry-run` запобігає). Обґрунтування:
  commit-sweep створює незворотні коміти, тому безпечніше показати план першим.
- **`cs_` prefix** — namespace для helpers (як `agent_sweep_` в agent-sweep)
- **Без jq** — JSON будується через printf + `json_escape()` (існуюча функція)
- **Без `--no-verify`** — v0.1 поважає git hooks; користувач може додати якщо потрібно
- **4 bucket grouping** — source/test/doc/config; не subdivision по директоріях (v0.2)
- **Graceful degradation** — якщо `br` не встановлений, task_title = "", працює далі
- **`--respect-staging`** — якщо користувач вручну підготував staging, не ламати його
- **Timeout для `br`** — 3 секунди; якщо `br` зависне, fallback на порожній title
- **[CC-1] Bucket-first type detection** — type визначається з bucket, потім status як tiebreaker
- **`_meta` в JSON** — стандартний паттерн `ru` через `build_json_envelope()`
- **`file_statuses` в JSON** — кожен файл зі своїм git status code для прозорості
- **Per-group rollback** — `git reset HEAD -- <files>` тільки для файлів конкретної групи
- **[CC-5] Stash checkpoint** — safety net для `--execute`, особливо з `--atomic`
- **[CC-6] Batch git operations** — один `git status -z` виклик замість per-file
- **[CC-7] Confidence factors** — explainable scoring, не просто label
- **[CC-8] Binary skip by default** — safety, explicit opt-in з `--include-binary`
- **[CC-9] Submodule skip by default** — prevents accidental submodule commits

### Reuse existing ru functions

- `resolve_repo_spec()` (рядок 6622) — парсинг repo spec
- `get_all_repos()` (рядок 6742) — завантаження всіх реп
- `repo_is_dirty()` (рядок 6857) — перевірка dirty worktree
- `is_git_repo()` — перевірка git repo
- `json_escape()` (рядок 4849) — екранування для JSON
- `build_json_envelope()` (рядок 5137) — JSON envelope з `generated_at`, `version`, `_meta`
- `emit_structured()` (рядок 5098) — вивід JSON/TOON з fallback
- `print_fork_op_summary()` (рядок 8776) — summary box з gum/ANSI fallback
- `log_info/success/error/warn/step/verbose` — logging
- `GUM_AVAILABLE` + gum style — summary box

---

## Concrete Examples

### Example 1: Test file in lib/ directory

```
$ git status --porcelain
M  lib/session.sh
M  lib/session_test.sh

$ ru commit-sweep  # BEFORE [CC-1]
Group 1: source (2 files)
  fix(lib): update session handling (bd-4f2a)
  - M lib/session.sh
  - M lib/session_test.sh  # WRONG: should be test group!

$ ru commit-sweep  # AFTER [CC-1]
Group 1: source (1 file)
  fix(lib): update session handling (bd-4f2a)
  - M lib/session.sh

Group 2: test (1 file)
  test(lib): update session tests (bd-4f2a)
  - M lib/session_test.sh  # CORRECT: filename pattern wins
```

**Lesson:** `cs_classify_file()` checks filename patterns (`*_test.sh`) BEFORE directory.

### Example 2: Mixed add/modify

```
$ git status --porcelain
A  lib/new_feature.sh
M  lib/existing.sh

$ ru commit-sweep
Group 1: source (2 files)
  feat(lib): add new feature (bd-4f2a)  # A wins tie-breaker
  - A lib/new_feature.sh
  - M lib/existing.sh
```

**Lesson:** Dominant status with tie-breaker: A > M > R > D.

### Example 3: Binary file warning

```
$ git status --porcelain
M  lib/code.sh
A  images/logo.png

$ ru commit-sweep
⚠ Skipped 1 binary file: images/logo.png
  Use --include-binary to include in commits

Group 1: source (1 file)
  fix(lib): update code (bd-4f2a)
  - M lib/code.sh

$ ru commit-sweep --include-binary
Group 1: source (1 file)
  fix(lib): update code (bd-4f2a)
  - M lib/code.sh

Group 2: binary (1 file)
  chore: add logo.png
  - A images/logo.png [binary]
```

---

## Test files

### 2. `scripts/test_unit_commit_sweep.sh` (новий файл)

Unit тести для cs_* helpers (~45 тестів):

**cs_extract_task_id:** 6 кейсів
- `feature/bd-XXXX` → `bd-XXXX`
- `feature/br-XXXX` → `br-XXXX`
- `main` → empty
- empty → empty
- `feature/nested/bd-XXXX` → `bd-XXXX`
- `bd-XXXX-suffix` → `bd-XXXX`

**cs_classify_file:** 12 кейсів
- `test/*` → test
- `*_test.go` → test
- `*_test.sh` → test
- `*.spec.ts` → test
- `scripts/test_*` → test
- `*.md` → doc
- `docs/*` → doc
- `README*` → doc
- `.gitignore` → config
- `*.yml` in root → config
- `Makefile` → config
- `lib/foo.sh` → source

**cs_detect_commit_type:** 8 кейсів
- bucket=test, any status → test
- bucket=doc, any status → docs
- bucket=config, any status → chore
- bucket=source, dominant=A → feat
- bucket=source, dominant=M → fix
- bucket=source, dominant=D → chore
- bucket=source, dominant=R → refactor
- bucket=source, tie A=M → feat (tie-breaker)

**cs_detect_scope:** 4 кейси
- `lib/foo.sh` → lib
- `scripts/test_x.sh` → scripts
- `README.md` (root) → root
- empty → empty

**cs_build_message:** 6 кейсів
- з task_id → `type(scope): description (task_id)`
- без task_id → `type(scope): description`
- truncation >72 chars
- no scope → `type: description`
- special chars escaped
- --no-task-id flag

**cs_assess_confidence:** 6 кейсів
- task_id + 1 file → high, score=4
- no task_id + 1 file → medium, score=2
- task_id + 10 files → medium, score=1
- mixed statuses → -1 penalty
- broad scope (>2 dirs) → -1 penalty
- factors array contains expected strings

**cs_should_exclude:** 4 кейси
- `*.orig` matches `foo.orig`
- `*.bak` matches `data.bak`
- `lib/*` matches `lib/foo.sh`
- `foo.sh` does not match `*.orig`

**cs_is_binary:** 3 кейси (require mock git)
- text file → false
- png file → true
- new untracked binary → true

**cs_is_submodule:** 2 кейси (require mock git)
- regular file → false
- submodule path → true

### 3. `scripts/test_e2e_commit_sweep.sh` (новий файл)

E2E тести з mock git repos (~15 сценаріїв):

1. Одна репа, один файл → 1 commit group
2. Source + test файли → 2 groups
3. Branch `feature/bd-XXXX` → task ID extraction
4. `--json` → validates JSON envelope keys
5. `--execute` → git log shows new commits, working tree clean after
6. Clean repo → skipped
7. Немає реп → clean exit
8. Deleted file → chore commit type, file removed
9. `--respect-staging` → manually staged files preserved in separate group
10. `--execute` rollback → якщо commit fails, files unstaged per-group
11. **[CC-3]** `--exclude=*.orig` → skips matching files
12. **[CC-4]** `--save-plan` → creates valid JSON file
13. **[CC-4]** `--load-plan` → executes saved plan
14. **[CC-8]** Binary files → skipped with warning by default
15. **[CC-9]** Submodule changes → skipped with warning by default

---

## Що НЕ ввійшло в MVP v0.1 (roadmap)

### v0.2: Attribution та bv інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **bv correlation engine** | Зв'язування файлів з beads | `bv --robot-history` → `BeadEvent{BeadID, CommitSHA, Author}` |
| **agent-mail file reservations** | Визначення хто "володіє" файлами | `file_reservation_paths(project_key, agent, paths, ttl, exclusive)` |
| **Multi-agent attribution** | Розділення комітів per-agent | Glob matching через `fnmatchcase()` |
| **Co-Authored-By trailer** | `Co-Authored-By: <agent-name>` | Agent profile з `register_agent()` |
| **Sub-directory grouping** | Source bucket → під-групи по директоріях | — |

### v0.3: LLM та розумне групування

| Фіча | Опис | Залежність |
|-------|------|------------|
| **LLM commit messages** | LLM для генерації commit messages | API key config |
| **Semantic grouping** | LLM групує файли за семантикою | LLM |
| **Confidence-based routing** | `confidence: low` → LLM review | LLM |
| **Interactive mode** | `--interactive` для ручного перегрупування | gum |

### v0.4: Parallel, push та conflict detection

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **Parallel sweep** | `--parallel=N` | Паттерн з `run_parallel_agent_sweep()` |
| **Auto-push** | `--push` після commit | DCG: push=High severity |
| **Force push approval** | `--force` потребує review | SLB: `Request{min_approvals:2}` |
| **Conflict detection** | Перевірка lock-ів | NTM: `CheckPathConflict()` |
| **Resume/restart** | `--resume` та `--restart` | state file |
| **Pre-commit hooks** | `--no-verify` | — |

### v0.5: Ecosystem інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **GitHub PR creation** | `--pr` після push | `gh pr create` |
| **Beads auto-close** | Commit закриває task | `br close <id>` |
| **Audit trail** | Sweep log → agent-mail | `send_message()` |
| **Learning from history** | Покращення на основі минулого | CASS: `cm context` |
| **Config file** | `~/.config/ru/commit-sweep.yaml` | — |

### v0.6: Hook system

**Config file: `.commit-sweep.yml` в repo root**
```yaml
# Custom classification rules
classify:
  - pattern: "migrations/*.sql"
    bucket: "config"
    type: "chore"
    scope: "db"
  - pattern: "**/*.generated.go"
    exclude: true

# Custom type detection
types:
  security:
    paths: ["auth/**", "crypto/**"]
    type: "fix"
    scope: "security"

# Pre-commit message hook
hooks:
  pre_message: |
    echo "$1" | sed 's/fix/hotfix/g'
```

---

## Наскрізний принцип: Human-in-the-Loop

**Рішення завжди приймає людина. LLM готує варіанти та аналіз розвитку подій.**

| Версія | Що робить LLM | Що вирішує людина |
|--------|---------------|-------------------|
| **v0.1** | Групує файли, генерує commit messages, оцінює confidence | Перший запуск — dry-run. `--execute` для виконання |
| **v0.2** | Attribution, Co-Authored-By, закриває beads | Автономно |
| **v0.3** | LLM messages, семантичне групування | Автономно. `--interactive` opt-in |
| **v0.4** | Parallel, conflict resolution, push | Push потребує `--push` |
| **v0.5** | PR creation, audit trail | PR потребує `--pr` |

**Межа автономності (DCG принцип):**

| Дія | Автономно? | Чому |
|-----|-----------|------|
| `git add` + `git commit` | Так | Локальна, зворотна |
| Вибір commit message | Так | Локальна |
| `br close` | Так | Зворотна (`br reopen`) |
| `git push` | **Ні — `--push`** | Shared state |
| `git push --force` | **Ні — `--force`** | Деструктивна |
| PR creation | **Ні — `--pr`** | Shared state |

---

## Свідомо відкладені архітектурні рішення

1. **Без `git add .`** — завжди конкретні файли. Безпечніше. Перегляд — v0.4.
2. **Без jq** — JSON через printf. Якщо schema ускладниться — перехід на jq.
3. **Без паралельності** — v0.1 sequential. Паралельність потребує lock management.
4. **Без push** — коміти локальні. Push — окрема відповідальність.
5. **Без rollback всього sweep** — partial success дозволений. Повний rollback — v0.5.

---

## Verification

```bash
# Unit тести
bash scripts/test_unit_commit_sweep.sh

# E2E тести
bash scripts/test_e2e_commit_sweep.sh

# Manual: dry-run на реальному dirty repo
ru commit-sweep owner/repo
ru commit-sweep owner/repo --json

# Manual: execute на тестовому repo
ru commit-sweep owner/repo --execute --verbose

# Manual: save and load plan
ru commit-sweep owner/repo --save-plan=/tmp/plan.json
cat /tmp/plan.json
ru commit-sweep --load-plan=/tmp/plan.json --execute

# Full suite (має бути 97+ pass, +2 new suites)
bash scripts/run_all_tests.sh
```

---

## Change Summary

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
