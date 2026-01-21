# SVAO Phase 2: PRD Compiler & Parallel Dispatch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend SVAO with a PRD compiler, parallel agent dispatch, and Claude checkpoints for adaptive orchestration.

**Architecture:** Strict OpenSpec compiler generates immutable `prd.json`; orchestrator manages mutable `prd-state.json`; parallel agents write status files; Claude checkpoints provide intelligence at key decision points.

**Tech Stack:** Bash, Python 3, jq, Claude CLI

**Reference:** `designs/2026-01-20-svao-phase2-design.md`

---

## Phase 2a: PRD Compiler

### Task 1: PRD JSON Schema

**Files:**
- Create: `.claude/svao/schemas/prd.schema.json`

**Step 1: Write the schema file**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://svao.local/prd.schema.json",
  "title": "SVAO PRD Specification",
  "description": "Immutable task specification compiled from OpenSpec",
  "type": "object",
  "required": ["version", "change_id", "compiled_at", "sections", "summary"],
  "properties": {
    "version": {
      "type": "string",
      "pattern": "^\\d+\\.\\d+\\.\\d+$"
    },
    "change_id": {
      "type": "string",
      "pattern": "^[a-z0-9-]+$"
    },
    "compiled_at": {
      "type": "string",
      "format": "date-time"
    },
    "source_hash": {
      "type": "string",
      "pattern": "^sha256:[a-f0-9]{64}$"
    },
    "context": {
      "type": "object",
      "properties": {
        "summary": { "type": "string" },
        "proposal_file": { "type": "string" },
        "design_file": { "type": "string" }
      }
    },
    "success_criteria": {
      "type": "object",
      "properties": {
        "tests_pass": { "type": "string" },
        "lint_clean": { "type": "string" },
        "type_check": { "type": "string" }
      }
    },
    "sections": {
      "type": "array",
      "items": { "$ref": "#/$defs/section" }
    },
    "dependencies": {
      "type": "object",
      "properties": {
        "explicit": {
          "type": "array",
          "items": { "$ref": "#/$defs/dependency" }
        },
        "inferred": {
          "type": "array",
          "items": { "$ref": "#/$defs/dependency" }
        },
        "pending_review": {
          "type": "array",
          "items": { "$ref": "#/$defs/dependency" }
        }
      }
    },
    "summary": {
      "type": "object",
      "required": ["total_sections", "total_tasks"],
      "properties": {
        "total_sections": { "type": "integer" },
        "total_tasks": { "type": "integer" },
        "explicit_dependencies": { "type": "integer" },
        "inferred_dependencies": { "type": "integer" },
        "pending_review": { "type": "integer" }
      }
    }
  },
  "$defs": {
    "section": {
      "type": "object",
      "required": ["number", "name", "tasks"],
      "properties": {
        "number": { "type": "integer", "minimum": 1 },
        "name": { "type": "string" },
        "tasks": {
          "type": "array",
          "items": { "$ref": "#/$defs/task" }
        }
      }
    },
    "task": {
      "type": "object",
      "required": ["id", "description", "files"],
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^\\d+\\.\\d+$"
        },
        "description": { "type": "string" },
        "files": {
          "type": "array",
          "items": { "type": "string" }
        },
        "agent_type": { "type": "string" },
        "complexity": {
          "type": "string",
          "enum": ["low", "medium", "high"]
        },
        "depends_on": {
          "type": "array",
          "items": { "type": "string" }
        },
        "blocks": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "dependency": {
      "type": "object",
      "required": ["from", "to"],
      "properties": {
        "from": { "type": "string" },
        "to": { "type": "string" },
        "confidence": { "type": "integer", "minimum": 0, "maximum": 100 },
        "reason": { "type": "string" }
      }
    }
  }
}
```

**Step 2: Commit**

```bash
git add .claude/svao/schemas/prd.schema.json
git commit -m "feat(svao): add PRD JSON schema"
```

---

### Task 2: PRD State JSON Schema

**Files:**
- Create: `.claude/svao/schemas/prd-state.schema.json`

**Step 1: Write the schema file**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://svao.local/prd-state.schema.json",
  "title": "SVAO PRD Execution State",
  "description": "Mutable execution state managed by orchestrator",
  "type": "object",
  "required": ["version", "change_id", "prd_file", "prd_hash", "session", "tasks", "queue", "summary"],
  "properties": {
    "version": { "type": "string" },
    "change_id": { "type": "string" },
    "prd_file": { "type": "string" },
    "prd_hash": { "type": "string", "pattern": "^sha256:[a-f0-9]{64}$" },
    "session": {
      "type": "object",
      "required": ["id", "started_at", "status"],
      "properties": {
        "id": { "type": "string" },
        "started_at": { "type": "string", "format": "date-time" },
        "updated_at": { "type": "string", "format": "date-time" },
        "iteration": { "type": "integer", "minimum": 0 },
        "status": {
          "type": "string",
          "enum": ["running", "paused", "completed", "failed"]
        }
      }
    },
    "tasks": {
      "type": "object",
      "additionalProperties": { "$ref": "#/$defs/taskState" }
    },
    "queue": {
      "type": "object",
      "properties": {
        "ready": { "type": "array", "items": { "type": "string" } },
        "in_progress": { "type": "array", "items": { "type": "string" } },
        "blocked": { "type": "array", "items": { "type": "string" } },
        "completed": { "type": "array", "items": { "type": "string" } }
      }
    },
    "discovered_dependencies": {
      "type": "array",
      "items": { "$ref": "#/$defs/discoveredDep" }
    },
    "checkpoints": {
      "type": "object",
      "properties": {
        "last_queue_planning": { "type": "string", "format": "date-time" },
        "last_iteration_at_checkpoint": { "type": "integer" },
        "history": { "type": "array" }
      }
    },
    "metrics": {
      "type": "object",
      "properties": {
        "tasks_completed": { "type": "integer" },
        "tasks_failed": { "type": "integer" },
        "total_retries": { "type": "integer" },
        "agents_used": { "type": "object" },
        "avg_task_duration_seconds": { "type": "number" },
        "parallel_utilization": { "type": "number" }
      }
    },
    "summary": {
      "type": "object",
      "properties": {
        "total_tasks": { "type": "integer" },
        "completed": { "type": "integer" },
        "in_progress": { "type": "integer" },
        "blocked": { "type": "integer" },
        "ready": { "type": "integer" },
        "pending": { "type": "integer" },
        "progress_percent": { "type": "number" }
      }
    }
  },
  "$defs": {
    "taskState": {
      "type": "object",
      "required": ["status"],
      "properties": {
        "status": {
          "type": "string",
          "enum": ["pending", "in_progress", "completed", "blocked", "failed"]
        },
        "assigned_to": { "type": "string" },
        "assigned_at": { "type": "string", "format": "date-time" },
        "completed_at": { "type": "string", "format": "date-time" },
        "duration_seconds": { "type": "integer" },
        "commits": { "type": "array", "items": { "type": "string" } },
        "retries": { "type": "integer" },
        "retry_history": { "type": "array" },
        "isolation": { "type": "string", "enum": ["task", "worktree"] },
        "pid": { "type": "integer" },
        "status_file": { "type": "string" },
        "blocked_by": { "type": "array", "items": { "type": "string" } },
        "blocked_reason": { "type": "string" }
      }
    },
    "discoveredDep": {
      "type": "object",
      "required": ["from", "to", "status"],
      "properties": {
        "from": { "type": "string" },
        "to": { "type": "string" },
        "confidence": { "type": "integer" },
        "reason": { "type": "string" },
        "discovered_at": { "type": "string", "format": "date-time" },
        "discovered_by": { "type": "string" },
        "status": {
          "type": "string",
          "enum": ["pending_review", "applied", "rejected"]
        }
      }
    }
  }
}
```

