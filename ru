#!/usr/bin/env bash
#
# ru - Repo Updater
#
# A beautiful, automation-friendly CLI for synchronizing GitHub repositories.
# Keep dozens (or hundreds) of repos in sync with a single command.
#
# FEATURES:
#   - Clone missing repos automatically
#   - Pull updates for existing repos
#   - Detect and report conflicts with resolution help
#   - Git plumbing for reliable status detection (no string parsing)
#   - Beautiful terminal UI with gum (with ANSI fallbacks)
#   - JSON output for scripting
#   - Meaningful exit codes for automation
#
# USAGE:
#   ru [command] [options]
#
# COMMANDS:
#   sync          Clone missing repos and pull updates (default)
#   status        Show repository status without making changes
#   init          Initialize configuration directory and files
#   add <repo>    Add a repository to your list
#   list          Show configured repositories
#   doctor        Run system diagnostics
#   self-update   Update ru to the latest version
#   config        Show or set configuration values
#
# GLOBAL OPTIONS:
#   -h, --help           Show help message
#   -v, --version        Show version
#   --json               Output JSON to stdout
#   -q, --quiet          Minimal output (errors only)
#   --verbose            Detailed output
#   --non-interactive    Never prompt (for CI/automation)
#
# CONFIGURATION:
#   Config directory: ~/.config/ru/
#   Repo lists:       ~/.config/ru/repos.d/
#   Logs:             ~/.local/state/ru/logs/
#
# EXIT CODES:
#   0 - Success (all repos synced or already current)
#   1 - Partial failure (some repos failed)
#   2 - Conflicts exist (repos need manual resolution)
#   3 - Dependency error (gh missing, auth failed)
#   4 - Invalid arguments (bad CLI options, missing config)
#
# REPOSITORY:
#   https://github.com/Dicklesworthstone/repo_updater
#
# LICENSE:
#   MIT License - Copyright (c) 2025 Jeffrey Emanuel
#
#==============================================================================

# Shell options: strict mode WITHOUT set -e
# We explicitly avoid set -e because:
#   1. `output=$(failing_cmd); exit_code=$?` exits before capturing exit_code
#   2. We need repos to continue processing after individual failures
#   3. Explicit error handling is more predictable
set -uo pipefail

#==============================================================================
# SECTION 1: VERSION AND CONSTANTS
#==============================================================================

# Version: read from VERSION file, fallback to embedded
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    VERSION="$(cat "$SCRIPT_DIR/VERSION")"
fi

# XDG Base Directory defaults
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# ru-specific directories
RU_CONFIG_DIR="${RU_CONFIG_DIR:-$XDG_CONFIG_HOME/ru}"
RU_STATE_DIR="${RU_STATE_HOME:-$XDG_STATE_HOME/ru}"
RU_CACHE_DIR="${RU_CACHE_HOME:-$XDG_CACHE_HOME/ru}"
RU_LOG_DIR="$RU_STATE_DIR/logs"

# Default configuration values
DEFAULT_PROJECTS_DIR="${RU_PROJECTS_DIR:-$HOME/projects}"
DEFAULT_LAYOUT="flat"           # flat | owner-repo | full
DEFAULT_UPDATE_STRATEGY="ff-only"  # ff-only | rebase | merge
DEFAULT_AUTOSTASH="false"
DEFAULT_PARALLEL="1"

#==============================================================================
# SECTION 2: ANSI COLOR DEFINITIONS
#==============================================================================

# Colors (disabled if not a terminal or NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

#==============================================================================
# SECTION 3: RUNTIME STATE VARIABLES
#==============================================================================

# These are set during argument parsing and runtime
COMMAND=""
PROJECTS_DIR=""
LAYOUT=""
UPDATE_STRATEGY=""
AUTOSTASH=""
PARALLEL=""
JSON_OUTPUT="false"
QUIET="false"
VERBOSE="false"
NON_INTERACTIVE="false"
DRY_RUN="false"
CLONE_ONLY="false"
PULL_ONLY="false"
FETCH_REMOTES="true"

# Results tracking (NDJSON temp file)
RESULTS_FILE=""

# Gum availability
GUM_AVAILABLE="false"

#==============================================================================
# SECTION 4: CORE UTILITIES
#==============================================================================

# Check if running interactively (TTY attached)
is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# Check if we can prompt the user (interactive and not --non-interactive)
can_prompt() {
    is_interactive && [[ "$NON_INTERACTIVE" != "true" ]]
}

