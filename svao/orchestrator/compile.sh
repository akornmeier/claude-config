#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO PRD Compiler
# Compiles OpenSpec (proposal.md, tasks.md) into prd.json
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVAO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "$*"; }
log_info() { echo -e "${BLUE}i${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}!${NC} $*"; }
log_error() { echo -e "${RED}x${NC} $*" >&2; }

usage() {
  cat <<EOF
SVAO PRD Compiler

Usage: compile.sh <change-id> [options]

Options:
  --dry-run         Show what would be generated without writing
  --skip-inference  Don't infer dependencies, only use explicit
  --strict          Fail on any validation warning
  -h, --help        Show this help

Examples:
  compile.sh add-user-collections
  compile.sh add-user-collections --dry-run
EOF
  exit 0
}

# Parse arguments
CHANGE_ID=""
DRY_RUN=false
SKIP_INFERENCE=false
STRICT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-inference) SKIP_INFERENCE=true; shift ;;
    --strict) STRICT=true; shift ;;
    -*) log_error "Unknown option: $1"; exit 1 ;;
    *) CHANGE_ID="$1"; shift ;;
  esac
done

[[ -z "$CHANGE_ID" ]] && log_error "Missing change-id" && usage

# Find change directory
CHANGE_DIR=""
for candidate in "openspec/changes/$CHANGE_ID" ".claude/changes/$CHANGE_ID" "changes/$CHANGE_ID"; do
  if [[ -d "$candidate" ]]; then
    CHANGE_DIR="$candidate"
    break
  fi
done

if [[ -z "$CHANGE_DIR" ]]; then
  log_error "Change directory not found for: $CHANGE_ID"
  log_info "Looked in: openspec/changes/, .claude/changes/, changes/"
  exit 1
fi

TASKS_FILE="$CHANGE_DIR/tasks.md"
PROPOSAL_FILE="$CHANGE_DIR/proposal.md"
DESIGN_FILE="$CHANGE_DIR/design.md"
PRD_FILE="$CHANGE_DIR/prd.json"
STATE_FILE="$CHANGE_DIR/prd-state.json"

# Validate required files
if [[ ! -f "$TASKS_FILE" ]]; then
  log_error "Required file not found: $TASKS_FILE"
  exit 1
fi

log_info "Compiling: $CHANGE_ID"
log_info "Source: $CHANGE_DIR"

# Parse tasks.md
log "Parsing tasks.md..."
PARSED_OUTPUT=$(python3 "$SCRIPT_DIR/parser.py" "$TASKS_FILE" 2>&1) || {
  log_error "Failed to parse tasks.md"
  echo "$PARSED_OUTPUT" >&2
  exit 2
}

# Extract just the JSON (skip status messages)
PARSED_JSON=$(echo "$PARSED_OUTPUT" | sed -n '/^{$/,/^}$/p')

SECTION_COUNT=$(echo "$PARSED_JSON" | jq '.sections | length')
TASK_COUNT=$(echo "$PARSED_JSON" | jq '[.sections[].tasks[]] | length')
log_success "Parsed $SECTION_COUNT sections, $TASK_COUNT tasks"

# Infer dependencies
INFERRED_JSON='{"auto_apply":[],"pending_review":[]}'
if [[ "$SKIP_INFERENCE" != true ]]; then
  log "Inferring dependencies..."
  INFERRED_OUTPUT=$(echo "$PARSED_JSON" | python3 "$SCRIPT_DIR/inference.py" 2>&1) || {
    log_warn "Dependency inference failed, continuing without"
    INFERRED_JSON='{"auto_apply":[],"pending_review":[]}'
  }
  INFERRED_JSON=$(echo "$INFERRED_OUTPUT" | sed -n '/^{$/,/^}$/p')

  AUTO_COUNT=$(echo "$INFERRED_JSON" | jq '.auto_apply | length')
  REVIEW_COUNT=$(echo "$INFERRED_JSON" | jq '.pending_review | length')
  log_success "Inferred $AUTO_COUNT high-confidence, $REVIEW_COUNT need review"

  if [[ "$STRICT" == true && "$REVIEW_COUNT" -gt 0 ]]; then
    log_error "Strict mode: $REVIEW_COUNT dependencies need review"
    echo "$INFERRED_JSON" | jq '.pending_review[]'
    exit 2
  fi
fi

# Extract context from proposal.md
CONTEXT_SUMMARY=""
if [[ -f "$PROPOSAL_FILE" ]]; then
  # Extract first paragraph after # heading (portable awk)
  CONTEXT_SUMMARY=$(awk '/^# /{found=1;next} /^## /{exit} found{print}' "$PROPOSAL_FILE" | head -5 | tr '\n' ' ' | xargs)
  log_success "Extracted context from proposal.md"
fi

# Calculate source hash
SOURCE_HASH="sha256:$(shasum -a 256 "$TASKS_FILE" | cut -d' ' -f1)"

