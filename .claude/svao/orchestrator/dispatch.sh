#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO Parallel Dispatch Loop
# Manages concurrent agent execution with status monitoring
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVAO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "[$(date +%H:%M:%S)] $*"; }
log_info() { echo -e "[$(date +%H:%M:%S)] ${BLUE}i${NC} $*"; }
log_success() { echo -e "[$(date +%H:%M:%S)] ${GREEN}OK${NC} $*"; }
log_warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}!${NC} $*"; }
log_error() { echo -e "[$(date +%H:%M:%S)] ${RED}x${NC} $*" >&2; }
log_agent() { echo -e "[$(date +%H:%M:%S)] ${CYAN}agent${NC} $*"; }

# Configuration
MAX_PARALLEL="${MAX_PARALLEL:-3}"
MAX_RETRIES="${MAX_RETRIES:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-5}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"

# State (use temp files since bash associative arrays don't export well)
ITERATION=0
SESSION_ID=""
STATUS_DIR=""
ACTIVE_FILE=""
RETRIES_FILE=""

# ─────────────────────────────────────────────────────────────
# State Management
# ─────────────────────────────────────────────────────────────

load_state() {
  local state_file="$1"

  SESSION_ID=$(jq -r '.session.id' "$state_file")
  STATUS_DIR="/tmp/svao/$SESSION_ID"
  ACTIVE_FILE="$STATUS_DIR/.active_pids"
  RETRIES_FILE="$STATUS_DIR/.retries"

  mkdir -p "$STATUS_DIR"
  touch "$ACTIVE_FILE"
  touch "$RETRIES_FILE"

  ITERATION=$(jq -r '.session.iteration' "$state_file")

  log_info "Loaded session: $SESSION_ID (iteration $ITERATION)"
}

