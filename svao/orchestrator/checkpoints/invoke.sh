#!/usr/bin/env bash
# Checkpoint invoker - runs Claude with checkpoint prompt and validates output
# Usage: invoke.sh <checkpoint-type> <change-id> [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ORCHESTRATOR_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
PARSER="$SCRIPT_DIR/parser.sh"

# Configuration
DEFAULT_MAX_PARALLEL=3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[checkpoint]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[checkpoint]${NC} $*" >&2; }
log_error() { echo -e "${RED}[checkpoint]${NC} $*" >&2; }
log_checkpoint() { echo -e "${CYAN}[checkpoint:$1]${NC} $2" >&2; }

usage() {
    cat << EOF
Usage: $(basename "$0") <checkpoint-type> <change-id> [options]

Checkpoint types:
  queue-planning      - Decide which tasks to dispatch
  completion-review   - Review completed section
  blocker-resolution  - Handle blocked task

Options:
  --dry-run           Show prompt without invoking Claude
  --section <n>       Section number (for completion-review)
  --task <id>         Task ID (for blocker-resolution)
  --max-parallel <n>  Max parallel agents (for queue-planning)

Examples:
  $(basename "$0") queue-planning my-feature
  $(basename "$0") completion-review my-feature --section 2
  $(basename "$0") blocker-resolution my-feature --task 3.2
EOF
    exit 1
}

# Find change directory
find_change_dir() {
    local change_id="$1"
    local candidates=(
        "openspec/changes/$change_id"
        ".claude/changes/$change_id"
    )

    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    done

    log_error "Change directory not found for: $change_id"
    exit 1
}

# Build PRD summary from prd.json
build_prd_summary() {
    local prd_file="$1"

    jq -r '
        "**Total Sections:** \(.summary.total_sections // 0)\n" +
        "**Total Tasks:** \(.summary.total_tasks // 0)\n" +
        "**Success Criteria:**\n" +
        (if .success_criteria then
            (.success_criteria | to_entries | map("- \(.key): `\(.value)`") | join("\n"))
        else "- None defined" end)
    ' "$prd_file"
}

# Build state summary from prd-state.json
build_state_summary() {
    local state_file="$1"

    jq -r '
        "**Progress:** \(.summary.progress_percent // 0)% complete\n" +
        "**Completed:** \(.summary.completed // 0)/\(.summary.total_tasks // 0)\n" +
        "**In Progress:** \(.summary.in_progress // 0)\n" +
        "**Blocked:** \(.summary.blocked // 0)\n" +
        "**Ready:** \(.summary.ready // 0)"
    ' "$state_file"
}

# Build ready queue details
build_ready_queue() {
    local prd_file="$1"
    local state_file="$2"

    local ready_tasks
    ready_tasks=$(jq -r '.queue.ready[]?' "$state_file" 2>/dev/null || echo "")

    if [[ -z "$ready_tasks" ]]; then
        echo "No tasks currently ready for dispatch."
        return
    fi

    echo "| Task | Description | Files | Agent Type | Complexity |"
    echo "|------|-------------|-------|------------|------------|"

    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        jq -r --arg id "$task_id" '
            .sections[]?.tasks[]? | select(.id == $id) |
            "| \(.id) | \(.description | .[0:50]) | \(.files | join(", ") | .[0:30]) | \(.agent_type // "-") | \(.complexity // "-") |"
        ' "$prd_file" 2>/dev/null || true
    done <<< "$ready_tasks"
}

# Build in-progress details
build_in_progress() {
    local state_file="$1"

    local in_progress
    in_progress=$(jq -r '.queue.in_progress[]?' "$state_file" 2>/dev/null || echo "")

    if [[ -z "$in_progress" ]]; then
        echo "No tasks currently in progress."
        return
    fi

    echo "| Task | Agent | Started | Status |"
    echo "|------|-------|---------|--------|"

    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        jq -r --arg id "$task_id" '
            .tasks[$id] // {} |
            "| \($id) | \(.assigned_to // "-") | \(.assigned_at // "-") | running |"
        ' "$state_file" 2>/dev/null || true
    done <<< "$in_progress"
}

