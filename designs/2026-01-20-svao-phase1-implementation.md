# SVAO Phase 1: Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the foundation of SVAO: validators, agent definitions, registry, and single-agent orchestrator.

**Architecture:** Standalone shell/Python validators in `.claude/validators/`, agent definitions in `.claude/agents/`, and a shell orchestrator that dispatches one agent at a time with full hook validation.

**Tech Stack:** Bash, Python 3, jq, Claude Code hooks

---

## Task 1: Create Directory Structure

**Files:**
- Create: `.claude/svao/validators/`
- Create: `.claude/svao/agents/`
- Create: `.claude/svao/orchestrator/`
- Create: `.claude/svao/schemas/`

**Step 1: Create the directory structure**

```bash
mkdir -p .claude/svao/{validators,agents,orchestrator/checkpoints,schemas}
```

**Step 2: Verify structure**

Run: `ls -la .claude/svao/`
Expected: Four directories listed

**Step 3: Commit**

```bash
git add .claude/svao
git commit -m "chore(svao): create directory structure for Phase 1"
```

---

## Task 2: TDD Guard Validator

**Files:**
- Create: `.claude/svao/validators/tdd-guard.sh`
- Test: Manual test with echo piped to stdin

**Step 1: Write the validator script**

```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────
# TDD Guard - Blocks edits to implementation files without tests
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Read tool input from stdin (Claude Code hook format)
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check Edit/Write operations
[[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]] && exit 0

# Skip if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# ─────────────────────────────────────────────────────────────
# Files that DON'T need tests (config, types, etc.)
# ─────────────────────────────────────────────────────────────
is_exempt() {
  local file="$1"
  case "$file" in
    *.test.ts|*.spec.ts|*.test.tsx|*.spec.tsx) return 0 ;;
    *.test.js|*.spec.js|*.test.jsx|*.spec.jsx) return 0 ;;
    *.d.ts) return 0 ;;
    */types/*|*/types.ts|*/@types/*) return 0 ;;
    *.config.*|*.config) return 0 ;;
    *.json|*.md|*.css|*.scss|*.yaml|*.yml) return 0 ;;
    */__mocks__/*|*/fixtures/*|*/__fixtures__/*) return 0 ;;
    */.claude/*|*/openspec/*) return 0 ;;
    *.sh|*.py) return 0 ;;  # Scripts don't need tests
    */index.ts|*/index.js) return 0 ;;  # Re-export files
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Check if this is an implementation file that needs tests
# ─────────────────────────────────────────────────────────────
needs_tests() {
  local file="$1"
  case "$file" in
    */src/*.ts|*/src/*.tsx|*/src/*.js|*/src/*.jsx) return 0 ;;
    */components/*.vue|*/components/*.ts|*/components/*.tsx) return 0 ;;
    */composables/*.ts|*/hooks/*.ts) return 0 ;;
    */lib/*.ts|*/utils/*.ts|*/services/*.ts) return 0 ;;
    */packages/*/src/*) return 0 ;;
    */apps/*/src/*|*/apps/*/components/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Find corresponding test file
# ─────────────────────────────────────────────────────────────
find_test_file() {
  local impl_file="$1"
  local dir=$(dirname "$impl_file")
  local base=$(basename "$impl_file")
  local name="${base%.*}"
  local ext="${base##*.}"

  # Common test file locations
  local candidates=(
    "${dir}/${name}.test.${ext}"
    "${dir}/${name}.spec.${ext}"
    "${dir}/${name}.test.ts"
    "${dir}/${name}.spec.ts"
    "${dir}/__tests__/${name}.test.${ext}"
    "${dir}/__tests__/${name}.spec.${ext}"
    "${dir}/test/${name}.test.${ext}"
  )

  # Also check parallel test directory structure
  local test_dir="${dir/\/src\//\/test\/}"
  candidates+=(
    "${test_dir}/${name}.test.${ext}"
    "${test_dir}/${name}.spec.${ext}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# ─────────────────────────────────────────────────────────────
# Check that test file has actual test cases
# ─────────────────────────────────────────────────────────────
has_test_cases() {
  local test_file="$1"

  # Look for common test patterns
  if grep -qE '(describe|it|test)\s*\(' "$test_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

# ─────────────────────────────────────────────────────────────
# Main logic
# ─────────────────────────────────────────────────────────────

# Check if exempt
if is_exempt "$FILE_PATH"; then
  exit 0
fi

# Check if this file needs tests
if ! needs_tests "$FILE_PATH"; then
  exit 0
fi

# Find corresponding test file
TEST_FILE=$(find_test_file "$FILE_PATH") || true

if [[ -z "$TEST_FILE" ]]; then
  echo "❌ TDD Guard: No test file found for $FILE_PATH" >&2
  echo "" >&2
  echo "Expected test file at one of:" >&2
  echo "  - $(dirname "$FILE_PATH")/$(basename "${FILE_PATH%.*}").test.ts" >&2
  echo "  - $(dirname "$FILE_PATH")/$(basename "${FILE_PATH%.*}").spec.ts" >&2
  echo "" >&2
  echo "Write the test first, then implement." >&2
  exit 2
fi

if ! has_test_cases "$TEST_FILE"; then
  echo "❌ TDD Guard: Test file exists but has no test cases" >&2
  echo "   File: $TEST_FILE" >&2
  echo "" >&2
  echo "Add at least one test case (describe/it/test) before editing implementation." >&2
  exit 2
fi

# All checks passed
echo "✅ TDD Guard: Test file found at $TEST_FILE"
exit 0
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/validators/tdd-guard.sh
```