# Build PRD JSON
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PRD_JSON=$(jq -n \
  --arg version "1.0.0" \
  --arg change_id "$CHANGE_ID" \
  --arg compiled_at "$TIMESTAMP" \
  --arg source_hash "$SOURCE_HASH" \
  --arg summary "$CONTEXT_SUMMARY" \
  --arg proposal_file "$(basename "$PROPOSAL_FILE")" \
  --arg design_file "$(basename "$DESIGN_FILE")" \
  --argjson sections "$(echo "$PARSED_JSON" | jq '.sections')" \
  --argjson inferred "$(echo "$INFERRED_JSON" | jq '.auto_apply')" \
  --argjson pending "$(echo "$INFERRED_JSON" | jq '.pending_review')" \
  --argjson section_count "$SECTION_COUNT" \
  --argjson task_count "$TASK_COUNT" \
  '{
    "$schema": "../../../.claude/svao/schemas/prd.schema.json",
    "version": $version,
    "change_id": $change_id,
    "compiled_at": $compiled_at,
    "source_hash": $source_hash,
    "context": {
      "summary": $summary,
      "proposal_file": $proposal_file,
      "design_file": $design_file
    },
    "success_criteria": {
      "tests_pass": "pnpm test",
      "lint_clean": "pnpm lint",
      "type_check": "pnpm type-check"
    },
    "sections": $sections,
    "dependencies": {
      "explicit": [],
      "inferred": $inferred,
      "pending_review": $pending
    },
    "summary": {
      "total_sections": $section_count,
      "total_tasks": $task_count,
      "explicit_dependencies": 0,
      "inferred_dependencies": ($inferred | length),
      "pending_review": ($pending | length)
    }
  }')