# Build agent metrics
build_agent_metrics() {
    local state_file="$1"

    jq -r '
        if .metrics.agents_used then
            "| Agent | Completed | Failed | Success Rate |\n|-------|-----------|--------|--------------|" +
            (.metrics.agents_used | to_entries | map(
                "\n| \(.key) | \(.value.completed // 0) | \(.value.failed // 0) | " +
                (if ((.value.completed // 0) + (.value.failed // 0)) > 0 then
                    (((.value.completed // 0) / ((.value.completed // 0) + (.value.failed // 0)) * 100) | floor | tostring) + "%"
                else "N/A" end) + " |"
            ) | join(""))
        else
            "No agent metrics available yet."
        end
    ' "$state_file" 2>/dev/null || echo "No agent metrics available yet."
}

# Build file overlap analysis for queue planning
build_file_overlap() {
    local prd_file="$1"
    local state_file="$2"

    local ready_tasks
    ready_tasks=$(jq -r '.queue.ready[]?' "$state_file" 2>/dev/null || echo "")
    local in_progress
    in_progress=$(jq -r '.queue.in_progress[]?' "$state_file" 2>/dev/null || echo "")

    if [[ -z "$ready_tasks" || -z "$in_progress" ]]; then
        echo "No potential file conflicts detected."
        return
    fi

    # Get files for in-progress tasks
    local active_files=""
    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        local files
        files=$(jq -r --arg id "$task_id" '.sections[]?.tasks[]? | select(.id == $id) | .files[]?' "$prd_file" 2>/dev/null || true)
        active_files="$active_files"$'\n'"$files"
    done <<< "$in_progress"
    active_files=$(echo "$active_files" | grep -v '^$' | sort -u || true)

    if [[ -z "$active_files" ]]; then
        echo "No potential file conflicts detected."
        return
    fi

    echo "**In-progress files:** $(echo "$active_files" | tr '\n' ', ' | sed 's/,$//')"
    echo ""
    echo "**Conflicts with ready tasks:**"

    local has_conflicts=false
    while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        local task_files
        task_files=$(jq -r --arg id "$task_id" '.sections[]?.tasks[]? | select(.id == $id) | .files[]?' "$prd_file" 2>/dev/null || true)

        if [[ -n "$task_files" && -n "$active_files" ]]; then
            local overlap
            overlap=$(comm -12 <(echo "$active_files" | sort) <(echo "$task_files" | sort) 2>/dev/null || true)

            if [[ -n "$overlap" ]]; then
                has_conflicts=true
                echo "- Task $task_id conflicts: $(echo "$overlap" | tr '\n' ', ' | sed 's/,$//')"
            fi
        fi
    done <<< "$ready_tasks"

    if [[ "$has_conflicts" == "false" ]]; then
        echo "- None detected"
    fi
}

# Build section tasks for completion review
build_section_tasks() {
    local prd_file="$1"
    local state_file="$2"
    local section_num="$3"

    echo "| Task | Description | Status | Agent | Duration |"
    echo "|------|-------------|--------|-------|----------|"

    jq -r --arg section "$section_num" '
        .sections[]? | select(.number == ($section | tonumber)) |
        .tasks[]?.id
    ' "$prd_file" 2>/dev/null | while IFS= read -r task_id; do
        [[ -z "$task_id" ]] && continue
        local task_desc
        task_desc=$(jq -r --arg id "$task_id" '.sections[]?.tasks[]? | select(.id == $id) | .description | .[0:40]' "$prd_file" 2>/dev/null || echo "-")

        jq -r --arg id "$task_id" --arg desc "$task_desc" '
            (.tasks[$id] // {status: "pending", assigned_to: "-", duration_seconds: 0}) |
            "| \($id) | \($desc) | \(.status // "pending") | \(.assigned_to // "-") | \(.duration_seconds // 0)s |"
        ' "$state_file" 2>/dev/null || echo "| $task_id | $task_desc | pending | - | 0s |"
    done
}

# Build section commits
build_section_commits() {
    local state_file="$1"
    local section_num="$2"

    jq -r --arg section "$section_num" '
        [.tasks | to_entries[]? |
         select(.key | startswith($section + ".")) |
         .value.commits[]?] | unique |
        if length > 0 then
            map("- `\(.)`") | join("\n")
        else
            "No commits recorded."
        end
    ' "$state_file" 2>/dev/null || echo "No commits recorded."
}

# Build blocker task details
build_task_details() {
    local prd_file="$1"
    local state_file="$2"
    local task_id="$3"

    echo "**Task ID:** $task_id"

    jq -r --arg id "$task_id" '
        .sections[]?.tasks[]? | select(.id == $id) |
        "**Description:** \(.description)\n**Files:** \(.files | join(", "))\n**Agent Type:** \(.agent_type // "-")\n**Complexity:** \(.complexity // "-")"
    ' "$prd_file" 2>/dev/null || echo "**Description:** Unknown task"

    echo ""
    echo "**Current State:**"
    jq -r --arg id "$task_id" '
        (.tasks[$id] // {status: "unknown", assigned_to: "-", retries: 0}) |
        "- Status: \(.status // "unknown")\n- Assigned to: \(.assigned_to // "-")\n- Retries: \(.retries // 0)"
    ' "$state_file" 2>/dev/null || echo "- Status: unknown"
}

# Build failure history
build_failure_history() {
    local state_file="$1"
    local task_id="$2"

    jq -r --arg id "$task_id" '
        .tasks[$id].retry_history // [] |
        if length > 0 then
            map("- **\(.timestamp // "unknown")** - Agent: \(.agent // "-"), Error: \(.error // "-")") | join("\n")
        else
            "No previous failures."
        end
    ' "$state_file" 2>/dev/null || echo "No previous failures."
}

# Build available agents list
build_available_agents() {
    local registry_file="${ORCHESTRATOR_DIR}/../agents/registry.json"

    if [[ ! -f "$registry_file" ]]; then
        echo "Registry not found."
        return
    fi

    jq -r '
        .agents | to_entries |
        map(select(.value.enabled != false)) |
        map("- **\(.key)**: \(.value.definition // "no definition")") |
        join("\n")
    ' "$registry_file" 2>/dev/null || echo "No agents available."
}

# Main prompt builder
build_prompt() {
    local checkpoint_type="$1"
    local change_dir="$2"
    local extra_args="$3"

    local prd_file="$change_dir/prd.json"
    local state_file="$change_dir/prd-state.json"

    if [[ ! -f "$prd_file" ]]; then
        log_error "prd.json not found in $change_dir"
        exit 1
    fi

    if [[ ! -f "$state_file" ]]; then
        log_error "prd-state.json not found in $change_dir"
        exit 1
    fi

    # Load base template
    local base_template_file="$TEMPLATES_DIR/base.md"
    if [[ ! -f "$base_template_file" ]]; then
        log_error "Base template not found: $base_template_file"
        exit 1
    fi

    # Load checkpoint-specific template
    local template_file="$TEMPLATES_DIR/${checkpoint_type}.md"
    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: $template_file"
        exit 1
    fi

    # Build common context
    local change_id
    change_id=$(jq -r '.change_id // "unknown"' "$prd_file")
    local session_id
    session_id=$(jq -r '.session.id // "unknown"' "$state_file")
    local iteration
    iteration=$(jq -r '.session.iteration // 0' "$state_file")

    local prd_summary
    prd_summary=$(build_prd_summary "$prd_file")
    local state_summary
    state_summary=$(build_state_summary "$state_file")

    # Start with base template
    local prompt
    prompt=$(cat "$base_template_file")

    # Replace common placeholders
    prompt="${prompt//\{\{CHECKPOINT_TYPE\}\}/$checkpoint_type}"
    prompt="${prompt//\{\{CHANGE_ID\}\}/$change_id}"
    prompt="${prompt//\{\{SESSION_ID\}\}/$session_id}"
    prompt="${prompt//\{\{ITERATION\}\}/$iteration}"
    prompt="${prompt//\{\{PRD_SUMMARY\}\}/$prd_summary}"
    prompt="${prompt//\{\{STATE_SUMMARY\}\}/$state_summary}"

    # Build checkpoint-specific content (load template and strip {{BASE_TEMPLATE}} reference line)
    local specific_content
    specific_content=$(tail -n +2 "$template_file")  # Skip first line (template reference: {{BASE_TEMPLATE}})

    # Build checkpoint-specific context
    case "$checkpoint_type" in
        queue-planning)
            local max_parallel="${extra_args:-$DEFAULT_MAX_PARALLEL}"
            local ready_queue
            ready_queue=$(build_ready_queue "$prd_file" "$state_file")
            local in_progress
            in_progress=$(build_in_progress "$state_file")
            local agent_metrics
            agent_metrics=$(build_agent_metrics "$state_file")
            local file_overlap
            file_overlap=$(build_file_overlap "$prd_file" "$state_file")

            specific_content="${specific_content//\{\{READY_QUEUE\}\}/$ready_queue}"
            specific_content="${specific_content//\{\{IN_PROGRESS\}\}/$in_progress}"
            specific_content="${specific_content//\{\{AGENT_METRICS\}\}/$agent_metrics}"
            specific_content="${specific_content//\{\{FILE_OVERLAP\}\}/$file_overlap}"
            specific_content="${specific_content//\{\{MAX_PARALLEL\}\}/$max_parallel}"
            ;;

        completion-review)
            local section_num="${extra_args:-1}"
            local section_name
            section_name=$(jq -r --arg n "$section_num" '.sections[]? | select(.number == ($n | tonumber)) | .name // "Unknown"' "$prd_file")
            local section_tasks
            section_tasks=$(build_section_tasks "$prd_file" "$state_file" "$section_num")
            local section_commits
            section_commits=$(build_section_commits "$state_file" "$section_num")

            # Get phase review results if available
            local phase_review_results
            phase_review_results=$(jq -r --arg n "$section_num" '
              if .phase_reviews[$n] then
                "**Completed at:** \(.phase_reviews[$n].completed_at)\n\n" +
                if (.phase_reviews[$n].human_reviews | length) > 0 then
                  "**Issues flagged for human review:**\n" +
                  (.phase_reviews[$n].human_reviews | map("- " + .) | join("\n"))
                else
                  "No issues flagged for human review."
                end
              else
                "Phase review not yet run."
              end
            ' "$state_file" 2>/dev/null || echo "Phase review data not available.")

            specific_content="${specific_content//\{\{SECTION_NUMBER\}\}/$section_num}"
            specific_content="${specific_content//\{\{SECTION_NAME\}\}/$section_name}"
            specific_content="${specific_content//\{\{SECTION_TASKS\}\}/$section_tasks}"
            specific_content="${specific_content//\{\{SECTION_COMMITS\}\}/$section_commits}"
            specific_content="${specific_content//\{\{FILES_CHANGED\}\}/See commits above}"
            specific_content="${specific_content//\{\{TEST_RESULTS\}\}/Run test suite to verify}"
            specific_content="${specific_content//\{\{PHASE_REVIEW_RESULTS\}\}/$phase_review_results}"
            ;;

        blocker-resolution)
            local task_id="$extra_args"
            if [[ -z "$task_id" ]]; then
                log_error "Task ID required for blocker-resolution checkpoint"
                exit 1
            fi
            local task_details
            task_details=$(build_task_details "$prd_file" "$state_file" "$task_id")
            local failure_history
            failure_history=$(build_failure_history "$state_file" "$task_id")
            local retry_count
            retry_count=$(jq -r --arg id "$task_id" '.tasks[$id].retries // 0' "$state_file")
            local last_error
            last_error=$(jq -r --arg id "$task_id" '.tasks[$id].retry_history[-1].error // "No error recorded"' "$state_file" 2>/dev/null || echo "No error recorded")
            local available_agents
            available_agents=$(build_available_agents)

            specific_content="${specific_content//\{\{TASK_ID\}\}/$task_id}"
            specific_content="${specific_content//\{\{TASK_DETAILS\}\}/$task_details}"
            specific_content="${specific_content//\{\{FAILURE_HISTORY\}\}/$failure_history}"
            specific_content="${specific_content//\{\{RETRY_COUNT\}\}/$retry_count}"
            specific_content="${specific_content//\{\{LAST_ERROR\}\}/$last_error}"
            specific_content="${specific_content//\{\{AVAILABLE_AGENTS\}\}/$available_agents}"
            ;;
    esac

    # Replace the checkpoint-specific placeholder in base template
    prompt="${prompt//\{\{CHECKPOINT_SPECIFIC_INSTRUCTIONS\}\}/$specific_content}"

    echo "$prompt"
}

# Invoke Claude with prompt
invoke_claude() {
    local prompt="$1"

    log_info "Invoking Claude checkpoint..."

    # Invoke claude with the prompt directly
    local output
    if ! output=$(claude --print -p "$prompt" 2>&1); then
        log_error "Claude invocation failed: $output"
        return 1
    fi

    echo "$output"
}

# Main
main() {
    local checkpoint_type=""
    local change_id=""
    local dry_run=false
    local extra_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            --section)
                extra_arg="$2"
                shift 2
                ;;
            --task)
                extra_arg="$2"
                shift 2
                ;;
            --max-parallel)
                extra_arg="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                if [[ -z "$checkpoint_type" ]]; then
                    checkpoint_type="$1"
                elif [[ -z "$change_id" ]]; then
                    change_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$checkpoint_type" || -z "$change_id" ]]; then
        usage
    fi

    # Validate checkpoint type
    case "$checkpoint_type" in
        queue-planning|completion-review|blocker-resolution)
            ;;
        *)
            log_error "Unknown checkpoint type: $checkpoint_type"
            usage
            ;;
    esac

    # Find change directory
    local change_dir
    change_dir=$(find_change_dir "$change_id")

    log_checkpoint "$checkpoint_type" "Building prompt for $change_id"

    # Build the prompt
    local prompt
    prompt=$(build_prompt "$checkpoint_type" "$change_dir" "$extra_arg")

    if [[ "$dry_run" == "true" ]]; then
        echo "=== DRY RUN: Checkpoint Prompt ==="
        echo "$prompt"
        echo "=== END PROMPT ==="
        exit 0
    fi

    # Invoke Claude
    local output
    output=$(invoke_claude "$prompt")

    log_checkpoint "$checkpoint_type" "Validating output..."

    # Parse and validate output
    local parsed
    parsed=$(echo "$output" | "$PARSER")

    local valid
    valid=$(echo "$parsed" | jq -r '.valid')

    if [[ "$valid" != "true" ]]; then
        log_error "Checkpoint output validation failed"
        echo "$parsed" | jq -r '.commands'
        exit 1
    fi

    log_checkpoint "$checkpoint_type" "Output validated successfully"

    # Output the parsed commands
    echo "$parsed"
}

main "$@"
