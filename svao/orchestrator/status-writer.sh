#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO Agent Status Writer
# Writes structured status files for orchestrator monitoring
# ─────────────────────────────────────────────────────────────

set -euo pipefail

STATUS_DIR="${SVAO_STATUS_DIR:-/tmp/svao}"
SESSION_ID="${SVAO_SESSION_ID:-unknown}"
TASK_ID="${SVAO_TASK_ID:-unknown}"

STATUS_FILE="$STATUS_DIR/$SESSION_ID/$TASK_ID.status.json"

mkdir -p "$(dirname "$STATUS_FILE")"

write_status() {
  local status="$1"
  local phase="${2:-}"
  local progress="${3:-}"

  jq -n \
    --arg task_id "$TASK_ID" \
    --arg agent "${SVAO_AGENT:-unknown}" \
    --arg pid "$$" \
    --arg started "${SVAO_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "$status" \
    --arg phase "$phase" \
    --arg progress "$progress" \
    '{
      task_id: $task_id,
      agent: $agent,
      pid: ($pid | tonumber),
      started_at: $started,
      updated_at: $updated,
      status: $status,
      phase: $phase,
      progress: $progress,
      files_touched: [],
      commits: [],
      signals: []
    }' > "$STATUS_FILE"
}

write_complete() {
  local signal="${1:-TASK_COMPLETE}"
  local files_json="${2:-[]}"
  local commits_json="${3:-[]}"

  jq -n \
    --arg task_id "$TASK_ID" \
    --arg agent "${SVAO_AGENT:-unknown}" \
    --arg started "${SVAO_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg signal "$signal" \
    --argjson files "$files_json" \
    --argjson commits "$commits_json" \
    '{
      task_id: $task_id,
      agent: $agent,
      started_at: $started,
      completed_at: $updated,
      status: "completed",
      signal: $signal,
      files_changed: $files,
      commits: $commits,
      discovered_dependencies: [],
      duration_seconds: 0
    }' > "$STATUS_FILE"
}

write_failed() {
  local signal="$1"
  local error="$2"
  local retry_count="${3:-0}"

  jq -n \
    --arg task_id "$TASK_ID" \
    --arg agent "${SVAO_AGENT:-unknown}" \
    --arg started "${SVAO_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg signal "$signal" \
    --arg error "$error" \
    --argjson retry "$retry_count" \
    '{
      task_id: $task_id,
      agent: $agent,
      started_at: $started,
      failed_at: $updated,
      status: "failed",
      signal: $signal,
      error: $error,
      retry_count: $retry
    }' > "$STATUS_FILE"
}

# If called directly, handle arguments
case "${1:-}" in
  running) shift; write_status "running" "$@" ;;
  complete) shift; write_complete "$@" ;;
  failed) shift; write_failed "$@" ;;
  *) echo "Usage: status-writer.sh running|complete|failed [args...]" >&2; exit 1 ;;
esac