**Step 2: Commit**

```bash
git add .claude/svao/schemas/prd-state.schema.json
git commit -m "feat(svao): add PRD state JSON schema"
```

---

### Task 3: Task Parser (Python)

**Files:**
- Create: `.claude/svao/orchestrator/parser.py`

**Step 1: Write the parser**

```python
#!/usr/bin/env python3
"""
OpenSpec Task Parser
Parses tasks.md into structured format with strict validation.
"""

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Task:
    id: str
    description: str
    files: list[str]
    depends_on: list[str] = field(default_factory=list)
    agent_type: str | None = None
    complexity: str = "medium"


@dataclass
class Section:
    number: int
    name: str
    tasks: list[Task] = field(default_factory=list)


@dataclass
class ParseResult:
    sections: list[Section]
    errors: list[str]
    warnings: list[str]


def parse_tasks_md(content: str) -> ParseResult:
    """Parse tasks.md content into structured sections and tasks."""
    sections: list[Section] = []
    errors: list[str] = []
    warnings: list[str] = []

    # Pattern for section headers: ## N. Name
    section_pattern = re.compile(r'^## (\d+)\. (.+)$', re.MULTILINE)

    # Pattern for tasks: - [ ] N.M Description (files: ...) (depends: ...) etc
    task_pattern = re.compile(
        r'^- \[[ x]\] (\d+\.\d+) (.+?)(?:\s*\(files?:\s*([^)]+)\))?'
        r'(?:\s*\(depends?:\s*([^)]+)\))?'
        r'(?:\s*\(agent:\s*([^)]+)\))?'
        r'(?:\s*\(complexity:\s*([^)]+)\))?$',
        re.MULTILINE
    )

    # Split by sections
    section_matches = list(section_pattern.finditer(content))

    if not section_matches:
        errors.append("No sections found. Expected format: '## 1. Section Name'")
        return ParseResult([], errors, warnings)

    for i, match in enumerate(section_matches):
        section_num = int(match.group(1))
        section_name = match.group(2).strip()

        # Get content until next section or end
        start = match.end()
        end = section_matches[i + 1].start() if i + 1 < len(section_matches) else len(content)
        section_content = content[start:end]

        section = Section(number=section_num, name=section_name)

        # Parse tasks in this section
        for task_match in task_pattern.finditer(section_content):
            task_id = task_match.group(1)
            description = task_match.group(2).strip()
            files_str = task_match.group(3)
            depends_str = task_match.group(4)
            agent = task_match.group(5)
            complexity = task_match.group(6)

            # Validate task ID matches section
            expected_prefix = f"{section_num}."
            if not task_id.startswith(expected_prefix):
                errors.append(f"Task {task_id} in section {section_num} should start with '{expected_prefix}'")

            # Parse files
            if files_str:
                files = [f.strip() for f in files_str.split(',')]
            else:
                errors.append(f"Task {task_id} missing required (files: ...) annotation")
                files = []

            # Parse dependencies
            depends_on = []
            if depends_str:
                depends_on = [d.strip() for d in depends_str.split(',')]

            # Parse complexity
            if complexity:
                complexity = complexity.strip().lower()
                if complexity not in ('low', 'medium', 'high'):
                    warnings.append(f"Task {task_id} has invalid complexity '{complexity}', using 'medium'")
                    complexity = 'medium'
            else:
                complexity = 'medium'

            task = Task(
                id=task_id,
                description=description,
                files=files,
                depends_on=depends_on,
                agent_type=agent.strip() if agent else None,
                complexity=complexity
            )
            section.tasks.append(task)

        if not section.tasks:
            warnings.append(f"Section {section_num} '{section_name}' has no tasks")

        sections.append(section)

    return ParseResult(sections, errors, warnings)


def validate_dependencies(sections: list[Section]) -> list[str]:
    """Validate that all dependencies reference existing tasks."""
    errors = []
    all_task_ids = {task.id for section in sections for task in section.tasks}

    for section in sections:
        for task in section.tasks:
            for dep in task.depends_on:
                if dep not in all_task_ids:
                    errors.append(f"Task {task.id} depends on unknown task '{dep}'")

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: parser.py <tasks.md>", file=sys.stderr)
        sys.exit(1)

    tasks_file = Path(sys.argv[1])
    if not tasks_file.exists():
        print(f"Error: File not found: {tasks_file}", file=sys.stderr)
        sys.exit(1)

    content = tasks_file.read_text()
    result = parse_tasks_md(content)

    # Validate dependencies
    dep_errors = validate_dependencies(result.sections)
    result.errors.extend(dep_errors)

    # Output results
    if result.errors:
        print("❌ Parsing errors:", file=sys.stderr)
        for error in result.errors:
            print(f"   - {error}", file=sys.stderr)
        sys.exit(2)

    if result.warnings:
        print("⚠️  Warnings:")
        for warning in result.warnings:
            print(f"   - {warning}")

    print(f"✓ Parsed {len(result.sections)} sections, {sum(len(s.tasks) for s in result.sections)} tasks")

    # Output JSON
    import json
    output = {
        "sections": [
            {
                "number": s.number,
                "name": s.name,
                "tasks": [
                    {
                        "id": t.id,
                        "description": t.description,
                        "files": t.files,
                        "depends_on": t.depends_on,
                        "agent_type": t.agent_type,
                        "complexity": t.complexity
                    }
                    for t in s.tasks
                ]
            }
            for s in result.sections
        ]
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/parser.py
```

