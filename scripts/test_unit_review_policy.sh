#!/usr/bin/env bash
#
# Unit tests: Review Policy Functions (bd-7onq)
#
# Covers:
# - get_review_policy_dir
# - init_review_policies
# - validate_policy_file
# - load_policy_for_repo
# - get_policy_value
# - repo_allows_push
# - repo_requires_approval
# - apply_policy_priority_boost
#
# Uses real file operations in isolated temp directories.
#
# shellcheck disable=SC1091  # Sourced files checked separately
# shellcheck disable=SC2317  # Test functions invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/test_framework.sh"

source_ru_function "get_review_policy_dir"
source_ru_function "init_review_policies"
source_ru_function "validate_policy_file"
source_ru_function "load_policy_for_repo"
source_ru_function "get_policy_value"
source_ru_function "repo_allows_push"
source_ru_function "repo_requires_approval"
source_ru_function "apply_policy_priority_boost"

# Stub logging functions
log_info() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_warn() { :; }
log_verbose() { :; }

require_jq_or_skip() {
    if ! command -v jq &>/dev/null; then
        skip_test "jq not installed"
        return 1
    fi
    return 0
}

# Helper: create an isolated policy environment
# NOTE: Must set RU_CONFIG_DIR in the caller after capturing stdout,
# because command substitution runs in a subshell (exports don't propagate).
setup_policy_env() {
    local tmp
    tmp=$(create_temp_dir)
    mkdir -p "$tmp/config/ru"
    echo "$tmp"
}

# Helper: set RU_CONFIG_DIR from setup_policy_env output
# Usage: local tmp; tmp=$(setup_policy_env); use_policy_env "$tmp"
use_policy_env() {
    export RU_CONFIG_DIR="$1/config/ru"
}

# Helper: write a policy file
write_policy() {
    local dir="$1" name="$2"
    shift 2
    local policy_dir="$dir/config/ru/review-policies.d"
    mkdir -p "$policy_dir"
    printf '%s\n' "$@" > "$policy_dir/$name"
}

#==============================================================================
# Tests: get_review_policy_dir
#==============================================================================

test_get_review_policy_dir_uses_config_dir() {
    local test_name="get_review_policy_dir: uses RU_CONFIG_DIR"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local result
    result=$(get_review_policy_dir)
    assert_equals "$tmp/config/ru/review-policies.d" "$result" "Should use RU_CONFIG_DIR"

    log_test_pass "$test_name"
}

