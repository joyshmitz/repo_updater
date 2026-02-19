# Plan: `ru commit-sweep` v0.1 MVP

## Context

AI-агенти кодери (працюють з beads-задачами `bd-*` через `br` CLI) зараз і кодують, і комітять. Це призводить до:
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

## Аудит екосистеми (60+ проєктів портфеля)

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
- `cs_detect_commit_type()` — bucket-first policy + dominant status → conventional commit type
- `cs_detect_scope()` — top-level directory як scope
- `cs_build_message()` — форматування conventional commit subject
- `cs_assess_confidence()` — scoring high/medium/low
- `cs_analyze_repo()` — оркестрація з чіткими Step-блоками: collect → classify → group → render
- `cs_execute_group()` — safe git add + commit з per-group rollback

## Scope v0.1

**Робить:**
1. Сканує репо (всі або конкретну) на dirty worktrees
2. Групує змінені файли: source / test / docs / config
3. Генерує conventional commit messages з евристик (не LLM)
4. Витягує task ID з назви гілки (`feature/bd-XXXX`, `fix/bd-XXXX`)
5. Виводить план комітів (JSON або human-readable)
6. Виконує план з `--execute` (default = dry-run для безпеки)

**НЕ робить:** LLM, agent-mail lookup, bv integration, push, parallel, conflict resolution.

## Зміни у файлах

### 1. `ru` (головний скрипт)

**A. Dispatch — рядок ~23826, додати перед `*)`:**
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

**E. Help text — два місця:**

E1. Команда в список — після рядка 5644 (robot-docs), додати:
```
    commit-sweep    Analyze dirty repos and create logical commits
```

