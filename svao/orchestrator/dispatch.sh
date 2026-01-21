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
log_info() { echo -e "[$(date +%H:%M:%S)] ${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "[$(date +%H:%M:%S)] ${GREEN}✅${NC} $*"; }
log_warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}⚠️${NC} $*"; }
log_error() { echo -e "[$(date +%H:%M:%S)] ${RED}❌${NC} $*" >&2; }
log_agent() { echo -e "[$(date +%H:%M:%S)] ${CYAN}agent${NC} $*"; }

# Configuration
MAX_PARALLEL="${MAX_PARALLEL:-3}"
MAX_RETRIES="${MAX_RETRIES:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-5}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"

# Checkpoint configuration
CHECKPOINT_DIR="$HOME/.claude/svao/orchestrator/checkpoints"
CHECKPOINT_INVOKER="$CHECKPOINT_DIR/invoke.sh"

# Progress writer
PROGRESS_WRITER="$SCRIPT_DIR/progress-writer.sh"

# PR creator
PR_CREATOR="$SCRIPT_DIR/pr-creator.sh"

# State (use temp files since bash associative arrays don't export well)
ITERATION=0
SESSION_ID=""
STATUS_DIR=""
ACTIVE_FILE=""
RETRIES_FILE=""

# ─────────────────────────────────────────────────────────────
# Resume Detection
# ─────────────────────────────────────────────────────────────

detect_interrupted_session() {
  local state_file="$1"

  # Check if session was running
  local status
  status=$(jq -r '.session.status // "unknown"' "$state_file")

  if [[ "$status" == "running" ]]; then
    return 0  # Was interrupted
  fi

  return 1  # Clean state
}

validate_prd_unchanged() {
  local prd_file="$1"
  local state_file="$2"

  local expected
  expected=$(jq -r '.prd_hash' "$state_file")
  local actual
  actual="sha256:$(shasum -a 256 "$prd_file" | cut -d' ' -f1)"

  if [[ "$expected" != "$actual" ]]; then
    log_error "PRD modified since last run!"
    log_error "Expected: $expected"
    log_error "Got: $actual"
    return 1
  fi

  return 0
}

cleanup_stale_processes() {
  local state_file="$1"
  local cleaned=0

  # Get session ID from state
  local session_id
  session_id=$(jq -r '.session.id' "$state_file")
  local status_dir="/tmp/svao/$session_id"
  local active_file="$status_dir/.active_pids"

  if [[ ! -f "$active_file" ]]; then
    return 0
  fi

  log_info "Checking for stale processes..."

  # Read each PID and check if still running
  while IFS=: read -r pid task_id; do
    [[ -z "$pid" ]] && continue

    if ! kill -0 "$pid" 2>/dev/null; then
      log_warn "Stale process found: PID $pid (task $task_id)"

      # Check if task completed
      local status_file="$status_dir/${task_id}.status.json"
      if [[ -f "$status_file" ]]; then
        local task_status
        task_status=$(jq -r '.status' "$status_file")
        if [[ "$task_status" == "completed" ]]; then
          log_info "Task $task_id completed before crash"
          update_task_status "$state_file" "$task_id" "completed"
        else
          log_warn "Task $task_id was interrupted, will be re-dispatched"
          update_task_status "$state_file" "$task_id" "pending"
        fi
      else
        log_warn "No status for task $task_id, marking pending"
        update_task_status "$state_file" "$task_id" "pending"
      fi

      ((cleaned++))
    fi
  done < "$active_file"

  # Clear the active PIDs file
  if [[ $cleaned -gt 0 ]]; then
    : > "$active_file"
    log_info "Cleaned $cleaned stale process(es)"
  fi

  return 0
}

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
# Checkpoint System
# ─────────────────────────────────────────────────────────────

should_trigger_queue_planning() {
  local state_file="$1"
  local last_checkpoint_iteration
  last_checkpoint_iteration=$(jq -r '.checkpoints.last_iteration_at_checkpoint // 0' "$state_file")
  local diff=$((ITERATION - last_checkpoint_iteration))
  [[ $diff -ge $CHECKPOINT_INTERVAL ]]
}

