#!/usr/bin/env bash
#
# Tests: fork-sync main↔master auto-fallback
#
# Tests the interim hotfix that auto-detects main↔master when the configured
# branch doesn't exist locally. Covers fallback, dedupe, dry-run, push,
# CLI --branches exact mode, and upstream mismatch.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

#==============================================================================
# Test Framework
#==============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

# Colors (disabled if not a terminal)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' RESET=''
fi

setup_test_env() {
    TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEMP_DIR/config"
    export XDG_STATE_HOME="$TEMP_DIR/state"
    export XDG_CACHE_HOME="$TEMP_DIR/cache"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME"

    export TEST_PROJECTS_DIR="$TEMP_DIR/projects"
    mkdir -p "$TEST_PROJECTS_DIR"
    mkdir -p "$TEMP_DIR/remotes"
}

cleanup_test_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

pass() {
    echo -e "${GREEN}PASS${RESET}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    ((TESTS_FAILED++))
}

#==============================================================================
# Git Helpers
#==============================================================================

# Create a bare repo with a given default branch and initial commit
create_bare_with_branch() {
    local name="$1"
    local branch="$2"
    local bare_dir="$TEMP_DIR/remotes/$name.git"
    mkdir -p "$bare_dir"
    git init --bare "$bare_dir" >/dev/null 2>&1
    git -C "$bare_dir" symbolic-ref HEAD "refs/heads/$branch"

    # Add initial commit via a temp clone
    local tmp_clone="$TEMP_DIR/_tmp_clone_$$_$name"
    git clone "$bare_dir" "$tmp_clone" >/dev/null 2>&1
    git -C "$tmp_clone" config user.email "test@test.com"
    git -C "$tmp_clone" config user.name "Test"
    git -C "$tmp_clone" checkout -b "$branch" 2>/dev/null || true
    echo "init" > "$tmp_clone/file.txt"
    git -C "$tmp_clone" add file.txt
    git -C "$tmp_clone" commit -m "Initial commit" >/dev/null 2>&1
    git -C "$tmp_clone" push -u origin "$branch" >/dev/null 2>&1
    rm -rf "$tmp_clone"

    echo "$bare_dir"
}

# Add a commit to a bare repo on a given branch
add_commit_to_bare() {
    local bare_dir="$1"
    local branch="$2"
    local msg="${3:-upstream change}"
    local tmp_clone="$TEMP_DIR/_tmp_commit_$$"
    git clone -b "$branch" "$bare_dir" "$tmp_clone" >/dev/null 2>&1
    git -C "$tmp_clone" config user.email "test@test.com"
    git -C "$tmp_clone" config user.name "Test"
    echo "$msg" >> "$tmp_clone/file.txt"
    git -C "$tmp_clone" add file.txt
    git -C "$tmp_clone" commit -m "$msg" >/dev/null 2>&1
    git -C "$tmp_clone" push >/dev/null 2>&1
    rm -rf "$tmp_clone"
}

# Set up a fork-like repo structure:
# - upstream bare repo (the original)
# - origin bare repo (the fork on GitHub, cloned from upstream)
# - local clone of origin with upstream remote added
#
# $1 = repo name
# $2 = branch name (default branch of both upstream and origin)
# Returns: prints local_path
setup_fork_repo() {
    local name="$1"
    local branch="$2"

    # Create upstream bare repo
    local upstream_dir
    upstream_dir=$(create_bare_with_branch "${name}-upstream" "$branch")

    # Make upstream ahead (so there's something to sync)
    add_commit_to_bare "$upstream_dir" "$branch" "upstream ahead"

    # Create origin bare repo (fork) — clone of upstream at initial state
    local origin_dir
    origin_dir=$(create_bare_with_branch "${name}-origin" "$branch")

    # Clone origin to projects dir
    local local_path="$TEST_PROJECTS_DIR/$name"
    git clone -b "$branch" "$origin_dir" "$local_path" >/dev/null 2>&1
    git -C "$local_path" config user.email "test@test.com"
    git -C "$local_path" config user.name "Test"

    # Add upstream remote and fetch
    git -C "$local_path" remote add upstream "$upstream_dir"
    git -C "$local_path" fetch upstream >/dev/null 2>&1

    echo "$local_path"
}

