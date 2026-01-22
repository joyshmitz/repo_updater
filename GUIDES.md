# 🇺🇦 RU (Repo Updater) - Повний практичний посібник

> **Результати глибокого дослідження можливостей ru утиліти**
> *Створено на основі практичного тестування та аналізу архітектури*

## 📚 Зміст

1. [Швидкий старт](#швидкий-старт)
2. [Основні команди](#основні-команди)
3. [Варіанти використання](#варіанти-використання)
4. [Побудова ланцюгів команд](#побудова-ланцюгів-команд)
5. [Автоматизація та scripting](#автоматизація-та-scripting)
6. [Розв'язання проблем](#розвязання-проблем)
7. [Інтеграція з екосистемою](#інтеграція-з-екосистемою)
8. [Advanced workflows](#advanced-workflows)
9. [Налагодження та діагностика](#налагодження-та-діагностика)
10. [Best practices](#best-practices)

---

## 🚀 Швидкий старт

### Перша настройка
```bash
# Ініціалізація конфігурації
ru init --example

# Додавання репозиторіїв
ru add власник/репозиторій
ru add власник/репозиторій@develop        # конкретна гілка
ru add власник/репозиторій as моя-назва    # кастомна назва

# Перша синхронізація
ru sync
```

### Щоденне використання
```bash
# Швидка перевірка стану
ru status

# Синхронізація з автоматичним stash
ru sync --autostash

# Паралельна синхронізація (швидше)
ru sync -j4
```

---

## 🎯 Основні команди

### Керування репозиторіями
```bash
# === ДОДАВАННЯ ===
ru add microsoft/terminal                    # Базове додавання
ru add rust-lang/cargo@main                  # Конкретна гілка
ru add neovim/neovim as nvim                 # Кастомна назва
ru add --from-cwd                            # З поточної директорії
ru add sxyazi/yazi --private                 # До приватного списку

# === ІМПОРТ ===
echo "microsoft/terminal
rust-lang/cargo
neovim/neovim@master" > repos.txt
ru import repos.txt --dry-run                # Попередній перегляд
ru import repos.txt                          # Імпорт списку

# === ВИДАЛЕННЯ ===
ru remove власник/репозиторій
ru list | grep pattern | xargs ru remove    # Масове видалення
```

### Синхронізація
```bash
# === БАЗОВА СИНХРОНІЗАЦІЯ ===
ru sync                                      # Стандартна синхронізація
ru sync --dry-run                           # Показати що буде зроблено
ru sync --verbose                           # Детальний вивід

# === СТРАТЕГІЇ ОНОВЛЕННЯ ===
ru sync --autostash                         # Безпечна обробка змін
ru sync --rebase                           # Rebase замість merge
ru sync --pull-only                        # Тільки pull, без clone
ru sync --clone-only                       # Тільки clone нових

# === ПРОДУКТИВНІСТЬ ===
ru sync -j8                                # 8 паралельних потоків
ru sync --timeout 60                       # Таймаут 60 секунд
ru sync --resume                           # Продовжити перерваний sync
```

### Моніторинг та діагностика
```bash
# === СТАТУС ===
ru status                                  # Стан репозиторіїв
ru status --json                          # JSON для автоматизації
ru status --no-fetch                      # Без оновлення з remote
ru status --fetch                         # З оновленням (по замовчуванню)

# === АНАЛІЗ ===
ru list --paths                           # Показати локальні шляхи
ru list --public                          # Тільки публічні
ru list --private                         # Тільки приватні
ru prune                                  # Знайти "сироти" репозиторії
ru prune --archive                        # Архівувати сироти
```

---

## 💡 Варіанти використання

### 1. 👨‍💻 **Розробник з багатьма проєктами**
```bash
# Щоранкова синхронізація всіх проєктів
ru sync -j4 --autostash

# Перевірка які проєкти потребують уваги
ru status | grep -E "(dirty|behind|diverged)"

# Швидке додавання нового проєкту
cd /path/to/new/project
ru add --from-cwd
```

### 2. 🏢 **Team Lead / DevOps**
```bash
# Клонування всіх проєктів команди
cat team-repos.txt | xargs -I {} ru add {}

# Масова перевірка стану всіх проєктів
ru status --json | jq '.[] | select(.dirty == true) | .repo'

# Пошук проблемних репозиторіїв
ru status --json | jq '.[] | select(.status != "current")'
```

### 3. 🔬 **Дослідник / Аналітик**
```bash
# Клонування цікавих open-source проєктів
ru add torvalds/linux
ru add microsoft/vscode
ru add facebook/react

# Регулярне оновлення для відстеження змін
ru sync --pull-only -j8

# Пошук нових features через git log
ru list --paths | while read repo; do
  echo "=== $repo ==="
  git -C "$repo" log --since="1 week ago" --oneline
done
```

### 4. 🎓 **Студент / Навчання**
```bash
# Колекція навчальних матеріалів
ru add awesome-lists/awesome
ru add github/gitignore
ru add microsoft/TypeScript

# Створення власних категорій
ru add student-project-1 --private
ru add coursework-repo --private

# Backup всіх навчальних проєктів
ru sync --pull-only
```

---

## ⛓️ Побудова ланцюгів команд

### Аналітичні ланцюги
```bash
# === ПОШУК DIRTY REPOS ===
# Знайти всі репозиторії з незбереженими змінами
ru status --json | jq -r '.[] | select(.dirty == true) | .repo'

# Показати шлях до dirty repos
ru status --json | jq -r '.[] | select(.dirty == true) | .path'

# Детальна інформація про dirty repos
ru status --json | jq '.[] | select(.dirty == true) | {repo, path, branch, ahead, behind}'

# === АНАЛІЗ КОНФЛІКТІВ ===
# Знайти репозиторії що потребують merge/rebase
ru status --json | jq -r '.[] | select(.status == "diverged") | .repo'

# Статистика по статусам
ru status --json | jq 'group_by(.status) | map({status: .[0].status, count: length})'

# === ПРОДУКТИВНІСТЬ ===
# Виміряти час синхронізації
time ru sync -j4 --dry-run

# Порівняння serial vs parallel
time ru sync --dry-run          # Serial
time ru sync -j4 --dry-run      # Parallel
```

### Operational ланцюги
```bash
# === AUTOMATED WORKFLOW ===
#!/bin/bash
# daily-sync.sh - Щоденна синхронізація з звітністю

echo "🌅 Початок щоденної синхронізації..."
start_time=$(date +%s)

# Синхронізація з автоматичним stash
if ru sync -j4 --autostash; then
  echo "✅ Синхронізація успішна"
else
  echo "⚠️ Синхронізація з помилками"
  ru status | grep -E "(conflict|dirty|diverged)"
fi

# Звіт про orphan repos
orphans=$(ru prune 2>/dev/null | wc -l)
if [ "$orphans" -gt 0 ]; then
  echo "📁 Знайдено $orphans orphan repositories"
  ru prune
fi

end_time=$(date +%s)
echo "⏱️ Час виконання: $((end_time - start_time)) секунд"

# === MAINTENANCE WORKFLOW ===
#!/bin/bash
# weekly-maintenance.sh

# Архівування orphan repos
ru prune --archive

# Перевірка конфігурації
ru doctor

# Cleanup старих логів
find ~/.local/state/ru/logs -type f -mtime +30 -delete

# Self-update check
ru self-update --check
```

### Git integration ланцюги
```bash
# === CROSS-REPO GIT OPERATIONS ===
# Знайти всі repos на конкретній гілці
ru status --json | jq -r '.[] | select(.branch == "develop") | .path'

# Виконати git команду для всіх repos
ru list --paths | xargs -I {} git -C {} status --porcelain

# Знайти repos з uncommitted changes
ru list --paths | while read repo; do
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    echo "Dirty: $repo"
    git -C "$repo" status --short
  fi
done

# === BULK OPERATIONS ===
# Створити feature branch у всіх repos
ru list --paths | xargs -I {} git -C {} checkout -b feature/new-feature

# Commit changes у всіх dirty repos
ru status --json | jq -r '.[] | select(.dirty == true) | .path' | \
  xargs -I {} sh -c 'cd "{}" && git add . && git commit -m "Bulk update"'
```

---

## 🤖 Автоматизація та Scripting

### JSON API для автоматизації
```bash
# === STRUCTURED DATA ===
# Отримати список всіх repos у JSON
ru status --json > repos-status.json

# Фільтрувати за критеріями
jq '.[] | select(.ahead > 0)' repos-status.json    # Repos ahead of remote
jq '.[] | select(.behind > 0)' repos-status.json   # Repos behind remote
jq '.[] | select(.dirty == true)' repos-status.json # Dirty repos

# === SCRIPTING EXAMPLES ===
#!/bin/bash
# check-repos.sh - Automated repo health check

STATUS=$(ru status --json)

# Count repos by status
current=$(echo "$STATUS" | jq '[.[] | select(.status == "current")] | length')
behind=$(echo "$STATUS" | jq '[.[] | select(.status == "behind")] | length')
dirty=$(echo "$STATUS" | jq '[.[] | select(.dirty == true)] | length')

echo "📊 Repo Health Report:"
echo "   ✅ Current: $current"
echo "   📥 Behind:  $behind"
echo "   📝 Dirty:   $dirty"

# Alert if problems found
if [ "$behind" -gt 0 ] || [ "$dirty" -gt 0 ]; then
  echo "⚠️  Action required!"
  exit 1
fi
```

### CI/CD Integration
```yaml
# .github/workflows/repo-sync.yml
name: Daily Repo Sync
on:
  schedule:
    - cron: '0 9 * * *'  # 9 AM daily

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Install ru
        run: curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/repo_updater/main/install.sh | bash

      - name: Configure ru
        run: |
          ru init
          echo "${{ secrets.REPO_LIST }}" > ~/.config/ru/repos.d/public.txt

      - name: Sync repos
        run: ru sync --json > sync-results.json

      - name: Generate report
        run: |
          jq -r '.summary | "Synced: \(.updated + .cloned) repos, \(.conflicts) conflicts"' sync-results.json
```

### Monitoring Integration
```bash
# === PROMETHEUS METRICS ===
#!/bin/bash
# ru-metrics.sh - Export metrics for monitoring

STATUS=$(ru status --json)

echo "# HELP ru_repos_total Total number of configured repos"
echo "# TYPE ru_repos_total gauge"
echo "ru_repos_total $(echo "$STATUS" | jq 'length')"

echo "# HELP ru_repos_dirty Number of repos with uncommitted changes"
echo "# TYPE ru_repos_dirty gauge"
echo "ru_repos_dirty $(echo "$STATUS" | jq '[.[] | select(.dirty == true)] | length')"

echo "# HELP ru_repos_behind Number of repos behind remote"
echo "# TYPE ru_repos_behind gauge"
echo "ru_repos_behind $(echo "$STATUS" | jq '[.[] | select(.behind > 0)] | length')"
```

---

## 🔧 Розв'язання проблем

### Типові проблеми та рішення
```bash
# === DIRTY REPOS ===
# Проблема: репозиторій має uncommitted changes
ru status | grep dirty

# Рішення 1: Automatic stash
ru sync --autostash

# Рішення 2: Manual commit
cd /path/to/dirty/repo
git add .
git commit -m "WIP: temporary commit"
ru sync

# Рішення 3: Stash manually
cd /path/to/dirty/repo
git stash push -m "Before ru sync"
ru sync
git stash pop

# === DIVERGED REPOS ===
# Проблема: local та remote розійшлися
ru status | grep diverged

# Рішення 1: Rebase (recommended)
ru sync --rebase

# Рішення 2: Force update (DANGEROUS)
cd /path/to/diverged/repo
git reset --hard origin/main  # ВТРАТА ЛОКАЛЬНИХ ЗМІН!

# === AUTHENTICATION ISSUES ===
# Проблема: git authentication failed
ru doctor  # Перевірити gh CLI status

# Рішення: Re-authenticate
gh auth login
gh auth status

# === NETWORK ISSUES ===
# Проблема: timeout при синхронізації
ru sync --timeout 120  # Збільшити timeout

# Рішення: Послідовна синхронізація замість паралельної
ru sync -j1  # Single thread
```

### Debug та діагностика
```bash
# === VERBOSE MODE ===
ru sync --verbose                 # Детальний вивід
ru status --verbose              # Додаткова інформація

# === CONFIGURATION DEBUG ===
ru config --print               # Показати всю конфігурацію
ru doctor                       # Системна діагностика
ru doctor --review              # Включно з review prerequisites

# === LOG ANALYSIS ===
# Знайти останні логи
find ~/.local/state/ru/logs -name "*.log" -mtime -1

# Аналіз помилок
grep -r "ERROR\|FAILED" ~/.local/state/ru/logs/

# Статистика синхронізації
tail -f ~/.local/state/ru/logs/latest/ru.log
```

---

## 🌐 Інтеграція з екосистемою

### Інтеграція з NTM (Named Tmux Manager)
```bash
# === AI-POWERED WORKFLOWS ===
# Створити AI session для проєкту
cd /path/to/project
ntm spawn project-work --cc=2

# Використати ru з NTM
ru agent-sweep --dry-run         # Показати кандидатів для AI обробки
ru review --dry-run              # Показати issues для AI огляду

# === SESSION MANAGEMENT ===
# Комбіновані workflows
ntm spawn multi-repo --cc=3
ru sync -j4                      # Синхронізувати в background
# AI agents працюють у tmux panes
```

### Інтеграція з BD (Beads Daemon)
```bash
# === ISSUE TRACKING ===
# Створити bead для repo maintenance
bd create "Sync all repos" --type task --priority 2

# Відмітити completion після синхронізації
ru sync && bd close bead-id "Repos synced successfully"

# === WORKFLOW AUTOMATION ===
# Створювати beads для кожної проблеми
ru status --json | jq -r '.[] | select(.status != "current") | .repo' | \
  while read repo; do
    bd create "Fix $repo conflicts" --type bug --priority 1
  done
```

### Інтеграція з CASS (Coding Agent Session Search)
```bash
# === HISTORICAL ANALYSIS ===
# Шукати past sessions по repo problems
cass search "git conflict resolution"
cass search "repository synchronization issues"

# === KNOWLEDGE BASE ===
# Індексувати ru logs для майбутнього пошуку
cass index ~/.local/state/ru/logs/
```

### Інтеграція з BV (Beads Viewer)
```bash
# === DEPENDENCY VISUALIZATION ===
# Створити граф залежностей для repo maintenance
bv --graph repo-dependencies.json

# === PROJECT TRACKING ===
# Track ru maintenance як beads project
bv --project ru-maintenance
```

---

## 🚀 Advanced Workflows

### Multi-environment Management
```bash
# === ENVIRONMENT SEPARATION ===
# Development environment
export RU_PROJECTS_DIR="$HOME/dev"
ru init
ru sync

# Production environment
export RU_PROJECTS_DIR="/data/production"
ru init
ru sync

# === PROFILE SWITCHING ===
#!/bin/bash
# ru-profile.sh - Switch between different ru profiles

case "$1" in
  dev)
    export RU_PROJECTS_DIR="$HOME/development"
    export RU_CONFIG_DIR="$HOME/.config/ru-dev"
    ;;
  prod)
    export RU_PROJECTS_DIR="/data/production"
    export RU_CONFIG_DIR="$HOME/.config/ru-prod"
    ;;
  personal)
    export RU_PROJECTS_DIR="$HOME/personal-projects"
    export RU_CONFIG_DIR="$HOME/.config/ru-personal"
    ;;
esac

echo "Switched to $1 profile"
ru status
```

### Automated Quality Gates
```bash
# === PRE-SYNC VALIDATION ===
#!/bin/bash
# pre-sync-checks.sh

echo "🔍 Running pre-sync validation..."

# Check disk space
available=$(df /data/projects | awk 'NR==2 {print $4}')
if [ "$available" -lt 1000000 ]; then  # Less than 1GB
  echo "❌ Insufficient disk space"
  exit 1
fi

# Check network connectivity
if ! ping -c 1 github.com >/dev/null 2>&1; then
  echo "❌ No network connectivity to GitHub"
  exit 1
fi

# Check authentication
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ GitHub authentication required"
  exit 1
fi

echo "✅ Pre-sync checks passed"

# === POST-SYNC VALIDATION ===
#!/bin/bash
# post-sync-validation.sh

echo "🔍 Running post-sync validation..."

# Check for any remaining conflicts
conflicts=$(ru status --json | jq '[.[] | select(.status == "diverged")] | length')
if [ "$conflicts" -gt 0 ]; then
  echo "⚠️  $conflicts repositories still have conflicts"
  ru status --json | jq -r '.[] | select(.status == "diverged") | .repo'
fi

# Verify all expected repos are present
expected=$(wc -l < ~/.config/ru/repos.d/public.txt)
actual=$(ru list | wc -l)
if [ "$actual" -ne "$expected" ]; then
  echo "⚠️  Expected $expected repos, found $actual"
fi

echo "✅ Post-sync validation complete"
```

### Custom Sync Strategies
```bash
# === SELECTIVE SYNC ===
#!/bin/bash
# selective-sync.sh - Sync only specific categories

# High-priority repos first
ru status --json | jq -r '.[] | select(.repo | startswith("critical/")) | .repo' | \
  while read repo; do
    echo "Syncing critical: $repo"
    ru sync "$repo"
  done

# Background sync for others
ru status --json | jq -r '.[] | select(.repo | startswith("critical/") | not) | .repo' | \
  xargs -P 4 -I {} ru sync {}

# === CONDITIONAL SYNC ===
#!/bin/bash
# smart-sync.sh - Sync based on conditions

current_hour=$(date +%H)

if [ "$current_hour" -lt 9 ] || [ "$current_hour" -gt 17 ]; then
  # Off-hours: full parallel sync
  echo "🌙 Off-hours: full sync with maximum parallelism"
  ru sync -j8 --timeout 60
else
  # Work hours: gentle sync
  echo "🌅 Work hours: gentle sync"
  ru sync -j2 --timeout 30
fi
```

---

## 🔧 Налагодження та діагностика

### System Health Monitoring
```bash
# === COMPREHENSIVE HEALTH CHECK ===
#!/bin/bash
# ru-health-check.sh

echo "🏥 RU Health Check Report"
echo "========================"

# System information
echo "📋 System Info:"
echo "   RU Version: $(ru --version)"
echo "   Git Version: $(git --version)"
echo "   GH Version: $(gh --version | head -1)"

# Configuration status
echo ""
echo "⚙️  Configuration:"
ru config --print

# Repository statistics
echo ""
echo "📊 Repository Statistics:"
status_json=$(ru status --json)
total=$(echo "$status_json" | jq 'length')
current=$(echo "$status_json" | jq '[.[] | select(.status == "current")] | length')
behind=$(echo "$status_json" | jq '[.[] | select(.status == "behind")] | length')
dirty=$(echo "$status_json" | jq '[.[] | select(.dirty == true)] | length')

echo "   Total repos: $total"
echo "   Current: $current"
echo "   Behind: $behind"
echo "   Dirty: $dirty"

# Disk usage
echo ""
echo "💾 Disk Usage:"
du -sh $(ru config --print | grep PROJECTS_DIR | cut -d'=' -f2)

# Recent activity
echo ""
echo "📝 Recent Activity:"
if [ -f ~/.local/state/ru/logs/latest/ru.log ]; then
  echo "   Last sync: $(stat -c %y ~/.local/state/ru/logs/latest/ru.log)"
  echo "   Recent errors: $(grep -c ERROR ~/.local/state/ru/logs/latest/ru.log 2>/dev/null || echo 0)"
fi

# === PERFORMANCE ANALYSIS ===
#!/bin/bash
# ru-performance.sh

echo "⚡ RU Performance Analysis"
echo "=========================="

# Benchmark sync speed
echo "🏃 Sync Performance Test:"
echo "   Serial sync:"
time ru sync --dry-run 2>&1 | grep "processed in"

echo "   Parallel sync (4 workers):"
time ru sync -j4 --dry-run 2>&1 | grep "processed in"

echo "   Parallel sync (8 workers):"
time ru sync -j8 --dry-run 2>&1 | grep "processed in"

# Repository size analysis
echo ""
echo "📏 Repository Sizes:"
ru list --paths | while read repo; do
  size=$(du -sh "$repo" 2>/dev/null | cut -f1)
  echo "   $(basename "$repo"): $size"
done | sort -k2 -hr | head -10
```

### Troubleshooting Automation
```bash
# === AUTOMATED ISSUE DETECTION ===
#!/bin/bash
# ru-doctor-plus.sh - Enhanced diagnostics

echo "🩺 Enhanced RU Diagnostics"
echo "========================="

# Run standard doctor
ru doctor

echo ""
echo "🔍 Additional Checks:"

# Check for common issues
echo "   Checking authentication..."
if gh auth status >/dev/null 2>&1; then
  echo "   ✅ GitHub authentication OK"
else
  echo "   ❌ GitHub authentication required: run 'gh auth login'"
fi

echo "   Checking network connectivity..."
if curl -s --connect-timeout 5 https://api.github.com >/dev/null; then
  echo "   ✅ GitHub API accessible"
else
  echo "   ❌ GitHub API not accessible"
fi

echo "   Checking disk space..."
projects_dir=$(ru config --print | grep PROJECTS_DIR | cut -d'=' -f2)
available=$(df "$projects_dir" | awk 'NR==2 {print $4}')
if [ "$available" -gt 1000000 ]; then
  echo "   ✅ Sufficient disk space ($(($available / 1024))MB available)"
else
  echo "   ⚠️  Low disk space ($(($available / 1024))MB available)"
fi

# Check for problematic repos
echo "   Checking repository states..."
problematic=$(ru status --json | jq '[.[] | select(.status != "current" or .dirty == true)] | length')
if [ "$problematic" -eq 0 ]; then
  echo "   ✅ All repositories in good state"
else
  echo "   ⚠️  $problematic repositories need attention"
  ru status --json | jq -r '.[] | select(.status != "current" or .dirty == true) | "      - \(.repo): \(.status)\(if .dirty then " (dirty)" else "" end)"'
fi

# === LOG ANALYSIS AUTOMATION ===
#!/bin/bash
# analyze-ru-logs.sh

echo "📜 RU Log Analysis"
echo "=================="

log_dir="$HOME/.local/state/ru/logs"
if [ ! -d "$log_dir" ]; then
  echo "No logs found"
  exit 0
fi

echo "📊 Error Summary (last 7 days):"
find "$log_dir" -name "*.log" -mtime -7 | xargs grep -h "ERROR\|FAILED" | \
  sort | uniq -c | sort -rn | head -10

echo ""
echo "📈 Sync Performance (last 7 days):"
find "$log_dir" -name "*.log" -mtime -7 | xargs grep -h "processed in" | \
  sed 's/.*processed in \([0-9]\+\)s.*/\1/' | \
  awk '{sum+=$1; count++} END {if(count>0) print "   Average sync time: " sum/count "s"}'

echo ""
echo "🔄 Most Active Repositories:"
find "$log_dir" -name "*.log" -mtime -7 | xargs grep -h "Updated:\|Cloned:" | \
  awk '{print $2}' | sort | uniq -c | sort -rn | head -10
```

---

## 💎 Best Practices

### 1. 🏗️ **Організація репозиторіїв**
```bash
# === СТРУКТУРУВАННЯ ===
# Використовуйте осмислені імена та категорії
ru add work-project/frontend as frontend-app
ru add work-project/backend as backend-api
ru add work-project/mobile as mobile-app

# Розділяйте work та personal projects
ru add personal/blog --private
ru add company/internal-tool

# === ГІЛКОВЕ КЕРУВАННЯ ===
# Закріплюйте стабільні гілки для production
ru add company/prod-app@main
ru add company/staging-app@develop

# Використовуйте custom names для clarity
ru add kubernetes/kubernetes as k8s-source
```

### 2. ⚡ **Оптимізація продуктивності**
```bash
# === PARALLEL PROCESSING ===
# Для щоденної роботи - помірний паралелізм
ru sync -j4

# Для initial setup - максимальний паралелізм
ru sync -j8 --clone-only

# Для повільного мережі - послідовно
ru sync -j1 --timeout 120

# === SMART SYNC STRATEGIES ===
# Використовуйте --pull-only коли не очікуєте нових repos
ru sync --pull-only -j4

# Autostash за замовчуванням для безпеки
alias rus='ru sync --autostash -j4'
```

### 3. 🔐 **Безпека та надійність**
```bash
# === BACKUP STRATEGIES ===
# Регулярне архівування конфігурації
cp -r ~/.config/ru ~/.config/ru.backup.$(date +%Y%m%d)

# Export списку repos для disaster recovery
ru list > ~/ru-repos-backup.txt

# === SAFETY CHECKS ===
# Завжди використовуйте --dry-run для нових workflows
ru sync --dry-run | grep -E "(clone|update|conflict)"

# Перевіряйте стан перед складними операціями
ru doctor && ru status
```

### 4. 📊 **Моніторинг та звітність**
```bash
# === DAILY MONITORING ===
# Створіть daily health check
cat > ~/.local/bin/ru-daily-check << 'EOF'
#!/bin/bash
echo "📅 $(date): Daily RU Health Check"
ru doctor --quiet || echo "⚠️ System issues detected"
conflicts=$(ru status --json | jq '[.[] | select(.status == "diverged")] | length')
[ "$conflicts" -gt 0 ] && echo "⚠️ $conflicts repositories have conflicts"
echo "✅ Check complete"
EOF
chmod +x ~/.local/bin/ru-daily-check

# === WEEKLY MAINTENANCE ===
# Створіть weekly maintenance script
cat > ~/.local/bin/ru-weekly-maintenance << 'EOF'
#!/bin/bash
echo "🧹 Weekly RU Maintenance"
ru prune --archive    # Archive orphans
ru self-update --check  # Check for updates
# Cleanup old logs (keep 30 days)
find ~/.local/state/ru/logs -mtime +30 -delete
echo "✅ Maintenance complete"
EOF
chmod +x ~/.local/bin/ru-weekly-maintenance
```

### 5. 🤖 **Автоматизація workflows**
```bash
# === SMART ALIASES ===
# Створіть корисні aliases
alias ruq='ru status --json | jq -r ".[] | select(.dirty == true or .status != \"current\") | .repo"'
alias ruf='ru sync --autostash -j4'  # Fast sync
alias rus='ru status | grep -v current'  # Show problems only

# === INTEGRATION WITH SHELL ===
# Додайте до ~/.bashrc or ~/.zshrc
ru_status_prompt() {
  local dirty_count=$(ru status --json 2>/dev/null | jq '[.[] | select(.dirty == true)] | length' 2>/dev/null || echo 0)
  [ "$dirty_count" -gt 0 ] && echo "📝$dirty_count"
}

# Додайте до PS1 для показу dirty repos count
export PS1="$(ru_status_prompt) $PS1"
```

### 6. 🔄 **Disaster Recovery**
```bash
# === BACKUP STRATEGY ===
#!/bin/bash
# ru-backup.sh - Complete backup strategy

backup_dir="$HOME/ru-backup-$(date +%Y%m%d)"
mkdir -p "$backup_dir"

# Backup configuration
cp -r ~/.config/ru "$backup_dir/config"

# Export repository list
ru list > "$backup_dir/repos-list.txt"
ru list --paths > "$backup_dir/repos-paths.txt"

# Backup important state
cp -r ~/.local/state/ru/logs "$backup_dir/logs" 2>/dev/null || true

echo "✅ Backup created: $backup_dir"

# === RESTORE PROCEDURE ===
#!/bin/bash
# ru-restore.sh - Restore from backup

backup_dir="$1"
if [ -z "$backup_dir" ]; then
  echo "Usage: $0 <backup-directory>"
  exit 1
fi

# Restore configuration
rm -rf ~/.config/ru
cp -r "$backup_dir/config" ~/.config/ru

# Restore repositories
ru sync

echo "✅ Restore complete"
```

---

## 🎯 Заключення

RU (repo_updater) - це потужний інструмент, який може кардинально покращити ваш workflow при роботі з множинними репозиторіями. Ключові принципи ефективного використання:

### ✅ **Почніть просто:**
- `ru init --example`
- `ru add your/repos`
- `ru sync`

### 🚀 **Масштабуйтеся поступово:**
- Додайте паралелізм: `ru sync -j4`
- Використовуйте автоматизацію: `ru sync --autostash`
- Інтегруйте у ваші скрипти з JSON API

### 💎 **Досягніть майстерності:**
- Створіть кастомні workflows для вашого use case
- Інтегруйте з іншими інструментами екосистеми
- Автоматизуйте моніторинг та maintenance

**RU - це не просто sync tool, це платформа для керування вашим development ecosystem!** 🌟

---

*Цей посібник створено на базі глибокого практичного дослідження можливостей ru утиліти. Використовуйте його як reference для побудови власних workflows та автоматизації.*