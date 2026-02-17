# Покращення плану `commit-sweep` (версія cod)

Нижче 12 змін, які найбільше піднімуть надійність, керованість і корисність `commit-sweep`.

## 1) Нормалізувати ідентифікатори задач (`br-*`) і прибрати hardcoded абсолютний шлях

**Аналіз:** зараз у плані змішані `bd-*`/`br-*` і абсолютний шлях macOS. Це створює неоднозначність у парсингу задач і робить документ непереносимим між середовищами.  
**Обґрунтування:** єдиний формат ID і repo-relative paths зменшують помилки інтеграції та спрощують підтримку.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-| **br** (beads_rust) | Task title за bead ID | v0.1 | `br show bd-XXXX --format json` → парсити `.[0].title` |
+| **br** (beads_rust) | Task title за bead ID | v0.1 | `br show br-123 --format json` → парсити `.[0].title` |
@@
-4. Витягує task ID з назви гілки (`feature/bd-XXXX`)
+4. Витягує task ID з назви гілки (`feature/br-123`, `fix/br-456`)
@@
-### 1. `/Users/sd/projects/joyshmitz/repo_updater/ru`
+### 1. `ru`
@@
-| `cs_extract_task_id()` | Branch name → task ID (`feature/bd-4f2a` → `bd-4f2a`) |
+| `cs_extract_task_id()` | Branch name → task ID (`feature/br-123` → `br-123`) |
```

## 2) Розбити ядро на чіткий pipeline замість “все в `cs_analyze_repo()`”

**Аналіз:** поточний дизайн занадто монолітний, складно тестувати і локалізувати баги.  
**Обґрунтування:** ізольовані етапи (collect/normalize/group/render/execute) покращують тестованість, дебаг і майбутню еволюцію.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-- `cs_analyze_repo()` — оркестрація: git status → classify → group → JSON
+- `cs_collect_changes_porcelain_z()` — один прохід `git status --porcelain=v1 -z`
+- `cs_normalize_changes()` — нормалізація у `{xy, old_path, path, staged, unstaged}`
+- `cs_group_changes()` — детерміноване групування
+- `cs_plan_repo()` — формує план репи (`groups`, `warnings`, `errors`)
+- `cs_render_repo_json()` — серіалізує план у JSON
+- `cs_analyze_repo()` — thin orchestrator над collect→group→render
```

## 3) Перейти на NUL-safe парсинг `git status` і коректну обробку rename/delete/conflicts

**Аналіз:** поточний опис не гарантує коректність для пробілів у файлах, rename-пар і unmerged paths.  
**Обґрунтування:** `--porcelain -z` прибирає клас помилок парсингу і різко підвищує стабільність.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-1. Зібрати файли:
-   - Якщо --respect-staging: тільки unstaged + untracked
-   - Інакше: staged + unstaged + untracked (дедупліковано)
-2. Для deleted files (D): зберегти шлях, позначити status=D
-3. Для renamed files (R): використовувати NEW path, позначити status=R
+1. Отримати зміни через `git -C "$repo" status --porcelain=v1 -z` (NUL-safe)
+2. Парсити `XY` статуси (`M`,`A`,`D`,`R`,`C`,`U`,`??`) зі staged/unstaged частиною окремо
+3. Для `D` зберігати `old_path`; для `R/C` зберігати `old_path` + `new_path`
+4. Якщо знайдено unmerged (`U*`/`*U`) — repo позначається `skipped_conflict`
```

## 4) Поліпшити grouping: “affinity rules” замість жорсткого 4-бакетного розриву

**Аналіз:** розділення `source` і `test` завжди у різні коміти часто ламає атомарність змін.  
**Обґрунтування:** прив’язка `test/docs/config` до того ж `scope` дає більш корисну історію і простіший `git bisect`.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-5. Для кожної непорожньої групи:
-   - Визначити type з git status codes (A→feat, M→fix/refactor, D→chore, R→refactor)
+5. Первинно класифікувати файли у buckets: source/test/docs/config
+6. Застосувати affinity rule: test/docs/config з тим самим `scope` приєднувати до source-групи
+7. Commit type визначати за `bucket + branch_prefix + status_mix`, а не тільки за A/M/D/R
+8. Для неоднозначних випадків ставити `type=chore` + `confidence=low` + `reason_codes`
```