should_trigger_completion_review() {
  local prd_file="$1"
  local state_file="$2"
  local section_num="$3"

  # Get all tasks in section
  local section_tasks
  section_tasks=$(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .tasks[].id
  ' "$prd_file")

  # Check if all are completed
  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue
    local status
    status=$(jq -r --arg id "$task_id" '.tasks[$id].status // "pending"' "$state_file")
    if [[ "$status" != "completed" ]]; then
      return 1
    fi
  done <<< "$section_tasks"

  # Check if already reviewed
  local reviewed
  reviewed=$(jq -r --arg n "$section_num" '
    .checkpoints.reviewed_sections // [] | map(select(. == ($n | tonumber))) | length
  ' "$state_file")
  [[ "$reviewed" -eq 0 ]]
}

run_checkpoint() {
  local checkpoint_type="$1"
  local prd_file="$2"
  local state_file="$3"
  local extra_args="${4:-}"
  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")

  log_info "Running $checkpoint_type checkpoint..."

  # Find the checkpoint invoker - handle nested .claude paths
  local invoker=""
  if [[ -f "$CHECKPOINT_DIR/invoke.sh" ]]; then
    invoker="$CHECKPOINT_DIR/invoke.sh"
  elif [[ -f "$HOME/.claude/svao/orchestrator/checkpoints/invoke.sh" ]]; then
    invoker="$HOME/.claude/svao/orchestrator/checkpoints/invoke.sh"
  fi

  if [[ -z "$invoker" || ! -f "$invoker" ]]; then
    log_warn "Checkpoint invoker not found, skipping checkpoint"
    return 0
  fi

  local output
  if ! output=$("$invoker" "$checkpoint_type" "$change_id" $extra_args 2>&1); then
    log_error "Checkpoint invocation failed: $output"
    return 1
  fi

  local valid
  valid=$(echo "$output" | jq -r '.valid // false')

  if [[ "$valid" != "true" ]]; then
    log_error "Checkpoint output invalid"
    return 1
  fi

  # Process commands
  while IFS= read -r cmd_json; do
    local cmd
    cmd=$(echo "$cmd_json" | jq -r '.command')
    local args
    args=$(echo "$cmd_json" | jq -r '.args')
    execute_checkpoint_command "$prd_file" "$state_file" "$cmd" "$args"
  done < <(echo "$output" | jq -c '.commands[]')

  # Update checkpoint tracking
  local tmp_file="${state_file}.tmp.$$"
  jq --arg type "$checkpoint_type" \
     --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson iter "$ITERATION" \
     '.checkpoints.last_queue_planning = $time |
      .checkpoints.last_iteration_at_checkpoint = $iter |
      .checkpoints.history += [{type: $type, timestamp: $time, iteration: $iter}]' \
     "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

execute_checkpoint_command() {
  local prd_file="$1"
  local state_file="$2"
  local cmd="$3"
  local args="$4"
  local tmp_file="${state_file}.tmp.$$"

  case "$cmd" in
    DISPATCH)
      # Format: task-id:agent:isolation
      local task_id agent isolation
      IFS=':' read -r task_id agent isolation <<< "$args"
      log_info "Checkpoint dispatching $task_id to $agent (isolation: $isolation)"
      dispatch_agent "$prd_file" "$state_file" "$task_id" "$agent"
      ;;
    REORDER)
      # Format: task-id, task-id, ...
      log_info "Checkpoint reordering queue: $args"
      local new_order
      new_order=$(echo "$args" | tr -d ' ' | tr ',' '\n' | jq -R . | jq -s .)
      jq --argjson order "$new_order" '.queue.ready = $order' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    REASSIGN)
      # Format: task-id:agent
      local task_id agent
      IFS=':' read -r task_id agent <<< "$args"
      log_info "Checkpoint reassigning $task_id to $agent"
      jq --arg id "$task_id" --arg agent "$agent" \
         '.tasks[$id].assigned_to = $agent' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    ADD_DEPENDENCY)
      # Format: from:to:confidence
      local from to confidence
      IFS=':' read -r from to confidence <<< "$args"
      log_info "Checkpoint adding dependency: $from -> $to (confidence: $confidence)"
      jq --arg from "$from" --arg to "$to" --arg conf "$confidence" \
         '.discovered_dependencies += [{
             from: $from,
             to: $to,
             confidence: ($conf | tonumber),
             discovered_at: (now | todate),
             discovered_by: "checkpoint",
             status: "applied"
         }]' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      rebuild_queue "$prd_file" "$state_file"
      ;;
    UNBLOCK)
      # Format: task-id:strategy[:details]
      local task_id strategy details
      IFS=':' read -r task_id strategy details <<< "$args"
      log_info "Checkpoint unblocking $task_id with strategy: $strategy"
      handle_unblock_strategy "$state_file" "$task_id" "$strategy" "$details"
      ;;
    APPROVED)
      # Format: section-number
      log_info "Checkpoint approved section $args"
      jq --arg section "$args" \
         '.checkpoints.reviewed_sections = ((.checkpoints.reviewed_sections // []) + [($section | tonumber)] | unique)' \
         "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"

      # Create PR for approved section
      if [[ -f "$PR_CREATOR" ]]; then
        log_info "Creating PR for section $args..."
        local pr_url=""
        local progress_file="$(dirname "$state_file")/progress.md"
        if pr_url=$("$PR_CREATOR" create "$prd_file" "$state_file" "$args" 2>&1); then
          # Log to progress only on success
          "$PROGRESS_WRITER" log "$progress_file" section_complete "$args" "PR: $pr_url" || true
        else
          log_warn "PR creation failed: $pr_url"
          # Log to progress without PR URL
          "$PROGRESS_WRITER" log "$progress_file" section_complete "$args" "PR creation failed" || true
        fi
      fi
      ;;
    NEEDS_WORK)
      # Format: section-number:reason
      local section reason
      IFS=':' read -r section reason <<< "$args"
      log_warn "Checkpoint: Section $section needs work: $reason"
      mark_section_needs_rework "$prd_file" "$state_file" "$section" "$reason"
      ;;
    WAIT)
      log_info "Checkpoint: Waiting - $args"
      ;;
    NOOP)
      log_info "Checkpoint: No action needed"
      ;;
  esac
}