test_get_review_policy_dir_falls_back_to_home() {
    local test_name="get_review_policy_dir: falls back to HOME"
    log_test_start "$test_name"

    local old_config="${RU_CONFIG_DIR:-}"
    unset RU_CONFIG_DIR
    local result
    result=$(get_review_policy_dir)
    assert_equals "$HOME/.config/ru/review-policies.d" "$result" "Should fall back to HOME"
    if [[ -n "$old_config" ]]; then
        export RU_CONFIG_DIR="$old_config"
    fi

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: init_review_policies
#==============================================================================

test_init_review_policies_creates_dir_and_example() {
    local test_name="init_review_policies: creates dir with example"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    init_review_policies "quiet" >/dev/null 2>&1
    local policy_dir="$tmp/config/ru/review-policies.d"

    assert_dir_exists "$policy_dir" "Policy directory should be created"
    assert_file_exists "$policy_dir/_default.example" "Example file should exist"

    log_test_pass "$test_name"
}

test_init_review_policies_idempotent() {
    local test_name="init_review_policies: idempotent on existing dir"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    init_review_policies "quiet" >/dev/null 2>&1
    # Second call should succeed
    init_review_policies "quiet" >/dev/null 2>&1
    local rc=$?
    assert_equals "0" "$rc" "Second call should succeed"

    log_test_pass "$test_name"
}

test_init_review_policies_example_content() {
    local test_name="init_review_policies: example has expected keys"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    init_review_policies "quiet" >/dev/null 2>&1
    local example="$tmp/config/ru/review-policies.d/_default.example"

    assert_file_contains "$example" "BASE_PRIORITY" "Should contain BASE_PRIORITY"
    assert_file_contains "$example" "REVIEW_ALLOW_PUSH" "Should contain REVIEW_ALLOW_PUSH"
    assert_file_contains "$example" "LABEL_PRIORITY_BOOST" "Should contain LABEL_PRIORITY_BOOST"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: validate_policy_file
#==============================================================================

test_validate_policy_file_valid() {
    local test_name="validate_policy_file: accepts valid file"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_valid"
    printf '%s\n' \
        "# Comment line" \
        "" \
        "BASE_PRIORITY=2" \
        "REVIEW_ALLOW_PUSH=true" \
        "REVIEW_REQUIRE_APPROVAL=false" \
        "MAX_PARALLEL_AGENTS=8" \
        'LABEL_PRIORITY_BOOST=security=2,bug=1' \
        "SKIP_PATTERNS=*.generated.go,vendor/*" \
        'TEST_COMMAND=make test' \
        'LINT_COMMAND=golangci-lint run' \
        > "$pf"

    local output
    output=$(validate_policy_file "$pf" 2>/dev/null)
    assert_equals "Valid" "$output" "Should output Valid"

    log_test_pass "$test_name"
}

test_validate_policy_file_missing_file() {
    local test_name="validate_policy_file: rejects missing file"
    log_test_start "$test_name"

    validate_policy_file "/nonexistent/path/policy" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should return 1 for missing file"

    log_test_pass "$test_name"
}

test_validate_policy_file_invalid_format() {
    local test_name="validate_policy_file: rejects bad KEY=VALUE format"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_bad_format"
    printf '%s\n' \
        "not a valid line" \
        "lowercase_key=value" \
        > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject invalid format"

    log_test_pass "$test_name"
}

test_validate_policy_file_invalid_base_priority() {
    local test_name="validate_policy_file: rejects non-integer BASE_PRIORITY"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_bad_priority"
    echo "BASE_PRIORITY=abc" > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject non-integer priority"

    log_test_pass "$test_name"
}

test_validate_policy_file_negative_base_priority() {
    local test_name="validate_policy_file: accepts negative BASE_PRIORITY"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_neg_priority"
    echo "BASE_PRIORITY=-3" > "$pf"

    local output
    output=$(validate_policy_file "$pf" 2>/dev/null)
    assert_equals "Valid" "$output" "Should accept negative integer"

    log_test_pass "$test_name"
}

test_validate_policy_file_invalid_boolean() {
    local test_name="validate_policy_file: rejects bad boolean"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_bad_bool"
    echo "REVIEW_ALLOW_PUSH=yes" > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject 'yes' (not true/false)"

    log_test_pass "$test_name"
}

test_validate_policy_file_invalid_max_parallel() {
    local test_name="validate_policy_file: rejects zero MAX_PARALLEL_AGENTS"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_bad_max"
    echo "MAX_PARALLEL_AGENTS=0" > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject 0 (must be positive)"

    log_test_pass "$test_name"
}

test_validate_policy_file_invalid_label_boost() {
    local test_name="validate_policy_file: rejects bad LABEL_PRIORITY_BOOST"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_bad_label"
    echo "LABEL_PRIORITY_BOOST=security:high,bug:low" > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject colon-separated format"

    log_test_pass "$test_name"
}

test_validate_policy_file_unknown_key() {
    local test_name="validate_policy_file: rejects unknown key"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_unknown_key"
    echo "FOOBAR_SETTING=value" > "$pf"

    validate_policy_file "$pf" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should reject unknown policy key"

    log_test_pass "$test_name"
}

test_validate_policy_file_comments_and_blanks_ignored() {
    local test_name="validate_policy_file: skips comments and blank lines"
    log_test_start "$test_name"

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    local pf="$tmp/policy_comments"
    printf '%s\n' \
        "# Full line comment" \
        "" \
        "  # Indented comment" \
        "BASE_PRIORITY=0" \
        "" \
        > "$pf"

    local output
    output=$(validate_policy_file "$pf" 2>/dev/null)
    assert_equals "Valid" "$output" "Should skip comments/blanks"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: load_policy_for_repo
#==============================================================================

test_load_policy_defaults_when_no_files() {
    local test_name="load_policy_for_repo: returns defaults with no policy files"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    mkdir -p "$tmp/config/ru/review-policies.d"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local base_p allow_push require_approval max_p
    base_p=$(echo "$output" | jq -r '.base_priority')
    allow_push=$(echo "$output" | jq -r '.allow_push')
    require_approval=$(echo "$output" | jq -r '.require_approval')
    max_p=$(echo "$output" | jq -r '.max_parallel_agents')

    assert_equals "0" "$base_p" "Default base_priority=0"
    assert_equals "false" "$allow_push" "Default allow_push=false"
    assert_equals "true" "$require_approval" "Default require_approval=true"
    assert_equals "4" "$max_p" "Default max_parallel_agents=4"

    log_test_pass "$test_name"
}

test_load_policy_reads_default_file() {
    local test_name="load_policy_for_repo: reads _default policy"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=3" \
        "REVIEW_ALLOW_PUSH=true"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local base_p allow_push policies
    base_p=$(echo "$output" | jq -r '.base_priority')
    allow_push=$(echo "$output" | jq -r '.allow_push')
    policies=$(echo "$output" | jq -r '.policies_loaded | join(",")')

    assert_equals "3" "$base_p" "Should read BASE_PRIORITY from _default"
    assert_equals "true" "$allow_push" "Should read REVIEW_ALLOW_PUSH from _default"
    assert_contains "$policies" "_default" "Should track _default in loaded list"

    log_test_pass "$test_name"
}

test_load_policy_exact_repo_overrides_default() {
    local test_name="load_policy_for_repo: exact repo overrides _default"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=1" \
        "REVIEW_ALLOW_PUSH=false"
    write_policy "$tmp" "github.com_owner_repo" \
        "BASE_PRIORITY=5" \
        "REVIEW_ALLOW_PUSH=true"

    local output
    output=$(load_policy_for_repo "github.com/owner/repo")
    local base_p allow_push
    base_p=$(echo "$output" | jq -r '.base_priority')
    allow_push=$(echo "$output" | jq -r '.allow_push')

    assert_equals "5" "$base_p" "Exact match should override default"
    assert_equals "true" "$allow_push" "Exact match should override allow_push"

    log_test_pass "$test_name"
}

test_load_policy_skips_example_files() {
    local test_name="load_policy_for_repo: skips .example files"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default.example" \
        "BASE_PRIORITY=99"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local base_p
    base_p=$(echo "$output" | jq -r '.base_priority')
    assert_equals "0" "$base_p" "Should not load .example file"

    log_test_pass "$test_name"
}

test_load_policy_normalizes_repo_id() {
    local test_name="load_policy_for_repo: normalizes slashes/colons to underscores"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "github.com_owner_myrepo" \
        "MAX_PARALLEL_AGENTS=12"

    local output
    output=$(load_policy_for_repo "github.com/owner/myrepo")
    local max_p
    max_p=$(echo "$output" | jq -r '.max_parallel_agents')
    assert_equals "12" "$max_p" "Should match after normalizing slashes"

    log_test_pass "$test_name"
}

test_load_policy_strips_quotes() {
    local test_name="load_policy_for_repo: strips surrounding quotes from values"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        'SKIP_PATTERNS="*.generated.go,vendor/*"' \
        "TEST_COMMAND='make test'"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local skip test_cmd
    skip=$(echo "$output" | jq -r '.skip_patterns')
    test_cmd=$(echo "$output" | jq -r '.test_command')
    assert_equals "*.generated.go,vendor/*" "$skip" "Should strip double quotes"
    assert_equals "make test" "$test_cmd" "Should strip single quotes"

    log_test_pass "$test_name"
}

test_load_policy_merge_order() {
    local test_name="load_policy_for_repo: merge order default < exact"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=1" \
        "REVIEW_ALLOW_PUSH=false" \
        "MAX_PARALLEL_AGENTS=2"
    # Exact match only overrides some keys
    write_policy "$tmp" "owner_repo" \
        "BASE_PRIORITY=10"

    local output
    output=$(load_policy_for_repo "owner/repo")
    local base_p allow_push max_p
    base_p=$(echo "$output" | jq -r '.base_priority')
    allow_push=$(echo "$output" | jq -r '.allow_push')
    max_p=$(echo "$output" | jq -r '.max_parallel_agents')

    assert_equals "10" "$base_p" "Exact overrides base_priority"
    assert_equals "false" "$allow_push" "Default preserved when not overridden"
    assert_equals "2" "$max_p" "Default preserved for max_parallel"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: get_policy_value
#==============================================================================

test_get_policy_value_returns_field() {
    local test_name="get_policy_value: returns specific field"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=7"

    local value
    value=$(get_policy_value "owner/repo" "base_priority")
    assert_equals "7" "$value" "Should return base_priority value"

    log_test_pass "$test_name"
}

test_get_policy_value_returns_boolean() {
    local test_name="get_policy_value: returns boolean as string"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "REVIEW_ALLOW_PUSH=true"

    local value
    value=$(get_policy_value "owner/repo" "allow_push")
    assert_equals "true" "$value" "Should return true"

    log_test_pass "$test_name"
}

test_get_policy_value_fails_for_empty() {
    local test_name="get_policy_value: fails for empty string field"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    mkdir -p "$tmp/config/ru/review-policies.d"

    # test_command defaults to "" which jq returns as empty
    get_policy_value "owner/repo" "test_command" >/dev/null 2>&1
    local rc=$?
    assert_equals "1" "$rc" "Should return 1 for empty value"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: repo_allows_push
#==============================================================================

test_repo_allows_push_default_false() {
    local test_name="repo_allows_push: default is false"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    mkdir -p "$tmp/config/ru/review-policies.d"

    repo_allows_push "owner/repo"
    local rc=$?
    assert_equals "1" "$rc" "Default should deny push (rc=1)"

    log_test_pass "$test_name"
}

test_repo_allows_push_when_enabled() {
    local test_name="repo_allows_push: returns 0 when policy enables it"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "REVIEW_ALLOW_PUSH=true"

    repo_allows_push "owner/repo"
    local rc=$?
    assert_equals "0" "$rc" "Should allow push (rc=0)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: repo_requires_approval
#==============================================================================

test_repo_requires_approval_default_true() {
    local test_name="repo_requires_approval: default is true"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    mkdir -p "$tmp/config/ru/review-policies.d"

    repo_requires_approval "owner/repo"
    local rc=$?
    assert_equals "0" "$rc" "Default should require approval (rc=0)"

    log_test_pass "$test_name"
}

test_repo_requires_approval_when_disabled() {
    local test_name="repo_requires_approval: returns 1 when disabled"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "REVIEW_REQUIRE_APPROVAL=false"

    repo_requires_approval "owner/repo"
    local rc=$?
    assert_equals "1" "$rc" "Should not require approval (rc=1)"

    log_test_pass "$test_name"
}

#==============================================================================
# Tests: apply_policy_priority_boost
#==============================================================================

test_apply_priority_boost_no_policy_no_change() {
    local test_name="apply_policy_priority_boost: no policy returns same priority"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    mkdir -p "$tmp/config/ru/review-policies.d"

    local result
    result=$(apply_policy_priority_boost "owner/repo" 2 "")
    assert_equals "2" "$result" "No policy should leave priority unchanged"

    log_test_pass "$test_name"
}

test_apply_priority_boost_base_boost() {
    local test_name="apply_policy_priority_boost: base boost subtracts from priority"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=1"

    # Priority 3 with boost 1 → 3-1=2
    local result
    result=$(apply_policy_priority_boost "owner/repo" 3 "")
    assert_equals "2" "$result" "boost=1 should lower priority from 3 to 2"

    log_test_pass "$test_name"
}

test_apply_priority_boost_label_boost() {
    local test_name="apply_policy_priority_boost: label boost adds to total"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=0" \
        "LABEL_PRIORITY_BOOST=security=2,bug=1"

    # Priority 3, label "security" → boost 2 → 3-2=1
    local result
    result=$(apply_policy_priority_boost "owner/repo" 3 "security")
    assert_equals "1" "$result" "security label should lower priority by 2"

    log_test_pass "$test_name"
}

test_apply_priority_boost_multiple_labels() {
    local test_name="apply_policy_priority_boost: multiple labels accumulate"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "LABEL_PRIORITY_BOOST=security=2,bug=1"

    # Priority 4, labels "security,bug" → boost 2+1=3 → 4-3=1
    local result
    result=$(apply_policy_priority_boost "owner/repo" 4 "security,bug")
    assert_equals "1" "$result" "security+bug should lower priority by 3"

    log_test_pass "$test_name"
}

test_apply_priority_boost_clamps_to_zero() {
    local test_name="apply_policy_priority_boost: clamps to minimum 0"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=10"

    # Priority 2, boost 10 → 2-10=-8 → clamped to 0
    local result
    result=$(apply_policy_priority_boost "owner/repo" 2 "")
    assert_equals "0" "$result" "Should clamp to 0"

    log_test_pass "$test_name"
}

test_apply_priority_boost_clamps_to_four() {
    local test_name="apply_policy_priority_boost: clamps to maximum 4"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "BASE_PRIORITY=-10"

    # Priority 2, boost -10 → 2-(-10)=12 → clamped to 4
    local result
    result=$(apply_policy_priority_boost "owner/repo" 2 "")
    assert_equals "4" "$result" "Should clamp to 4"

    log_test_pass "$test_name"
}

test_apply_priority_boost_negative_label_boost() {
    local test_name="apply_policy_priority_boost: negative label boost increases priority number"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "LABEL_PRIORITY_BOOST=documentation=-1"

    # Priority 2, label "documentation" → boost -1 → 2-(-1)=3
    local result
    result=$(apply_policy_priority_boost "owner/repo" 2 "documentation")
    assert_equals "3" "$result" "Negative label boost should increase priority number"

    log_test_pass "$test_name"
}

test_apply_priority_boost_unmatched_labels_ignored() {
    local test_name="apply_policy_priority_boost: unmatched labels are ignored"
    log_test_start "$test_name"
    require_jq_or_skip || return 0

    local tmp
    tmp=$(setup_policy_env); use_policy_env "$tmp"
    write_policy "$tmp" "_default" \
        "LABEL_PRIORITY_BOOST=security=2"

    # Priority 3, label "feature" (not in policy) → no boost → stays 3
    local result
    result=$(apply_policy_priority_boost "owner/repo" 3 "feature")
    assert_equals "3" "$result" "Unmatched label should not change priority"

    log_test_pass "$test_name"
}

#==============================================================================
# Run all tests
#==============================================================================

# get_review_policy_dir
run_test test_get_review_policy_dir_uses_config_dir
run_test test_get_review_policy_dir_falls_back_to_home

# init_review_policies
run_test test_init_review_policies_creates_dir_and_example
run_test test_init_review_policies_idempotent
run_test test_init_review_policies_example_content

# validate_policy_file
run_test test_validate_policy_file_valid
run_test test_validate_policy_file_missing_file
run_test test_validate_policy_file_invalid_format
run_test test_validate_policy_file_invalid_base_priority
run_test test_validate_policy_file_negative_base_priority
run_test test_validate_policy_file_invalid_boolean
run_test test_validate_policy_file_invalid_max_parallel
run_test test_validate_policy_file_invalid_label_boost
run_test test_validate_policy_file_unknown_key
run_test test_validate_policy_file_comments_and_blanks_ignored

# load_policy_for_repo
run_test test_load_policy_defaults_when_no_files
run_test test_load_policy_reads_default_file
run_test test_load_policy_exact_repo_overrides_default
run_test test_load_policy_skips_example_files
run_test test_load_policy_normalizes_repo_id
run_test test_load_policy_strips_quotes
run_test test_load_policy_merge_order

# get_policy_value
run_test test_get_policy_value_returns_field
run_test test_get_policy_value_returns_boolean
run_test test_get_policy_value_fails_for_empty

# repo_allows_push / repo_requires_approval
run_test test_repo_allows_push_default_false
run_test test_repo_allows_push_when_enabled
run_test test_repo_requires_approval_default_true
run_test test_repo_requires_approval_when_disabled

# apply_policy_priority_boost
run_test test_apply_priority_boost_no_policy_no_change
run_test test_apply_priority_boost_base_boost
run_test test_apply_priority_boost_label_boost
run_test test_apply_priority_boost_multiple_labels
run_test test_apply_priority_boost_clamps_to_zero
run_test test_apply_priority_boost_clamps_to_four
run_test test_apply_priority_boost_negative_label_boost
run_test test_apply_priority_boost_unmatched_labels_ignored

print_results
exit "$(get_exit_code)"