## 5) Зробити execute flow fail-fast по репі з preflight + lock + backup ref

**Аналіз:** поточний flow може каскадно погіршити стан після першої помилки. Також відсутня ізоляція від паралельних процесів у тій самій репі.  
**Обґрунтування:** preflight + repo-lock + backup ref різко знижують ризик неконсистентних комітів.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-2. Для кожної групи по порядку через `cs_execute_group()`:
+2. Preflight перед execute:
+   - перевірити не-detached HEAD, відсутність merge/rebase/cherry-pick in-progress
+   - перевірити відсутність unmerged paths
+   - взяти repo lock (`dir_lock_acquire`) на час execute
+   - створити backup ref `refs/ru/commit-sweep/<run_id>/<repo>` -> HEAD
+3. Для кожної групи по порядку через `cs_execute_group()`:
@@
-   - Для deleted files: `git rm --cached -- <file>` (якщо не staged)
+   - Для deleted files: `git add -u -- <file>`
@@
-   - При помилці: `git reset HEAD -- <file1> <file2>...` (тільки файли цієї групи)
-   - Лог результату, продовжити до наступної групи
+   - При помилці: відкотити staged лише для файлів групи, repo позначити failed, зупинити цю репу (fail-fast)
+4. Звільнити lock; backup ref залишити для manual recovery
```

## 6) Формалізувати семантику `--respect-staging`, щоб не було дублювання/захоплення чужих змін

**Аналіз:** поточний опис не фіксує порядок і правила overlap між pre-staged та auto-групами.  
**Обґрунтування:** чіткий контракт опції робить поведінку передбачуваною в multi-agent режимі.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-    --respect-staging    Preserve manually staged files; only analyze unstaged/untracked
+    --respect-staging    Preserve manually staged files in a dedicated first group
@@
-6. Якщо є manually staged files + --respect-staging:
-   - Додати окрему групу "pre-staged" з цими файлами
+9. Якщо увімкнено `--respect-staging`:
+   - створити окрему групу `pre-staged` і виконувати її першою
+   - виключити ці файли з auto-груп
+   - при overlap staged/unstaged одного файлу додати warning у план
```

## 7) Додати “заморожений план”: `--save-plan` + `--execute-plan`

**Аналіз:** між dry-run і execute в активній репі можуть з’явитися нові зміни (особливо з багатьма агентами).  
**Обґрунтування:** execute за зафіксованим plan hash усуває гонки й робить результат відтворюваним.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-6. Виконує план з `--execute` (default = dry-run для безпеки)
+6. Виконує план з `--execute` (default = dry-run для безпеки)
+7. Підтримує freeze/rehydrate: `--save-plan <file>` і `--execute-plan <file>`
@@
 COMMIT-SWEEP OPTIONS:
     --execute            Actually create commits (default: dry-run/plan only)
+    --save-plan PATH     Save generated plan to file (with plan_hash)
+    --execute-plan PATH  Execute an existing plan file after integrity checks
```

## 8) Розширити JSON-контракт до стабільної схеми v1

**Аналіз:** поточний JSON не містить schema version, repo-level status/errors і machine-friendly причин рішень.  
**Обґрунтування:** це значно покращує інтеграцію з CI/ботами й аудит.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
   "data": {
+    "schema_version": "commit-sweep/v1",
     "repos": [{
+      "status": "planned",
+      "errors": [],
       "repo": "owner/project",
@@
       "groups": [{
+        "id": "g-001",
         "type": "fix",
@@
-        "confidence": "high"
+        "confidence": {"level": "high", "score": 0.92},
+        "reason_codes": ["scope=session", "status=M", "task_id=br-123"]
       }]
@@
-      "planned_commits": 3
+      "groups_planned": 3,
+      "groups_executed": 0,
+      "groups_failed": 0
@@
-    "exit_code": 0
+    "exit_code": 0,
+    "partial_failure": false
   }
 }
```