handle_unblock_strategy() {
  local state_file="$1"
  local task_id="$2"
  local strategy="$3"
  local details="$4"
  local tmp_file="${state_file}.tmp.$$"

  case "$strategy" in
    alternate-agent)
      jq --arg id "$task_id" --arg agent "$details" \
         '.tasks[$id].status = "pending" |
          .tasks[$id].assigned_to = $agent |
          .queue.blocked = (.queue.blocked - [$id]) |
          .queue.ready = (.queue.ready + [$id])' \
         "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    skip-and-continue)
      jq --arg id "$task_id" \
         '.tasks[$id].status = "skipped" |
          .queue.blocked = (.queue.blocked - [$id])' \
         "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    escalate)
      log_warn "ESCALATION REQUIRED for task $task_id: $details"
      jq --arg id "$task_id" --arg reason "$details" \
         '.tasks[$id].escalation_reason = $reason' \
         "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Metrics Aggregation
# ─────────────────────────────────────────────────────────────

update_metrics() {
  local state_file="$1"
  local event="$2"
  local agent="${3:-}"
  local duration="${4:-0}"
  local tmp_file="${state_file}.tmp.$$"

  case "$event" in
    task_completed)
      jq --arg agent "$agent" --argjson dur "$duration" '
        .metrics.tasks_completed += 1 |
        .metrics.agents_used[$agent].completed = ((.metrics.agents_used[$agent].completed // 0) + 1) |
        # Update average duration (running average)
        .metrics.avg_task_duration_seconds = (
          if .metrics.tasks_completed > 1 then
            ((.metrics.avg_task_duration_seconds * (.metrics.tasks_completed - 1)) + $dur) / .metrics.tasks_completed
          else
            $dur
          end
        )
      ' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    task_failed)
      jq --arg agent "$agent" '
        .metrics.tasks_failed += 1 |
        .metrics.agents_used[$agent].failed = ((.metrics.agents_used[$agent].failed // 0) + 1)
      ' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
    retry)
      jq '.metrics.total_retries += 1' "$state_file" > "$tmp_file"
      mv "$tmp_file" "$state_file"
      ;;
  esac
}

calculate_parallel_utilization() {
  local state_file="$1"
  local max_parallel="$2"
  local tmp_file="${state_file}.tmp.$$"

  # Parallel utilization = avg active agents / max_parallel
  # Calculated from in_progress counts over iterations
  local active
  active=$(jq '.queue.in_progress | length' "$state_file")

  jq --argjson active "$active" --argjson max "$max_parallel" '
    # Running average of utilization
    .metrics.parallel_utilization = (
      if .session.iteration > 0 then
        ((.metrics.parallel_utilization * (.session.iteration - 1)) + ($active / $max)) / .session.iteration
      else
        $active / $max
      end
    )
  ' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

persist_global_metrics() {
  local state_file="$1"
  local metrics_file="$SVAO_ROOT/agents/metrics.json"

  if [[ ! -f "$metrics_file" ]]; then
    log_warn "Global metrics file not found: $metrics_file"
    return 0
  fi

  local tmp_file="${metrics_file}.tmp.$$"
  local session_metrics
  session_metrics=$(jq '.metrics' "$state_file")

  jq --argjson session "$session_metrics" \
     --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .updated_at = $updated |
    .global.total_orchestration_sessions += 1 |
    .global.total_tasks_completed += ($session.tasks_completed // 0) |
    # Running average of parallel utilization
    .global.avg_parallel_utilization = (
      if .global.total_orchestration_sessions > 1 then
        ((.global.avg_parallel_utilization * (.global.total_orchestration_sessions - 1)) + ($session.parallel_utilization // 0)) / .global.total_orchestration_sessions
      else
        ($session.parallel_utilization // 0)
      end
    ) |
    # Update per-agent metrics
    reduce ($session.agents_used // {} | to_entries[]) as $agent (.;
      .agents[$agent.key].total_completed = ((.agents[$agent.key].total_completed // 0) + ($agent.value.completed // 0)) |
      .agents[$agent.key].total_failed = ((.agents[$agent.key].total_failed // 0) + ($agent.value.failed // 0))
    )
  ' "$metrics_file" > "$tmp_file"

  mv "$tmp_file" "$metrics_file"
  log_success "Updated global metrics: $metrics_file"
}

mark_section_needs_rework() {
  local prd_file="$1"
  local state_file="$2"
  local section="$3"
  local reason="$4"

  local section_tasks
  section_tasks=$(jq -r --arg n "$section" '
    .sections[] | select(.number == ($n | tonumber)) | .tasks[].id
  ' "$prd_file")

  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue
    local tmp_file="${state_file}.tmp.$$"
    jq --arg id "$task_id" --arg reason "$reason" \
       '.tasks[$id].status = "pending" |
        .tasks[$id].rework_reason = $reason |
        .queue.completed = (.queue.completed - [$id]) |
        .queue.ready = (.queue.ready + [$id])' \
       "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"
  done <<< "$section_tasks"
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

  # Log progress
  local progress_file="$(dirname "$state_file")/progress.md"
  "$PROGRESS_WRITER" log "$progress_file" task_started "$task_id" "$agent_type" || true
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
      # Log progress
      local progress_file="$(dirname "$state_file")/progress.md"
      local duration=$(jq -r '.duration_seconds // 0' "$status_file")
      "$PROGRESS_WRITER" log "$progress_file" task_completed "$task_id" "$duration" || true
      local agent
      agent=$(jq -r --arg id "$task_id" '.tasks[$id].assigned_to // "unknown"' "$state_file")
      update_metrics "$state_file" task_completed "$agent" "$duration"
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
  update_metrics "$state_file" retry

  if [[ $retries -lt $MAX_RETRIES ]]; then
    log_warn "Retrying task $task_id (attempt $((retries + 1))/$MAX_RETRIES)"
    local agent=$(get_agent_for_task "$prd_file" "$task_id")
    dispatch_agent "$prd_file" "$state_file" "$task_id" "$agent"
  else
    log_error "Task $task_id failed after $MAX_RETRIES attempts"
    update_task_status "$state_file" "$task_id" "blocked"
    local agent=$(get_agent_for_task "$prd_file" "$task_id")
    update_metrics "$state_file" task_failed "$agent"
  fi
}

# ─────────────────────────────────────────────────────────────
# Main Loop
# ─────────────────────────────────────────────────────────────

run_dispatch_loop() {
  local prd_file="$1"
  local state_file="$2"
  local resume="${3:-false}"

  # Validate PRD hasn't changed
  if ! validate_prd_unchanged "$prd_file" "$state_file"; then
    log_error "Cannot proceed: PRD modified. Re-compile required."
    exit 1
  fi

  # Handle resume vs fresh start
  if [[ "$resume" == "true" ]]; then
    if detect_interrupted_session "$state_file"; then
      log_warn "Resuming interrupted session..."
      cleanup_stale_processes "$state_file"
      load_state "$state_file"
      log_success "Resumed at iteration $ITERATION"
    else
      log_info "No interrupted session found, starting fresh"
      load_state "$state_file"
    fi
  else
    # Fresh start - reset session
    local tmp_file="${state_file}.tmp.$$"
    jq --arg id "svao-$(date +%Y%m%d-%H%M%S)" \
       --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.session.id = $id | .session.started_at = $started | .session.iteration = 0 | .session.status = "running"' \
       "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"
    load_state "$state_file"
  fi

  # Mark session as running
  local tmp_file="${state_file}.tmp.$$"
  jq '.session.status = "running"' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"

  # Write progress log entry
  local progress_file="$(dirname "$state_file")/progress.md"
  if [[ "$resume" == "true" ]]; then
    "$PROGRESS_WRITER" log "$progress_file" session_resume "Resuming from iteration $ITERATION" || true
  else
    "$PROGRESS_WRITER" log "$progress_file" session_start "Starting orchestration with $MAX_PARALLEL parallel agents" || true
  fi

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
      local progress_file="$(dirname "$state_file")/progress.md"
      local summary
      summary=$(jq -r '"Completed \(.summary.completed) tasks in \(.session.iteration) iterations"' "$state_file")
      "$PROGRESS_WRITER" log "$progress_file" session_complete "$summary" || true
      break
    fi

    # Process completed agents
    process_completed_agents "$prd_file" "$state_file"

    # Check for checkpoint triggers
    if should_trigger_queue_planning "$state_file"; then
      run_checkpoint "queue-planning" "$prd_file" "$state_file" "--max-parallel $MAX_PARALLEL"
    fi

    # Check for section completion and trigger review
    local sections
    sections=$(jq -r '.sections[].number' "$prd_file")
    for section_num in $sections; do
      if should_trigger_completion_review "$prd_file" "$state_file" "$section_num"; then
        run_checkpoint "completion-review" "$prd_file" "$state_file" "--section $section_num"
      fi
    done

    # Check for blocked tasks needing resolution
    local blocked_tasks
    blocked_tasks=$(jq -r '.queue.blocked[]?' "$state_file" 2>/dev/null || echo "")
    for task_id in $blocked_tasks; do
      [[ -z "$task_id" ]] && continue
      local retries
      retries=$(get_retries "$task_id")
      if [[ $retries -ge $MAX_RETRIES ]]; then
        run_checkpoint "blocker-resolution" "$prd_file" "$state_file" "--task $task_id"
      fi
    done

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

    # Update parallel utilization metric
    calculate_parallel_utilization "$state_file" "$MAX_PARALLEL"

    # Save state
    save_state "$state_file"

    # Render live status
    "$PROGRESS_WRITER" status "$state_file" || true

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

  # Persist metrics to global file
  persist_global_metrics "$state_file"

  # Mark session complete
  local tmp_file="${state_file}.tmp.$$"
  jq '.session.status = "completed"' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: dispatch.sh <prd.json> <prd-state.json>" >&2
    exit 1
  fi

  run_dispatch_loop "$1" "$2"
fi