# Add explicit dependencies from parsed tasks
PRD_JSON=$(echo "$PRD_JSON" | jq '
  .dependencies.explicit = [
    .sections[].tasks[] |
    select(.depends_on | length > 0) |
    .depends_on[] as $dep |
    {from: .id, to: $dep}
  ] |
  .summary.explicit_dependencies = (.dependencies.explicit | length)
')

# Apply inferred dependencies to task depends_on arrays
PRD_JSON=$(echo "$PRD_JSON" | jq '
  # Build a map of task_id -> [dependency_ids]
  (.dependencies.inferred | group_by(.from) | map({key: .[0].from, value: [.[].to]}) | from_entries) as $inferred_map |
  # Update each task with its inferred dependencies
  .sections |= map(
    .tasks |= map(
      . as $task |
      .depends_on = ((.depends_on // []) + ($inferred_map[$task.id] // []) | unique)
    )
  )
')

# Build blocks relationships (reverse of depends_on)
PRD_JSON=$(echo "$PRD_JSON" | jq '
  # Collect all task IDs and their depends_on arrays
  [.sections[].tasks[] | {id: .id, depends_on: (.depends_on // [])}] as $all_tasks |
  .sections |= map(
    .tasks |= map(
      . as $current |
      .blocks = [
        $all_tasks[] |
        select(.depends_on | index($current.id)) |
        .id
      ]
    )
  )
')

if [[ "$DRY_RUN" == true ]]; then
  # Calculate queue counts for dry-run display (excluding pre-completed tasks)
  COMPLETED_COUNT=$(echo "$PRD_JSON" | jq '[.sections[].tasks[] | select(.completed == true)] | length')
  READY_COUNT=$(echo "$PRD_JSON" | jq '[.sections[].tasks[] | select(.completed != true and (.depends_on | length) == 0)] | length')
  BLOCKED_COUNT=$(echo "$PRD_JSON" | jq '[.sections[].tasks[] | select(.completed != true and (.depends_on | length) > 0)] | length')
  PENDING_COUNT=$(echo "$INFERRED_JSON" | jq '.pending_review | length')
  REMAINING=$((TASK_COUNT - COMPLETED_COUNT))
  if (( TASK_COUNT > 0 )); then
    PROGRESS_PERCENT=$((COMPLETED_COUNT * 100 / TASK_COUNT))
  else
    PROGRESS_PERCENT=0
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Dry run - compilation preview"
  echo ""
  echo "  Progress:     $PROGRESS_PERCENT% ($COMPLETED_COUNT/$TASK_COUNT completed)"
  echo "  Ready:        $READY_COUNT (can execute immediately)"
  echo "  Blocked:      $BLOCKED_COUNT (waiting on dependencies)"
  echo "  Dependencies: $AUTO_COUNT applied automatically"
  echo ""
  echo "  Would write:"
  echo "    - $PRD_FILE"
  echo "    - $STATE_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Show first few ready tasks (incomplete only)
  echo ""
  log_info "First tasks ready to execute:"
  echo "$PRD_JSON" | jq -r '
    [.sections[].tasks[] | select(.completed != true and (.depends_on | length) == 0)] |
    .[0:5][] |
    "  \(.id): \(.description)"'

  if [[ $READY_COUNT -gt 5 ]]; then
    echo "  ... and $((READY_COUNT - 5)) more"
  fi

  if [[ "$PENDING_COUNT" -gt 0 ]]; then
    echo ""
    log_info "$PENDING_COUNT low-confidence dependencies available for optional review"
  fi

  echo ""
  log_info "Run without --dry-run to compile"
  exit 0
fi

# Write PRD file
echo "$PRD_JSON" > "$PRD_FILE"
log_success "Written: $PRD_FILE"

# Calculate PRD hash AFTER writing (dispatch.sh verifies prd.json, not tasks.md)
PRD_HASH="sha256:$(shasum -a 256 "$PRD_FILE" | cut -d' ' -f1)"

# Initialize state file
STATE_JSON=$(jq -n \
  --arg version "1.0.0" \
  --arg change_id "$CHANGE_ID" \
  --arg prd_file "prd.json" \
  --arg prd_hash "$PRD_HASH" \
  --arg session_id "svao-$(date +%Y%m%d-%H%M%S)" \
  --arg started_at "$TIMESTAMP" \
  '{
    "$schema": "../../../.claude/svao/schemas/prd-state.schema.json",
    "version": $version,
    "change_id": $change_id,
    "prd_file": $prd_file,
    "prd_hash": $prd_hash,
    "session": {
      "id": $session_id,
      "started_at": $started_at,
      "updated_at": $started_at,
      "iteration": 0,
      "status": "pending"
    },
    "tasks": {},
    "queue": {
      "ready": [],
      "in_progress": [],
      "blocked": [],
      "completed": []
    },
    "discovered_dependencies": [],
    "checkpoints": {
      "last_queue_planning": null,
      "last_iteration_at_checkpoint": 0,
      "history": []
    },
    "metrics": {
      "tasks_completed": 0,
      "tasks_failed": 0,
      "total_retries": 0,
      "agents_used": {},
      "avg_task_duration_seconds": 0,
      "parallel_utilization": 0
    },
    "summary": {
      "total_tasks": 0,
      "completed": 0,
      "in_progress": 0,
      "blocked": 0,
      "ready": 0,
      "pending": 0,
      "progress_percent": 0
    }
  }')

# Initialize task states from PRD (respecting pre-completed tasks from tasks.md)
STATE_JSON=$(echo "$STATE_JSON" | jq --argjson prd "$PRD_JSON" '
  reduce ($prd.sections[].tasks[]) as $task (.;
    .tasks[$task.id] = {
      "status": (if $task.completed then "completed" else "pending" end),
      "retries": 0
    }
  )
')

# Build initial queue (excluding pre-completed tasks from tasks.md)
STATE_JSON=$(echo "$STATE_JSON" | jq --argjson prd "$PRD_JSON" '
  # Pre-completed tasks go to completed queue
  .queue.completed = [
    $prd.sections[].tasks[] |
    select(.completed == true) |
    .id
  ] |
  # Incomplete tasks with no dependencies are ready
  .queue.ready = [
    $prd.sections[].tasks[] |
    select(.completed != true and (.depends_on | length) == 0) |
    .id
  ] |
  # Incomplete tasks with dependencies are blocked
  .queue.blocked = [
    $prd.sections[].tasks[] |
    select(.completed != true and (.depends_on | length) > 0) |
    .id
  ] |
  # Update summary
  .summary.total_tasks = ($prd.summary.total_tasks) |
  .summary.completed = (.queue.completed | length) |
  .summary.ready = (.queue.ready | length) |
  .summary.blocked = (.queue.blocked | length) |
  .summary.pending = (.summary.total_tasks - .summary.ready - .summary.blocked - .summary.completed) |
  .summary.progress_percent = (if .summary.total_tasks > 0 then (.summary.completed * 100 / .summary.total_tasks | floor) else 0 end)
')

echo "$STATE_JSON" > "$STATE_FILE"
log_success "Initialized: $STATE_FILE"

# Summary
COMPLETED_COUNT=$(echo "$STATE_JSON" | jq '.queue.completed | length')
READY_COUNT=$(echo "$STATE_JSON" | jq '.queue.ready | length')
BLOCKED_COUNT=$(echo "$STATE_JSON" | jq '.queue.blocked | length')
PENDING_COUNT=$(echo "$INFERRED_JSON" | jq '.pending_review | length')
REMAINING=$((TASK_COUNT - COMPLETED_COUNT))
PROGRESS_PERCENT=$(echo "$STATE_JSON" | jq '.summary.progress_percent')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Compilation complete!"
echo ""
echo "  Progress:     $PROGRESS_PERCENT% ($COMPLETED_COUNT/$TASK_COUNT completed)"
echo "  Ready:        $READY_COUNT (can execute now)"
echo "  Blocked:      $BLOCKED_COUNT (waiting on dependencies)"
echo "  Dependencies: $AUTO_COUNT applied automatically"
echo ""
echo "  PRD:   $PRD_FILE"
echo "  State: $STATE_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_success "Ready to execute!"
log_info "Run: svao.sh dispatch $CHANGE_ID"

if [[ "$PENDING_COUNT" -gt 0 ]]; then
  echo ""
  log_info "Optional: $PENDING_COUNT low-confidence dependencies available for review"
  log_info "Run: svao.sh deps review $CHANGE_ID"
fi