**Step 3: Test with sample input**

Create test file:
```bash
cat > /tmp/test-tasks.md << 'EOF'
# Test Feature

## 1. Setup

- [ ] 1.1 Create schema file (files: src/schema.ts)
- [ ] 1.2 Export types (files: src/types.ts) (depends: 1.1)

## 2. Implementation

- [ ] 2.1 Add mutations (files: src/mutations.ts) (depends: 1.1)
- [ ] 2.2 Add queries (files: src/queries.ts) (depends: 1.1, 2.1)
EOF
```

Run:
```bash
python3 .claude/svao/orchestrator/parser.py /tmp/test-tasks.md
```

Expected: JSON output with 2 sections, 4 tasks

**Step 4: Commit**

```bash
git add .claude/svao/orchestrator/parser.py
git commit -m "feat(svao): add OpenSpec task parser"
```

---

### Task 4: Dependency Inference Engine

**Files:**
- Create: `.claude/svao/orchestrator/inference.py`

**Step 1: Write the inference engine**

```python
#!/usr/bin/env python3
"""
Dependency Inference Engine
Infers task dependencies using multiple signals with confidence scoring.
"""

import re
from dataclasses import dataclass


@dataclass
class InferredDependency:
    from_task: str
    to_task: str
    confidence: int
    reason: str


def extract_stem(filepath: str) -> str:
    """Extract meaningful stem from filepath for matching."""
    # Remove extension and path
    name = filepath.split('/')[-1]
    name = re.sub(r'\.(ts|tsx|js|jsx|vue|py|go)$', '', name)
    # Convert to lowercase for matching
    return name.lower()


def extract_keywords(description: str) -> set[str]:
    """Extract meaningful keywords from task description."""
    # Common development keywords
    keywords = set()
    desc_lower = description.lower()

    patterns = {
        'schema': ['schema', 'model', 'table', 'entity'],
        'type': ['type', 'interface', 'typedef'],
        'mutation': ['mutation', 'create', 'update', 'delete', 'write'],
        'query': ['query', 'read', 'fetch', 'get', 'list'],
        'component': ['component', 'view', 'page', 'ui'],
        'test': ['test', 'spec', 'coverage'],
        'api': ['api', 'endpoint', 'route', 'handler'],
    }

    for category, words in patterns.items():
        if any(word in desc_lower for word in words):
            keywords.add(category)

    return keywords


def infer_from_file_patterns(tasks: list[dict]) -> list[InferredDependency]:
    """Infer dependencies from file naming patterns."""
    dependencies = []

    # Build stem -> task mapping
    stem_to_task: dict[str, list[str]] = {}
    for task in tasks:
        for filepath in task.get('files', []):
            stem = extract_stem(filepath)
            if stem not in stem_to_task:
                stem_to_task[stem] = []
            stem_to_task[stem].append(task['id'])

    # Find tasks with shared stems
    for stem, task_ids in stem_to_task.items():
        if len(task_ids) > 1:
            # Sort by task ID (earlier tasks are dependencies)
            sorted_ids = sorted(task_ids, key=lambda x: tuple(map(int, x.split('.'))))
            for i, later_task in enumerate(sorted_ids[1:], 1):
                for earlier_task in sorted_ids[:i]:
                    dependencies.append(InferredDependency(
                        from_task=later_task,
                        to_task=earlier_task,
                        confidence=85,
                        reason=f"file pattern: shared stem '{stem}'"
                    ))

    return dependencies


def infer_from_keywords(tasks: list[dict]) -> list[InferredDependency]:
    """Infer dependencies from keyword relationships."""
    dependencies = []

    # Keyword dependency rules
    keyword_deps = {
        'mutation': ['schema', 'type'],
        'query': ['schema', 'type'],
        'component': ['type', 'query', 'mutation'],
        'test': [],  # Tests don't create dependencies
        'api': ['schema', 'type'],
    }

    # Build keyword -> tasks mapping
    keyword_to_tasks: dict[str, list[str]] = {}
    task_keywords: dict[str, set[str]] = {}

    for task in tasks:
        keywords = extract_keywords(task.get('description', ''))
        task_keywords[task['id']] = keywords
        for kw in keywords:
            if kw not in keyword_to_tasks:
                keyword_to_tasks[kw] = []
            keyword_to_tasks[kw].append(task['id'])

    # Find dependencies based on keyword relationships
    for task in tasks:
        task_kws = task_keywords.get(task['id'], set())
        for kw in task_kws:
            required_kws = keyword_deps.get(kw, [])
            for req_kw in required_kws:
                if req_kw in keyword_to_tasks:
                    for dep_task_id in keyword_to_tasks[req_kw]:
                        if dep_task_id != task['id']:
                            # Check if dep_task is earlier
                            dep_parts = tuple(map(int, dep_task_id.split('.')))
                            task_parts = tuple(map(int, task['id'].split('.')))
                            if dep_parts < task_parts:
                                dependencies.append(InferredDependency(
                                    from_task=task['id'],
                                    to_task=dep_task_id,
                                    confidence=50,
                                    reason=f"keyword: '{kw}' typically depends on '{req_kw}'"
                                ))

    return dependencies


def infer_from_section_order(sections: list[dict]) -> list[InferredDependency]:
    """Infer coarse-grained dependencies from section order."""
    dependencies = []

    for i, section in enumerate(sections[1:], 1):
        prev_section = sections[i - 1]
        # Last task of previous section blocks first task of current section
        if prev_section.get('tasks') and section.get('tasks'):
            prev_last = prev_section['tasks'][-1]['id']
            curr_first = section['tasks'][0]['id']
            dependencies.append(InferredDependency(
                from_task=curr_first,
                to_task=prev_last,
                confidence=25,
                reason=f"section order: section {section['number']} after section {prev_section['number']}"
            ))

    return dependencies


def infer_dependencies(parsed_data: dict, confidence_threshold: int = 70) -> dict:
    """
    Run all inference strategies and categorize results.

    Returns:
        {
            "auto_apply": [...],  # confidence >= threshold
            "pending_review": [...]  # confidence < threshold
        }
    """
    all_tasks = []
    for section in parsed_data.get('sections', []):
        all_tasks.extend(section.get('tasks', []))

    # Collect all inferences
    all_deps: list[InferredDependency] = []
    all_deps.extend(infer_from_file_patterns(all_tasks))
    all_deps.extend(infer_from_keywords(all_tasks))
    all_deps.extend(infer_from_section_order(parsed_data.get('sections', [])))

    # Deduplicate (keep highest confidence)
    unique_deps: dict[tuple[str, str], InferredDependency] = {}
    for dep in all_deps:
        key = (dep.from_task, dep.to_task)
        if key not in unique_deps or dep.confidence > unique_deps[key].confidence:
            unique_deps[key] = dep

    # Categorize by confidence
    auto_apply = []
    pending_review = []

    for dep in unique_deps.values():
        dep_dict = {
            "from": dep.from_task,
            "to": dep.to_task,
            "confidence": dep.confidence,
            "reason": dep.reason
        }
        if dep.confidence >= confidence_threshold:
            auto_apply.append(dep_dict)
        else:
            pending_review.append(dep_dict)

    return {
        "auto_apply": auto_apply,
        "pending_review": pending_review
    }


if __name__ == "__main__":
    import json
    import sys

    # Read parsed JSON from stdin or file
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    result = infer_dependencies(data)

    print(f"✓ Inferred {len(result['auto_apply'])} high-confidence dependencies")
    print(f"⚠️  {len(result['pending_review'])} dependencies need review")
    print(json.dumps(result, indent=2))
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/inference.py
```

