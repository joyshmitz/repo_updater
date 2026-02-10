#!/usr/bin/env bash
# Contract and golden fixture validation for fork-* JSON outputs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RU_SCRIPT="$PROJECT_DIR/ru"
FIXTURE_FILE="$SCRIPT_DIR/fixtures/real_world/fork_json_contracts.json"

TESTS_PASSED=0
TESTS_FAILED=0
TEMP_DIR=""

if [[ -t 2 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; RESET='\033[0m'
else
  RED=''; GREEN=''; RESET=''
fi

pass() { echo -e "${GREEN}PASS${RESET}: $1"; ((TESTS_PASSED++)); }
fail() { echo -e "${RED}FAIL${RESET}: $1"; ((TESTS_FAILED++)); }

setup_test_env() {
  TEMP_DIR=$(mktemp -d)
  export XDG_CONFIG_HOME="$TEMP_DIR/config"
  export XDG_STATE_HOME="$TEMP_DIR/state"
  export XDG_CACHE_HOME="$TEMP_DIR/cache"
  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME"
  export TEST_PROJECTS_DIR="$TEMP_DIR/projects"
  mkdir -p "$TEST_PROJECTS_DIR" "$TEMP_DIR/remotes"
}

cleanup_test_env() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

create_bare_with_branch() {
  local name="$1" branch="$2"
  local bare_dir="$TEMP_DIR/remotes/$name.git"
  mkdir -p "$bare_dir"
  git init --bare "$bare_dir" >/dev/null 2>&1
  git -C "$bare_dir" symbolic-ref HEAD "refs/heads/$branch"

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

add_commit_to_bare() {
  local bare_dir="$1" branch="$2" msg="${3:-upstream change}"
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

setup_fork_repo() {
  local name="$1" branch="$2"
  local upstream_dir
  upstream_dir=$(create_bare_with_branch "${name}-upstream" "$branch")
  add_commit_to_bare "$upstream_dir" "$branch" "upstream ahead"

  local origin_dir
  origin_dir=$(create_bare_with_branch "${name}-origin" "$branch")

  local local_path="$TEST_PROJECTS_DIR/$name"
  git clone -b "$branch" "$origin_dir" "$local_path" >/dev/null 2>&1
  git -C "$local_path" config user.email "test@test.com"
  git -C "$local_path" config user.name "Test"
  git -C "$local_path" remote add upstream "$upstream_dir"
  git -C "$local_path" fetch upstream >/dev/null 2>&1

  echo "$local_path"
}

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

validate_contract() {
  local command="$1" output="$2"

  if ! jq -e --arg cmd "$command" '.command == $cmd and .generated_at and .version and .output_format and .data' <<< "$output" >/dev/null 2>&1; then
    fail "$command envelope required fields"
    return
  fi
  pass "$command envelope required fields"

  if ! jq -e --arg cmd "$command" '.commands[$cmd]' "$FIXTURE_FILE" >/dev/null 2>&1; then
    fail "$command exists in golden fixture"
    return
  fi
  pass "$command exists in golden fixture"

  local requires_meta
  requires_meta=$(jq -r --arg cmd "$command" '.commands[$cmd].requires_meta' "$FIXTURE_FILE")
  if [[ "$requires_meta" == "true" ]]; then
    if jq -e '._meta and (._meta.duration_seconds | type == "number") and (._meta.exit_code | type == "number")' <<< "$output" >/dev/null 2>&1; then
      pass "$command has _meta contract"
    else
      fail "$command missing _meta contract"
    fi
  fi

  local data_ok="true"
  while IFS= read -r field; do
    if ! jq -e --arg f "$field" '.data | has($f)' <<< "$output" >/dev/null 2>&1; then
      data_ok="false"
      break
    fi
  done < <(jq -r --arg cmd "$command" '.commands[$cmd].data_required_fields[]' "$FIXTURE_FILE")
  [[ "$data_ok" == "true" ]] && pass "$command data required fields" || fail "$command data required fields"

  local summary_ok="true"
  while IFS= read -r field; do
    [[ -z "$field" ]] && continue
    if ! jq -e --arg f "$field" '.data.summary | has($f)' <<< "$output" >/dev/null 2>&1; then
      summary_ok="false"
      break
    fi
  done < <(jq -r --arg cmd "$command" '.commands[$cmd].summary_required_fields[]? // empty' "$FIXTURE_FILE")
  [[ "$summary_ok" == "true" ]] && pass "$command summary required fields" || fail "$command summary required fields"

  local repo_ok="true"
  while IFS= read -r field; do
    if ! jq -e --arg f "$field" '(.data.repos | length) > 0 and (.data.repos[0] | has($f))' <<< "$output" >/dev/null 2>&1; then
      repo_ok="false"
      break
    fi
  done < <(jq -r --arg cmd "$command" '.commands[$cmd].repo_required_fields[]' "$FIXTURE_FILE")
  [[ "$repo_ok" == "true" ]] && pass "$command repo required fields" || fail "$command repo required fields"

  local status_field status_ok="false"
  status_field=$(jq -r --arg cmd "$command" '.commands[$cmd].status_field' "$FIXTURE_FILE")
  if [[ -n "$status_field" && "$status_field" != "null" ]]; then
    local status_value
    status_value=$(jq -r --arg sf "$status_field" '.data.repos[0][$sf] // empty' <<< "$output")
    if [[ -n "$status_value" ]]; then
      if jq -e --arg cmd "$command" --arg sv "$status_value" '.commands[$cmd].status_enum | index($sv) != null' "$FIXTURE_FILE" >/dev/null 2>&1; then
        status_ok="true"
      fi
    fi
  fi
  [[ "$status_ok" == "true" ]] && pass "$command status enum membership" || fail "$command status enum membership"
}

run_contract_suite() {
  echo "=== fork-* JSON contract tests ==="
  setup_test_env
  init_ru_config

  local local_path
  local_path=$(setup_fork_repo "contractrepo" "master")

  local status_json sync_json clean_json
  status_json=$("$RU_SCRIPT" fork-status "testowner/contractrepo" --json --no-fetch 2>/dev/null)
  sync_json=$("$RU_SCRIPT" fork-sync "testowner/contractrepo" --json --dry-run --force 2>/dev/null)
  clean_json=$("$RU_SCRIPT" fork-clean "testowner/contractrepo" --json --dry-run --force 2>/dev/null)

  validate_contract "fork-status" "$status_json"
  validate_contract "fork-sync" "$sync_json"
  validate_contract "fork-clean" "$clean_json"

  cleanup_test_env
}

run_contract_suite

echo ""
echo "=== Results: $TESTS_PASSED passed, $TESTS_FAILED failed ==="
[[ "$TESTS_FAILED" -gt 0 ]] && exit 1
exit 0