**Step 3: Test with exempt file (should pass)**

Run:
```bash
echo '{"tool_name":"Write","tool_input":{"file_path":"src/types.ts"}}' | .claude/svao/validators/tdd-guard.sh
echo "Exit code: $?"
```
Expected: Exit code 0

**Step 4: Test with implementation file without test (should fail)**

Run:
```bash
echo '{"tool_name":"Edit","tool_input":{"file_path":"src/components/Button.ts"}}' | .claude/svao/validators/tdd-guard.sh
echo "Exit code: $?"
```
Expected: Exit code 2, error message about missing test file

**Step 5: Commit**

```bash
git add .claude/svao/validators/tdd-guard.sh
git commit -m "feat(svao): add TDD guard validator"
```

---

## Task 3: Test Suite Validator

**Files:**
- Create: `.claude/svao/validators/test-suite.sh`

**Step 1: Write the validator script**

```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Test Suite Validator - Runs tests for modified packages
# Used as Stop hook to validate agent completed work correctly
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Allow overriding test command
TEST_CMD="${TEST_CMD:-pnpm test}"

# Get project root (git root or current dir)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

echo "🧪 Running test suite validation..."

# Check if this is a monorepo with packages
if [[ -d "packages" ]] || [[ -d "apps" ]]; then
  # Monorepo: Find modified packages from git
  MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only HEAD 2>/dev/null || echo "")

  if [[ -z "$MODIFIED_FILES" ]]; then
    echo "✅ No modified files detected, skipping tests"
    exit 0
  fi

  # Extract unique package paths
  PACKAGES=$(echo "$MODIFIED_FILES" | grep -E "^(packages|apps)/" | cut -d'/' -f1-2 | sort -u || echo "")

  if [[ -z "$PACKAGES" ]]; then
    echo "✅ No package changes detected, skipping tests"
    exit 0
  fi

  echo "📦 Modified packages:"
  echo "$PACKAGES" | sed 's/^/  - /'
  echo ""

  FAILED=0
  for pkg_path in $PACKAGES; do
    if [[ ! -f "$pkg_path/package.json" ]]; then
      continue
    fi

    pkg_name=$(jq -r '.name // empty' "$pkg_path/package.json" 2>/dev/null || echo "")
    if [[ -z "$pkg_name" ]]; then
      continue
    fi

    echo "🧪 Testing $pkg_name..."

    if pnpm --filter "$pkg_name" test 2>&1; then
      echo "✅ $pkg_name tests passed"
    else
      echo "❌ $pkg_name tests failed" >&2
      FAILED=1
    fi
    echo ""
  done

  if [[ $FAILED -eq 1 ]]; then
    echo "❌ Test suite failed - some packages have failing tests" >&2
    exit 2
  fi
else
  # Single package: Run tests directly
  echo "🧪 Running $TEST_CMD..."

  if $TEST_CMD 2>&1; then
    echo "✅ All tests passed"
  else
    echo "❌ Tests failed" >&2
    exit 2
  fi
fi

echo "✅ Test suite validation complete"
exit 0
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/validators/test-suite.sh
```

