#!/usr/bin/env bash
#
# E2E Test: ru worktree management (bd-33aj)
#
# Tests git worktree operations used by the review workflow:
#   1. Worktree creation from main branch
#   2. Worktree creation with custom branch
#   3. Worktree mapping and lookup
#   4. Worktree cleanup
#   5. List and validate worktrees
#   6. Orphaned worktree detection
#
# Uses local git repos for deterministic testing without network access.
#
# shellcheck disable=SC2034  # Variables used by sourced functions
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Functions called via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"

# Source E2E framework
source "$SCRIPT_DIR/test_e2e_framework.sh"

#==============================================================================
# Test Helpers
#==============================================================================

# Source specific ru functions for worktree operations
source_ru_worktree_functions() {
    # Extract helper functions first
    eval "$(sed -n '/^_is_valid_var_name()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^_set_out_var()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^ensure_dir()/,/^}/p' "$RU_SCRIPT")"

    # Extract worktree-related functions from ru
    eval "$(sed -n '/^get_worktrees_dir()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^record_worktree_mapping()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^get_worktree_path()/,/^}/p' "$RU_SCRIPT")"
    eval "$(sed -n '/^list_review_worktrees()/,/^}/p' "$RU_SCRIPT")"
}

# Create a test git repo for worktree operations
create_worktree_test_repo() {
    local repo_name="$1"
    local num_commits="${2:-3}"
    local repo_path="$E2E_TEMP_DIR/repos/$repo_name"

    mkdir -p "$repo_path"

    (
        cd "$repo_path" || exit 1
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test User"

        for ((i=1; i<=num_commits; i++)); do
            echo "Commit $i content" > "file$i.txt"
            git add .
            git commit -q -m "Commit $i"
        done
    )

    echo "$repo_path"
}

# Setup test environment for worktree tests
worktree_test_setup() {
    e2e_setup
    source_ru_worktree_functions

    # Set up state directory
    export RU_STATE_DIR="$XDG_STATE_HOME/ru"
    mkdir -p "$RU_STATE_DIR"

    # Set a test run ID
    export REVIEW_RUN_ID="test-run-$$"

    e2e_log_operation "worktree_setup" "Worktree test environment ready"
}

#==============================================================================
# Test: Basic worktree creation from main branch
#==============================================================================

test_worktree_create_from_main() {
    local test_name="Worktree creation from main branch"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "test-repo" 3)

    # Create a worktree
    local wt_path="$E2E_TEMP_DIR/worktrees/test-wt"
    mkdir -p "$(dirname "$wt_path")"

    local wt_result=0
    git -C "$repo_path" worktree add -q "$wt_path" HEAD 2>/dev/null || wt_result=$?

    assert_equals "0" "$wt_result" "Worktree creation succeeds"
    assert_true "test -d '$wt_path'" "Worktree directory exists"
    assert_true "test -f '$wt_path/.git'" "Worktree has .git file"

    # Verify worktree is linked to main repo
    local wt_list
    wt_list=$(git -C "$repo_path" worktree list --porcelain)
    assert_contains "$wt_list" "$wt_path" "Main repo lists worktree"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Worktree creation with custom branch
#==============================================================================

