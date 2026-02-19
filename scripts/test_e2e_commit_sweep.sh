#!/usr/bin/env bash
#
# E2E Test: ru commit-sweep workflow
#
# Coverage:
# - dry-run on dirty repo shows plan
# - json dry-run output validates envelope
# - execute creates commits
# - protected branch guard
# - protected branch override
# - respect-staging option
# - clean repo produces no output
# - json envelope structure
#
# shellcheck disable=SC1091
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_e2e_framework.sh"

create_dirty_repo() {
    local name="$1"
    local repo_dir="$RU_PROJECTS_DIR/$name"
    local remote_dir="$E2E_TEMP_DIR/remotes/$name.git"

    mkdir -p "$remote_dir"
    git -C "$remote_dir" init --bare >/dev/null 2>&1

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init >/dev/null 2>&1
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"

    echo "initial" > "$repo_dir/README.md"
    echo "print('hello')" > "$repo_dir/main.py"
    git -C "$repo_dir" add . >/dev/null 2>&1
    git -C "$repo_dir" commit -m "init" >/dev/null 2>&1

    git -C "$repo_dir" remote add origin "$remote_dir" >/dev/null 2>&1
    git -C "$repo_dir" push -u origin main >/dev/null 2>&1 || \
        git -C "$repo_dir" push -u origin master >/dev/null 2>&1

    echo "$repo_dir"
}