# Ensure a directory exists
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

# Write a result to the NDJSON results file
write_result() {
    local repo_name="$1"
    local action="$2"
    local status="$3"
    local duration="${4:-}"
    local message="${5:-}"

    if [[ -n "$RESULTS_FILE" ]]; then
        printf '{"repo":"%s","action":"%s","status":"%s","duration":%s,"message":"%s","timestamp":"%s"}\n' \
            "$repo_name" "$action" "$status" "${duration:-0}" "$message" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >> "$RESULTS_FILE"
    fi
}

#==============================================================================
# SECTION 5: LOGGING FUNCTIONS
# Stream separation: stderr for humans, stdout for data
#==============================================================================

log_info() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${BLUE}ℹ${RESET} $*" >&2
}

log_success() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${GREEN}✓${RESET} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}⚠${RESET} $*" >&2
}

log_error() {
    echo -e "${RED}✗${RESET} $*" >&2
}

log_step() {
    [[ "$QUIET" == "true" ]] && return
    echo -e "${CYAN}→${RESET} $*" >&2
}

log_verbose() {
    [[ "$VERBOSE" != "true" ]] && return
    echo -e "${DIM}$*${RESET}" >&2
}

# Output JSON to stdout (only in --json mode)
output_json() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$1"
    fi
}

#==============================================================================
# SECTION 6: HELP AND VERSION
#==============================================================================

show_version() {
    echo "ru version $VERSION"
}

show_help() {
    cat >&2 << 'EOF'
ru - Repo Updater

A beautiful, automation-friendly CLI for synchronizing GitHub repositories.

USAGE:
    ru [command] [options]

COMMANDS:
    sync            Clone missing repos and pull updates (default)
    status          Show repository status without making changes
    init            Initialize configuration directory and files
    add <repo>      Add a repository to your list
    list            Show configured repositories
    doctor          Run system diagnostics
    self-update     Update ru to the latest version
    config          Show or set configuration values

GLOBAL OPTIONS:
    -h, --help           Show this help message
    -v, --version        Show version
    --json               Output JSON to stdout
    -q, --quiet          Minimal output (errors only)
    --verbose            Detailed output
    --non-interactive    Never prompt (for CI/automation)

SYNC OPTIONS:
    --clone-only         Only clone missing repos, don't pull
    --pull-only          Only pull existing repos, don't clone
    --autostash          Stash changes before pull, pop after
    --rebase             Use git pull --rebase
    --dry-run            Show what would happen without making changes
    --dir PATH           Override projects directory

STATUS OPTIONS:
    --fetch              Fetch remotes first (default)
    --no-fetch           Skip fetch, use cached state

EXAMPLES:
    ru sync              Sync all configured repos
    ru sync --dry-run    Preview sync without changes
    ru status            Show status of all repos
    ru add owner/repo    Add a repository
    ru doctor            Check system configuration

CONFIGURATION:
    Config:  ~/.config/ru/config
    Repos:   ~/.config/ru/repos.d/repos.txt
    Logs:    ~/.local/state/ru/logs/

EXIT CODES:
    0  Success
    1  Partial failure (some repos failed)
    2  Conflicts exist (need manual resolution)
    3  Dependency error (gh missing, auth failed)
    4  Invalid arguments

More info: https://github.com/Dicklesworthstone/repo_updater
EOF
}

#==============================================================================
# SECTION 7: CONFIGURATION
#==============================================================================

# Get a configuration value with priority: CLI > env > file > default
get_config_value() {
    local key="$1"
    local default="$2"
    local cli_value="${3:-}"
    local env_var="RU_${key^^}"  # Uppercase key with RU_ prefix

    # Priority 1: CLI argument
    if [[ -n "$cli_value" ]]; then
        echo "$cli_value"
        return
    fi

    # Priority 2: Environment variable
    if [[ -n "${!env_var:-}" ]]; then
        echo "${!env_var}"
        return
    fi

    # Priority 3: Config file
    local config_file="$RU_CONFIG_DIR/config"
    if [[ -f "$config_file" ]]; then
        local file_value
        file_value=$(grep "^${key}=" "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$file_value" ]]; then
            echo "$file_value"
            return
        fi
    fi

    # Priority 4: Default
    echo "$default"
}