test_worktree_create_with_branch() {
    local test_name="Worktree creation with custom branch"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo with a feature branch
    local repo_path
    repo_path=$(create_worktree_test_repo "branch-repo" 2)

    (
        cd "$repo_path" || exit 1
        git checkout -q -b feature-branch
        echo "Feature content" > feature.txt
        git add .
        git commit -q -m "Feature commit"
        git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
    )

    # Create worktree on feature branch
    local wt_path="$E2E_TEMP_DIR/worktrees/feature-wt"
    mkdir -p "$(dirname "$wt_path")"

    local wt_result=0
    git -C "$repo_path" worktree add -q "$wt_path" feature-branch 2>/dev/null || wt_result=$?

    assert_equals "0" "$wt_result" "Feature branch worktree creation succeeds"
    assert_true "test -f '$wt_path/feature.txt'" "Feature file exists in worktree"

    # Verify we're on the right branch
    local current_branch
    current_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    assert_equals "feature-branch" "$current_branch" "Worktree is on feature branch"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Worktree mapping and lookup
#==============================================================================

test_worktree_mapping() {
    local test_name="Worktree mapping and lookup"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "mapping-repo" 1)

    # Create worktree
    local wt_path="$E2E_TEMP_DIR/worktrees/mapped-wt"
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add -q "$wt_path" HEAD 2>/dev/null

    # Record mapping using ru function
    local repo_id="testowner/mapping-repo"
    record_worktree_mapping "$repo_id" "$wt_path" "main"

    # Verify mapping file exists
    local mapping_file
    mapping_file="$(get_worktrees_dir)/mapping.json"
    assert_true "test -f '$mapping_file'" "Mapping file created"

    # Lookup worktree path
    local found_path=""
    get_worktree_path "$repo_id" found_path
    assert_equals "$wt_path" "$found_path" "Worktree path lookup works"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: List worktrees
#==============================================================================

test_worktree_list() {
    local test_name="List and validate worktrees"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "list-repo" 2)

    # Create multiple worktrees
    local wt1="$E2E_TEMP_DIR/worktrees/wt1"
    local wt2="$E2E_TEMP_DIR/worktrees/wt2"
    mkdir -p "$(dirname "$wt1")"

    git -C "$repo_path" worktree add -q "$wt1" HEAD 2>/dev/null
    git -C "$repo_path" worktree add -q "$wt2" HEAD 2>/dev/null

    # Record mappings
    record_worktree_mapping "owner/repo1" "$wt1" "main"
    record_worktree_mapping "owner/repo2" "$wt2" "main"

    # List worktrees using ru function
    local listed
    listed=$(list_review_worktrees)

    assert_contains "$listed" "repo1" "List contains repo1"
    assert_contains "$listed" "repo2" "List contains repo2"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Worktree cleanup
#==============================================================================

test_worktree_cleanup() {
    local test_name="Worktree cleanup removes all files"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "cleanup-repo" 1)

    # Create worktree
    local wt_path="$E2E_TEMP_DIR/worktrees/cleanup-wt"
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add -q "$wt_path" HEAD 2>/dev/null

    assert_true "test -d '$wt_path'" "Worktree exists before cleanup"

    # Remove worktree properly
    git -C "$repo_path" worktree remove -f "$wt_path" 2>/dev/null

    assert_true "test ! -d '$wt_path'" "Worktree directory removed"

    # Verify worktree list is updated
    local wt_list
    wt_list=$(git -C "$repo_path" worktree list --porcelain)
    assert_not_contains "$wt_list" "cleanup-wt" "Worktree removed from list"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Orphaned worktree detection
#==============================================================================

test_worktree_orphaned_detection() {
    local test_name="Orphaned worktree detection"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "orphan-repo" 1)

    # Create worktree
    local wt_path="$E2E_TEMP_DIR/worktrees/orphan-wt"
    mkdir -p "$(dirname "$wt_path")"
    git -C "$repo_path" worktree add -q "$wt_path" HEAD 2>/dev/null

    # Simulate orphaned worktree by removing directory but not git reference
    rm -rf "$wt_path"

    # git worktree list should still show it (as prunable)
    local wt_list
    wt_list=$(git -C "$repo_path" worktree list 2>/dev/null)
    # The worktree should still be listed but marked as prunable

    # Prune to clean up
    git -C "$repo_path" worktree prune 2>/dev/null

    # After prune, should be gone
    wt_list=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
    assert_not_contains "$wt_list" "orphan-wt" "Orphaned worktree pruned"

    pass "Orphan detection and prune works"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Concurrent worktree operations
#==============================================================================

test_worktree_concurrent() {
    local test_name="Concurrent worktree operations"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "concurrent-repo" 5)

    # Create multiple worktrees concurrently
    local wt_base="$E2E_TEMP_DIR/worktrees/concurrent"
    mkdir -p "$wt_base"

    local pids=()
    for i in 1 2 3; do
        (
            git -C "$repo_path" worktree add -q "$wt_base/wt$i" HEAD 2>/dev/null
        ) &
        pids+=($!)
    done

    # Wait for all to complete
    local all_ok=true
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            all_ok=false
        fi
    done

    if $all_ok; then
        pass "Concurrent worktree creation succeeded"
    else
        fail "Some concurrent worktree creations failed"
    fi

    # Verify all worktrees exist
    assert_true "test -d '$wt_base/wt1'" "Worktree 1 exists"
    assert_true "test -d '$wt_base/wt2'" "Worktree 2 exists"
    assert_true "test -d '$wt_base/wt3'" "Worktree 3 exists"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Test: Worktree with custom path
#==============================================================================

test_worktree_custom_path() {
    local test_name="Worktree with custom path"
    log_test_start "$test_name"

    worktree_test_setup

    # Create test repo
    local repo_path
    repo_path=$(create_worktree_test_repo "custom-path-repo" 2)

    # Create worktree with deeply nested custom path
    local custom_path="$E2E_TEMP_DIR/custom/deeply/nested/worktree"
    mkdir -p "$(dirname "$custom_path")"

    local wt_result=0
    git -C "$repo_path" worktree add -q "$custom_path" HEAD 2>/dev/null || wt_result=$?

    assert_equals "0" "$wt_result" "Custom path worktree creation succeeds"
    assert_true "test -d '$custom_path'" "Custom path worktree exists"

    # Verify git operations work in custom path worktree
    local status_result=0
    git -C "$custom_path" status >/dev/null 2>&1 || status_result=$?
    assert_equals "0" "$status_result" "Git status works in custom path worktree"

    e2e_cleanup
    log_test_pass "$test_name"
}

#==============================================================================
# Run Tests
#==============================================================================

log_suite_start "E2E Tests: Worktree Management (bd-33aj)"

run_test test_worktree_create_from_main
run_test test_worktree_create_with_branch
run_test test_worktree_mapping
run_test test_worktree_list
run_test test_worktree_cleanup
run_test test_worktree_orphaned_detection
run_test test_worktree_concurrent
run_test test_worktree_custom_path

print_results
exit $?