**Step 3: Test in current directory**

Run:
```bash
.claude/svao/validators/test-suite.sh
echo "Exit code: $?"
```
Expected: Exit code 0 (or 2 if tests fail)

**Step 4: Commit**

```bash
git add .claude/svao/validators/test-suite.sh
git commit -m "feat(svao): add test suite validator"
```

---

## Task 4: Coverage Check Validator

**Files:**
- Create: `.claude/svao/validators/coverage-check.sh`

**Step 1: Write the validator script**

```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Coverage Check Validator
# Ensures minimum test coverage threshold is met
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Configuration
MINIMUM_COVERAGE="${MINIMUM_COVERAGE:-80}"
COVERAGE_CMD="${COVERAGE_CMD:-pnpm test:coverage}"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

echo "📊 Running coverage check (minimum: ${MINIMUM_COVERAGE}%)..."

# Check if coverage command exists
if ! command -v pnpm &> /dev/null && [[ "$COVERAGE_CMD" == pnpm* ]]; then
  echo "⚠️  pnpm not found, skipping coverage check"
  exit 0
fi

# Run coverage
if ! $COVERAGE_CMD --reporter=json 2>/dev/null; then
  echo "⚠️  Coverage command failed or not configured, skipping check"
  exit 0
fi

# Find coverage report
COVERAGE_FILE=""
for candidate in "coverage/coverage-summary.json" "coverage-summary.json" ".coverage/coverage-summary.json"; do
  if [[ -f "$candidate" ]]; then
    COVERAGE_FILE="$candidate"
    break
  fi
done

if [[ -z "$COVERAGE_FILE" ]]; then
  echo "⚠️  No coverage report found, skipping check"
  exit 0
fi

# Extract coverage percentages
LINE_COVERAGE=$(jq -r '.total.lines.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")
BRANCH_COVERAGE=$(jq -r '.total.branches.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")
FUNC_COVERAGE=$(jq -r '.total.functions.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")

echo "  Line coverage:     ${LINE_COVERAGE}%"
echo "  Branch coverage:   ${BRANCH_COVERAGE}%"
echo "  Function coverage: ${FUNC_COVERAGE}%"

# Check against threshold (using line coverage as primary metric)
if (( $(echo "$LINE_COVERAGE < $MINIMUM_COVERAGE" | bc -l) )); then
  echo "" >&2
  echo "❌ Line coverage ${LINE_COVERAGE}% is below minimum ${MINIMUM_COVERAGE}%" >&2
  echo "   Add more tests to increase coverage." >&2
  exit 2
fi

echo "✅ Coverage check passed"
exit 0
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/validators/coverage-check.sh
```

**Step 3: Commit**

```bash
git add .claude/svao/validators/coverage-check.sh
git commit -m "feat(svao): add coverage check validator"
```

---

## Task 5: Spec Format Validator (Python)

**Files:**
- Create: `.claude/svao/validators/spec-format.py`

**Step 1: Write the validator script**

