#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO Progress Writer
# Writes append-only progress log and renders progress bar
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# Progress Bar
# ─────────────────────────────────────────────────────────────

render_progress_bar() {
  local completed="$1"
  local total="$2"
  local width="${3:-40}"

  if [[ $total -eq 0 ]]; then
    echo "[ No tasks ]"
    return
  fi

  local percent=$((completed * 100 / total))
  local filled=$((completed * width / total))
  local empty=$((width - filled))

  # Build bar
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  printf "${GREEN}[%s]${NC} %d/%d (%d%%)" "$bar" "$completed" "$total" "$percent"
}

# ─────────────────────────────────────────────────────────────
# Progress Log (append-only markdown)
# ─────────────────────────────────────────────────────────────

write_progress_entry() {
  local progress_file="$1"
  local event_type="$2"
  local message="$3"
  local details="${4:-}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Create file with header if doesn't exist
  if [[ ! -f "$progress_file" ]]; then
    cat > "$progress_file" << 'EOF'
# SVAO Progress Log

This file contains an append-only log of orchestration events.

---

EOF
  fi

  # Format entry based on type
  case "$event_type" in
    session_start)
      echo "" >> "$progress_file"
      echo "## Session Started: $timestamp" >> "$progress_file"
      echo "" >> "$progress_file"
      echo "$message" >> "$progress_file"
      ;;
    session_resume)
      echo "" >> "$progress_file"
      echo "## Session Resumed: $timestamp" >> "$progress_file"
      echo "" >> "$progress_file"
      echo "$message" >> "$progress_file"
      ;;
    task_started)
      echo "- **$timestamp** | 🚀 Task $message started" >> "$progress_file"
      [[ -n "$details" ]] && echo "  - Agent: $details" >> "$progress_file"
      ;;
    task_completed)
      echo "- **$timestamp** | ✅ Task $message completed" >> "$progress_file"
      [[ -n "$details" ]] && echo "  - Duration: ${details}s" >> "$progress_file"
      ;;
    task_failed)
      echo "- **$timestamp** | ❌ Task $message failed" >> "$progress_file"
      [[ -n "$details" ]] && echo "  - Error: $details" >> "$progress_file"
      ;;
    checkpoint)
      echo "- **$timestamp** | 🔍 Checkpoint: $message" >> "$progress_file"
      [[ -n "$details" ]] && echo "  - Result: $details" >> "$progress_file"
      ;;
    section_complete)
      echo "" >> "$progress_file"
      echo "### Section $message Complete" >> "$progress_file"
      [[ -n "$details" ]] && echo "$details" >> "$progress_file"
      ;;
    session_complete)
      echo "" >> "$progress_file"
      echo "## Session Complete: $timestamp" >> "$progress_file"
      echo "" >> "$progress_file"
      echo "$message" >> "$progress_file"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Live Status Display
# ─────────────────────────────────────────────────────────────

render_status_line() {
  local state_file="$1"

  local completed in_progress blocked ready total
  completed=$(jq -r '.summary.completed // 0' "$state_file")
  in_progress=$(jq -r '.summary.in_progress // 0' "$state_file")
  blocked=$(jq -r '.summary.blocked // 0' "$state_file")
  ready=$(jq -r '.summary.ready // 0' "$state_file")
  total=$(jq -r '.summary.total_tasks // 0' "$state_file")

  # Clear line and render
  printf "\r\033[K"
  render_progress_bar "$completed" "$total" 30
  printf " | ${CYAN}▶${NC}$in_progress ${GREEN}✓${NC}$completed ${YELLOW}⏳${NC}$ready ${BLUE}⛔${NC}$blocked"
}

format_duration() {
  local seconds="$1"
  if [[ $seconds -lt 60 ]]; then
    echo "${seconds}s"
  elif [[ $seconds -lt 3600 ]]; then
    local mins=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${mins}m ${secs}s"
  else
    local hours=$((seconds / 3600))
    local mins=$(((seconds % 3600) / 60))
    echo "${hours}h ${mins}m"
  fi
}

