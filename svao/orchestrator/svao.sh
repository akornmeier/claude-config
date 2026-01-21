#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO - Self-Validating Agent Orchestra (Phase 2: Parallel Dispatch)
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Resolve symlinks to find actual script location
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
SVAO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$SVAO_ROOT/agents/registry.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────
log() { echo -e "[$(date +%H:%M:%S)] $*"; }
log_info() { echo -e "[$(date +%H:%M:%S)] ${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "[$(date +%H:%M:%S)] ${GREEN}✅${NC} $*"; }
log_warn() { echo -e "[$(date +%H:%M:%S)] ${YELLOW}⚠️${NC} $*"; }
log_error() { echo -e "[$(date +%H:%M:%S)] ${RED}❌${NC} $*" >&2; }
log_agent() { echo -e "[$(date +%H:%M:%S)] ${BLUE}🤖${NC} $*"; }

# ─────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
SVAO - Self-Validating Agent Orchestra (Phase 2)

Usage: svao.sh <command> [options]

Commands:
  compile <change-id>        Compile OpenSpec to PRD
  dispatch <change-id>       Run parallel dispatch for a compiled PRD
  status <change-id>         Show execution status for a change
  checkpoint <type> <id>     Manually invoke a checkpoint
  pr <change-id> <section>   Create PR for a completed section
  run <agent-type> <task>    Run single agent with a task description
  list                       List available agents
  validate <file>            Run validators on a file
  test-hooks                 Test that hooks are working

Dispatch Options:
  --max-parallel N           Maximum concurrent agents (default: 3)
  --max-iterations N         Maximum iterations (default: 50)
  --resume                   Resume an interrupted session

Options:
  -h, --help                 Show this help message

Examples:
  svao.sh compile my-feature
  svao.sh dispatch my-feature
  svao.sh dispatch my-feature --max-parallel 5
  svao.sh status my-feature
  svao.sh run frontend-coder "Create a Button component"
EOF
  exit 0
}

# ─────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────

cmd_list() {
  log_info "Available agents:"
  echo ""

  jq -r '.agents | to_entries[] | select(.value.enabled == true) | "  \(.key): \(.value.definition)"' "$REGISTRY"

  echo ""
  log_info "Validators:"
  echo ""

  jq -r '.validators | to_entries[] | "  \(.key): \(.value)"' "$REGISTRY"
}

cmd_validate() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    exit 1
  fi

  log_info "Validating: $file"

  # Simulate hook input
  local input=$(jq -n --arg file "$file" '{tool_name: "Write", tool_input: {file_path: $file}}')

  # Run TDD guard
  log "Running TDD guard..."
  if echo "$input" | "$SVAO_ROOT/validators/tdd-guard.sh"; then
    log_success "TDD guard passed"
  else
    log_error "TDD guard failed"
    return 1
  fi
}

cmd_dispatch() {
  local change_id="$1"
  shift

  # Parse additional options
  local max_parallel=3
  local max_iterations=50
  local resume=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --max-parallel) max_parallel="$2"; shift 2 ;;
      --max-iterations) max_iterations="$2"; shift 2 ;;
      --resume) resume=true; shift ;;
      *) shift ;;
    esac
  done

  # Find change directory
  local change_dir=""
  for candidate in "openspec/changes/$change_id" ".claude/changes/$change_id"; do
    if [[ -d "$candidate" ]]; then
      change_dir="$candidate"
      break
    fi
  done

  if [[ -z "$change_dir" ]]; then
    log_error "Change not found: $change_id"
    exit 1
  fi

  local prd_file="$change_dir/prd.json"
  local state_file="$change_dir/prd-state.json"

  if [[ ! -f "$prd_file" ]]; then
    log_error "PRD not found: $prd_file"
    log_info "Run: svao.sh compile $change_id"
    exit 1
  fi

  if [[ ! -f "$state_file" ]]; then
    log_error "State file not found: $state_file"
    log_info "Run: svao.sh compile $change_id"
    exit 1
  fi

  # Auto-detect resume if session was running
  if [[ "$resume" == "false" ]]; then
    local session_status
    session_status=$(jq -r '.session.status' "$state_file")
    if [[ "$session_status" == "running" ]]; then
      log_warn "Detected interrupted session. Use --resume to continue."
      log_info "Or re-compile to start fresh: svao.sh compile $change_id"
      exit 1
    fi
  fi

  log_info "Running SVAO for: $change_id"
  log_info "PRD: $prd_file"
  log_info "Max parallel: $max_parallel"
  [[ "$resume" == "true" ]] && log_info "Mode: Resume"

  export MAX_PARALLEL="$max_parallel"
  export MAX_ITERATIONS="$max_iterations"
  export SVAO_RESUME="$resume"

  "$SCRIPT_DIR/dispatch.sh" "$prd_file" "$state_file" "$resume"
}