save_state() {
  local state_file="$1"
  local tmp_file="${state_file}.tmp.$$"

  jq --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson iteration "$ITERATION" \
     '.session.updated_at = $updated | .session.iteration = $iteration' \
     "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

update_task_status() {
  local state_file="$1"
  local task_id="$2"
  local status="$3"
  local tmp_file="${state_file}.tmp.$$"

  jq --arg id "$task_id" --arg status "$status" \
     --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.tasks[$id].status = $status | .session.updated_at = $updated' \
     "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

rebuild_queue() {
  local prd_file="$1"
  local state_file="$2"
  local tmp_file="${state_file}.tmp.$$"

  # Get completed task IDs
  local completed=$(jq -r '[.tasks | to_entries[] | select(.value.status == "completed") | .key] | @json' "$state_file")

  jq --argjson completed "$completed" --slurpfile prd "$prd_file" '
    ($prd[0]) as $p |
    # Ready: pending tasks with all deps completed
    .queue.ready = [
      $p.sections[].tasks[] |
      . as $task |
      select(
        (.tasks[$task.id].status // "pending") == "pending" and
        (($task.depends_on // []) - $completed | length) == 0
      ) |
      .id
    ] |
    # In progress
    .queue.in_progress = [.tasks | to_entries[] | select(.value.status == "in_progress") | .key] |
    # Blocked: pending with unmet deps
    .queue.blocked = [
      $p.sections[].tasks[] |
      . as $task |
      select(
        (.tasks[$task.id].status // "pending") == "pending" and
        (($task.depends_on // []) - $completed | length) > 0
      ) |
      .id
    ] |
    # Completed
    .queue.completed = $completed |
    # Update summary
    .summary.completed = ($completed | length) |
    .summary.in_progress = (.queue.in_progress | length) |
    .summary.ready = (.queue.ready | length) |
    .summary.blocked = (.queue.blocked | length) |
    .summary.progress_percent = (if .summary.total_tasks > 0 then (($completed | length) / .summary.total_tasks * 100 | . * 10 | floor / 10) else 0 end)
  ' "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

# ─────────────────────────────────────────────────────────────
# Agent Dispatch
# ─────────────────────────────────────────────────────────────

get_agent_for_task() {
  local prd_file="$1"
  local task_id="$2"

  # Get agent_type from task, default to frontend-coder
  local agent=$(jq -r --arg id "$task_id" '
    .sections[].tasks[] | select(.id == $id) | .agent_type // "frontend-coder"
  ' "$prd_file")

  echo "$agent"
}

get_active_count() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    grep -c "^" "$ACTIVE_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

add_active() {
  local pid="$1"
  local task_id="$2"
  echo "$pid:$task_id" >> "$ACTIVE_FILE"
}

remove_active() {
  local pid="$1"
  if [[ -f "$ACTIVE_FILE" ]]; then
    grep -v "^$pid:" "$ACTIVE_FILE" > "${ACTIVE_FILE}.tmp" || true
    mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
  fi
}

get_task_for_pid() {
  local pid="$1"
  grep "^$pid:" "$ACTIVE_FILE" 2>/dev/null | cut -d: -f2 || echo ""
}

get_retries() {
  local task_id="$1"
  grep "^$task_id:" "$RETRIES_FILE" 2>/dev/null | cut -d: -f2 || echo "0"
}

set_retries() {
  local task_id="$1"
  local count="$2"
  grep -v "^$task_id:" "$RETRIES_FILE" > "${RETRIES_FILE}.tmp" 2>/dev/null || true
  echo "$task_id:$count" >> "${RETRIES_FILE}.tmp"
  mv "${RETRIES_FILE}.tmp" "$RETRIES_FILE"
}

dispatch_agent() {
  local prd_file="$1"
  local state_file="$2"
  local task_id="$3"
  local agent_type="$4"

  local task_json=$(jq --arg id "$task_id" '.sections[].tasks[] | select(.id == $id)' "$prd_file")
  local agent_def="$SVAO_ROOT/agents/${agent_type}.md"

  if [[ ! -f "$agent_def" ]]; then
    log_error "Agent definition not found: $agent_def"
    return 1
  fi

  # Extract agent prompt (skip frontmatter)
  local agent_prompt=$(awk '/^---$/{p=!p;next} !p' "$agent_def")

  # Build full prompt
  local prompt="$agent_prompt

---

## Current Task

Task ID: $task_id
$(echo "$task_json" | jq -r '"Description: \(.description)\nFiles: \(.files | join(", "))"')

---

## Instructions

1. Follow TDD practices - write tests first
2. Commit after completing the task
3. Report status using signals:

   TASK_COMPLETE: $task_id
   FILES_CHANGED: [list files]

   If blocked:
   BLOCKED:TESTS: [details]
   BLOCKED:DEPENDENCY: need [task] first
   BLOCKED:CLARIFICATION: [question]

   If you discover a dependency:
   DISCOVERED_DEPENDENCY: [from] needs [to] because [reason]
"

  log_agent "Dispatching $agent_type for task $task_id"

  # Update state
  update_task_status "$state_file" "$task_id" "in_progress"

  # Set environment for status writer
  export SVAO_STATUS_DIR="$STATUS_DIR"
  export SVAO_SESSION_ID="$SESSION_ID"
  export SVAO_TASK_ID="$task_id"
  export SVAO_AGENT="$agent_type"
  export SVAO_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Write initial status
  "$SCRIPT_DIR/status-writer.sh" running "starting" "Initializing..."

  # Dispatch agent (background)
  (
    if command -v claude &> /dev/null; then
      echo "$prompt" | claude --print 2>&1 | tee "$STATUS_DIR/${task_id}.output"
      exit_code=${PIPESTATUS[1]}
    else
      log_warn "Claude CLI not found, simulating..."
      echo "$prompt" > "$STATUS_DIR/${task_id}.prompt"
      sleep 2
      echo "TASK_COMPLETE: $task_id" > "$STATUS_DIR/${task_id}.output"
      exit_code=0
    fi

    # Write final status based on output
    if grep -q "TASK_COMPLETE" "$STATUS_DIR/${task_id}.output"; then
      "$SCRIPT_DIR/status-writer.sh" complete "TASK_COMPLETE"
    elif grep -q "BLOCKED:" "$STATUS_DIR/${task_id}.output"; then
      signal=$(grep -o "BLOCKED:[A-Z]*" "$STATUS_DIR/${task_id}.output" | head -1)
      "$SCRIPT_DIR/status-writer.sh" failed "$signal" "See output file"
    else
      "$SCRIPT_DIR/status-writer.sh" failed "UNKNOWN" "Agent exited without signal"
    fi
  ) &

  local pid=$!
  add_active "$pid" "$task_id"

  log_agent "Agent PID $pid assigned to task $task_id"
}

# ─────────────────────────────────────────────────────────────
# Status Monitoring
# ─────────────────────────────────────────────────────────────

check_agent_status() {
  local state_file="$1"
  local task_id="$2"

  local status_file="$STATUS_DIR/${task_id}.status.json"

  if [[ ! -f "$status_file" ]]; then
    return 1  # Still running, no status yet
  fi

  local status=$(jq -r '.status' "$status_file")

  case "$status" in
    completed)
      log_success "Task $task_id completed"
      update_task_status "$state_file" "$task_id" "completed"
      return 0
      ;;
    failed)
      local signal=$(jq -r '.signal' "$status_file")
      local error=$(jq -r '.error // "unknown"' "$status_file")
      log_error "Task $task_id failed: $signal - $error"
      return 2
      ;;
    running)
      return 1
      ;;
  esac
}

process_completed_agents() {
  local prd_file="$1"
  local state_file="$2"

  if [[ ! -f "$ACTIVE_FILE" ]]; then
    return
  fi

  # Read active PIDs
  while IFS=: read -r pid task_id; do
    [[ -z "$pid" ]] && continue

    if ! kill -0 "$pid" 2>/dev/null; then
      # Process exited
      remove_active "$pid"

      check_agent_status "$state_file" "$task_id"
      local result=$?

      if [[ $result -eq 2 ]]; then
        # Failed - handle retry
        handle_failure "$prd_file" "$state_file" "$task_id"
      fi
    fi
  done < "$ACTIVE_FILE"
}

handle_failure() {
  local prd_file="$1"
  local state_file="$2"
  local task_id="$3"

  local retries=$(get_retries "$task_id")
  ((retries++))
  set_retries "$task_id" "$retries"

  if [[ $retries -lt $MAX_RETRIES ]]; then
    log_warn "Retrying task $task_id (attempt $((retries + 1))/$MAX_RETRIES)"
    local agent=$(get_agent_for_task "$prd_file" "$task_id")
    dispatch_agent "$prd_file" "$state_file" "$task_id" "$agent"
  else
    log_error "Task $task_id failed after $MAX_RETRIES attempts"
    update_task_status "$state_file" "$task_id" "blocked"
  fi
}

# ─────────────────────────────────────────────────────────────
# Main Loop
# ─────────────────────────────────────────────────────────────

run_dispatch_loop() {
  local prd_file="$1"
  local state_file="$2"

  load_state "$state_file"

  log_info "Starting dispatch loop (max parallel: $MAX_PARALLEL)"

  while [[ $ITERATION -lt $MAX_ITERATIONS ]]; do
    ((ITERATION++))
    log "--- Iteration $ITERATION ---"

    # Rebuild queue
    rebuild_queue "$prd_file" "$state_file"

    # Check completion
    local progress=$(jq -r '.summary.progress_percent' "$state_file")
    if [[ "$progress" == "100" ]]; then
      log_success "All tasks complete!"
      break
    fi

    # Process completed agents
    process_completed_agents "$prd_file" "$state_file"

    # Dispatch new agents
    local active_count=$(get_active_count)
    local available=$((MAX_PARALLEL - active_count))

    if [[ $available -gt 0 ]]; then
      local ready_tasks=$(jq -r '.queue.ready[]' "$state_file" | head -n "$available")

      for task_id in $ready_tasks; do
        local agent=$(get_agent_for_task "$prd_file" "$task_id")
        dispatch_agent "$prd_file" "$state_file" "$task_id" "$agent"
        ((active_count++))
        [[ $active_count -ge $MAX_PARALLEL ]] && break
      done
    fi

    # Save state
    save_state "$state_file"

    # Wait before next iteration
    active_count=$(get_active_count)
    if [[ $active_count -gt 0 ]]; then
      log_agent "Waiting for $active_count active agent(s)..."
      sleep "$POLL_INTERVAL"
    else
      local ready_count=$(jq -r '.queue.ready | length' "$state_file")
      if [[ "$ready_count" -eq 0 ]]; then
        local blocked_count=$(jq -r '.queue.blocked | length' "$state_file")
        if [[ "$blocked_count" -gt 0 ]]; then
          log_warn "No ready tasks, $blocked_count blocked"
          break
        fi
      fi
    fi
  done

  if [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    log_warn "Max iterations reached ($MAX_ITERATIONS)"
  fi

  # Final summary
  log_info "Dispatch loop complete"
  jq '.summary' "$state_file"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: dispatch.sh <prd.json> <prd-state.json>" >&2
    exit 1
  fi

  run_dispatch_loop "$1" "$2"
fi