render_live_status() {
  local state_file="$1"
  local status_dir="$2"
  local last_event="${3:-}"

  # Get summary stats
  local completed in_progress blocked ready total percent
  completed=$(jq -r '.summary.completed // 0' "$state_file")
  in_progress=$(jq -r '.summary.in_progress // 0' "$state_file")
  blocked=$(jq -r '.summary.blocked // 0' "$state_file")
  ready=$(jq -r '.summary.ready // 0' "$state_file")
  total=$(jq -r '.summary.total_tasks // 0' "$state_file")
  percent=$(jq -r '.summary.progress_percent // 0' "$state_file")

  local change_id
  change_id=$(jq -r '.change_id // "unknown"' "$state_file" 2>/dev/null || echo "unknown")

  # Clear screen and move cursor to top
  printf "\033[2J\033[H"

  # Header
  echo -e "┌────────────────────────────────────────────────────────────────┐"
  printf "│ ${CYAN}SVAO Orchestrator${NC} - %-43s │\n" "$change_id"
  echo -e "├────────────────────────────────────────────────────────────────┤"

  # Progress bar
  local bar_width=40
  local filled=$((completed * bar_width / (total > 0 ? total : 1)))
  local empty=$((bar_width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  printf "│ Progress: ${GREEN}[%s]${NC} %d%% (%d/%d)      │\n" "$bar" "${percent%.*}" "$completed" "$total"
  printf "│ Status:   ${CYAN}▶${NC}%-2d active  ${GREEN}✓${NC}%-3d done  ${YELLOW}⏳${NC}%-2d ready  ${BLUE}⛔${NC}%-2d blocked │\n" "$in_progress" "$completed" "$ready" "$blocked"
  echo -e "├────────────────────────────────────────────────────────────────┤"

  # Active tasks
  echo -e "│ ${CYAN}Active Tasks:${NC}                                                  │"

  local now=$(date -u +%s)  # Use UTC for consistency with stored timestamps
  local active_file="$status_dir/.active_pids"
  local has_tasks=false

  if [[ -f "$active_file" ]]; then
    while IFS=: read -r pid task_id; do
      [[ -z "$pid" || -z "$task_id" ]] && continue
      [[ "$task_id" == phase-review-* ]] && continue  # Skip phase reviews here

      has_tasks=true

      # Get task info from state
      local agent_type start_time duration_str
      agent_type=$(jq -r --arg id "$task_id" '.tasks[$id].assigned_to // "unknown"' "$state_file" 2>/dev/null || echo "unknown")
      start_time=$(jq -r --arg id "$task_id" '.tasks[$id].started_at // ""' "$state_file" 2>/dev/null || echo "")

      # Calculate duration
      if [[ -n "$start_time" ]]; then
        local start_epoch
        # Parse UTC timestamp correctly - remove Z suffix and use -u flag
        local start_time_stripped="${start_time%Z}"
        start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$start_time_stripped" "+%s" 2>/dev/null) || \
          start_epoch=$(date -u -d "$start_time" "+%s" 2>/dev/null) || \
          start_epoch=$now
        # Get current time in UTC epoch for fair comparison
        local now_utc=$(date -u +%s)
        local duration=$((now_utc - start_epoch))
        duration_str=$(format_duration "$duration")
      else
        duration_str="--"
      fi

      printf "│   ${GREEN}●${NC} %-8s [%-16s] Running for %-12s │\n" "$task_id" "$agent_type" "$duration_str"
    done < "$active_file"
  fi

  if [[ "$has_tasks" == "false" ]]; then
    echo -e "│   ${YELLOW}(none)${NC}                                                     │"
  fi

  # Phase reviewers
  echo -e "├────────────────────────────────────────────────────────────────┤"
  echo -e "│ ${BLUE}Phase Reviewers:${NC}                                               │"

  local has_reviewers=false
  if [[ -f "$active_file" ]]; then
    while IFS=: read -r pid task_id; do
      [[ -z "$pid" || -z "$task_id" ]] && continue
      [[ "$task_id" != phase-review-* ]] && continue

      has_reviewers=true
      local section_num="${task_id#phase-review-}"

      # Get status file for timing info
      local status_file_path="$status_dir/phase-review-section-${section_num}.status"
      local status="running"
      [[ -f "$status_file_path" ]] && status=$(cat "$status_file_path")

      printf "│   ${BLUE}●${NC} Section %-3s [phase-reviewer] %-23s │\n" "$section_num" "$status"
    done < "$active_file"
  fi

  if [[ "$has_reviewers" == "false" ]]; then
    echo -e "│   ${YELLOW}(none)${NC}                                                     │"
  fi

  # Last event
  echo -e "├────────────────────────────────────────────────────────────────┤"
  if [[ -n "$last_event" ]]; then
    printf "│ Last Event: %-51s │\n" "$last_event"
  else
    echo -e "│ Last Event: ${YELLOW}Waiting for events...${NC}                             │"
  fi

  echo -e "└────────────────────────────────────────────────────────────────┘"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

main() {
  local action="${1:-}"

  case "$action" in
    bar)
      render_progress_bar "$2" "$3" "${4:-40}"
      ;;
    log)
      write_progress_entry "$2" "$3" "$4" "${5:-}"
      ;;
    status)
      render_status_line "$2"
      ;;
    live)
      # Full-screen live status display
      render_live_status "$2" "$3" "${4:-}"
      ;;
    *)
      echo "Usage: progress-writer.sh <action> [args]"
      echo ""
      echo "Actions:"
      echo "  bar <completed> <total> [width]     - Render progress bar"
      echo "  log <file> <type> <msg> [detail]    - Write to progress log"
      echo "  status <state-file>                 - Render status line"
      echo "  live <state-file> <status-dir> [event] - Full live dashboard"
      exit 1
      ;;
  esac
}

main "$@"