**Step 3: Test with parser output**

```bash
python3 .claude/svao/orchestrator/parser.py /tmp/test-tasks.md 2>/dev/null | \
  python3 .claude/svao/orchestrator/inference.py
```

**Step 4: Commit**

```bash
git add .claude/svao/orchestrator/inference.py
git commit -m "feat(svao): add dependency inference engine"
```

---

### Task 5: PRD Compiler Script

**Files:**
- Create: `.claude/svao/orchestrator/compile.sh`

**Step 1: Write the compiler script**

```bash
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
log_info() { echo -e "${BLUE}ℹ${NC} $*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; }
log_warn() { echo -e "${YELLOW}⚠️${NC} $*"; }
log_error() { echo -e "${RED}❌${NC} $*" >&2; }

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
PARSED_JSON=$(python3 "$SCRIPT_DIR/parser.py" "$TASKS_FILE" 2>&1) || {
  log_error "Failed to parse tasks.md"
  echo "$PARSED_JSON" >&2
  exit 2
}

# Extract just the JSON (skip status messages)
PARSED_JSON=$(echo "$PARSED_JSON" | grep -A9999 '^{')

SECTION_COUNT=$(echo "$PARSED_JSON" | jq '.sections | length')
TASK_COUNT=$(echo "$PARSED_JSON" | jq '[.sections[].tasks[]] | length')
log_success "Parsed $SECTION_COUNT sections, $TASK_COUNT tasks"

# Infer dependencies
INFERRED_JSON='{"auto_apply":[],"pending_review":[]}'
if [[ "$SKIP_INFERENCE" != true ]]; then
  log "Inferring dependencies..."
  INFERRED_JSON=$(echo "$PARSED_JSON" | python3 "$SCRIPT_DIR/inference.py" 2>&1) || {
    log_warn "Dependency inference failed, continuing without"
    INFERRED_JSON='{"auto_apply":[],"pending_review":[]}'
  }
  INFERRED_JSON=$(echo "$INFERRED_JSON" | grep -A9999 '^{')

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
  # Extract first paragraph after # heading
  CONTEXT_SUMMARY=$(sed -n '/^# /,/^## /{/^# /d;/^## /d;p}' "$PROPOSAL_FILE" | head -5 | tr '\n' ' ' | xargs)
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

# Build blocks relationships (reverse of depends_on)
PRD_JSON=$(echo "$PRD_JSON" | jq '
  # Build a map of task_id -> tasks that depend on it
  (.sections[].tasks | map({key: .id, value: .depends_on}) | from_entries) as $deps |
  .sections[].tasks |= map(
    .blocks = [
      $deps | to_entries[] |
      select(.value | contains([.key])) |
      .key
    ] // []
  )
')

if [[ "$DRY_RUN" == true ]]; then
  log_info "Dry run - would write:"
  echo "$PRD_JSON"
  exit 0
fi

# Write PRD file
echo "$PRD_JSON" > "$PRD_FILE"
log_success "Written: $PRD_FILE"

# Initialize state file
STATE_JSON=$(jq -n \
  --arg version "1.0.0" \
  --arg change_id "$CHANGE_ID" \
  --arg prd_file "prd.json" \
  --arg prd_hash "$SOURCE_HASH" \
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

# Initialize task states from PRD
TASK_IDS=$(echo "$PRD_JSON" | jq -r '.sections[].tasks[].id')
for task_id in $TASK_IDS; do
  STATE_JSON=$(echo "$STATE_JSON" | jq --arg id "$task_id" '
    .tasks[$id] = {
      "status": "pending",
      "retries": 0
    }
  ')
done

# Build initial queue
STATE_JSON=$(echo "$STATE_JSON" | jq --argjson prd "$PRD_JSON" '
  # Tasks with no dependencies are ready
  .queue.ready = [
    $prd.sections[].tasks[] |
    select((.depends_on | length) == 0) |
    .id
  ] |
  # Tasks with dependencies are blocked
  .queue.blocked = [
    $prd.sections[].tasks[] |
    select((.depends_on | length) > 0) |
    .id
  ] |
  # Update summary
  .summary.total_tasks = ($prd.summary.total_tasks) |
  .summary.ready = (.queue.ready | length) |
  .summary.blocked = (.queue.blocked | length) |
  .summary.pending = (.summary.total_tasks - .summary.ready - .summary.blocked)
')

echo "$STATE_JSON" > "$STATE_FILE"
log_success "Initialized: $STATE_FILE"

# Summary
echo ""
log_success "Compilation complete!"
log_info "PRD: $PRD_FILE"
log_info "State: $STATE_FILE"

PENDING_COUNT=$(echo "$INFERRED_JSON" | jq '.pending_review | length')
if [[ "$PENDING_COUNT" -gt 0 ]]; then
  echo ""
  log_warn "Review suggested dependencies:"
  echo "$INFERRED_JSON" | jq -r '.pending_review[] | "   - \(.from) → \(.to) (\(.reason), confidence: \(.confidence)%)"'
  echo ""
  log_info "Run: svao.sh deps review $CHANGE_ID"
fi
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/compile.sh
```

