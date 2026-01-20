#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO - Self-Validating Agent Orchestra (Phase 1: Single Agent)
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
SVAO - Self-Validating Agent Orchestra (Phase 1)

Usage: svao.sh <command> [options]

Commands:
  run <agent-type> <task>    Run an agent with a task description
  list                       List available agents
  validate <file>            Run validators on a file
  test-hooks                 Test that hooks are working

Options:
  -h, --help                 Show this help message

Examples:
  svao.sh list
  svao.sh run frontend-coder "Create a Button component with hover states"
  svao.sh validate src/components/Button.ts
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
    echo "$full_prompt" | claude --print
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
  list) cmd_list ;;
  validate)
    [[ $# -lt 2 ]] && log_error "Missing file argument" && exit 1
    cmd_validate "$2"
    ;;
  run)
    [[ $# -lt 3 ]] && log_error "Missing agent type or task" && exit 1
    cmd_run "$2" "$3"
    ;;
  test-hooks) cmd_test_hooks ;;
  *)
    log_error "Unknown command: $1"
    usage
    ;;
esac