E2. Секція опцій — після ROBOT-DOCS OPTIONS (рядок 5761), перед EXAMPLES (рядок 5763):
```
COMMIT-SWEEP OPTIONS:
    --execute            Actually create commits (default: dry-run/plan only)
    --dry-run            Show commit plan without changes (default)
    --respect-staging    Keep manually staged files in a dedicated first group
    --allow-protected-branch
                         Allow execute on protected branches (`main`, `release/*`)
```

**F. command-scoped flags routing — додати ПЕРЕД catch-all `-*)` (рядок 8565):**
```bash
            --execute|--respect-staging|--allow-protected-branch)
                if [[ "$COMMAND" == "commit-sweep" ]]; then
                    ARGS+=("$1")
                elif [[ -z "$COMMAND" ]]; then
                    pending_global_args+=("$1")
                else
                    log_error "Unknown option: $1"
                    show_help
                    exit 4
                fi
                shift
                ;;
```
Паттерн аналогічний `--push` (рядок 8350) — валідує що прапорець належить конкретній команді.

**G. Нова секція перед SECTION 14 (рядок 23783):**

`SECTION 13.11: COMMIT SWEEP` (після SECTION 13b: ROBOT-DOCS на рядку 23144) — ~520 рядків з такими функціями:

| Функція | Призначення |
|---------|-------------|
| `cmd_commit_sweep()` | Головна команда: parse args → load repos → iterate → plan/execute |
| `cs_extract_task_id()` | Branch name → task ID (`feature/bd-4f2a` → `bd-4f2a`) |
| `cs_get_task_title()` | Task ID → title через `br show <id> --format json` з 3s timeout (graceful degradation). br повертає `[{title, status, priority, ...}]` — парсимо title через grep/sed (без jq) |
| `cs_analyze_repo()` | Ядро: `git status --porcelain=v1 -z` → classify → group (з чіткими Step-блоками всередині) |
| `cs_classify_file()` | Один файл → bucket (test/doc/config/source) |
| `cs_detect_commit_type()` | Bucket-first type policy + dominant status для source bucket |
| `cs_detect_scope()` | Найчастіша top-level директорія серед файлів |
| `cs_build_message()` | type + scope + task_id → conventional commit subject |
| `cs_assess_confidence()` | task_id + file_count + mixed_statuses → high/medium/low |
| `cs_get_task_title_cached()` | Memoize task_id→title для уникнення повторних `br show` у межах run |
| `cs_files_to_json_array()` | File list → JSON array (uses `json_escape`) |
| `cs_build_group_json()` | Group data → JSON object |
| `cs_print_repo_plan()` | Human-readable план для однієї репи |
| `cs_execute_group()` | Одна група: git add → git commit (з rollback per-group) |
| `cs_execute_plan()` | Ітерація по групах → `cs_execute_group()` для кожної |

Видалені/замінені функції з оригінального плану:
- ~~`cs_is_test_file/doc/config()`~~ → замінені на одну `cs_classify_file()`
- ~~`cs_count_json_array()`~~ → видалена (лічильники під час побудови)
- ~~`cs_print_summary()`~~ → використовується існуюча `print_fork_op_summary()`

### Алгоритм групування

```
1. Зібрати зміни через `git -C "$repo_path" status --porcelain=v1 -z` (NUL-safe)
2. Нормалізувати записи:
   - `XY` статуси (`M`,`A`,`D`,`R`,`C`,`U`,`??`) у staged/unstaged прапорці
   - Для `D`: зберігати `old_path`
   - Для `R/C`: зберігати `old_path` + `new_path`
3. Пропустити файли через denylist (`filter_files_denylist()`)
4. Якщо знайдено unmerged (`U*`/`*U`) → `repo.status = skipped_conflict`, execute для repo заборонено
5. Classify кожен файл → test / doc / config / source через `cs_classify_file()`
6. Якщо увімкнено `--respect-staging`:
   - сформувати окрему групу `pre-staged`
   - виключити ці файли з auto-grouping (no overlap)
   - при staged+unstaged overlap додати `reason_code=partial_staging_overlap`
7. Для кожної непорожньої auto-групи:
   - визначити dominant status
   - визначити type через bucket-first policy:
     - `test -> test`, `doc -> docs`, `config -> chore`
     - `source + A -> feat`, `source + M -> fix`, `source + D -> chore`, `source + R -> refactor`
   - визначити scope
   - згенерувати message (з task_id якщо є)
   - оцінити confidence
8. Детермінізувати порядок:
   - repos: lexicographic
   - groups: `pre-staged -> source -> test -> doc -> config`
   - files: lexicographic
9. Проставити `group_id = <repo>:<bucket>:<scope>:<seq>`
10. Вивести JSON array of groups
```

### JSON output schema

```json
{
  "generated_at": "2026-02-16T12:34:56Z",
  "version": "0.15.0",
  "output_format": "json",
  "command": "commit-sweep",
  "data": {
    "schema_version": "commit-sweep/v1",
    "repos": [{
      "repo": "owner/project",
      "path": "/abs/path",
      "branch": "feature/bd-4f2a",
      "task_id": "bd-4f2a",
      "task_title": "Fix session lock",
      "groups": [{
        "id": "owner/project:source:session:001",
        "bucket": "source",
        "type": "fix",
        "scope": "session",
        "message": "fix(session): fix session lock (bd-4f2a)",
        "files": ["lib/session.sh"],
        "file_statuses": {"lib/session.sh": "M"},
        "confidence": "high",
        "reason_codes": ["bucket=source", "dominant_status=M", "task_id=bd-4f2a"]
      }]
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
    "run_id": "cs-20260219-054500"
  }
}
```

### `--execute` flow

1. Preflight перед execute:
   - `repo_preflight_check()` + readable reason/action
   - branch guard: блокувати `main|release/*` без `--allow-protected-branch`
   - lock: `dir_lock_acquire "$repo_path/.git/commit-sweep.lock.d" 30`
2. Аналіз як у dry-run → groups array
3. Для кожної групи по порядку через `cs_execute_group()`:
   - Для `pre-staged`: використовувати поточний index як є
   - Для інших груп: staging у звичайний index (перелік файлів тільки з поточної групи)
   - Файли пропускаються через `filter_files_denylist()` перед staging
   - `git add -- <file1> <file2>...` (конкретні файли, не `git add .`)
   - Для deleted files: `git add -u -- <file>`
   - Перевірити що staging не порожній: `git diff --cached --quiet && skip`
   - `git commit -m "<message>"`
   - При помилці: rollback тільки для поточної групи
4. Вивести summary (`planned_commits`, `repos_dirty`, `repos_clean`)
5. Завжди звільняти lock через `dir_lock_release` (finally)

### Ключові рішення

- **Default dry-run** — безпека; `--execute` явний opt-in. Це свідоме відхилення від
  паттерну `ru` (де команди одразу виконуються, а `--dry-run` запобігає). Обґрунтування:
  commit-sweep створює незворотні коміти, тому безпечніше показати план першим.
- **`cs_` prefix** — namespace для helpers (як `agent_sweep_` в agent-sweep)
- **Без jq** — JSON будується через printf + `json_escape()` (існуюча функція)
- **Без `--no-verify`** — v0.1 поважає git hooks; користувач може додати якщо потрібно
- **Детермінізм за замовчуванням** — стабільний порядок repos/groups/files + стабільний `group_id`
- **Graceful degradation** — якщо `br` не встановлений, task_title = "", працює далі
- **`--respect-staging`** — pre-staged група завжди перша, без overlap з auto-групами
- **Timeout для `br`** — 3 секунди; якщо `br` зависне, fallback на порожній title
- **Task title cache** — memoize `task_id -> title` у межах run, щоб уникати повторних `br show`
- **Task ID policy** — `bd-*` primary; `br-*` alias можливий тільки як future migration-compatible pattern
- **Bucket-first commit type** — `test/doc/config` задають type напряму; source використовує dominant status
- **`_meta` в JSON** — стандартний паттерн `ru` через `build_json_envelope()`
- **Schema v1 (MVP)** — `schema_version` + `run_id` + `reason_codes`, без розширених execution counters
- **Per-group rollback** — rollback обмежений файлами поточної групи
- **Fail-safe execute** — preflight + lock + protected-branch guard перед будь-яким commit

### Reuse existing ru functions

- `resolve_repo_spec()` (рядок 6622) — парсинг repo spec
- `get_all_repos()` (рядок 6742) — завантаження всіх реп
- `repo_is_dirty()` (рядок 6857) — перевірка dirty worktree
- `repo_preflight_check()` (рядок 21975) — preflight safety checks
- `preflight_skip_reason_message()` / `preflight_skip_reason_action()` — actionable diagnostics
- `is_git_repo()` — перевірка git repo
- `dir_lock_acquire()` / `dir_lock_release()` (рядки 463/457) — portable repo lock
- `json_escape()` (рядок 4852) — екранування для JSON
- `build_json_envelope()` (рядок 5137) — JSON envelope з `generated_at`, `version`, `_meta`
- `emit_structured()` (рядок 5098) — вивід JSON/TOON з fallback
- `is_file_denied()` / `filter_files_denylist()` — guardrails для секретів/артефактів
- `print_fork_op_summary()` (рядок 8776) — summary box з gum/ANSI fallback
- `log_info/success/error/warn/step/verbose` — logging
- `GUM_AVAILABLE` + gum style — summary box

**H. robot-docs integration — додати schema та command entry:**
- `_robot_docs_commands()` (рядок 23244): додати command entry з description та options
- `_robot_docs_examples()` (рядок 23427): додати приклади використання
- `_robot_docs_schemas()` (рядок 23554): додати `commit-sweep` JSON schema

Паттерн з upstream `10f504e` (robot-docs schemas) та `a7aa3d5` (fork command entries).

### 2. `scripts/test_unit_commit_sweep.sh` (новий файл)

Unit тести для cs_* helpers (~30 тестів).

**Паттерн:** наслідувати `test_unit_parsing_coverage.sh` (upstream `ce5ac34`):
- Використовувати `source_function()` для ізоляції кожної функції
- Stub log функції: `log_warn() { :; }` тощо
- Секційна організація через `section "function_name"`
- Відновлювати HOME перед видаленням temp dir (upstream fix `6b82479`)

Кейси:
- `cs_extract_task_id`: 6 кейсів (`bd-XXXX` primary, no match, empty, nested/bd-XXXX, prefix/suffix, invalid format)
- `cs_classify_file`: 8 кейсів (test/*, *_test.go, scripts/test_*, *.md, docs/*, .gitignore, *.yml, lib/foo.sh)
- `cs_detect_commit_type`: 7 кейсів (bucket-first + source dominant status + fallback)
- `cs_detect_scope`: 4 кейси (lib/foo.sh→lib, scripts/test_x.sh→scripts, root file→root, empty)
- `cs_build_message`: 5 кейсів (з task_id, без, truncation >72 chars, no scope, special chars)
- `cs_assess_confidence`: 4 кейси (task_id+few files→high, no task_id→medium, many files→low, 1 file→high)
- `cs_get_task_title_cached`: 4 кейси (cache hit/miss, timeout fallback, empty task_id)

### 3. `scripts/test_e2e_commit_sweep.sh` (новий файл)

E2E тести з mock git repos (~10 сценаріїв).

**Паттерн:** наслідувати `test_e2e_fork_*.sh` (upstream `1e0fa15`, `b90ad10`):
- Обов'язково `source "$SCRIPT_DIR/test_e2e_framework.sh"`
- Використовувати `e2e_setup` / `e2e_cleanup` (не inline framework)
- Використовувати `$E2E_RU_SCRIPT` (не `$RU_SCRIPT`)
- Використовувати `assert_equals`, `assert_contains` (не ручні if/else)
- Local bare repo як remote для ізоляції від мережі
- Helper функції: `setup_dirty_repo()`, `init_sweep_config()`

Сценарії:
1. Одна репа, один файл → 1 commit group
2. Source + test файли → 2 groups
3. Branch `feature/bd-4f2a` → task ID extraction
4. `--json` → validates JSON envelope keys (`generated_at`, `version`, `command`, `data`, `_meta`)
5. `--execute` → git log shows new commits, working tree clean after
6. Clean repo → skipped
7. Немає реп → clean exit
8. Deleted file → chore commit type, file removed
9. `--respect-staging` → manually staged files preserved in separate group
10. `--execute` rollback → якщо commit fails (simulate via bad hook), files unstaged per-group
11. Repo з unmerged (`U*`) → analysis skip (`skipped_conflict`) з actionable reason/action
12. Locked repo → timeout + clean unlock path

## Що НЕ ввійшло в MVP v0.1 (roadmap)

### v0.2: Attribution та bv інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **bv correlation engine** | Зв'язування файлів з beads: зміни в `lib/session.sh` → `bd-4f2a` | `bv --robot-history` → `BeadEvent{BeadID, CommitSHA, Author, EventType}` через `pkg/correlation/extractor.go` |
| **agent-mail file reservations** | Визначення хто "володіє" файлами для attribution | `file_reservation_paths(project_key, agent, paths, ttl, exclusive)` → `{granted, conflicts}`. Query: `_collect_file_reservation_statuses()` з `app.py:3485` |
| **Multi-agent attribution** | Розділення комітів per-agent на основі file reservations | Glob matching через `fnmatchcase()` в `app.py:3712`. Конфлікт = `{path, holders: [agent_names]}` |
| **Co-Authored-By trailer** | `Co-Authored-By: <agent-name>` на основі agent-mail identity | Agent profile з `register_agent()` → `{name, program, model}` |
| **Sub-directory grouping** | Source bucket → під-групи по директоріях | — |
| **Pipeline refactor** | Рознести `cs_analyze_repo()` на `collect/normalize/group/finalize/render` після стабілізації MVP | — |
| **Plan freeze/fingerprint** | `--save-plan`/`--execute-plan` + drift check для multi-agent execute | — |

### v0.3: LLM та розумне групування

| Фіча | Опис | Залежність |
|-------|------|------------|
| **LLM commit messages** | Замість евристик використовувати LLM для генерації commit messages з контексту diff | API key config |
| **Semantic grouping** | LLM аналізує diff та групує файли за семантичною зв'язаністю (не за bucket), наприклад: auth-related зміни в одному коміті навіть якщо це source + test + config | LLM |
| **Confidence-based routing** | Групи з `confidence: low` автоматично направляються на LLM review перед commit | LLM |
| **Interactive mode** | `--interactive` — показує план, дозволяє вручну перегрупувати/перейменувати перед execute | gum |

### v0.4: Parallel, push та conflict detection

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **Parallel sweep** | `--parallel=N` для обробки N реп одночасно | Паттерн з `run_parallel_agent_sweep()` в `ru` |
| **Auto-push** | `--push` після commit виконує `git push` | DCG класифікація: push=High severity, потребує explicit flag |
| **Force push approval** | `--force` для force-push потребує review | SLB: `Request{min_approvals:2, require_different_model:true}` → approve/reject/escalate |
| **Conflict detection** | Перевірка lock-ів інших агентів перед commit | NTM: `CheckPathConflict(path, excludeAgent)` → `Conflict{holders, priority}`. Negotiation: вищий пріоритет запитує release |
| **Resume/restart** | `--resume` та `--restart` після перерваного sweep | state file (як agent-sweep) |
| **Run lifecycle + revert-run** | Формальна state machine + `--revert-run <run_id>` через `git revert` | — |
| **Pre-commit hooks** | `--no-verify` для пропуску git hooks (opt-in) | — |

### v0.5: Ecosystem інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **GitHub PR creation** | `--pr` після push створює PR з commit messages як body | `gh pr create` (DCG: PR creation=shared state, потребує `--pr` flag) |
| **Beads auto-close** | Commit закриває task → `br close bd-4f2a` автоматично | `br close <id> --reason "Completed"` + `br sync --flush-only` |
| **Audit trail** | Sweep log → agent-mail повідомлення з confidence scores | `send_message(project_key, sender, to, subject, body_md, thread_id)` |
| **Learning from history** | Покращення commit messages на основі минулих сесій | CASS: `cm context "commit patterns" --json` → `{relevantBullets, antiPatterns}` |
| **Config file** | `~/.config/ru/commit-sweep.yaml` для персистентних налаштувань | — |

### Наскрізний принцип: Human-in-the-Loop

**Рішення завжди приймає людина. У v0.1 система евристична (без LLM).**

Цей принцип діє з v0.1 і масштабується з кожною версією:

| Версія | Що робить система | Що вирішує людина |
|--------|-------------------|-------------------|
| **v0.1** | Евристичне grouping, commit message generation, confidence scoring (без LLM) | Людина вирішує запуск `--execute` після dry-run |
| **v0.2** | Rule-based attribution, Co-Authored-By, інтеграція з reservations | Людина задає політику attribution та auto-close |
| **v0.3** | LLM-assisted message/grouping (opt-in) | Людина керує політикою LLM і fallback |
| **v0.4** | Parallel execute, lifecycle recovery, push workflow | Людина дає explicit згоду на push/force-поведінку |
| **v0.5** | PR workflow, audit trail, ecosystem automation | Людина керує політикою PR/create/merge |

**Межа автономності (за принципом DCG):**

Агенти працюють повністю автономно. Блокуються тільки **деструктивні дії** —
ті, що змінюють shared state або незворотні (аналог `destructive_command_guard`):

| Дія | Автономно? | Чому |
|-----|-----------|------|
| `git add` + `git commit` | Так | Локальна, зворотна (`git reset --soft`) |
| Вибір commit message | Так | Локальна, перезаписується `--amend` |
| Вибір стратегії grouping | Так | Не впливає на shared state |
| `br close` (закриття beads) | Так | Зворотна (`br reopen`) |
| Commit з `confidence: low` | Так | Локальна; confidence — інформативний, не блокуючий |
| `git push` | **Ні — потребує `--push`** | Змінює remote (shared state) |
| `git push --force` | **Ні — потребує `--force`** | Деструктивна: перезаписує remote history |
| PR creation | **Ні — потребує `--pr`** | Видима дія на GitHub (shared state) |
| `git reset --hard` | **Ні — DCG блокує** | Знищує uncommitted changes |

**Принцип:** fail-safe default — дозволяти все що локальне та зворотне.
Блокувати тільки те, що змінює shared state або незворотне. Confidence scores,
варіанти messages, scenario analysis — це інформація для audit trail, а не
блокери для агента.

### Свідомо відкладені архітектурні рішення

1. **Без `git add .` або `git add -A`** — завжди конкретні файли. Це повільніше але безпечніше. Перегляд продуктивності — v0.4.
2. **Без jq dependency** — JSON будується через printf. Якщо schema ускладниться в v0.2+, перехід на jq буде необхідний.
3. **Без паралельності** — v0.1 sequential only. Для десятків реп це може бути повільно, але коректно. Паралельність потребує lock management.
4. **Без push** — коміти тільки локальні. Push — окрема відповідальність (може бути `ru sync --push`).
5. **Без rollback всього sweep** — якщо 3 з 5 комітів успішні і 4-й впав, перші 3 залишаються. Повний rollback та `--revert-run` — v0.4.
6. **`M→fix` евристика неточна** — `cs_detect_commit_type()` маппить `M→fix`, але modified файл може бути feat/refactor/chore. Без LLM (v0.3) це найслабша ланка. Прийнятно для v0.1: `cs_assess_confidence()` має знижувати score для груп де всі файли — `M` без task ID. Перегляд у v0.3 (LLM commit messages).
7. **`--respect-staging` + `--execute` порядок груп** — "pre-staged" група виконується **першою**, auto-групи не мають overlap зі staged файлами.
8. **`print_fork_op_summary()` — fork-специфічна назва для reuse** — функція підходить для commit-sweep summary, але назва вводить в оману. Залишаємо як є в v0.1. Рефакторинг на `print_op_summary()` — v0.2 коли буде більше споживачів.

## Verification

```bash
# ShellCheck (warning+)
shellcheck -s bash -S warning ru

# Syntax checks
bash -n ru

# Unit тести
bash scripts/test_unit_commit_sweep.sh

# E2E тести
bash scripts/test_e2e_commit_sweep.sh

# Manual: dry-run на реальному dirty repo
ru commit-sweep owner/repo
ru commit-sweep owner/repo --json

# Manual: execute на тестовому repo
ru commit-sweep owner/repo --execute --verbose

# Full suite (має бути 97+ pass, +2 new suites)
bash scripts/run_all_tests.sh
```

## Upstream sync findings (2026-02-19)

26 upstream комітів (25d24f1..1552bac) проаналізовано на відповідність цьому плану.

### Критичні залежності

| Upstream коміт | Вплив на commit-sweep |
|---|---|
| `40b40b1` Normalize JSON envelope | **CRITICAL** — вводить `build_json_envelope()` (рядок 5137). commit-sweep МУСИТЬ використовувати цю функцію замість побудови власного envelope. Сигнатура: `build_json_envelope "commit-sweep" "$data_json" "$meta_json"` |
| `a7aa3d5` + `89f89f2` Fork arg parsing | Модифікують command recognition (рядок 8474) та додають routing паттерни для fork-специфічних прапорців. commit-sweep додається до того ж рядка |

### Паттерни для наслідування

| Upstream коміт | Паттерн |
|---|---|
| `a258cf9`+`fc4f0dc`+`b90c2b3` E2E migration | `test_e2e_commit_sweep.sh` МУСИТЬ source `test_e2e_framework.sh`, використовувати `e2e_setup`/`e2e_cleanup`/`assert_*`/`$E2E_RU_SCRIPT` |
| `ce5ac34` Unit test coverage | `test_unit_commit_sweep.sh` має використовувати `source_function()` + inline mini-framework |
| `1e0fa15`+`b90ad10` Fork E2E tests | Local bare repo як remote, helper функції `setup_*()` |
| `6b82479` HOME restore fix | Відновлювати HOME перед `rm -rf $TEMP_DIR` в тестах |
| `0ebe82d`+`10f504e` robot-docs | Додати commit-sweep schema/command/examples до robot-docs |

### Конфліктні зони

| Зона | Ризик | Примітка |
|---|---|---|
| Command recognition (рядок 8474) | Середній | Єдиний рядок куди всі команди додаються |
| `--dry-run` routing (рядок 8241) | Низький | Не змінений upstream |
| Dispatch table (рядок ~23826) | Низький | Чисте додавання перед `*)` |
| Section insertion | Низький | Після SECTION 13b (robot-docs, рядок 23144) |

### Висновок

Конфліктів немає. Upstream зміни **підтримують** план: `build_json_envelope()` тепер існує,
тест-фреймворки стандартизовані, robot-docs конвенція встановлена. Номери рядків перевірені
та актуальні для `feature/commit-sweep`.