**Step 3: Test compilation**

```bash
# Create test change directory
mkdir -p openspec/changes/test-feature
cp /tmp/test-tasks.md openspec/changes/test-feature/tasks.md
cat > openspec/changes/test-feature/proposal.md << 'EOF'
# Test Feature

This is a test feature for validating the compiler.

## Problem

We need to test the compiler.

## Solution

Run the compiler on test data.

## Impact

Validates the compiler works correctly.
EOF

# Run compiler
.claude/svao/orchestrator/compile.sh test-feature

# Check output
cat openspec/changes/test-feature/prd.json | jq '.summary'
```

**Step 4: Commit**

```bash
git add .claude/svao/orchestrator/compile.sh
git commit -m "feat(svao): add PRD compiler script"
```

---

### Task 6: Add compile command to svao.sh

**Files:**
- Modify: `.claude/svao/orchestrator/svao.sh`

**Step 1: Add compile command**

Add to the case statement in svao.sh:

```bash
# Add after the existing commands in the case statement:

    compile)
      [[ $# -lt 2 ]] && log_error "Missing change-id" && exit 1
      shift
      "$SCRIPT_DIR/compile.sh" "$@"
      ;;
```

**Step 2: Update usage**

Add to usage():
```bash
  compile <change-id>       Compile OpenSpec to PRD
```

