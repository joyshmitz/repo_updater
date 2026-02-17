Нижче мій наступний раунд покращень саме **поверх** `PLAN_COMMIT_SWEEP_V01_cod2.md`.

## 1) Зробити документ канонічним (не “список доповнень”, а цілісний план)
**Аналіз:** зараз `cod2` — це перелік додаткових змін із вкладеними diff-блоками до іншого файлу. Це ускладнює реалізацію: виконавцю треба “зливати в голові” кілька поколінь плану.  
**Обґрунтування:** єдиний canonical-doc зменшує ризик пропустити критичну вимогу і прискорює імплементацію/рев’ю.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -1,3 +1,13 @@
-Нижче додаткові high-impact зміни саме до `PLAN_COMMIT_SWEEP_V01_cod.md` (поверх уже наявних 12).
+# PLAN_COMMIT_SWEEP_V01_cod2 — Converged Commit-Sweep Plan
+
+Цей документ є канонічним джерелом вимог для `ru commit-sweep`.
+Він замінює попередні ітерації (`..._cod.md`) і не вимагає читати інші файли
+для розуміння функціональності.
+
+## Цілі
+- Безпечне та відтворюване групування змін у атомарні коміти
+- Детермінованість plan/execute
+- Сильні guardrails для multi-agent середовища
```

## 2) Прибрати `master` з політики гілок (main-only policy)
**Аналіз:** у `cod2` є `main|master|release/*`, що суперечить правилам репозиторію (main-only).  
**Обґрунтування:** усуває нормативну суперечність і прибирає технічний борг у CLI/документації.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@
-3. Захист гілок за замовчуванням (`main`, `master`, `release/*`)
+3. Захист гілок за замовчуванням (`main`, `release/*`)
@@
-+- Блокувати `--execute` у `main|master|release/*` за замовчуванням
++- Блокувати `--execute` у `main|release/*` за замовчуванням
```

## 3) Явна state machine для run lifecycle
**Аналіз:** є resume/checkpoint, але немає формального автомата станів; через це легко отримати “напів-легальні” переходи (наприклад, `execute` після failed validate).  
**Обґрунтування:** явні стани роблять поведінку передбачуваною, спрощують відновлення і тестування.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,18 @@
+11. Run state machine (формальний lifecycle)
+Аналіз: без формальних переходів важко гарантувати коректний resume.
+Обґрунтування: FSM зменшує edge-case баги і робить crash recovery детермінованим.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 23) Run Lifecycle State Machine
++`initialized -> planned -> validated -> executing -> completed`
++`initialized|planned|executing -> interrupted`
++`validated|executing -> failed`
++Недопустимі переходи блокуються з exit code 4.
++State manifest: `${RU_STATE_DIR}/commit-sweep/<run_id>.json`
+```
```

## 4) Виконання через ізольований індекс (`GIT_INDEX_FILE`)
**Аналіз:** навіть із `--respect-staging` робота в “живому” index ризикує захопити зайві staged-hunks.  
**Обґрунтування:** isolated index дає майже транзакційний execute для кожної групи без псування поточного staging користувача.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,20 @@
+12. Isolated index execution model
+Аналіз: live index у multi-agent workflows має високий ризик side effects.
+Обґрунтування: `GIT_INDEX_FILE` ізолює staging групи та підвищує коректність комітів.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 24) Isolated Index для `cs_execute_group()`
++- На кожну групу створювати тимчасовий index (`GIT_INDEX_FILE`)
++- Stage/commit виконувати тільки в цьому index
++- Після коміту видаляти tmp index
++- Оригінальний index залишається незмінним (крім pre-staged групи за явним policy)
+```
```

## 5) Двофазна валідація плану: schema + semantic invariants
**Аналіз:** зараз є сильний JSON, але не зафіксовано перевірки цілісності (дублі файлів між групами, missing paths, конфлікти статусів).  
**Обґрунтування:** це прибирає цілий клас runtime-помилок до початку execute.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,21 @@
+13. План-валідатор перед execute
+Аналіз: schema-valid JSON може бути семантично некоректним.
+Обґрунтування: pre-exec semantic validation підвищує надійність і прогнозованість.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 25) Plan Validation Pipeline
++- `cs_validate_plan_schema()` — перевірка обов'язкових полів/типів
++- `cs_validate_plan_semantics()` — інваріанти:
++  - файл не може бути у двох auto-групах
++  - `D` має існувати в `HEAD` і бути відсутнім у working tree
++  - `R` має мати `old_path` і `new_path`
++  - група без файлів => invalid
++- При fail: exit code 4, execute не стартує
+```
```

## 6) Політика для `confidence` (машино-керована, не лише інформативна)
**Аналіз:** зараз confidence переважно informational. Для production-режиму потрібна policy-дія при `low`.  
**Обґрунтування:** дає контрольований баланс між автономністю і безпекою.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,19 @@
+14. Policy routing для low-confidence груп
+Аналіз: однакова поведінка для high/low confidence не оптимальна.
+Обґрунтування: policy flags дозволяють адаптувати strictness під CI чи локальний режим.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 26) Confidence Policy
++Новий прапорець: `--on-low-confidence=warn|skip|fail`
++- `warn` (default): виконувати і логувати попередження
++- `skip`: не комітити low-confidence групи
++- `fail`: перервати repo execute на першій low-confidence групі
+```
```

## 7) Безпечний rollback як окрема функція (`revert-run`), без hard reset
**Аналіз:** backup refs корисні, але manual rollback часто приводить до unsafe команд.  
**Обґрунтування:** `revert-run` через `git revert` дає безпечний, аудитовний шлях скасування без руйнування робочого дерева.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,22 @@
+15. Керований rollback: `--revert-run <run_id>`
+Аналіз: ручний rollback часто деструктивний і помилковий.
+Обґрунтування: `git revert` по журналу run_id безпечніший за reset-підходи.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 27) Run Revert Workflow
++- Зберігати `committed_shas` у run manifest
++- Додати команду `ru commit-sweep --revert-run <run_id>`
++- Реалізація: `git revert --no-edit <sha...>` у зворотному порядку
++- Без `git reset --hard`; rollback тільки через нові revert commits
+```
```

## 8) Точкові фільтри `--repos/--include-path/--exclude-path`
**Аналіз:** без path/repo filters інструмент менш практичний для великих монореп або часткових hotfix-сценаріїв.  
**Обґрунтування:** покращує UX і продуктивність, зменшує шум та помилкові автогрупи.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,20 @@
+16. Операторські фільтри для керованого sweep
+Аналіз: повний sweep не завжди доречний (частковий rollout, emergency fix).
+Обґрунтування: фільтри зменшують blast radius і прискорюють виконання.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 28) Filtering Controls
++Нові прапорці:
++- `--repos=PATTERN` (glob по repo id)
++- `--include-path=GLOB` (можна повторювати)
++- `--exclude-path=GLOB` (можна повторювати)
++Фільтри застосовуються до `cs_collect_changes_porcelain_z()` до групування.
+```
```

## 9) Додати performance budget і cache шар
**Аналіз:** є ідея parallel analyze, але без бюджетів/метрик складно контролювати деградацію.  
**Обґрунтування:** SLO + cache роблять продуктивність керованою, а не випадковою.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,20 @@
+17. Performance budget + lightweight caching
+Аналіз: без цілей часу важко оцінити “достатньо швидко”.
+Обґрунтування: budget-driven оптимізація допомагає тримати MVP responsive.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 29) Performance Targets
++- Ціль dry-run: P50 <= 1.5s/repo, P95 <= 4s/repo
++- Ціль execute overhead (без hooks): <= 20% від dry-run
++Cache:
++- memoize `cs_classify_file(path)` в межах run
++- memoize task title lookup для однакових `task_id`
+```
```

## 10) Chaos/robustness test pack (переривання, lock contention, drift race)
**Аналіз:** базові unit/e2e потрібні, але головні падіння в полі — це interrupt/race/lock contention.  
**Обґрунтування:** chaos-набір напряму підвищує стабільність в реальному multi-agent середовищі.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod2.md b/PLAN_COMMIT_SWEEP_V01_cod2.md
@@ -193,0 +194,22 @@
+18. Chaos/robustness тести для реальних збоїв
+Аналіз: поточна матриця ще слабо покриває аварійні сценарії.
+Обґрунтування: контрольовані fault-injection тести радикально знижують runtime-ризики.
+
+```diff
+diff --git a/PLAN_COMMIT_SWEEP_V01.md b/PLAN_COMMIT_SWEEP_V01.md
+@@
++## 30) Robustness Test Suite
++Додати e2e сценарії:
++- SIGINT під час execute -> коректний checkpoint + `--resume`
++- Stale lock recovery
++- Drift mismatch між `--save-plan` і `--execute-plan`
++- Hook timeout/failure з перевіркою часткового прогресу
++- Concurrent commit-sweep instances на одній репі (lock contention)
+```
```

Якщо потрібно, запишу це як `PLAN_COMMIT_SWEEP_V01_cod3.md` у тому ж форматі, як ви робили для `cod`/`cod2`.