## 9) Закрити інтеграцію CLI повністю: help + `robot-docs` + schema docs

**Аналіз:** план покриває тільки dispatch/help; але в `ru` є окремий `robot-docs` контракт, який треба оновлювати синхронно.  
**Обґрунтування:** без цього автоматизація (`ru robot-docs`) буде відставати від реальної CLI.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
 **E. Help text — після рядка 5643, додати команду:**
@@
+**G. robot-docs integration (обов'язково):**
+- Оновити `_robot_docs_commands()` з новою командою `commit-sweep` і flags
+- Оновити `_robot_docs_examples()` прикладами dry-run/json/execute-plan
+- Оновити `_robot_docs_schemas()` схемою `commit-sweep` (`data_schema`)
```

## 10) Додати guardrails: denylist + binary/size policy вже у v0.1

**Аналіз:** без denylist є ризик автокоміту секретів або великих артефактів.  
**Обґрунтування:** reuse існуючих guardrail-функцій дає захист майже без додаткової складності.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
 ### Ключові рішення
@@
+- **Denylist enforcement** — перевикористати `is_file_denied()` / `filter_files_denylist()`; denylisted файли не потрапляють у auto-commit
+- **Binary/size guard** — binary або файли > configurable threshold позначати `skipped_large_or_binary`
@@
 ### Reuse existing ru functions
@@
+- `is_file_denied()` + `filter_files_denylist()` — guardrails проти секретів/артефактів
+- `dir_lock_acquire()` / `dir_lock_release()` — repo-level lock під час execute
```

## 11) Підсилити Verification обов’язковими quality gates (lint/syntax)

**Аналіз:** у плані є тільки нові тести і full suite; відсутні обов’язкові перевірки ShellCheck/syntax, критичні для Bash-проєкту.  
**Обґрунтування:** це ловить regressions до виконання E2E і робить релізний процес стабільнішим.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
 ## Verification
@@
+# Shell lint (warning+)
+shellcheck -s bash -S warning ru install.sh
+
+# Syntax checks
+bash -n ru
+bash -n install.sh
+for f in scripts/*.sh; do bash -n "$f"; done
+
 # Unit тести
 bash scripts/test_unit_commit_sweep.sh
@@
 # Full suite (має бути 97+ pass, +2 new suites)
 bash scripts/run_all_tests.sh
```

## 12) Вирівняти розділ Human-in-the-Loop з фактом “v0.1 без LLM”

**Аналіз:** зараз є внутрішня суперечність: `Scope v0.1` каже “без LLM”, а таблиця HITL каже що LLM вже групує і генерує messages у v0.1.  
**Обґрунтування:** усунення суперечності важливе для коректних очікувань і тест-плану.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
@@
-| Версія | Що робить LLM | Що вирішує людина |
+| Версія | Що робить система | Що вирішує людина |
@@
-| **v0.1** | Групує файли, генерує commit messages, оцінює confidence | Перший запуск — dry-run (план). `--execute` дозволяє автономне виконання |
+| **v0.1** | Евристичне групування + шаблонні conventional messages (без LLM) | Перший запуск — dry-run; людина вирішує чи запускати `--execute` |
@@
-| **v0.2** | Визначає attribution, додає Co-Authored-By, закриває beads | Автономно. Агент сам вирішує attribution на основі file reservations |
+| **v0.2** | Attribution rules + Co-Authored-By (без LLM) | Людина визначає політику attribution та auto-close |
```
