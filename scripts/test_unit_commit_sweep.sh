#!/usr/bin/env bash
#
# Unit Tests: Commit-Sweep Functions (SECTION 13.11)
# Tests for cs_* pure functions used by the commit-sweep analyzer:
#   - cs_extract_task_id (branch name → bead task ID)
#   - cs_classify_file (file path → bucket)
#   - cs_detect_commit_type (bucket + status → conventional type)
#   - cs_detect_scope (file list → scope)
#   - cs_build_message (type + scope + task_id → message)
#   - cs_assess_confidence (task_id + count + mixed → confidence)
#   - cs_files_to_json_array (file list → JSON array)
#   - cs_build_group_json (9 positional args → JSON object)
#
# shellcheck disable=SC2034  # Variables used by sourced functions
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_SECTION=""

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' BLUE='' YELLOW='' RESET=''
fi

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got:      $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

section() {
    CURRENT_SECTION="$1"
    echo ""
    echo -e "${BLUE}--- $1 ---${RESET}"
}

#==============================================================================
# Stub functions (no-op loggers)
#==============================================================================

log_warn() { :; }
log_error() { :; }
log_verbose() { :; }
log_info() { :; }
log_debug() { :; }
log_step() { :; }
log_success() { :; }

#==============================================================================
# Source functions from ru
#==============================================================================

source_function() {
    local func_name="$1"
    local tmp_file
    tmp_file=$(mktemp)
    sed -n "/^${func_name}()/,/^}/p" "$RU_SCRIPT" > "$tmp_file"
    if [[ -s "$tmp_file" ]]; then
        # shellcheck disable=SC1090
        source "$tmp_file"
    else
        echo "Warning: Function $func_name not found in ru" >&2
    fi
    rm -f "$tmp_file"
}

# Source json_escape (needed by cs_files_to_json_array, cs_build_group_json)
source_function "json_escape"

# Source all commit-sweep functions under test
source_function "cs_extract_task_id"
source_function "cs_classify_file"
source_function "cs_detect_commit_type"
source_function "cs_detect_scope"
source_function "cs_build_message"
source_function "cs_assess_confidence"
source_function "cs_files_to_json_array"
source_function "cs_build_group_json"

#==============================================================================
# Tests: cs_extract_task_id
#==============================================================================

section "cs_extract_task_id"

# Test 1: feature branch with bd- prefix
result=$(cs_extract_task_id "feature/bd-4f2a")
if [[ "$result" == "bd-4f2a" ]]; then
    pass "feature/bd-4f2a → bd-4f2a"
else
    fail "feature/bd-4f2a → bd-4f2a" "bd-4f2a" "$result"
fi

# Test 2: bd- prefix at start with trailing text
result=$(cs_extract_task_id "bd-abcd-more-stuff")
if [[ "$result" == "bd-abcd" ]]; then
    pass "bd-abcd-more-stuff → bd-abcd"
else
    fail "bd-abcd-more-stuff → bd-abcd" "bd-abcd" "$result"
fi

# Test 3: main branch has no task ID
result=$(cs_extract_task_id "main")
if [[ -z "$result" ]]; then
    pass "main → empty (no task ID)"
else
    fail "main → empty (no task ID)" "" "$result"
fi

# Test 4: br- prefix is not a valid bead ID
result=$(cs_extract_task_id "feature/br-1234")
if [[ -z "$result" ]]; then
    pass "feature/br-1234 → empty (br- not valid bead prefix)"
else
    fail "feature/br-1234 → empty (br- not valid bead prefix)" "" "$result"
fi

# Test 5: bd- prefix nested in path segments
result=$(cs_extract_task_id "fix/bd-0000/something")
if [[ "$result" == "bd-0000" ]]; then
    pass "fix/bd-0000/something → bd-0000"
else
    fail "fix/bd-0000/something → bd-0000" "bd-0000" "$result"
fi

#==============================================================================
# Tests: cs_classify_file
#==============================================================================

section "cs_classify_file"

# Test 6: test/ directory
result=$(cs_classify_file "test/unit.py")
if [[ "$result" == "test" ]]; then
    pass "test/unit.py → test"
else
    fail "test/unit.py → test" "test" "$result"
fi

# Test 7: tests/ directory with test_ prefix
result=$(cs_classify_file "tests/test_foo.sh")
if [[ "$result" == "test" ]]; then
    pass "tests/test_foo.sh → test"
