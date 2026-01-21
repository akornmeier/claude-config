#!/usr/bin/env bash
# Checkpoint output parser and validator
# Parses Claude checkpoint output and validates commands

set -euo pipefail

# Resolve symlinks for .claude directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ORCHESTRATOR_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[checkpoint]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[checkpoint]${NC} $*" >&2; }
log_error() { echo -e "${RED}[checkpoint]${NC} $*" >&2; }

# Allowed commands
ALLOWED_COMMANDS=(
    "DISPATCH"
    "REORDER"
    "REASSIGN"
    "ADD_DEPENDENCY"
    "UNBLOCK"
    "APPROVED"
    "NEEDS_WORK"
    "WAIT"
    "NOOP"
)

# Forbidden commands (spec modifications)
FORBIDDEN_COMMANDS=(
    "MODIFY_TASK"
    "DELETE_TASK"
    "CHANGE_CRITERIA"
    "ADD_TASK"
)

# Check if a line looks like it might be a command (starts with uppercase word)
# Returns 0 if it looks like a command attempt, 1 if it's clearly prose
looks_like_command() {
    local line="$1"

    # Skip empty lines, comments, markdown elements
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ ^# ]] && return 1
    [[ "$line" == '```' || "$line" =~ ^\`\`\` ]] && return 1

    # Skip obvious markdown/prose patterns
    [[ "$line" =~ ^\*\* ]] && return 1  # Bold text
    [[ "$line" =~ ^\| ]] && return 1    # Table rows
    [[ "$line" =~ ^- ]] && return 1     # List items (that aren't commands)
    [[ "$line" =~ ^[0-9]+\. ]] && return 1  # Numbered lists
    [[ "$line" =~ ^--- ]] && return 1   # Horizontal rules
    [[ "$line" =~ ^=== ]] && return 1   # Another horizontal rule
    [[ "$line" =~ ^\[.*\] ]] && return 1  # Markdown links

    # Check if line starts with any known command word (allowed or forbidden)
    local first_word="${line%%:*}"
    first_word="${first_word%% *}"

    for cmd in "${ALLOWED_COMMANDS[@]}" "${FORBIDDEN_COMMANDS[@]}"; do
        if [[ "$first_word" == "$cmd" ]]; then
            return 0
        fi
    done

    # Doesn't look like a command - it's prose
    return 1
}

# Validate a single command line
validate_command() {
    local line="$1"
    local command

    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^# ]] && return 0

    # Extract command name (before colon)
    command="${line%%:*}"
    command="${command%% *}"  # Handle NOOP which has no colon

    # Check forbidden commands
    for forbidden in "${FORBIDDEN_COMMANDS[@]}"; do
        if [[ "$command" == "$forbidden" ]]; then
            log_error "REJECTED: Forbidden command '$command' - cannot modify spec"
            return 1
        fi
    done

    # Check allowed commands
    local found=false
    for allowed in "${ALLOWED_COMMANDS[@]}"; do
        if [[ "$command" == "$allowed" ]]; then
            found=true
            break
        fi
    done

    if [[ "$found" == "false" ]]; then
        log_error "REJECTED: Unknown command '$command'"
        return 1
    fi

    # Command-specific validation
    case "$command" in
        DISPATCH)
            # Format: DISPATCH: task-id:agent:isolation
            if [[ ! "$line" =~ ^DISPATCH:\ *[0-9]+\.[0-9]+:[a-z_-]+:(task|worktree)$ ]]; then
                log_error "REJECTED: Invalid DISPATCH format. Expected 'DISPATCH: X.Y:agent:isolation'"
                return 1
            fi
            ;;
        REORDER)
            # Format: REORDER: task-id, task-id, ...
            if [[ ! "$line" =~ ^REORDER:\ *[0-9]+\.[0-9]+(,\ *[0-9]+\.[0-9]+)*$ ]]; then
                log_error "REJECTED: Invalid REORDER format. Expected 'REORDER: X.Y, X.Z, ...'"
                return 1
            fi
            ;;
        REASSIGN)
            # Format: REASSIGN: task-id:agent
            if [[ ! "$line" =~ ^REASSIGN:\ *[0-9]+\.[0-9]+:[a-z_-]+$ ]]; then
                log_error "REJECTED: Invalid REASSIGN format. Expected 'REASSIGN: X.Y:agent'"
                return 1
            fi
            ;;
        ADD_DEPENDENCY)
            # Format: ADD_DEPENDENCY: from:to:confidence
            if [[ ! "$line" =~ ^ADD_DEPENDENCY:\ *[0-9]+\.[0-9]+:[0-9]+\.[0-9]+:[0-9]+$ ]]; then
                log_error "REJECTED: Invalid ADD_DEPENDENCY format. Expected 'ADD_DEPENDENCY: X.Y:X.Z:NN'"
                return 1
            fi
            ;;
        UNBLOCK)
            # Format: UNBLOCK: task-id:strategy[:details]
            if [[ ! "$line" =~ ^UNBLOCK:\ *[0-9]+\.[0-9]+:(alternate-agent|skip-and-continue|escalate) ]]; then
                log_error "REJECTED: Invalid UNBLOCK format. Expected 'UNBLOCK: X.Y:strategy[:details]'"
                return 1
            fi
            ;;
        APPROVED)
            # Format: APPROVED: section-number
            if [[ ! "$line" =~ ^APPROVED:\ *[0-9]+$ ]]; then
                log_error "REJECTED: Invalid APPROVED format. Expected 'APPROVED: N'"
                return 1
            fi
            ;;
        NEEDS_WORK)
            # Format: NEEDS_WORK: section-number:reason
            if [[ ! "$line" =~ ^NEEDS_WORK:\ *[0-9]+:.+$ ]]; then
                log_error "REJECTED: Invalid NEEDS_WORK format. Expected 'NEEDS_WORK: N:reason'"
                return 1
            fi
            ;;
        WAIT)
            # Format: WAIT: reason
            if [[ ! "$line" =~ ^WAIT:\ *.+$ ]]; then
                log_error "REJECTED: Invalid WAIT format. Expected 'WAIT: reason'"
                return 1
            fi
            ;;
        NOOP)
            # No additional validation needed
            ;;
    esac

    return 0
}

# Parse checkpoint output and return validated commands as JSON array
parse_checkpoint_output() {
    local input="$1"
    local commands=()
    local errors=()
    local has_errors=false
    local skipped_prose=0

    while IFS= read -r line; do
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Check if this line looks like a command attempt
        if ! looks_like_command "$line"; then
            # It's prose/markdown - skip silently
            ((skipped_prose++)) || true
            continue
        fi

        # This looks like a command - validate it
        if validate_command "$line"; then
            # Extract command and args
            local cmd="${line%%:*}"
            local args="${line#*: }"
            [[ "$cmd" == "$args" ]] && args=""  # Handle NOOP

            commands+=("$(jq -n --arg cmd "$cmd" --arg args "$args" '{command: $cmd, args: $args}')")
        else
            has_errors=true
            errors+=("$line")
        fi
    done <<< "$input"

    # Build JSON output
    local json_commands
    if [[ ${#commands[@]} -gt 0 ]]; then
        json_commands=$(printf '%s\n' "${commands[@]}" | jq -s '.')
    else
        json_commands="[]"
    fi

    jq -n \
        --argjson commands "$json_commands" \
        --argjson has_errors "$has_errors" \
        --arg error_count "${#errors[@]}" \
        --argjson skipped "$skipped_prose" \
        '{
            valid: (if $has_errors then false else true end),
            commands: $commands,
            error_count: ($error_count | tonumber),
            skipped_prose: $skipped
        }'
}

# Main entry point
main() {
    local input_file="${1:-/dev/stdin}"
    local input

    if [[ "$input_file" == "/dev/stdin" ]]; then
        input=$(cat)
    else
        input=$(cat "$input_file")
    fi

    parse_checkpoint_output "$input"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