```python
#!/usr/bin/env python3
"""
Spec Format Validator
Ensures OpenSpec documents follow required structure.
Exit 0: pass, Exit 2: block
"""

import json
import sys
import re
from pathlib import Path


def validate_proposal(content: str) -> list[str]:
    """Validate proposal.md structure."""
    errors = []

    required_sections = ["## Problem", "## Solution", "## Impact"]

    for section in required_sections:
        if section not in content:
            errors.append(f"Missing required section: {section.replace('## ', '')}")

    # Check for empty sections
    sections = re.split(r"^## ", content, flags=re.MULTILINE)
    for section in sections[1:]:  # Skip content before first ##
        lines = section.strip().split("\n")
        if lines:
            header = lines[0].strip()
            body = "\n".join(lines[1:]).strip()

            if len(body) < 20:
                errors.append(f"Section '{header}' is too short (< 20 chars)")

    return errors


def validate_tasks(content: str) -> list[str]:
    """Validate tasks.md structure."""
    errors = []

    # Must have numbered sections
    if not re.search(r"^## \d+\.", content, re.MULTILINE):
        errors.append("No numbered sections found (expected '## 1. Section Name')")
        return errors

    # Each section should have task items
    sections = re.split(r"^## \d+\.", content, flags=re.MULTILINE)
    for i, section in enumerate(sections[1:], 1):
        if not re.search(r"^- \[[ x]\]", section, re.MULTILINE):
            section_name = section.split("\n")[0].strip() if section.strip() else f"Section {i}"
            errors.append(f"Section '{section_name}' has no task checkboxes")

    return errors


def validate_design(content: str) -> list[str]:
    """Validate design.md structure (advisory only)."""
    warnings = []

    recommended = ["architecture", "component", "data"]
    content_lower = content.lower()

    for term in recommended:
        if term not in content_lower:
            warnings.append(f"Consider discussing: {term}")

    return warnings


def main():
    # Read hook input from stdin
    try:
        input_data = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        # If not JSON, might be direct file path for testing
        sys.exit(0)

    file_path = input_data.get("tool_input", {}).get("file_path", "")

    if not file_path:
        sys.exit(0)

    path = Path(file_path)

    # Only validate openspec files
    if "openspec" not in str(path):
        sys.exit(0)

    if not path.exists():
        sys.exit(0)

    content = path.read_text()
    errors = []

    # Route to appropriate validator
    if path.name == "proposal.md":
        errors = validate_proposal(content)
    elif path.name == "tasks.md":
        errors = validate_tasks(content)
    elif path.name == "design.md":
        # Design validation is advisory, don't block
        warnings = validate_design(content)
        if warnings:
            print(f"💡 Suggestions for {path.name}:")
            for warning in warnings:
                print(f"   - {warning}")
        sys.exit(0)

    if errors:
        print(f"❌ Spec format issues in {path.name}:", file=sys.stderr)
        for error in errors:
            print(f"   - {error}", file=sys.stderr)
        sys.exit(2)

    print(f"✅ {path.name} format valid")
    sys.exit(0)


if __name__ == "__main__":
    main()
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/validators/spec-format.py
```

**Step 3: Test with valid proposal**

Create a temporary test file and run:
```bash
mkdir -p /tmp/openspec/changes/test
cat > /tmp/openspec/changes/test/proposal.md << 'EOF'
# Test Proposal

## Problem
This is the problem description that needs to be solved.

## Solution
This is the proposed solution to the problem.

## Impact
This describes the impact of the change.
EOF

echo '{"tool_input":{"file_path":"/tmp/openspec/changes/test/proposal.md"}}' | python3 .claude/svao/validators/spec-format.py
echo "Exit code: $?"
```
Expected: Exit code 0

**Step 4: Commit**

```bash
git add .claude/svao/validators/spec-format.py
git commit -m "feat(svao): add spec format validator"
```

---

## Task 6: Agent Registry Schema

**Files:**
- Create: `.claude/svao/schemas/registry.schema.json`