**Step 3: Test**

```bash
.claude/svao.sh compile test-feature --dry-run
```

**Step 4: Commit**

```bash
git add .claude/svao/orchestrator/svao.sh
git commit -m "feat(svao): add compile command to orchestrator"
```

---

### Task 7: Clean up test files

**Step 1: Remove test artifacts**

```bash
rm -rf openspec/changes/test-feature
rm -f /tmp/test-tasks.md
```

**Step 2: Commit Phase 2a complete**

```bash
git add -A
git commit -m "feat(svao): complete Phase 2a - PRD compiler

- JSON schemas for prd.json and prd-state.json
- Task parser with strict validation
- Dependency inference engine with confidence scoring
- Compiler script with --dry-run, --strict options
- Integrated compile command in svao.sh"
```

---

## Phase 2b: Parallel Dispatch

### Task 8: Agent Status File Writer

**Files:**
- Create: `.claude/svao/orchestrator/status-writer.sh`

**Step 1: Write the status helper**

```bash
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
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/status-writer.sh
```

**Step 3: Commit**

```bash
git add .claude/svao/orchestrator/status-writer.sh
git commit -m "feat(svao): add agent status file writer"
```

---

### Task 9: Parallel Dispatch Loop

**Files:**
- Create: `.claude/svao/orchestrator/dispatch.sh`

