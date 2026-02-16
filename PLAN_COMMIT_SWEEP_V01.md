# Plan: `ru commit-sweep` v0.1 MVP

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
- `cs_detect_commit_type()` — git status codes → conventional commit type
- `cs_detect_scope()` — top-level directory як scope
- `cs_build_message()` — форматування conventional commit subject
- `cs_assess_confidence()` — scoring high/medium/low
- `cs_analyze_repo()` — оркестрація: git status → classify → group → JSON
- `cs_execute_group()` — safe git add + commit з per-group rollback

## Scope v0.1

**Робить:**
1. Сканує репо (всі або конкретну) на dirty worktrees
2. Групує змінені файли: source / test / docs / config
3. Генерує conventional commit messages з евристик (не LLM)
4. Витягує task ID з назви гілки (`feature/bd-XXXX`)
5. Виводить план комітів (JSON або human-readable)
6. Виконує план з `--execute` (default = dry-run для безпеки)

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
```

**F. Нова секція перед SECTION 14 (~рядок 23783):**

`SECTION 13.11: COMMIT SWEEP` — ~500 рядків з такими функціями:

| Функція | Призначення |
|---------|-------------|
| `cmd_commit_sweep()` | Головна команда: parse args → load repos → iterate → plan/execute |
| `cs_extract_task_id()` | Branch name → task ID (`feature/bd-4f2a` → `bd-4f2a`) |
| `cs_get_task_title()` | Task ID → title через `br show <id> --format json` з 3s timeout (graceful degradation). br повертає `[{title, status, priority, ...}]` — парсимо title через grep/sed (без jq) |
| `cs_analyze_repo()` | Ядро: git status → classify files → build groups |
| `cs_classify_file()` | Один файл → bucket (test/doc/config/source) |
| `cs_detect_commit_type()` | Git status codes (A/M/D/R) + bucket → feat/fix/test/docs/chore |
| `cs_detect_scope()` | Найчастіша top-level директорія серед файлів |
| `cs_build_message()` | type + scope + task_id → conventional commit subject |
| `cs_assess_confidence()` | task_id + file_count + mixed_statuses → high/medium/low |
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
1. Зібрати файли:
   - Якщо --respect-staging: тільки unstaged + untracked
   - Інакше: staged + unstaged + untracked (дедупліковано)
2. Для deleted files (D): зберегти шлях, позначити status=D
3. Для renamed files (R): використовувати NEW path, позначити status=R
4. Classify кожен файл → test / doc / config / source через cs_classify_file()
5. Для кожної непорожньої групи:
   - Визначити type з git status codes (A→feat, M→fix/refactor, D→chore, R→refactor)
   - Визначити scope (top-level directory)
   - Згенерувати message (з task_id якщо є)
   - Оцінити confidence (high/medium/low)
6. Якщо є manually staged files + --respect-staging:
   - Додати окрему групу "pre-staged" з цими файлами
7. Вивести JSON array of groups
```

