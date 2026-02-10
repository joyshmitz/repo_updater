#!/usr/bin/env bash
#
# Tests: fork-sync main↔master auto-fallback
#
# Tests the interim hotfix that auto-detects main↔master when the configured
# branch doesn't exist locally. Covers fallback, dedupe, dry-run, push,
# CLI --branches exact mode, and upstream mismatch.
#
# Migrated to test_framework.sh for standardized logging/output.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1090  # Dynamic sourcing is intentional
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

source "$SCRIPT_DIR/test_framework.sh"

# Suppress log output from ru internals
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_verbose() { :; }

TEMP_DIR=""

#==============================================================================
# Git Helpers
#==============================================================================

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
    local test_name="fallback: main to master (default config)"
    log_test_start "$test_name"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo1" "master")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    # Run fork-sync with default config (branches=main, should fallback to master)
    "$RU_SCRIPT" fork-sync "testowner/testrepo1" --force >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    assert_not_equals "$before_sha" "$after_sha" "master was synced via fallback (SHA changed)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 2: CLI --branches disables fallback
#==============================================================================

test_cli_exact_no_fallback() {
    local test_name="--branches main disables fallback on master-only repo"
    log_test_start "$test_name"
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

    assert_equals "$before_sha" "$after_sha" "master NOT synced with explicit --branches main (exact mode)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 3: No fallback when configured branch exists
#==============================================================================

test_no_fallback_when_exists() {
    local test_name="no fallback when main exists (repo has both main and master)"
    log_test_start "$test_name"
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

    assert_not_equals "$main_before" "$main_after" "main was synced (no fallback needed)"
    assert_equals "$master_before" "$master_after" "master was NOT synced (fallback didn't activate)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 4: No fallback for develop
#==============================================================================

test_no_fallback_develop() {
    local test_name="no fallback for develop (only main/master)"
    log_test_start "$test_name"
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

    assert_equals "$before_sha" "$after_sha" "develop NOT synced (no fallback for non main/master)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 5: Fallback with --push
#==============================================================================

test_fallback_with_push() {
    local test_name="fallback to master with --push updates origin"
    log_test_start "$test_name"
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

    assert_not_equals "$origin_sha_before" "$origin_sha_after" "origin/master was updated after push"
    assert_equals "$local_sha" "$origin_sha_after" "origin/master matches local master"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 6: Fallback with --dry-run
#==============================================================================

test_fallback_dry_run() {
    local test_name="fallback with --dry-run doesn't change repo"
    log_test_start "$test_name"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo6" "master")

    local before_sha
    before_sha=$(get_head_sha "$local_path" "master")

    "$RU_SCRIPT" fork-sync "testowner/testrepo6" --force --dry-run >/dev/null 2>&1

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    assert_equals "$before_sha" "$after_sha" "dry-run did NOT change master (SHA unchanged)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 7: Dedupe — FORK_SYNC_BRANCHES=main,master with repo only having master
#==============================================================================

test_dedupe_main_master_list() {
    local test_name="dedupe: branches=main,master, repo only has master"
    log_test_start "$test_name"
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

    local after_sha
    after_sha=$(get_head_sha "$local_path" "master")

    assert_not_equals "$before_sha" "$after_sha" "master was synced"

    # Count how many times "already synced, skipping" appears (dedupe)
    local dedupe_count
    dedupe_count=$(printf '%s\n' "$output" | grep -c "already synced" || true)

    assert_true "[[ $dedupe_count -ge 1 ]]" "dedupe prevented second sync of master"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 8: Local main exists but upstream only has master
#==============================================================================

test_local_exists_upstream_missing() {
    local test_name="local main exists, upstream only has master: skip"
    log_test_start "$test_name"
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

    assert_equals "$before_sha" "$after_sha" "main NOT synced (upstream/main doesn't exist, no upstream fallback)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 9: Fail then retry — dedupe doesn't block retry on failure
#==============================================================================

test_fail_then_retry_no_dedupe() {
    local test_name="dedupe doesn't block retry after failure (ff-only diverged)"
    log_test_start "$test_name"
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
    local git_ok="false"
    git -C "$local_path" rev-parse --verify HEAD >/dev/null 2>&1 && git_ok="true"
    assert_equals "true" "$git_ok" "git wrapper doesn't break other commands"

    # Core: merge --ff-only was attempted at least twice (both iterations tried)
    local merge_count=0
    if [[ -f "$TEMP_DIR/merge_attempts.log" ]]; then
        merge_count=$(wc -l < "$TEMP_DIR/merge_attempts.log")
    fi

    assert_true "[[ $merge_count -ge 2 ]]" "merge --ff-only attempted $merge_count times (dedupe didn't block retry)"

    # Behavioral: repo should be Failed (ff-only can't handle divergence)
    assert_not_equals "0" "$exit_code" "fork-sync exited non-zero (failed as expected)"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 10: fork-status JSON envelope shape
#==============================================================================

test_fork_status_json_envelope() {
    local test_name="fork-status --json returns envelope with data.repos"
    log_test_start "$test_name"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo10" "master")

    local json_output
    json_output=$("$RU_SCRIPT" fork-status "testowner/testrepo10" --json --no-fetch 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "fork-status --json exits zero"

    local has_command="false"
    echo "$json_output" | jq -e '.command == "fork-status"' >/dev/null 2>&1 && has_command="true"
    assert_equals "true" "$has_command" "JSON envelope includes command=fork-status"

    local has_meta="false"
    echo "$json_output" | jq -e '.version and .generated_at and .output_format' >/dev/null 2>&1 && has_meta="true"
    assert_equals "true" "$has_meta" "JSON envelope includes version/generated_at/output_format"

    local has_data="false"
    echo "$json_output" | jq -e '.data.total >= 1 and (.data.repos | type == "array")' >/dev/null 2>&1 && has_data="true"
    assert_equals "true" "$has_data" "JSON data includes total and repos array"

    local has_repo="false"
    echo "$json_output" | jq -e '.data.repos[] | select(.repo == "testowner/testrepo10")' >/dev/null 2>&1 && has_repo="true"
    assert_equals "true" "$has_repo" "JSON data contains target repo entry"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 11: fork-sync JSON envelope shape
#==============================================================================

test_fork_sync_json_envelope() {
    local test_name="fork-sync --json returns envelope with summary and repos"
    log_test_start "$test_name"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo11" "master")

    local json_output
    json_output=$("$RU_SCRIPT" fork-sync "testowner/testrepo11" --json --dry-run --force 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "fork-sync --json exits zero"

    local has_command="false"
    echo "$json_output" | jq -e '.command == "fork-sync"' >/dev/null 2>&1 && has_command="true"
    assert_equals "true" "$has_command" "JSON envelope includes command=fork-sync"

    local has_data="false"
    echo "$json_output" | jq -e '.data.summary.total >= 1 and (.data.repos | type == "array")' >/dev/null 2>&1 && has_data="true"
    assert_equals "true" "$has_data" "JSON data includes summary and repos array"

    local has_status="false"
    echo "$json_output" | jq -e '.data.repos[] | select(.repo == "testowner/testrepo11") | .status' >/dev/null 2>&1 && has_status="true"
    assert_equals "true" "$has_status" "JSON data contains target repo status"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Test 12: fork-clean JSON envelope shape
#==============================================================================

test_fork_clean_json_envelope() {
    local test_name="fork-clean --json returns envelope with summary and repos"
    log_test_start "$test_name"
    setup_test_env
    init_ru_config

    local local_path
    local_path=$(setup_fork_repo "testrepo12" "master")

    local json_output
    json_output=$("$RU_SCRIPT" fork-clean "testowner/testrepo12" --json --dry-run --force 2>/dev/null)
    local exit_code=$?

    assert_equals "0" "$exit_code" "fork-clean --json exits zero"

    local has_command="false"
    echo "$json_output" | jq -e '.command == "fork-clean"' >/dev/null 2>&1 && has_command="true"
    assert_equals "true" "$has_command" "JSON envelope includes command=fork-clean"

    local has_data="false"
    echo "$json_output" | jq -e '.data.summary.total >= 1 and (.data.repos | type == "array")' >/dev/null 2>&1 && has_data="true"
    assert_equals "true" "$has_data" "JSON data includes summary and repos array"

    local has_status="false"
    echo "$json_output" | jq -e '.data.repos[] | select(.repo == "testowner/testrepo12") | .status' >/dev/null 2>&1 && has_status="true"
    assert_equals "true" "$has_status" "JSON data contains target repo status"

    cleanup_test_env
    log_test_pass "$test_name"
}

#==============================================================================
# Run all tests
#==============================================================================

run_test test_fallback_master
run_test test_cli_exact_no_fallback
run_test test_no_fallback_when_exists
run_test test_no_fallback_develop
run_test test_fallback_with_push
run_test test_fallback_dry_run
run_test test_dedupe_main_master_list
run_test test_local_exists_upstream_missing
run_test test_fail_then_retry_no_dedupe
run_test test_fork_status_json_envelope
run_test test_fork_sync_json_envelope
run_test test_fork_clean_json_envelope

print_results
exit "$(get_exit_code)"