**Step 1: Write the JSON schema**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://svao.local/registry.schema.json",
  "title": "SVAO Agent Registry",
  "description": "Schema for the SVAO agent registry configuration",
  "type": "object",
  "required": ["version", "agents", "orchestrator"],
  "properties": {
    "version": {
      "type": "string",
      "pattern": "^\\d+\\.\\d+\\.\\d+$"
    },
    "agents": {
      "type": "object",
      "additionalProperties": {
        "$ref": "#/$defs/agentEntry"
      }
    },
    "orchestrator": {
      "type": "object",
      "required": ["max_parallel_agents", "checkpoint_interval"],
      "properties": {
        "max_parallel_agents": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10
        },
        "checkpoint_interval": {
          "type": "integer",
          "minimum": 1
        },
        "metrics_file": {
          "type": "string"
        },
        "progress_file": {
          "type": "string"
        },
        "default_stop_signals": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "validators": {
      "type": "object",
      "additionalProperties": { "type": "string" }
    }
  },
  "$defs": {
    "agentEntry": {
      "type": "object",
      "required": ["definition", "enabled"],
      "properties": {
        "definition": {
          "type": "string",
          "description": "Path to agent definition file"
        },
        "enabled": {
          "type": "boolean"
        },
        "isolation_default": {
          "type": "string",
          "enum": ["task", "worktree"]
        },
        "isolation_threshold": {
          "type": "object",
          "properties": {
            "complexity": {
              "type": "string",
              "enum": ["low", "medium", "high"]
            },
            "upgrade_to": {
              "type": "string",
              "enum": ["task", "worktree"]
            }
          }
        },
        "description": {
          "type": "string"
        }
      }
    }
  }
}
```

**Step 2: Commit**

```bash
git add .claude/svao/schemas/registry.schema.json
git commit -m "feat(svao): add registry JSON schema"
```

---

## Task 7: Initial Agent Registry

**Files:**
- Create: `.claude/svao/agents/registry.json`
- Create: `.claude/svao/agents/metrics.json`

**Step 1: Write the registry file**

```json
{
  "$schema": "../schemas/registry.schema.json",
  "version": "1.0.0",
  "agents": {
    "frontend-coder": {
      "definition": ".claude/svao/agents/frontend-coder.md",
      "enabled": true,
      "isolation_default": "task",
      "isolation_threshold": {
        "complexity": "high",
        "upgrade_to": "worktree"
      }
    },
    "api-builder": {
      "definition": ".claude/svao/agents/api-builder.md",
      "enabled": true,
      "isolation_default": "task"
    },
    "test-writer": {
      "definition": ".claude/svao/agents/test-writer.md",
      "enabled": true,
      "isolation_default": "task"
    }
  },
  "orchestrator": {
    "max_parallel_agents": 3,
    "checkpoint_interval": 5,
    "metrics_file": ".claude/svao/agents/metrics.json",
    "progress_file": "progress.md",
    "default_stop_signals": [
      "TASK_COMPLETE",
      "SECTION_COMPLETE",
      "ALL_TASKS_COMPLETE",
      "BLOCKED:TESTS",
      "BLOCKED:CLARIFICATION",
      "BLOCKED:DEPENDENCY",
      "DISCOVERED_DEPENDENCY"
    ]
  },
  "validators": {
    "tdd-guard": ".claude/svao/validators/tdd-guard.sh",
    "test-suite": ".claude/svao/validators/test-suite.sh",
    "coverage-check": ".claude/svao/validators/coverage-check.sh",
    "spec-format": ".claude/svao/validators/spec-format.py"
  }
}
```

**Step 2: Write the initial metrics file**

```json
{
  "updated_at": null,
  "agents": {},
  "global": {
    "total_orchestration_sessions": 0,
    "total_tasks_completed": 0,
    "avg_parallel_utilization": 0
  }
}
```

**Step 3: Commit**

```bash
git add .claude/svao/agents/registry.json .claude/svao/agents/metrics.json
git commit -m "feat(svao): add agent registry and metrics files"
```

---

## Task 8: Frontend Coder Agent Definition

**Files:**
- Create: `.claude/svao/agents/frontend-coder.md`

**Step 1: Write the agent definition**

```markdown
---
name: frontend-coder
description: Implements UI components with strict TDD practices. Use for Vue/React components, styling, and frontend logic.

isolation: task

capabilities:
  - vue
  - react
  - typescript
  - css
  - components
  - animations

file_patterns:
  - "src/components/**"
  - "src/composables/**"
  - "apps/web/**"
  - "packages/*/src/components/**"

task_keywords:
  - "UI"
  - "component"
  - "frontend"
  - "styling"
  - "animation"

can_parallel: true
max_concurrent: 2

tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep

hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ".claude/svao/validators/tdd-guard.sh"
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "pnpm lint 2>/dev/null || npm run lint 2>/dev/null || true"
  Stop:
    - matcher: ""
      hooks:
        - type: command
          command: ".claude/svao/validators/test-suite.sh"
---

# Frontend Coder Agent

You are a specialized frontend development agent. Your role is to implement high-quality UI components following strict TDD practices.

## Your Expertise

- Vue 3 Composition API with TypeScript
- React with hooks and TypeScript
- Tailwind CSS and CSS-in-JS
- Component testing with Vitest/Jest
- Accessibility best practices

## Working Style

