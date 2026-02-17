Нижче додаткові high-impact зміни саме до `PLAN_COMMIT_SWEEP_V01_cod.md` (поверх уже наявних 12).

1. Drift-safe execute через fingerprint стану репозиторію  
Аналіз: навіть із `--save-plan/--execute-plan` можливий drift між планом і виконанням (інші агенти, нові staged/unstaged зміни). Це головна причина “план валідний, але коміти вже не ті”.  
Обґрунтування: fingerprint (`HEAD` + index tree + porcelain hash) робить виконання відтворюваним і безпечним за замовчуванням.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,16 @@
+## 13) Drift-safe execute через fingerprint стану репозиторію
+
+**Аналіз:** між `--save-plan` і `--execute-plan` стан репи може змінитися.
+**Обґрунтування:** без перевірки drift команда може закомітити вже інший набір змін.
+
+**Додати в план:**
+- `cs_repo_fingerprint()` = `head_sha` + `index_tree_sha` + `porcelain_sha256`
+- Зберігати fingerprint у файлі плану
+- Перед `--execute-plan` повторно обчислювати fingerprint і блокувати виконання при mismatch
+- Опція винятку: `--allow-drift` (тільки explicit opt-in)
+```

2. Детермінований planner (стабільний порядок груп/файлів/ID)  
Аналіз: без суворого порядку один і той самий стан може дати різний план (особливо з асоціативними структурами/різним порядком обходу).  
Обґрунтування: детермінізм знижує flaky-тести і робить `--save-plan` корисним для CI.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,18 @@
+## 14) Детермінований planner і стабільні group IDs
+
+**Аналіз:** недетермінований порядок породжує різні commit-плани при однаковому diff.
+**Обґрунтування:** стабільний порядок = повторюваність, простіші тести, менше surprise.
+
+**Додати в план:**
+- Сортування repo list, files і groups перед рендерингом JSON
+- Явний порядок bucket-ів: `source -> test -> docs -> config -> pre-staged`
+- Стабільний `group_id`: `<repo>:<bucket>:<scope>:<seq>`
+- Заборонити генерацію message до етапу після сортування
+```

3. Захист гілок за замовчуванням (`main`, `master`, `release/*`)  
Аналіз: команда спеціально “комітить все підряд”, отже ризик прямого коміту в protected branches високий.  
Обґрунтування: deny-by-default на protected branches прибирає найнебезпечніший людський/агентний фейл.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,15 @@
+## 15) Protected-branch guard у v0.1
+
+**Аналіз:** прямі локальні коміти в `main`/`master` часто стають джерелом інцидентів.
+**Обґрунтування:** safe default з explicit override зменшує аварійні коміти.
+
+**Додати в план:**
+- Блокувати `--execute` у `main|master|release/*` за замовчуванням
+- Новий прапорець: `--allow-protected-branch`
+- У JSON додати `branch_protection: blocked|overridden|not_applicable`
+```

4. Опційний `jq` fast-path для `br show` парсингу (fallback без `jq`)  
Аналіз: regex/sed-парсинг JSON ламкий (escaped символи, неочікуваний формат).  
Обґрунтування: optional `jq` дає надійність там, де доступний, без жорсткої залежності.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,16 @@
+## 16) Надійний парсинг `br show`: optional `jq` + fallback
+
+**Аналіз:** парсинг `br show ... --format json` через grep/sed крихкий.
+**Обґрунтування:** `jq` fast-path підвищує стабільність без порушення принципу "без hard dependency".
+
+**Додати в план:**
+- Якщо `jq` доступний: `jq -r '.[0].title // ""'`
+- Якщо `jq` відсутній: поточний sed/grep fallback
+- Логувати `parse_mode: jq|fallback` у verbose для дебагу
+```

5. Parallel analyze / sequential execute  
Аналіз: повна заборона паралельності до v0.4 робить dry-run повільним на великих наборах repo, хоча аналіз безпечний для паралелювання.  
Обґрунтування: гібрид дає продуктивність без ризику гонок у commit-фазі.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,17 @@
+## 17) Безпечна продуктивність: parallel analyze, sequential execute
+
+**Аналіз:** більшість часу у dry-run витрачається на read-only аналіз.
+**Обґрунтування:** паралельний analyze пришвидшує 60+ repo без підвищення write-ризиків.
+
+**Додати в план:**
+- Новий прапорець: `--parallel-analyze=N` (тільки для plan phase)
+- `--execute` завжди послідовний у v0.1
+- Окремо зазначити lock policy лише для execute phase
+```

6. Мінімальний resume/checkpoint уже в MVP  
Аналіз: при падінні на 40-й репі команда починає з нуля; це дорого і нестабільно.  
Обґрунтування: простий state-файл з repo/group progression різко підвищує практичну надійність.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,19 @@
+## 18) Resume/checkpoint у v0.1 (мінімальна версія)
+
+**Аналіз:** довгі sweep-сесії без checkpoint погано відновлюються після interrupt.
+**Обґрунтування:** навіть простий resume значно знижує операційні втрати.
+
+**Додати в план:**
+- State file: `${RU_STATE_DIR}/commit-sweep/<run_id>.json`
+- Поля: `repos_total`, `repo_idx`, `group_idx`, `last_success_commit`
+- Прапорці: `--resume`, `--restart`
+- Якщо fingerprint змінився під час resume — пропуск репи з warning
+```