cmd_status() {
  local change_id="$1"

  local change_dir=""
  for candidate in "openspec/changes/$change_id" ".claude/changes/$change_id"; do
    if [[ -d "$candidate" ]]; then
      change_dir="$candidate"
      break
    fi
  done

  if [[ -z "$change_dir" ]]; then
    log_error "Change not found: $change_id"
    exit 1
  fi

  local state_file="$change_dir/prd-state.json"

  if [[ ! -f "$state_file" ]]; then
    log_error "No state file found. Run compile first."
    exit 1
  fi

  log_info "Status: $change_id"
  echo ""

  # Summary
  jq -r '
    "Progress: \(.summary.completed)/\(.summary.total_tasks) (\(.summary.progress_percent)%)\n" +
    "Ready: \(.summary.ready) | In Progress: \(.summary.in_progress) | Blocked: \(.summary.blocked)"
  ' "$state_file"

  echo ""

  # Queue details
  log_info "Ready tasks:"
  jq -r '.queue.ready[] | "  - \(.)"' "$state_file" 2>/dev/null || echo "  (none)"

  if [[ $(jq '.queue.in_progress | length' "$state_file") -gt 0 ]]; then
    echo ""
    log_info "In progress:"
    jq -r '.queue.in_progress[] | "  - \(.)"' "$state_file"
  fi

  if [[ $(jq '.queue.blocked | length' "$state_file") -gt 0 ]]; then
    echo ""
    log_warn "Blocked:"
    jq -r '.queue.blocked[] | "  - \(.)"' "$state_file"
  fi
}

cmd_run() {
  local agent_type="$1"
  local task="$2"

  # Check agent exists
  local agent_def=$(jq -r --arg type "$agent_type" '.agents[$type].definition // empty' "$REGISTRY")

  if [[ -z "$agent_def" ]]; then
    log_error "Unknown agent type: $agent_type"
    log_info "Available agents:"
    jq -r '.agents | keys[]' "$REGISTRY" | sed 's/^/  - /'
    exit 1
  fi

  # Check agent is enabled
  local enabled=$(jq -r --arg type "$agent_type" '.agents[$type].enabled' "$REGISTRY")
  if [[ "$enabled" != "true" ]]; then
    log_error "Agent '$agent_type' is disabled"
    exit 1
  fi

  log_agent "Dispatching $agent_type agent"
  log_info "Task: $task"
  log_info "Definition: $agent_def"
  echo ""

  # Read agent definition
  local agent_prompt=""
  if [[ -f "$agent_def" ]]; then
    # Extract markdown content (skip frontmatter)
    agent_prompt=$(awk '/^---$/{p=!p;next} !p' "$agent_def")
  else
    log_warn "Agent definition file not found, using default prompt"
    agent_prompt="You are a $agent_type agent. Complete the following task."
  fi

  # Build full prompt
  local full_prompt="$agent_prompt

---

## Current Task

$task

---

Remember to:
1. Follow TDD practices
2. Commit after completing the task
3. Report your status using TASK_COMPLETE or BLOCKED signals
"

  # Run Claude with the prompt
  log_agent "Starting agent session..."
  echo ""

  # Use claude CLI if available, otherwise show prompt
  if command -v claude &> /dev/null; then
    # Grant file operation permissions for non-interactive autonomous agent mode
    echo "$full_prompt" | claude --print --permission-mode bypassPermissions
  else
    log_warn "Claude CLI not found. Prompt that would be sent:"
    echo "─────────────────────────────────────────"
    echo "$full_prompt"
    echo "─────────────────────────────────────────"
  fi

  log_success "Agent session complete"
}