**Step 1: Write the dispatch loop**

```bash
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
log_agent() { echo -e "[$(date +%H:%M:%S)] ${CYAN}🤖${NC} $*"; }

# Configuration
MAX_PARALLEL="${MAX_PARALLEL:-3}"
MAX_RETRIES="${MAX_RETRIES:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
CHECKPOINT_INTERVAL="${CHECKPOINT_INTERVAL:-5}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"

# State
declare -A ACTIVE_PIDS      # pid -> task_id
declare -A TASK_AGENTS      # task_id -> agent_type
declare -A TASK_RETRIES     # task_id -> retry_count
ITERATION=0
SESSION_ID=""
STATUS_DIR=""

# ─────────────────────────────────────────────────────────────
# State Management
# ─────────────────────────────────────────────────────────────

load_state() {
  local state_file="$1"

  SESSION_ID=$(jq -r '.session.id' "$state_file")
  STATUS_DIR="/tmp/svao/$SESSION_ID"
  mkdir -p "$STATUS_DIR"

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

  jq --argjson completed "$completed" --argjson prd "$(cat "$prd_file")" '
    # Ready: pending tasks with all deps completed
    .queue.ready = [
      $prd.sections[].tasks[] |
      select(
        .id as $id |
        (.tasks[$id].status // "pending") == "pending" and
        ((.depends_on // []) - $completed | length) == 0
      ) |
      .id
    ] |
    # In progress
    .queue.in_progress = [.tasks | to_entries[] | select(.value.status == "in_progress") | .key] |
    # Blocked: pending with unmet deps
    .queue.blocked = [
      $prd.sections[].tasks[] |
      select(
        .id as $id |
        (.tasks[$id].status // "pending") == "pending" and
        ((.depends_on // []) - $completed | length) > 0
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
    .summary.progress_percent = (($completed | length) / .summary.total_tasks * 100 | . * 10 | floor / 10)
  ' "$state_file" > "$tmp_file"

  mv "$tmp_file" "$state_file"
}

# ─────────────────────────────────────────────────────────────
# Agent Dispatch
# ─────────────────────────────────────────────────────────────

get_agent_for_task() {
  local prd_file="$1"
  local task_id="$2"

  # Get agent_type from task, default to first matching capability
  local agent=$(jq -r --arg id "$task_id" '
    .sections[].tasks[] | select(.id == $id) | .agent_type // "frontend-coder"
  ' "$prd_file")

  echo "$agent"
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
  ACTIVE_PIDS[$pid]="$task_id"
  TASK_AGENTS[$task_id]="$agent_type"

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

  for pid in "${!ACTIVE_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      # Process exited
      local task_id="${ACTIVE_PIDS[$pid]}"
      unset ACTIVE_PIDS[$pid]

      check_agent_status "$state_file" "$task_id"
      local result=$?

      if [[ $result -eq 2 ]]; then
        # Failed - handle retry
        handle_failure "$prd_file" "$state_file" "$task_id"
      fi
    fi
  done
}

handle_failure() {
  local prd_file="$1"
  local state_file="$2"
  local task_id="$3"

  local retries="${TASK_RETRIES[$task_id]:-0}"
  ((retries++))
  TASK_RETRIES[$task_id]=$retries

  if [[ $retries -lt $MAX_RETRIES ]]; then
    log_warn "Retrying task $task_id (attempt $((retries + 1))/$MAX_RETRIES)"
    local agent="${TASK_AGENTS[$task_id]}"
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
    log "━━━ Iteration $ITERATION ━━━"

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
    local active_count=${#ACTIVE_PIDS[@]}
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
    if [[ ${#ACTIVE_PIDS[@]} -gt 0 ]]; then
      log_agent "Waiting for ${#ACTIVE_PIDS[@]} active agent(s)..."
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
```