else
    fail "tests/test_foo.sh → test" "test" "$result"
fi

# Test 8: Go _test.go suffix
result=$(cs_classify_file "src/foo_test.go")
if [[ "$result" == "test" ]]; then
    pass "src/foo_test.go → test"
else
    fail "src/foo_test.go → test" "test" "$result"
fi

# Test 9: scripts/test_* pattern
result=$(cs_classify_file "scripts/test_unit_sweep.sh")
if [[ "$result" == "test" ]]; then
    pass "scripts/test_unit_sweep.sh → test"
else
    fail "scripts/test_unit_sweep.sh → test" "test" "$result"
fi

# Test 10: README.md → doc
result=$(cs_classify_file "README.md")
if [[ "$result" == "doc" ]]; then
    pass "README.md → doc"
else
    fail "README.md → doc" "doc" "$result"
fi

# Test 11: docs/ directory
result=$(cs_classify_file "docs/guide.rst")
if [[ "$result" == "doc" ]]; then
    pass "docs/guide.rst → doc"
else
    fail "docs/guide.rst → doc" "doc" "$result"
fi

# Test 12: .github/workflows → config
result=$(cs_classify_file ".github/workflows/ci.yml")
if [[ "$result" == "config" ]]; then
    pass ".github/workflows/ci.yml → config"
else
    fail ".github/workflows/ci.yml → config" "config" "$result"
fi

# Test 13: Dockerfile → config
result=$(cs_classify_file "Dockerfile")
if [[ "$result" == "config" ]]; then
    pass "Dockerfile → config"
else
    fail "Dockerfile → config" "config" "$result"
fi

# Test 14: .gitignore → config
result=$(cs_classify_file ".gitignore")
if [[ "$result" == "config" ]]; then
    pass ".gitignore → config"
else
    fail ".gitignore → config" "config" "$result"
fi

# Test 15: src/main.py → source
result=$(cs_classify_file "src/main.py")
if [[ "$result" == "source" ]]; then
    pass "src/main.py → source"
else
    fail "src/main.py → source" "source" "$result"
fi

# Test 16: lib/utils.sh → source
result=$(cs_classify_file "lib/utils.sh")
if [[ "$result" == "source" ]]; then
    pass "lib/utils.sh → source"
else
    fail "lib/utils.sh → source" "source" "$result"
fi

# Test 17: config.yaml → config (by extension)
result=$(cs_classify_file "config.yaml")
if [[ "$result" == "config" ]]; then
    pass "config.yaml → config"
else
    fail "config.yaml → config" "config" "$result"
fi

#==============================================================================
# Tests: cs_detect_commit_type
#==============================================================================

section "cs_detect_commit_type"

# Test 18: test bucket → test
result=$(cs_detect_commit_type "test" "M")
if [[ "$result" == "test" ]]; then
    pass "bucket=test, status=M → test"
else
    fail "bucket=test, status=M → test" "test" "$result"
fi

# Test 19: doc bucket → docs
result=$(cs_detect_commit_type "doc" "A")
if [[ "$result" == "docs" ]]; then
    pass "bucket=doc, status=A → docs"
else
    fail "bucket=doc, status=A → docs" "docs" "$result"
fi

# Test 20: config bucket → chore
result=$(cs_detect_commit_type "config" "M")
if [[ "$result" == "chore" ]]; then
    pass "bucket=config, status=M → chore"
else
    fail "bucket=config, status=M → chore" "chore" "$result"
fi

# Test 21: source + A → feat
result=$(cs_detect_commit_type "source" "A")
if [[ "$result" == "feat" ]]; then
    pass "bucket=source, status=A → feat"
else
    fail "bucket=source, status=A → feat" "feat" "$result"
fi

# Test 22: source + D → chore
result=$(cs_detect_commit_type "source" "D")
if [[ "$result" == "chore" ]]; then
    pass "bucket=source, status=D → chore"
else
    fail "bucket=source, status=D → chore" "chore" "$result"
fi

# Test 23: source + R → refactor
result=$(cs_detect_commit_type "source" "R")
if [[ "$result" == "refactor" ]]; then
    pass "bucket=source, status=R → refactor"
else
    fail "bucket=source, status=R → refactor" "refactor" "$result"
fi

# Test 24: source + M → fix (default)
result=$(cs_detect_commit_type "source" "M")
if [[ "$result" == "fix" ]]; then
    pass "bucket=source, status=M → fix"