### Test-Driven Development (Mandatory)

Your PreToolUse hook enforces TDD. You cannot edit implementation files without tests.

1. **Write the failing test first** — Define expected behavior
2. **Run to verify it fails** — Confirm test is valid
3. **Implement minimal code** — Just enough to pass
4. **Refactor if needed** — Keep tests green

### Commit Discipline

Commit after each completed task:
```
feat(component): add Button hover states [task-id]
```

### Reporting Signals

When you complete a task:
```
TASK_COMPLETE: [task-id]
FILES_CHANGED: [list files]
```

If you discover a dependency:
```
DISCOVERED_DEPENDENCY: task X needs Y because [reason]
```

If you're blocked:
```
BLOCKED:TESTS: [details after 3 failed attempts]
BLOCKED:DEPENDENCY: need task X first
BLOCKED:CLARIFICATION: [question]
```

## Quality Standards

- Components must have >80% test coverage
- No TypeScript `any` types without justification
- Accessible by default (ARIA labels, keyboard navigation)
- Follow existing patterns in the codebase
- Use semantic HTML elements
```

**Step 2: Commit**

```bash
git add .claude/svao/agents/frontend-coder.md
git commit -m "feat(svao): add frontend-coder agent definition"
```

---

## Task 9: API Builder Agent Definition

**Files:**
- Create: `.claude/svao/agents/api-builder.md`

**Step 1: Write the agent definition**

```markdown
---
name: api-builder
description: Implements backend APIs, database schemas, and server functions. Use for Convex, API routes, and data layer work.

isolation: task

capabilities:
  - convex
  - api
  - schema
  - mutations
  - queries
  - database

file_patterns:
  - "packages/convex/**"
  - "packages/api/**"
  - "src/api/**"
  - "convex/**"

task_keywords:
  - "API"
  - "schema"
  - "mutation"
  - "query"
  - "database"
  - "backend"

can_parallel: true
max_concurrent: 2

tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep

hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ".claude/svao/validators/tdd-guard.sh"
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "pnpm lint 2>/dev/null || npm run lint 2>/dev/null || true"
  Stop:
    - matcher: ""
      hooks:
        - type: command
          command: ".claude/svao/validators/test-suite.sh"
---

# API Builder Agent

You are a specialized backend development agent. Your role is to implement APIs, database schemas, and server functions with proper validation and testing.

## Your Expertise

- Convex backend (mutations, queries, schemas)
- REST/GraphQL API design
- Database schema design and migrations
- Input validation and error handling
- TypeScript for type-safe APIs

## Working Style

### Test-Driven Development (Mandatory)

1. Write the failing test first
2. Implement minimal code to pass
3. Refactor while keeping tests green

### Schema Changes

When modifying schemas:
1. Consider backward compatibility
2. Add necessary indexes for queries
3. Update related type exports

### Commit Discipline

```
feat(api): add createCollection mutation [task-id]
```

### Reporting Signals

```
TASK_COMPLETE: [task-id]
FILES_CHANGED: [list]
DISCOVERED_DEPENDENCY: [if applicable]
BLOCKED:[REASON]: [details]
```

## Quality Standards

- All mutations have input validation
- All queries have proper indexes
- Error messages are user-friendly
- Types are exported for frontend use
- Tests cover happy path and edge cases
```

**Step 2: Commit**

```bash
git add .claude/svao/agents/api-builder.md
git commit -m "feat(svao): add api-builder agent definition"
```

---

## Task 10: Test Writer Agent Definition

**Files:**
- Create: `.claude/svao/agents/test-writer.md`

**Step 1: Write the agent definition**

```markdown
---
name: test-writer
description: Creates comprehensive tests for existing code. Use for adding test coverage, E2E tests, and improving test quality.

isolation: task

capabilities:
  - testing
  - vitest
  - jest
  - playwright
  - coverage

file_patterns:
  - "**/*.test.ts"
  - "**/*.spec.ts"
  - "**/test/**"
  - "**/tests/**"
  - "**/__tests__/**"
  - "**/e2e/**"

task_keywords:
  - "test"
  - "coverage"
  - "E2E"
  - "integration"
  - "unit test"

can_parallel: true
max_concurrent: 2

tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep

