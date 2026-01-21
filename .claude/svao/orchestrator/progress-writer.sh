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
    *)
      echo "Usage: progress-writer.sh <action> [args]"
      echo ""
      echo "Actions:"
      echo "  bar <completed> <total> [width]  - Render progress bar"
      echo "  log <file> <type> <msg> [detail] - Write to progress log"
      echo "  status <state-file>              - Render status line"
      exit 1
      ;;
  esac
}

main "$@"