else
    fail "bucket=source, status=M → fix" "fix" "$result"
fi

#==============================================================================
# Tests: cs_detect_scope
#==============================================================================

section "cs_detect_scope"

# Test 25: most common directory wins
result=$(printf 'src/a.py\0src/b.py\0lib/c.py\0' | cs_detect_scope)
if [[ "$result" == "src" ]]; then
    pass "src/a.py + src/b.py + lib/c.py → src (most common dir)"
else
    fail "src/a.py + src/b.py + lib/c.py → src (most common dir)" "src" "$result"
fi

# Test 26: root-level files → root
result=$(printf 'a.py\0b.py\0' | cs_detect_scope)
if [[ "$result" == "root" ]]; then
    pass "a.py + b.py → root (no subdirs)"
else
    fail "a.py + b.py → root (no subdirs)" "root" "$result"
fi

#==============================================================================
# Tests: cs_build_message
#==============================================================================

section "cs_build_message"

# Test 27: full message with scope and task_id
result=$(cs_build_message "feat" "src" "bd-1234")
if [[ "$result" == "feat(src): add src changes (bd-1234)" ]]; then
    pass "feat + src + bd-1234 → feat(src): add src changes (bd-1234)"
else
    fail "feat + src + bd-1234 → feat(src): add src changes (bd-1234)" "feat(src): add src changes (bd-1234)" "$result"
fi

# Test 28: root scope suppressed from parens, no task_id
result=$(cs_build_message "fix" "root" "")
if [[ "$result" == "fix: fix root issues" ]]; then
    pass "fix + root + empty → fix: fix root issues"
else
    fail "fix + root + empty → fix: fix root issues" "fix: fix root issues" "$result"
fi

# Test 29: message truncated to 72 chars for very long scope
long_scope="this-is-a-very-long-scope-name-that-should-cause-truncation-in-the-message"
result=$(cs_build_message "feat" "$long_scope" "bd-1234")
if (( ${#result} <= 72 )); then
    pass "message with long scope is <= 72 chars (got ${#result})"
else
    fail "message with long scope is <= 72 chars" "<=72" "${#result}"
fi

#==============================================================================
# Tests: cs_assess_confidence
#==============================================================================

section "cs_assess_confidence"

# Test 30: task_id + few files + no mixed → high
result=$(cs_assess_confidence "bd-1234" 3 0)
if [[ "$result" == "high" ]]; then
    pass "task_id + 3 files + no mixed → high"
else
    fail "task_id + 3 files + no mixed → high" "high" "$result"
fi

# Test 31: task_id + >5 files → medium
result=$(cs_assess_confidence "bd-1234" 10 0)
if [[ "$result" == "medium" ]]; then
    pass "task_id + 10 files + no mixed → medium"
else
    fail "task_id + 10 files + no mixed → medium" "medium" "$result"
fi

# Test 32: no task_id + few files → medium
result=$(cs_assess_confidence "" 3 0)
if [[ "$result" == "medium" ]]; then
    pass "no task_id + 3 files + no mixed → medium"
else
    fail "no task_id + 3 files + no mixed → medium" "medium" "$result"
fi

# Test 33: no task_id + >20 files + mixed → low
result=$(cs_assess_confidence "" 25 1)
if [[ "$result" == "low" ]]; then
    pass "no task_id + 25 files + mixed → low"
else
    fail "no task_id + 25 files + mixed → low" "low" "$result"
fi

#==============================================================================
# Tests: cs_files_to_json_array
#==============================================================================

section "cs_files_to_json_array"

# Test 34: two files → JSON array
result=$(printf 'a.py\0b.py\0' | cs_files_to_json_array)
if [[ "$result" == '["a.py","b.py"]' ]]; then
    pass 'a.py + b.py → ["a.py","b.py"]'
else
    fail 'a.py + b.py → ["a.py","b.py"]' '["a.py","b.py"]' "$result"
fi

# Test 35: empty input → empty array
result=$(printf '' | cs_files_to_json_array)
if [[ "$result" == '[]' ]]; then
    pass 'empty input → []'
else
    fail 'empty input → []' '[]' "$result"
fi

#==============================================================================
# Results
#==============================================================================

echo ""
echo "========================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "========================"
exit $(( TESTS_FAILED > 0 ? 1 : 0 ))