# Initialize ru config for testing
init_ru_config() {
    "$RU_SCRIPT" init >/dev/null 2>&1
    local config_file="$XDG_CONFIG_HOME/ru/config"
    local tmp_file="$config_file.tmp"
    if grep -q "^PROJECTS_DIR=" "$config_file" 2>/dev/null; then
        sed "s|^PROJECTS_DIR=.*|PROJECTS_DIR=$TEST_PROJECTS_DIR|" "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    else
        echo "PROJECTS_DIR=$TEST_PROJECTS_DIR" >> "$config_file"
    fi
}

# Get HEAD sha of a branch in a repo
get_head_sha() {
    git -C "$1" rev-parse "refs/heads/$2" 2>/dev/null
}

#==============================================================================
# Test 1: Fallback from main to master
#==============================================================================

test_fallback_master() {
    echo "Test 1: Fallback from main to master (default config)"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo1" "master")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    # Run fork-sync with default config (branches=main, should fallback to master)
    "$RU_SCRIPT" fork-sync "testowner/testrepo1" --force >/dev/null 2>&1
    local exit_code=$?

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    if [[ "$before_sha" != "$after_sha" ]]; then
        pass "master was synced via fallback (SHA changed)"
    else
        fail "master was NOT synced (SHA unchanged: $before_sha)"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 2: CLI --branches disables fallback
#==============================================================================

test_cli_exact_no_fallback() {
    echo "Test 2: --branches main disables fallback on master-only repo"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo2" "master")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    # Run with explicit --branches main (no fallback)
    "$RU_SCRIPT" fork-sync "testowner/testrepo2" --branches main --force >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    if [[ "$before_sha" == "$after_sha" ]]; then
        pass "master NOT synced with explicit --branches main (exact mode)"
    else
        fail "master was synced despite explicit --branches main"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 3: No fallback when configured branch exists
#==============================================================================

test_no_fallback_when_exists() {
    echo "Test 3: No fallback when main exists (repo has both main and master)"
    setup_test_env
    init_ru_config

    # Create upstream with main
    local upstream_dir
    upstream_dir=$(create_bare_with_branch "testrepo3-upstream" "main")
    add_commit_to_bare "$upstream_dir" "main" "upstream ahead on main"

    # Create origin with main
    local origin_dir
    origin_dir=$(create_bare_with_branch "testrepo3-origin" "main")

    # Clone origin locally
    local local_path="$TEST_PROJECTS_DIR/testrepo3"
    git clone -b main "$origin_dir" "$local_path" >/dev/null 2>&1
    git -C "$local_path" config user.email "test@test.com"
    git -C "$local_path" config user.name "Test"

    # Also create master branch locally
    git -C "$local_path" branch master main >/dev/null 2>&1

    # Add upstream and fetch
    git -C "$local_path" remote add upstream "$upstream_dir"
    git -C "$local_path" fetch upstream >/dev/null 2>&1

    local main_before
    main_before=$(get_head_sha "$local_path" "main")
    local master_before
    master_before=$(get_head_sha "$local_path" "master")

    "$RU_SCRIPT" fork-sync "testowner/testrepo3" --force >/dev/null 2>&1

    local main_after
    main_after=$(get_head_sha "$local_path" "main")
    local master_after
    master_after=$(get_head_sha "$local_path" "master")

    if [[ "$main_before" != "$main_after" ]]; then
        pass "main was synced (no fallback needed)"
    else
        fail "main was NOT synced"
    fi

    if [[ "$master_before" == "$master_after" ]]; then
        pass "master was NOT synced (fallback didn't activate)"
    else
        fail "master was incorrectly synced"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 4: No fallback for develop
#==============================================================================

test_no_fallback_develop() {
    echo "Test 4: No fallback for develop (only main↔master)"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo4" "develop")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "develop")

    # Default config: branches=main; develop doesn't participate in fallback
    "$RU_SCRIPT" fork-sync "testowner/testrepo4" --force >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "develop")

    if [[ "$before_sha" == "$after_sha" ]]; then
        pass "develop NOT synced (no fallback for non main/master)"
    else
        fail "develop was incorrectly synced"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 5: Fallback with --push
#==============================================================================

test_fallback_with_push() {
    echo "Test 5: Fallback to master with --push updates origin"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo5" "master")

    # Get origin remote URL for verification
    local origin_url
    origin_url=$(git -C "$local_path" remote get-url origin)

    local origin_sha_before
    origin_sha_before=$(git -C "$origin_url" rev-parse "refs/heads/master" 2>/dev/null)

    "$RU_SCRIPT" fork-sync "testowner/testrepo5" --push --force >/dev/null 2>&1

    local origin_sha_after
    origin_sha_after=$(git -C "$origin_url" rev-parse "refs/heads/master" 2>/dev/null)

    local local_sha
    local_sha=$(get_head_sha "$local_path" "master")

    if [[ "$origin_sha_before" != "$origin_sha_after" ]]; then
        pass "origin/master was updated after push"
    else
        fail "origin/master was NOT updated"
    fi

    if [[ "$local_sha" == "$origin_sha_after" ]]; then
        pass "origin/master matches local master"
    else
        fail "origin/master doesn't match local master"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 6: Fallback with --dry-run
#==============================================================================

test_fallback_dry_run() {
    echo "Test 6: Fallback with --dry-run doesn't change repo"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo6" "master")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    "$RU_SCRIPT" fork-sync "testowner/testrepo6" --force --dry-run >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    if [[ "$before_sha" == "$after_sha" ]]; then
        pass "dry-run did NOT change master (SHA unchanged)"
    else
        fail "dry-run changed master (before=$before_sha after=$after_sha)"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 7: Dedupe — FORK_SYNC_BRANCHES=main,master with repo only having master
#==============================================================================

test_dedupe_main_master_list() {
    echo "Test 7: Dedupe — branches=main,master, repo only has master"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo7" "master")

    # Set FORK_SYNC_BRANCHES=main,master in config
    local config_file="$XDG_CONFIG_HOME/ru/config"
    echo "FORK_SYNC_BRANCHES=main,master" >> "$config_file"

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    local output
    output=$("$RU_SCRIPT" fork-sync "testowner/testrepo7" --force --verbose 2>&1)
    local exit_code=$?

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    if [[ "$before_sha" != "$after_sha" ]]; then
        pass "master was synced"
    else
        fail "master was NOT synced"
    fi

    # Count how many times "already synced, skipping" appears (dedupe)
    local dedupe_count
    dedupe_count=$(printf '%s\n' "$output" | grep -c "already synced" || true)

    if [[ "$dedupe_count" -ge 1 ]]; then
        pass "dedupe prevented second sync of master"
    else
        fail "dedupe message not found (expected 'already synced')"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 8: Local main exists but upstream only has master
#==============================================================================

test_local_exists_upstream_missing() {
    echo "Test 8: Local main exists, upstream only has master → skip"
    setup_test_env
    init_ru_config

    # Create upstream with master only
    local upstream_dir
    upstream_dir=$(create_bare_with_branch "testrepo8-upstream" "master")
    add_commit_to_bare "$upstream_dir" "master" "upstream change"

    # Create origin with main
    local origin_dir
    origin_dir=$(create_bare_with_branch "testrepo8-origin" "main")

    # Clone origin (has main)
    local local_path="$TEST_PROJECTS_DIR/testrepo8"
    git clone -b main "$origin_dir" "$local_path" >/dev/null 2>&1
    git -C "$local_path" config user.email "test@test.com"
    git -C "$local_path" config user.name "Test"

    # Add upstream (which only has master, not main)
    git -C "$local_path" remote add upstream "$upstream_dir"
    git -C "$local_path" fetch upstream >/dev/null 2>&1

    local before_sha
    before_sha=$(get_head_sha "$local_path" "main")

    "$RU_SCRIPT" fork-sync "testowner/testrepo8" --force >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "main")

    if [[ "$before_sha" == "$after_sha" ]]; then
        pass "main NOT synced (upstream/main doesn't exist, no upstream fallback)"
    else
        fail "main was incorrectly synced despite missing upstream/main"
    fi

    cleanup_test_env
}

#==============================================================================
# Test 9: Fail then retry — dedupe doesn't block retry on failure
#==============================================================================

test_fail_then_retry_no_dedupe() {
    echo "Test 9: Dedupe doesn't block retry after failure (ff-only diverged)"
    setup_test_env
    init_ru_config

    # Create upstream with master
    local upstream_dir
    upstream_dir=$(create_bare_with_branch "testrepo9-upstream" "master")
    add_commit_to_bare "$upstream_dir" "master" "upstream diverge"

    # Create origin with master
    local origin_dir
    origin_dir=$(create_bare_with_branch "testrepo9-origin" "master")

    # Clone origin
    local local_path="$TEST_PROJECTS_DIR/testrepo9"
    git clone -b master "$origin_dir" "$local_path" >/dev/null 2>&1
    git -C "$local_path" config user.email "test@test.com"
    git -C "$local_path" config user.name "Test"

    # Add upstream and fetch
    git -C "$local_path" remote add upstream "$upstream_dir"
    git -C "$local_path" fetch upstream >/dev/null 2>&1

    # Create local divergence so ff-only merge fails
    echo "local diverge" >> "$local_path/file.txt"
    git -C "$local_path" add file.txt
    git -C "$local_path" commit -m "local diverging commit" >/dev/null 2>&1

    # Set up git wrapper to count merge --ff-only invocations
    local real_git
    real_git=$(command -v git)
    mkdir -p "$TEMP_DIR/bin"
    cat > "$TEMP_DIR/bin/git" << WRAPPER
#!/bin/bash
# Intentional coupling: positional match tied to cmd_fork_sync's
# git -C <path> merge --ff-only <ref> (ru:10029). If CLI arg order
# changes, update this wrapper accordingly.
if [[ "\$1" == "-C" && "\$3" == "merge" && "\$4" == "--ff-only" ]]; then
    echo 1 >> "$TEMP_DIR/merge_attempts.log"
fi
exec "$real_git" "\$@"
WRAPPER
    chmod +x "$TEMP_DIR/bin/git"
    local _orig_path="$PATH"
    export PATH="$TEMP_DIR/bin:$PATH"

    # Set FORK_SYNC_BRANCHES=main,master so both iterations try master
    local config_file="$XDG_CONFIG_HOME/ru/config"
    echo "FORK_SYNC_BRANCHES=main,master" >> "$config_file"

    local output
    output=$("$RU_SCRIPT" fork-sync "testowner/testrepo9" --force 2>&1)
    local exit_code=$?

    # Restore PATH
    export PATH="$_orig_path"

    # Sanity: git still works
    if git -C "$local_path" rev-parse --verify HEAD >/dev/null 2>&1; then
        pass "git wrapper doesn't break other commands"
    else
        fail "git wrapper broke HEAD resolution"
    fi

    # Core: merge --ff-only was attempted at least twice (both iterations tried)
    local merge_count=0
    if [[ -f "$TEMP_DIR/merge_attempts.log" ]]; then
        merge_count=$(wc -l < "$TEMP_DIR/merge_attempts.log")
    fi

    if [[ "$merge_count" -ge 2 ]]; then
        pass "merge --ff-only attempted $merge_count times (dedupe didn't block retry)"
    else
        fail "merge --ff-only only attempted $merge_count times (expected >= 2)"
    fi

    # Behavioral: repo should be Failed (ff-only can't handle divergence)
    if [[ "$exit_code" -ne 0 ]]; then
        pass "fork-sync exited non-zero (failed as expected)"
    else
        fail "fork-sync exited 0 despite diverged branches"
    fi

    cleanup_test_env
}

#==============================================================================
# Run all tests
#==============================================================================

echo "=== fork-sync default branch fallback tests ==="
echo ""

test_fallback_master
test_cli_exact_no_fallback
test_no_fallback_when_exists
test_no_fallback_develop
test_fallback_with_push
test_fallback_dry_run
test_dedupe_main_master_list
test_local_exists_upstream_missing
test_fail_then_retry_no_dedupe

echo ""
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