### JSON output schema

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
        "confidence": "high"
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
    "exit_code": 0
  }
}
```

### `--execute` flow

1. Аналіз як у dry-run → groups array
2. Для кожної групи по порядку через `cs_execute_group()`:
   - `git add -- <file1> <file2>...` (конкретні файли, не `git add .`)
   - Для deleted files: `git rm --cached -- <file>` (якщо не staged)
   - Перевірити що staging не порожній: `git diff --cached --quiet && skip`
   - `git commit -m "<message>"`
   - При помилці: `git reset HEAD -- <file1> <file2>...` (тільки файли цієї групи)
   - Лог результату, продовжити до наступної групи

### Ключові рішення

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
- **Commit type з git status codes** — A→feat, M→fix, D→chore, R→refactor (надійніше
  ніж парсинг diff keywords)
- **`_meta` в JSON** — стандартний паттерн `ru` через `build_json_envelope()`
- **`file_statuses` в JSON** — кожен файл зі своїм git status code для прозорості
- **Per-group rollback** — `git reset HEAD -- <files>` тільки для файлів конкретної групи,
  не `git reset HEAD` яке зачепить файли інших груп

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

### 2. `scripts/test_unit_commit_sweep.sh` (новий файл)

Unit тести для cs_* helpers (~30 тестів):
- `cs_extract_task_id`: 6 кейсів (bd-XXXX, br-XXXX, no match, empty, nested/bd-XXXX)
- `cs_classify_file`: 8 кейсів (test/*, *_test.go, scripts/test_*, *.md, docs/*, .gitignore, *.yml, lib/foo.sh)
- `cs_detect_commit_type`: 5 кейсів (A→feat, M→fix, D→chore, R→refactor, mixed)
- `cs_detect_scope`: 4 кейси (lib/foo.sh→lib, scripts/test_x.sh→scripts, root file→root, empty)
- `cs_build_message`: 5 кейсів (з task_id, без, truncation >72 chars, no scope, special chars)
- `cs_assess_confidence`: 4 кейси (task_id+few files→high, no task_id→medium, many files→low, 1 file→high)

### 3. `scripts/test_e2e_commit_sweep.sh` (новий файл)

E2E тести з mock git repos (~10 сценаріїв):
1. Одна репа, один файл → 1 commit group
2. Source + test файли → 2 groups
3. Branch `feature/bd-XXXX` → task ID extraction
4. `--json` → validates JSON envelope keys (`generated_at`, `version`, `command`, `data`, `_meta`)
5. `--execute` → git log shows new commits, working tree clean after
6. Clean repo → skipped
7. Немає реп → clean exit
8. Deleted file → chore commit type, file removed
9. `--respect-staging` → manually staged files preserved in separate group
10. `--execute` rollback → якщо commit fails (simulate via bad hook), files unstaged per-group

## Що НЕ ввійшло в MVP v0.1 (roadmap)

### v0.2: Attribution та bv інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **bv correlation engine** | Зв'язування файлів з beads: зміни в `lib/session.sh` → `bd-4f2a` | `bv --robot-history` → `BeadEvent{BeadID, CommitSHA, Author, EventType}` через `pkg/correlation/extractor.go` |
| **agent-mail file reservations** | Визначення хто "володіє" файлами для attribution | `file_reservation_paths(project_key, agent, paths, ttl, exclusive)` → `{granted, conflicts}`. Query: `_collect_file_reservation_statuses()` з `app.py:3485` |
| **Multi-agent attribution** | Розділення комітів per-agent на основі file reservations | Glob matching через `fnmatchcase()` в `app.py:3712`. Конфлікт = `{path, holders: [agent_names]}` |
| **Co-Authored-By trailer** | `Co-Authored-By: <agent-name>` на основі agent-mail identity | Agent profile з `register_agent()` → `{name, program, model}` |
| **Sub-directory grouping** | Source bucket → під-групи по директоріях | — |

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
| **Pre-commit hooks** | `--no-verify` для пропуску git hooks (opt-in) | — |

### v0.5: Ecosystem інтеграція

| Фіча | Опис | Конкретний API з екосистеми |
|-------|------|---------------------------|
| **GitHub PR creation** | `--pr` після push створює PR з commit messages як body | `gh pr create` (DCG: PR creation=shared state, потребує `--pr` flag) |
| **Beads auto-close** | Commit закриває task → `br close bd-XXXX` автоматично | `br close <id> --reason "Completed"` + `br sync --flush-only` |
| **Audit trail** | Sweep log → agent-mail повідомлення з confidence scores | `send_message(project_key, sender, to, subject, body_md, thread_id)` |
| **Learning from history** | Покращення commit messages на основі минулих сесій | CASS: `cm context "commit patterns" --json` → `{relevantBullets, antiPatterns}` |
| **Config file** | `~/.config/ru/commit-sweep.yaml` для персистентних налаштувань | — |

### Наскрізний принцип: Human-in-the-Loop

**Рішення завжди приймає людина. LLM готує варіанти та аналіз розвитку подій.**

Цей принцип діє з v0.1 і масштабується з кожною версією:

| Версія | Що робить LLM | Що вирішує людина |
|--------|---------------|-------------------|
| **v0.1** | Групує файли, генерує commit messages, оцінює confidence | Перший запуск — dry-run (план). `--execute` дозволяє автономне виконання |
| **v0.2** | Визначає attribution, додає Co-Authored-By, закриває beads | Автономно. Агент сам вирішує attribution на основі file reservations |
| **v0.3** | Генерує commit messages через LLM, семантичне групування | Автономно. `--interactive` — opt-in для ручного втручання |
| **v0.4** | Parallel sweep, conflict resolution, push | Push потребує `--push`. Все інше автономно |
| **v0.5** | PR creation, audit trail | PR creation потребує `--pr`. Audit — автоматичний |

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
5. **Без rollback всього sweep** — якщо 3 з 5 комітів успішні і 4-й впав, перші 3 залишаються. Повний rollback — v0.5.

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

# Full suite (має бути 97+ pass, +2 new suites)
bash scripts/run_all_tests.sh
```