**Step 2: Make executable**

```bash
chmod +x .claude/svao/orchestrator/dispatch.sh
```

**Step 3: Commit**

```bash
git add .claude/svao/orchestrator/dispatch.sh
git commit -m "feat(svao): add parallel dispatch loop"
```

---

### Task 10: Add run command to svao.sh

**Files:**
- Modify: `.claude/svao/orchestrator/svao.sh`

**Step 1: Update run command**

Replace the existing `cmd_run` function:

```bash
cmd_run() {
  local change_id="$1"
  shift

  # Parse additional options
  local max_parallel=3
  local max_iterations=50
  local section_target=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --max-parallel) max_parallel="$2"; shift 2 ;;
      --max-iterations) max_iterations="$2"; shift 2 ;;
      --section) section_target="$2"; shift 2 ;;
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

  log_info "Running SVAO for: $change_id"
  log_info "PRD: $prd_file"
  log_info "Max parallel: $max_parallel"

  export MAX_PARALLEL="$max_parallel"
  export MAX_ITERATIONS="$max_iterations"

  "$SCRIPT_DIR/dispatch.sh" "$prd_file" "$state_file"
}
```

**Step 2: Update usage**

```bash
  run <change-id>           Run parallel dispatch for a change
      --max-parallel N      Maximum concurrent agents (default: 3)
      --max-iterations N    Maximum iterations (default: 50)
      --section N           Target specific section
```

**Step 3: Commit**

```bash
git add .claude/svao/orchestrator/svao.sh
git commit -m "feat(svao): update run command for parallel dispatch"
```

---

### Task 11: Add status command

**Files:**
- Modify: `.claude/svao/orchestrator/svao.sh`

**Step 1: Add status command**

```bash
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
  jq -r '.queue.ready[] | "  - \(.)"' "$state_file"

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
```

**Step 2: Add to case statement**

```bash
    status)
      [[ $# -lt 2 ]] && log_error "Missing change-id" && exit 1
      cmd_status "$2"
      ;;
```

**Step 3: Commit**

```bash
git add .claude/svao/orchestrator/svao.sh
git commit -m "feat(svao): add status command"
```

---

### Task 12: Phase 2b Complete

**Step 1: Final commit for Phase 2b**

```bash
git add -A
git commit -m "feat(svao): complete Phase 2b - parallel dispatch

- Agent status file protocol
- Parallel dispatch loop with configurable concurrency
- Automatic retry with max_retries limit
- Queue management and state persistence
- Status command for monitoring"
```

---

## Summary

Phase 2 implementation is split into sub-phases:

| Phase | Tasks | Description |
|-------|-------|-------------|
| 2a | 1-7 | PRD Compiler (schemas, parser, inference, compiler) |
| 2b | 8-12 | Parallel Dispatch (status files, dispatch loop, run/status commands) |
| 2c | 13+ | Checkpoints (to be planned separately) |

**Estimated commits:** 15-20
**Key files created:**
- `schemas/prd.schema.json`
- `schemas/prd-state.schema.json`
- `orchestrator/parser.py`
- `orchestrator/inference.py`
- `orchestrator/compile.sh`
- `orchestrator/status-writer.sh`
- `orchestrator/dispatch.sh`