7. Конфігурація правил у v0.1 (не переносити на v0.5)  
Аналіз: жорстко вшиті правила класифікації погано масштабуються між проєктами (різні тест-патерни, docs layout, config naming).  
Обґрунтування: мінімальний конфіг уже в MVP зменшує false grouping і підвищує корисність інструмента.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,18 @@
+## 19) Мінімальний config file у v0.1
+
+**Аналіз:** fixed евристики класифікації неминуче помиляються в частині реп.
+**Обґрунтування:** конфіг з override-правилами робить команду придатною для реального mixed-портфеля.
+
+**Додати в план:**
+- `~/.config/ru/commit-sweep.conf` (shell key=value)
+- Параметри: `PROTECTED_BRANCHES`, `MAX_FILES_PER_GROUP`, `TEST_PATTERNS`, `DOC_PATTERNS`, `CONFIG_PATTERNS`
+- Repo-local override: `.ru/commit-sweep.conf`
+```

8. Якість commit message: subject lint + структурований body  
Аналіз: навіть з правильною групою слабкі повідомлення знижують цінність історії.  
Обґрунтування: прості policy-правила підвищують читабельність без LLM.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,20 @@
+## 20) Політика якості commit messages без LLM
+
+**Аналіз:** лише subject недостатній для довгострокової підтримки.
+**Обґрунтування:** стандартизований body додає контекст "чому", а не тільки "що".
+
+**Додати в план:**
+- Subject lint: <=72 символів, conventional формат, без trailing period
+- Body template:
+  `Why:` причина
+  `What:` коротко зміни
+  `Risk:` вплив/ризик
+- Прапорець `--strict-message-lint` (fail group при порушенні)
+```

9. Спостережуваність: NDJSON run-log і причина кожного skip/fail  
Аналіз: без структурованого логу складно розбирати інциденти і регресії евристик.  
Обґрунтування: event log робить систему вимірюваною та придатною для подальшого тюнінгу.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,18 @@
+## 21) Observability: структурований run-log
+
+**Аналіз:** stderr-логи не дають стабільного інтерфейсу для аналітики.
+**Обґрунтування:** NDJSON дозволяє швидко будувати метрики й root-cause аналіз.
+
+**Додати в план:**
+- Лог: `${RU_STATE_DIR}/logs/YYYY-MM-DD/commit-sweep.ndjson`
+- Event schema: `repo_start`, `group_planned`, `group_committed`, `group_failed`, `repo_skipped`
+- Поля: `run_id`, `repo`, `group_id`, `reason_code`, `duration_ms`
+```

10. Розширити тест-матрицю edge-cases і race-сценаріями  
Аналіз: поточні тести покривають базові сценарії, але не найболючіші реальні кейси (rename with spaces, submodule, unmerged, staged-hunks).  
Обґрунтування: ці кейси найчастіше ламають Bash-автоматизацію; раннє покриття суттєво підвищує стабільність.

```diff
diff --git a/PLAN_COMMIT_SWEEP_V01_cod.md b/PLAN_COMMIT_SWEEP_V01_cod.md
@@ -252,0 +253,22 @@
+## 22) Розширена тест-матриця для надійності
+
+**Аналіз:** критичні edge-cases поки не формалізовані в плані тестування.
+**Обґрунтування:** ці тести зменшують ризик поломок у multi-agent і cross-platform середовищі.
+
+**Додати в план тестів:**
+- Файли з пробілами/табами в імені
+- Rename + modify в одному sweep
+- `U*` conflict status -> коректний skip
+- Submodule changes (gitlink) -> не комітити автоматично
+- Частково staged hunk + `--respect-staging`
+- Hook failure + resume continuation
+- Parallel analyze race simulation (дві зміни стану між plan/execute)
+```

Якщо хочете, наступним кроком зроблю одну консолідовану “готову до вставки” версію `PLAN_COMMIT_SWEEP_V01_cod.md` з цими 10 доповненнями в правильних місцях документа.