# Resolve all configuration values
resolve_config() {
    PROJECTS_DIR=$(get_config_value "PROJECTS_DIR" "$DEFAULT_PROJECTS_DIR" "$PROJECTS_DIR")
    LAYOUT=$(get_config_value "LAYOUT" "$DEFAULT_LAYOUT" "$LAYOUT")
    UPDATE_STRATEGY=$(get_config_value "UPDATE_STRATEGY" "$DEFAULT_UPDATE_STRATEGY" "$UPDATE_STRATEGY")
    AUTOSTASH=$(get_config_value "AUTOSTASH" "$DEFAULT_AUTOSTASH" "$AUTOSTASH")
    PARALLEL=$(get_config_value "PARALLEL" "$DEFAULT_PARALLEL" "$PARALLEL")
}

#==============================================================================
# SECTION 8: GUM INTEGRATION
#==============================================================================

# Check if gum is available
check_gum() {
    if command -v gum &>/dev/null; then
        GUM_AVAILABLE="true"
    fi
}

# Confirm prompt with gum fallback
gum_confirm() {
    local prompt="$1"
    local default="${2:-false}"

    if [[ "$GUM_AVAILABLE" == "true" ]]; then
        if gum confirm "$prompt"; then
            return 0
        else
            return 1
        fi
    else
        # ANSI fallback
        local yn
        if [[ "$default" == "true" ]]; then
            read -rp "$prompt [Y/n] " yn
            case "${yn,,}" in
                n|no) return 1 ;;
                *) return 0 ;;
            esac
        else
            read -rp "$prompt [y/N] " yn
            case "${yn,,}" in
                y|yes) return 0 ;;
                *) return 1 ;;
            esac
        fi
    fi
}

#==============================================================================
# SECTION 9: EXIT TRAP AND CLEANUP
#==============================================================================

cleanup() {
    # Remove temp files
    if [[ -n "${RESULTS_FILE:-}" && -f "$RESULTS_FILE" ]]; then
        rm -f "$RESULTS_FILE"
    fi
}

# Set up trap for cleanup
trap cleanup EXIT

#==============================================================================
# SECTION 10: ARGUMENT PARSING
#==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --json)
                JSON_OUTPUT="true"
                shift
                ;;
            -q|--quiet)
                QUIET="true"
                shift
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --clone-only)
                CLONE_ONLY="true"
                shift
                ;;
            --pull-only)
                PULL_ONLY="true"
                shift
                ;;
            --autostash)
                AUTOSTASH="true"
                shift
                ;;
            --rebase)
                UPDATE_STRATEGY="rebase"
                shift
                ;;
            --dir)
                PROJECTS_DIR="$2"
                shift 2
                ;;
            --fetch)
                FETCH_REMOTES="true"
                shift
                ;;
            --no-fetch)
                FETCH_REMOTES="false"
                shift
                ;;
            sync|status|init|add|list|doctor|self-update|config)
                COMMAND="$1"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 4
                ;;
            *)
                # Positional argument - store for command
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Default command is sync
    if [[ -z "$COMMAND" ]]; then
        COMMAND="sync"
    fi
}

#==============================================================================
# SECTION 11: COMMAND STUBS (to be implemented)
#==============================================================================

cmd_sync() {
    log_info "sync command not yet implemented"
    exit 0
}

cmd_status() {
    log_info "status command not yet implemented"
    exit 0
}

cmd_init() {
    log_info "init command not yet implemented"
    exit 0
}

cmd_add() {
    log_info "add command not yet implemented"
    exit 0
}

cmd_list() {
    log_info "list command not yet implemented"
    exit 0
}

cmd_doctor() {
    log_info "doctor command not yet implemented"
    exit 0
}

cmd_self_update() {
    log_info "self-update command not yet implemented"
    exit 0
}

cmd_config() {
    log_info "config command not yet implemented"
    exit 0
}

#==============================================================================
# SECTION 12: MAIN DISPATCH
#==============================================================================

main() {
    # Initialize
    ARGS=()
    parse_args "$@"
    check_gum
    resolve_config

    # Create results file for this run
    RESULTS_FILE=$(mktemp)

    # Dispatch to command
    case "$COMMAND" in
        sync)       cmd_sync ;;
        status)     cmd_status ;;
        init)       cmd_init ;;
        add)        cmd_add ;;
        list)       cmd_list ;;
        doctor)     cmd_doctor ;;
        self-update) cmd_self_update ;;
        config)     cmd_config ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 4
            ;;
    esac
}

# Run main
main "$@"