# ---------------------------------------------------------------------------
# Test 1: dry-run on dirty repo shows plan
# ---------------------------------------------------------------------------
test_commit_sweep_dry_run_shows_plan() {
    local test_name="commit-sweep: dry-run shows plan"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # Dirty some files: modify source, add test, add doc
    echo "print('changed')" > "$repo_dir/main.py"
    mkdir -p "$repo_dir/scripts"
    echo "echo test" > "$repo_dir/scripts/test_foo.sh"
    echo "# New doc" > "$repo_dir/README_NEW.md"

    e2e_assert_ru_exit 0 "commit-sweep" "dry-run exits 0"
    e2e_assert_ru_stderr_contains "commit-sweep" "Repository:" "shows repo info"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 2: json dry-run output
# ---------------------------------------------------------------------------
test_commit_sweep_json_dry_run() {
    local test_name="commit-sweep: json dry-run output"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # One dirty file (source bucket)
    echo "print('changed')" > "$repo_dir/main.py"

    e2e_assert_ru_json "commit-sweep --json" \
        ".data.summary.repos_dirty" "1" "json reports dirty repo"
    e2e_assert_ru_json "commit-sweep --json" \
        ".data.schema_version" "commit-sweep/v1" "json has schema version"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 3: execute creates commits on a feature branch
# ---------------------------------------------------------------------------
test_commit_sweep_execute_creates_commits() {
    local test_name="commit-sweep: execute creates commits"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # Checkout a feature branch so protected-branch guard passes
    git -C "$repo_dir" checkout -b feature/test-sweep >/dev/null 2>&1

    # Add dirty files in different buckets (source + doc)
    echo "print('updated')" > "$repo_dir/main.py"
    echo "# New documentation" > "$repo_dir/CHANGELOG.md"

    # Execute
    local stdout_file="$E2E_LOG_DIR/cs_exec_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/cs_exec_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --execute >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 0 ]]" "commit-sweep --execute exits 0"

    # Verify commits exist
    local commit_count
    commit_count=$(git -C "$repo_dir" log --oneline -10 2>/dev/null | wc -l)
    assert_true "[[ $commit_count -ge 2 ]]" "at least 2 commits exist (init + sweep)"

    # Working dir should be clean after execute
    local dirty_count
    dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l)
    assert_true "[[ $dirty_count -eq 0 ]]" "working directory is clean after execute"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 4: protected branch guard refuses commit on main
# ---------------------------------------------------------------------------
test_commit_sweep_protected_branch_guard() {
    local test_name="commit-sweep: protected branch guard"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # Stay on main (the default after create_dirty_repo)
    echo "print('dirty')" > "$repo_dir/main.py"

    # Execute should print the guard message
    e2e_assert_ru_stderr_contains "commit-sweep --execute" \
        "Refusing to commit on protected branch" \
        "protected branch guard message shown"

    # Files should still be dirty (uncommitted)
    local dirty_count
    dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l)
    assert_true "[[ $dirty_count -gt 0 ]]" "files still dirty after protected branch refusal"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 5: protected branch override with --allow-protected-branch
# ---------------------------------------------------------------------------
test_commit_sweep_protected_branch_override() {
    local test_name="commit-sweep: protected branch override"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # Stay on main, dirty a file
    echo "print('override')" > "$repo_dir/main.py"

    # Override the guard
    local stdout_file="$E2E_LOG_DIR/cs_override_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/cs_override_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --execute --allow-protected-branch \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 0 ]]" "override exits 0"

    # Working dir should be clean
    local dirty_count
    dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l)
    assert_true "[[ $dirty_count -eq 0 ]]" "working directory is clean after override"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 6: clean repo produces no output
# ---------------------------------------------------------------------------
test_commit_sweep_clean_repo() {
    local test_name="commit-sweep: clean repo produces no output"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    create_dirty_repo "testrepo" >/dev/null
    e2e_add_repo "example/testrepo"

    # Don't dirty anything; repo is clean after create_dirty_repo
    e2e_assert_ru_exit 0 "commit-sweep" "clean repo exits 0"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 7: json envelope has correct structure
# ---------------------------------------------------------------------------
test_commit_sweep_json_envelope() {
    local test_name="commit-sweep: json envelope structure"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # One dirty file so we get data
    echo "print('changed')" > "$repo_dir/main.py"

    e2e_assert_ru_json "commit-sweep --json" \
        ".command" "commit-sweep" "envelope command field"
    e2e_assert_ru_json "commit-sweep --json" \
        ".output_format" "json" "envelope output_format field"
    e2e_assert_ru_json "commit-sweep --json" \
        "has(\"generated_at\")" "true" "envelope has generated_at"
    e2e_assert_ru_json "commit-sweep --json" \
        "has(\"version\")" "true" "envelope has version"
    e2e_assert_ru_json "commit-sweep --json" \
        "has(\"data\")" "true" "envelope has data"
    e2e_assert_ru_json "commit-sweep --json" \
        "has(\"_meta\")" "true" "envelope has _meta"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 8: respect-staging separates pre-staged files
# ---------------------------------------------------------------------------
test_commit_sweep_respects_staging() {
    local test_name="commit-sweep: respect-staging option"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    # Checkout a feature branch
    git -C "$repo_dir" checkout -b feature/staging-test >/dev/null 2>&1

    # Stage one file explicitly
    echo "print('staged')" > "$repo_dir/main.py"
    git -C "$repo_dir" add main.py >/dev/null 2>&1

    # Leave another file unstaged
    echo "# unstaged doc" > "$repo_dir/NOTES.md"

    # With --respect-staging, the pre-staged file should be noted separately
    local stdout_file="$E2E_LOG_DIR/cs_staging_stdout.json"
    local stderr_file="$E2E_LOG_DIR/cs_staging_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --json --respect-staging \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 0 ]]" "respect-staging exits 0"

    if command -v jq &>/dev/null; then
        # Check that there are multiple groups (pre-staged + at least one bucket)
        local group_count
        group_count=$(jq -r '.data.repos[0].groups | length' "$stdout_file" 2>/dev/null || echo "0")
        assert_true "[[ $group_count -ge 2 ]]" "at least 2 groups with respect-staging (got $group_count)"

        # Check that a pre-staged bucket exists
        local has_prestaged
        has_prestaged=$(jq -r '[.data.repos[0].groups[].bucket] | any(. == "pre-staged")' "$stdout_file" 2>/dev/null || echo "false")
        assert_true "[[ \"$has_prestaged\" == \"true\" ]]" "pre-staged bucket present"
    else
        skip_test "jq not installed"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 9: exit code 1 on partial commit failure (Finding #1)
# ---------------------------------------------------------------------------
test_commit_sweep_exit_code_on_failure() {
    local test_name="commit-sweep: exit code 1 on commit failure"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    git -C "$repo_dir" checkout -b feature/fail-test >/dev/null 2>&1

    # Create a file and then delete it before commit to cause staging failure
    echo "content" > "$repo_dir/normal.py"
    # Install a pre-commit hook that fails for any commit containing "FAIL_THIS"
    mkdir -p "$repo_dir/.git/hooks"
    cat > "$repo_dir/.git/hooks/pre-commit" << 'HOOK'
#!/bin/bash
if git diff --cached --name-only | grep -q "fail_trigger"; then
    echo "Hook: rejecting commit" >&2
    exit 1
fi
exit 0
HOOK
    chmod +x "$repo_dir/.git/hooks/pre-commit"
    echo "trigger" > "$repo_dir/fail_trigger.py"

    local stdout_file="$E2E_LOG_DIR/cs_fail_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/cs_fail_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --execute \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 1 ]]" "exit code 1 on partial failure"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 10: comma in filename handled correctly (Finding #2)
# ---------------------------------------------------------------------------
test_commit_sweep_comma_in_filename() {
    local test_name="commit-sweep: comma in filename"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    git -C "$repo_dir" checkout -b feature/comma-test >/dev/null 2>&1

    # Create file with comma in name
    echo "data" > "$repo_dir/comma,name.py"

    local stdout_file="$E2E_LOG_DIR/cs_comma_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/cs_comma_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --execute \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 0 ]]" "comma filename: exits 0"

    # Verify the file was actually committed (working dir clean)
    local dirty_count
    dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l)
    assert_true "[[ $dirty_count -eq 0 ]]" "comma filename: working dir clean after execute"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 11: --respect-staging filters denylist (Finding #3)
# ---------------------------------------------------------------------------
test_commit_sweep_prestaged_denylist() {
    local test_name="commit-sweep: pre-staged denylist filtering"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    git -C "$repo_dir" checkout -b feature/denylist-test >/dev/null 2>&1

    # Stage a .env file (should be blocked by denylist)
    echo "SECRET=abc123" > "$repo_dir/.env"
    git -C "$repo_dir" add .env >/dev/null 2>&1

    # Also have a normal unstaged file
    echo "normal content" > "$repo_dir/app.py"

    # Run with --respect-staging --json
    local stdout_file="$E2E_LOG_DIR/cs_denylist_stdout.json"
    local stderr_file="$E2E_LOG_DIR/cs_denylist_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" commit-sweep --json --respect-staging \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    if command -v jq &>/dev/null; then
        # .env should NOT appear in any group's files
        local has_env
        has_env=$(jq -r '[.data.repos[0].groups[].files[]] | any(. == ".env")' "$stdout_file" 2>/dev/null || echo "true")
        assert_true "[[ \"$has_env\" == \"false\" ]]" ".env blocked by denylist in pre-staged group"
    else
        skip_test "jq not installed"
    fi

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Test 12: flags before command work (Finding #4)
# ---------------------------------------------------------------------------
test_commit_sweep_flags_before_command() {
    local test_name="commit-sweep: flags before command name"
    log_test_start "$test_name"

    e2e_setup
    e2e_init_ru

    local repo_dir
    repo_dir=$(create_dirty_repo "testrepo")
    e2e_add_repo "example/testrepo"

    git -C "$repo_dir" checkout -b feature/flags-test >/dev/null 2>&1
    echo "changed" > "$repo_dir/main.py"

    # Run with --execute BEFORE commit-sweep
    local stdout_file="$E2E_LOG_DIR/cs_flags_stdout.txt"
    local stderr_file="$E2E_LOG_DIR/cs_flags_stderr.txt"
    local actual_code=0
    "$E2E_RU_SCRIPT" --execute commit-sweep \
        >"$stdout_file" 2>"$stderr_file" || actual_code=$?

    assert_true "[[ $actual_code -eq 0 ]]" "flags-before-command: exits 0"

    # Should actually execute (not dry-run) — check stderr for "execute" mode
    assert_true "grep -q 'execute' \"$stderr_file\"" "flags-before-command: ran in execute mode"

    # Working dir should be clean (commits were made)
    local dirty_count
    dirty_count=$(git -C "$repo_dir" status --porcelain 2>/dev/null | wc -l)
    assert_true "[[ $dirty_count -eq 0 ]]" "flags-before-command: working dir clean"

    e2e_cleanup
    log_test_pass "$test_name"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
setup_cleanup_trap
run_test test_commit_sweep_dry_run_shows_plan
run_test test_commit_sweep_json_dry_run
run_test test_commit_sweep_execute_creates_commits
run_test test_commit_sweep_protected_branch_guard
run_test test_commit_sweep_protected_branch_override
run_test test_commit_sweep_clean_repo
run_test test_commit_sweep_json_envelope
run_test test_commit_sweep_respects_staging
run_test test_commit_sweep_exit_code_on_failure
run_test test_commit_sweep_comma_in_filename
run_test test_commit_sweep_prestaged_denylist
run_test test_commit_sweep_flags_before_command
print_results
exit "$(get_exit_code)"