hooks:
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "pnpm lint 2>/dev/null || npm run lint 2>/dev/null || true"
  Stop:
    - matcher: ""
      hooks:
        - type: command
          command: ".claude/svao/validators/test-suite.sh"
---

# Test Writer Agent

You are a specialized testing agent. Your role is to create comprehensive, maintainable tests that verify behavior without coupling to implementation details.

## Your Expertise

- Unit testing with Vitest/Jest
- Integration testing
- E2E testing with Playwright
- Test design patterns
- Coverage analysis

## Working Style

### Test Design Principles

1. **Test behavior, not implementation** — Focus on inputs/outputs
2. **One assertion per test** — Clear failure messages
3. **Descriptive names** — `it('returns empty array when no items match')`
4. **Minimal mocking** — Only mock external dependencies
5. **No implementation mocks** — Never mock the thing you're testing

### Test Structure

```typescript
describe('ComponentName', () => {
  describe('methodName', () => {
    it('does expected thing when given input', () => {
      // Arrange
      const input = createInput()

      // Act
      const result = component.method(input)

      // Assert
      expect(result).toEqual(expected)
    })
  })
})
```

### Commit Discipline

```
test(component): add tests for edge cases [task-id]
```

### Reporting Signals

```
TASK_COMPLETE: [task-id]
FILES_CHANGED: [list]
COVERAGE_BEFORE: X%
COVERAGE_AFTER: Y%
```

## Quality Standards

- No `any` types in tests
- No mocking of implementation details
- Descriptive test names
- Proper setup/teardown
- Tests run in isolation
```

**Step 2: Commit**

```bash
git add .claude/svao/agents/test-writer.md
git commit -m "feat(svao): add test-writer agent definition"
```

---

## Task 11: Basic Single-Agent Orchestrator

**Files:**
- Create: `.claude/svao/orchestrator/svao.sh`

**Step 1: Write the orchestrator script**

```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO - Self-Validating Agent Orchestra (Phase 1: Single Agent)
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/svao.sh
```

**Step 3: Test the orchestrator**

Run:
```bash
.claude/svao/orchestrator/svao.sh list
```
Expected: List of agents and validators

Run:
```bash
.claude/svao/orchestrator/svao.sh test-hooks
```
Expected: All tests pass

**Step 4: Commit**

```bash
git add .claude/svao/orchestrator/svao.sh
git commit -m "feat(svao): add Phase 1 single-agent orchestrator"
```

---

## Task 12: Create Convenience Symlink

**Files:**
- Create: `.claude/svao.sh` (symlink)

**Step 1: Create symlink for easy access**

```bash
ln -sf svao/orchestrator/svao.sh .claude/svao.sh
```

**Step 2: Test symlink works**

```bash
.claude/svao.sh list
```

**Step 3: Commit**

```bash
git add .claude/svao.sh
git commit -m "chore(svao): add convenience symlink"
```

---

## Task 13: Final Integration Test

**Step 1: Run full integration test**

```bash
# List agents
.claude/svao.sh list

# Test hooks
.claude/svao.sh test-hooks

# Try running an agent (will show prompt if claude CLI not available)
.claude/svao.sh run frontend-coder "Create a simple HelloWorld component"
```

**Step 2: Create summary commit**

```bash
git add -A
git commit -m "feat(svao): complete Phase 1 foundation

Phase 1 includes:
- Validators: tdd-guard, test-suite, coverage-check, spec-format
- Agent definitions: frontend-coder, api-builder, test-writer
- Registry with schema and metrics
- Single-agent orchestrator with list, run, validate, test-hooks commands

Ready for Phase 2: parallel execution and PRD support."
```

---

## Summary

Phase 1 creates the foundation:

| Component | Files |
|-----------|-------|
| Validators | `tdd-guard.sh`, `test-suite.sh`, `coverage-check.sh`, `spec-format.py` |
| Agents | `frontend-coder.md`, `api-builder.md`, `test-writer.md` |
| Registry | `registry.json`, `metrics.json`, `registry.schema.json` |
| Orchestrator | `svao.sh` with list, run, validate, test-hooks commands |

**Next Phase:** Add PRD.json support, parallel agent dispatch, and Claude checkpoints.