cmd_test_hooks() {
  log_info "Testing SVAO validators..."
  echo ""

  # Test TDD guard with exempt file
  log "Test 1: TDD guard with exempt file (should pass)"
  if echo '{"tool_name":"Write","tool_input":{"file_path":"src/types.ts"}}' | "$SVAO_ROOT/validators/tdd-guard.sh" > /dev/null 2>&1; then
    log_success "Passed"
  else
    log_error "Failed"
  fi

  # Test TDD guard with non-existent implementation (should fail)
  log "Test 2: TDD guard with implementation file (should fail without test)"
  if echo '{"tool_name":"Edit","tool_input":{"file_path":"src/components/NewThing.ts"}}' | "$SVAO_ROOT/validators/tdd-guard.sh" > /dev/null 2>&1; then
    log_error "Should have failed but passed"
  else
    log_success "Correctly blocked (exit code 2)"
  fi

  # Test spec format validator
  log "Test 3: Spec format validator"
  if command -v python3 &> /dev/null; then
    mkdir -p /tmp/svao-test/openspec/changes/test
    cat > /tmp/svao-test/openspec/changes/test/proposal.md << 'EOF'
# Test

## Problem
This is the problem we need to solve in this change.

## Solution
This is how we will solve the problem described above.

## Impact
This describes the impact and scope of the change.
EOF

    if echo '{"tool_input":{"file_path":"/tmp/svao-test/openspec/changes/test/proposal.md"}}' | python3 "$SVAO_ROOT/validators/spec-format.py" > /dev/null 2>&1; then
      log_success "Passed"
    else
      log_error "Failed"
    fi

    rm -rf /tmp/svao-test
  else
    log_warn "Python3 not found, skipping"
  fi

  echo ""
  log_success "Hook tests complete"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

[[ $# -eq 0 ]] && usage

case "${1:-}" in
  -h|--help) usage ;;
  compile)
    [[ $# -lt 2 ]] && log_error "Missing change-id" && exit 1
    shift
    "$SCRIPT_DIR/compile.sh" "$@"
    ;;
  dispatch)
    [[ $# -lt 2 ]] && log_error "Missing change-id" && exit 1
    shift
    cmd_dispatch "$@"
    ;;
  status)
    [[ $# -lt 2 ]] && log_error "Missing change-id" && exit 1
    cmd_status "$2"
    ;;
  checkpoint)
    shift
    checkpoint_type="${1:-}"
    change_id="${2:-}"

    if [[ -z "$checkpoint_type" || -z "$change_id" ]]; then
        echo "Usage: svao.sh checkpoint <type> <change-id> [options]"
        echo ""
        echo "Types: queue-planning, completion-review, blocker-resolution"
        echo ""
        echo "Options:"
        echo "  --dry-run         Show prompt without invoking Claude"
        echo "  --section <n>     Section number (completion-review)"
        echo "  --task <id>       Task ID (blocker-resolution)"
        exit 1
    fi

    shift 2
    # Use the checkpoint invoker
    invoker="$HOME/.claude/svao/orchestrator/checkpoints/invoke.sh"
    if [[ ! -f "$invoker" ]]; then
        invoker="$SCRIPT_DIR/checkpoints/invoke.sh"
    fi

    if [[ ! -f "$invoker" ]]; then
        echo "Error: Checkpoint invoker not found" >&2
        exit 1
    fi

    exec "$invoker" "$checkpoint_type" "$change_id" "$@"
    ;;
  list) cmd_list ;;
  validate)
    [[ $# -lt 2 ]] && log_error "Missing file argument" && exit 1
    cmd_validate "$2"
    ;;
  run)
    [[ $# -lt 3 ]] && log_error "Missing agent type or task" && exit 1
    cmd_run "$2" "$3"
    ;;
  pr)
    [[ $# -lt 3 ]] && log_error "Usage: svao.sh pr <change-id> <section-num>" && exit 1
    change_id="$2"
    section_num="$3"

    # Find change directory
    change_dir=""
    for candidate in "openspec/changes/$change_id" ".claude/changes/$change_id"; do
      if [[ -d "$candidate" ]]; then
        change_dir="$candidate"
        break
      fi
    done

    if [[ -z "$change_dir" ]]; then
      log_error "Change not found: $change_id"
      exit 1
    fi

    # Check pr-creator exists
    if [[ ! -f "$SCRIPT_DIR/pr-creator.sh" ]]; then
      log_error "PR creator not found: $SCRIPT_DIR/pr-creator.sh"
      exit 1
    fi

    prd_file="$change_dir/prd.json"
    state_file="$change_dir/prd-state.json"

    if [[ ! -f "$prd_file" ]]; then
      log_error "PRD not found: $prd_file"
      log_info "Run: svao.sh compile $change_id"
      exit 1
    fi

    if [[ ! -f "$state_file" ]]; then
      log_error "State file not found: $state_file"
      log_info "Run: svao.sh compile $change_id"
      exit 1
    fi

    "$SCRIPT_DIR/pr-creator.sh" create "$prd_file" "$state_file" "$section_num"
    ;;
  test-hooks) cmd_test_hooks ;;
  *)
    log_error "Unknown command: $1"
    usage
    ;;
esac
