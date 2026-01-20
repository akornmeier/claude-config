# Self-Validating Agent Orchestra (SVAO) Design

**Date:** 2026-01-20
**Status:** Draft
**Author:** Brainstorming session with Claude

## Executive Summary

SVAO is a framework for dispatching specialized, self-validating agents in parallel, coordinated by an adaptive orchestrator that learns from outcomes. It combines:

- **Focused agents** with domain-specific validation hooks
- **Deterministic validators** that enforce invariants (can't be fooled by LLM rationalization)
- **Parallel execution** via task or worktree isolation
- **Adaptive orchestration** using shell mechanics + Claude judgment
- **Learning loops** that improve scheduling and prompts over time

The framework builds on patterns from:
- [agentic-finance-review](https://github.com/disler/agentic-finance-review) — Self-validating agent concepts
- [Superpowers plugin](https://github.com/obra/superpowers-marketplace) — Subagent-driven development
- Ralph Wiggum (Oculis) — PRD.json execution with progress tracking

## Problem Statement

Current approaches to agent orchestration have limitations:

| Approach | Limitation |
|----------|------------|
| Single agent | Context pollution, can't parallelize |
| Superpowers subagents | LLM reviewers can rationalize/miss issues |
| Sequential execution | Slow, doesn't utilize available parallelism |
| Generic validation | One-size-fits-all doesn't match domain needs |

We need agents that:
1. Specialize in specific domains (frontend, API, testing, planning)
2. Self-validate with deterministic scripts, not LLM judgment
3. Work in parallel without conflicts
4. Report discoveries that update the task graph
5. Learn from outcomes to improve over time

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         SVAO SYSTEM                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌──────────────────────────────────────┐   │
│  │ PRD.json    │───▶│ ORCHESTRATOR (Shell + Claude)        │   │
│  │ Task Graph  │    │                                      │   │
│  └─────────────┘    │ Shell Loop:                          │   │
│                     │  - Parse dependency graph            │   │
│  ┌─────────────┐    │  - Spawn/monitor agent processes     │   │
│  │ agents.json │───▶│  - Track metrics, detect signals     │   │
│  │ Registry    │    │                                      │   │
│  └─────────────┘    │ Claude Checkpoints:                  │   │
│                     │  1. Queue Planning                   │   │
│  ┌─────────────┐    │  2. Blocker Resolution               │   │
│  │ progress.md │◀──▶│  3. Dependency Discovery             │   │
│  │ Learning    │    │  4. Conflict Detection               │   │
│  └─────────────┘    │  5. Prompt Adaptation                │   │
│                     │  6. Completion Review                │   │
│                     └──────────────────────────────────────┘   │
│                                    │                            │
│              ┌─────────────────────┼─────────────────────┐     │
│              ▼                     ▼                     ▼     │
│     ┌─────────────┐       ┌─────────────┐       ┌───────────┐ │
│     │ Agent A     │       │ Agent B     │       │ Agent C   │ │
│     │ (worktree)  │       │ (task)      │       │ (task)    │ │
│     │             │       │             │       │           │ │
│     │ Hooks:      │       │ Hooks:      │       │ Hooks:    │ │
│     │ ├─Pre       │       │ ├─Pre       │       │ ├─Pre     │ │
│     │ ├─Post      │       │ ├─Post      │       │ ├─Post    │ │
│     │ └─Stop      │       │ └─Stop      │       │ └─Stop    │ │
│     └─────────────┘       └─────────────┘       └───────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

1. **PRD.json** — Task graph with dependencies, status, and assignments
2. **Agent Registry** — Index of available agents with capabilities and metrics
3. **Orchestrator** — Shell script + Claude checkpoints for adaptive execution
4. **Validators** — Deterministic scripts that enforce domain-specific invariants
5. **Progress Log** — Append-only learning record

## Component Specifications

### 1. Agent Definition Format

Agents are defined in `.claude/agents/<agent-name>.md` with YAML frontmatter.

```yaml
---
name: frontend-coder
description: Implements UI components with strict TDD practices.

# Isolation strategy
isolation: task  # "task" (shared worktree) or "worktree" (separate branch)

# Task matching
capabilities:
  - vue
  - typescript
  - css
  - components
file_patterns:
  - "src/components/**"
  - "apps/web/**"
task_keywords:
  - "UI"
  - "component"

# Concurrency
can_parallel: true
max_concurrent: 2

# Tools
tools:
  - Read
  - Edit
  - Write
  - Bash
  - Glob
  - Grep

# Self-validation hooks
hooks:
  PreToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ".claude/validators/tdd-guard.sh"
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "pnpm lint"
        - type: command
          command: "pnpm type-check"
  Stop:
    - matcher: ""
      hooks:
        - type: command
          command: ".claude/validators/test-suite.sh"
---

# Frontend Coder Agent

You are a specialized frontend development agent...

[Agent system prompt continues]
```

#### Standard Agent Types

| Agent | Domain | Key Validators |
|-------|--------|----------------|
| `frontend-coder` | Vue/React components, styling | tdd-guard, lint, typecheck |
| `api-builder` | Convex/backend, schemas | convex-schema, test-suite |
| `spec-writer` | OpenSpec proposals, planning | spec-format, spec-actionable |
| `test-writer` | Test creation, coverage | no-implementation-mocks, coverage-check |
| `unblocker` | Dependency resolution | (dynamic based on blocker) |

### 2. Agent Registry

**File:** `.claude/agents/registry.json`

```json
{
  "$schema": "./registry.schema.json",
  "version": "1.0.0",
  "agents": {
    "frontend-coder": {
      "definition": ".claude/agents/frontend-coder.md",
      "enabled": true,
      "isolation_default": "task",
      "isolation_threshold": {
        "complexity": "high",
        "upgrade_to": "worktree"
      }
    },
    "api-builder": {
      "definition": ".claude/agents/api-builder.md",
      "enabled": true,
      "isolation_default": "task"
    },
    "spec-writer": {
      "definition": ".claude/agents/spec-writer.md",
      "enabled": true,
      "isolation_default": "task"
    },
    "test-writer": {
      "definition": ".claude/agents/test-writer.md",
      "enabled": true,
      "isolation_default": "task"
    },
    "unblocker": {
      "definition": ".claude/agents/unblocker.md",
      "enabled": true,
      "isolation_default": "worktree"
    }
  },
  "orchestrator": {
    "max_parallel_agents": 3,
    "checkpoint_interval": 5,
    "metrics_file": ".claude/agents/metrics.json",
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
    "tdd-guard": ".claude/validators/tdd-guard.sh",
    "lint": "pnpm lint",
    "typecheck": "pnpm type-check",
    "test-suite": ".claude/validators/test-suite.sh",
    "convex-schema": ".claude/validators/convex-schema.sh",
    "spec-format": ".claude/validators/spec-format.py",
    "spec-actionable": ".claude/validators/spec-actionable.py",
    "coverage-check": ".claude/validators/coverage-check.sh",
    "no-implementation-mocks": ".claude/validators/no-implementation-mocks.sh"
  }
}
```

### 3. Metrics Storage

**File:** `.claude/agents/metrics.json`

```json
{
  "updated_at": "2026-01-20T14:30:00Z",
  "agents": {
    "frontend-coder": {
      "success_rate": 0.87,
      "total_tasks_completed": 47,
      "total_tasks_failed": 7,
      "avg_tasks_per_session": 4.2,
      "avg_iterations_to_complete": 2.1,
      "time_to_first_commit_avg_seconds": 180,
      "recent_sessions": [
        {
          "timestamp": "2026-01-20T10:15:00Z",
          "tasks_completed": 5,
          "tasks_failed": 0,
          "iterations": 11,
          "duration_seconds": 1840
        }
      ],
      "by_task_type": {
        "component": { "success_rate": 0.91, "count": 32 },
        "styling": { "success_rate": 0.85, "count": 12 }
      }
    }
  },
  "global": {
    "total_orchestration_sessions": 23,
    "total_tasks_completed": 134,
    "avg_parallel_utilization": 2.1,
    "most_common_blockers": [
      "missing type export",
      "test fixture not found"
    ]
  }
}
```

### 4. PRD.json Format (Task Graph)

```json
{
  "$schema": ".claude/schemas/prd.schema.json",
  "version": "1.0.0",
  "change_id": "add-stache-collections",
  "created_at": "2026-01-20T09:00:00Z",
  "updated_at": "2026-01-20T14:30:00Z",

  "context": {
    "summary": "Add collections feature for organizing saved articles",
    "proposal": "openspec/changes/add-stache-collections/proposal.md",
    "design": "openspec/changes/add-stache-collections/design.md",
    "success_criteria": {
      "tests_pass": "pnpm test",
      "lint_clean": "pnpm lint",
      "coverage_minimum": 80
    }
  },

  "sections": [
    {
      "number": 1,
      "name": "Schema & Types",
      "status": "completed",
      "tasks": [
        {
          "id": "1.1",
          "description": "Define Collection schema in Convex",
          "agent_type": "api-builder",
          "status": "completed",
          "depends_on": [],
          "blocks": ["1.2", "2.1", "2.2"],
          "files": ["packages/convex/convex/schema.ts"],
          "complexity": "low",
          "completed_at": "2026-01-20T09:45:00Z",
          "completed_by": "api-builder"
        }
      ]
    }
  ],

  "queue": {
    "ready": ["2.3", "3.2"],
    "in_progress": ["2.2"],
    "blocked": ["3.1", "3.3"],
    "completed": ["1.1", "1.2", "2.1"]
  },

  "summary": {
    "total_sections": 4,
    "total_tasks": 11,
    "completed_tasks": 3,
    "progress_percent": 27.3
  },

  "discovered_dependencies": []
}
```

#### Task Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (e.g., "2.3") |
| `description` | string | What needs to be done |
| `agent_type` | string | Suggested agent for this task |
| `status` | enum | pending, in_progress, completed, blocked |
| `depends_on` | string[] | Task IDs that must complete first |
| `blocks` | string[] | Task IDs waiting on this task |
| `files` | string[] | Files this task will touch |
| `complexity` | enum | low, medium, high |
| `assigned_to` | string? | Agent currently working on this |
| `completed_by` | string? | Agent that completed this |

### 5. Validators

Validators are deterministic scripts that enforce invariants.

#### Exit Code Protocol

| Exit Code | Meaning | Effect |
|-----------|---------|--------|
| 0 | Pass | Operation continues |
| 1 | Warning | Operation continues with message |
| 2 | Block | Operation stopped, error returned to agent |

#### Hook Input Format

Validators receive JSON on stdin:

```json
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "/path/to/file.ts",
    "old_string": "...",
    "new_string": "..."
  }
}
```

#### Standard Validators

**tdd-guard.sh** (PreToolUse)
- Blocks edits to implementation files without corresponding test files
- Exempts: test files, type files, config, etc.
- Checks test file has actual test cases

**test-suite.sh** (Stop)
- Runs tests for modified packages
- Detects packages from git diff
- Fails if any test fails

**coverage-check.sh** (Stop)
- Runs tests with coverage
- Fails if below minimum threshold (default 80%)

**convex-schema.sh** (PostToolUse)
- TypeScript compilation check
- Convex schema validation
- Warns on breaking changes (table removal)

**spec-format.py** (PostToolUse)
- Validates proposal.md has required sections
- Validates tasks.md has numbered sections with checkboxes
- Checks for empty sections

**spec-actionable.py** (Stop)
- Checks tasks are specific (not vague)
- Checks design has no unresolved TODOs
- Ensures spec is ready for implementation

**no-implementation-mocks.sh** (PostToolUse)
- Detects when tests mock the implementation itself
- Warns on excessive mocking (>5 mocks)

### 6. Orchestrator

The orchestrator is a shell script with Claude checkpoints for intelligent decisions.

#### Shell Responsibilities (Deterministic)

- Parse PRD.json task graph
- Spawn and monitor agent processes
- Track timing metrics
- Manage worktrees for isolation
- Detect stop signals in agent output
- Update PRD.json status

#### Claude Checkpoints (Intelligent)

| Checkpoint | Trigger | Purpose |
|------------|---------|---------|
| Queue Planning | Every N iterations | Decide which agents work on which tasks |
| Blocker Resolution | Agent reports BLOCKED | Determine how to unblock |
| Dependency Discovery | Agent reports DISCOVERED_DEPENDENCY | Update task graph |
| Conflict Detection | Two agents touch same file | Reconcile changes |
| Prompt Adaptation | Agent fails 3x on similar tasks | Adjust prompts |
| Completion Review | Section complete | Validate ready for PR |

#### Main Loop

```
1. Read PRD.json, build dependency graph
2. Claude checkpoint: Queue Planning
3. Dispatch agents to ready tasks (up to max_parallel)
4. Wait for agent completion signals
5. Process signals:
   - TASK_COMPLETE → update PRD, check section complete
   - BLOCKED → Claude checkpoint: Blocker Resolution
   - DISCOVERED_DEPENDENCY → Claude checkpoint: Update graph
6. Check stop conditions:
   - All tasks complete → finish
   - Section target complete → PR checkpoint
   - Max iterations → pause
7. Repeat from step 2
```

### 7. Progress Log

**File:** `openspec/changes/<change-id>/progress.md`

Append-only log preserving context across sessions.

```markdown
# Progress: add-stache-collections

---

## Session: 2026-01-20T14:30:00Z

**Configuration:**
- Max parallel: 2
- Section target: all
- Max iterations: 50

### Task 1.1 (completed)
- **Agent:** api-builder
- **Time:** 2026-01-20T14:32:15Z
- **Details:** TASK_COMPLETE: 1.1

### Orchestrator Learning Note
- Pattern detected: Schema tasks should list required indexes
- Recommendation: Future PRDs include index requirements

### Session Summary
- **Ended:** 2026-01-20T16:45:00Z
- **Reason:** SECTION_COMPLETE: 2
- **Tasks completed:** 6
- **Iterations:** 28
```

## Directory Structure

```
.claude/
├── agents/
│   ├── registry.json              # Agent index + config
│   ├── registry.schema.json       # JSON schema
│   ├── metrics.json               # Performance tracking
│   ├── frontend-coder.md          # Agent definitions
│   ├── api-builder.md
│   ├── spec-writer.md
│   ├── test-writer.md
│   └── unblocker.md
├── orchestrator/
│   ├── svao.sh                    # Main orchestrator
│   ├── compile.sh                 # OpenSpec → PRD compiler
│   ├── status.sh                  # Progress checker
│   └── checkpoints/
│       ├── queue-planning.md
│       ├── blocker-resolution.md
│       ├── completion-review.md
│       ├── dependency-discovery.md
│       ├── conflict-detection.md
│       └── prompt-adaptation.md
├── validators/
│   ├── tdd-guard.sh
│   ├── test-suite.sh
│   ├── coverage-check.sh
│   ├── convex-schema.sh
│   ├── spec-format.py
│   ├── spec-actionable.py
│   └── no-implementation-mocks.sh
├── schemas/
│   ├── prd.schema.json
│   └── registry.schema.json
└── hooks/
    └── index.ts                   # Project hook router
```

## Usage

### Starting a Feature

```bash
# 1. Create OpenSpec proposal
claude "Create an OpenSpec proposal for adding collections feature"

# 2. Compile to PRD
.claude/orchestrator/compile.sh add-stache-collections

# 3. Run orchestrator
.claude/orchestrator/svao.sh add-stache-collections --max-parallel 2
```

### Command Reference

```bash
# Compile OpenSpec to PRD
.claude/orchestrator/compile.sh <change-id>
.claude/orchestrator/compile.sh <change-id> --section 2

# Run orchestrator
.claude/orchestrator/svao.sh <change-id>
.claude/orchestrator/svao.sh <change-id> --section 2
.claude/orchestrator/svao.sh <change-id> --max-parallel 3
.claude/orchestrator/svao.sh <change-id> --max-iterations 20

# Check status
.claude/orchestrator/status.sh <change-id>

# View metrics
cat .claude/agents/metrics.json | jq '.agents["frontend-coder"]'
```

## Implementation Priorities

### Phase 1: Foundation
1. Validator scripts (tdd-guard, test-suite, coverage-check)
2. Agent definition format and registry
3. Basic orchestrator loop (single agent)

### Phase 2: Parallelization
4. PRD.json format and compiler
5. Multi-agent dispatch with task isolation
6. Worktree isolation for complex tasks

### Phase 3: Intelligence
7. Claude checkpoints (queue planning, blocker resolution)
8. Metrics tracking and storage
9. Completion review and PR creation

### Phase 4: Learning
10. Progress log analysis
11. Prompt adaptation based on outcomes
12. Pattern detection and recommendations

## Design Decisions

### Why Shell + Claude Hybrid?

Shell provides reliability and speed for deterministic operations. Claude provides judgment for decisions that require understanding context. Separating concerns keeps the system debuggable and predictable.

### Why Deterministic Validators?

LLM reviewers can rationalize issues or miss edge cases. Deterministic scripts provide binary pass/fail that can't be fooled. If the test suite passes, it passes—no interpretation needed.

### Why Task-Level Parallelization?

File-level locking is too coarse (blocks valid parallel work). Optimistic + reconciliation is too complex (merge conflicts). Task-level with dependency tracking provides the right balance.

### Why Metrics in Separate File?

Agent definitions should be declarative config. Metrics are mutable state. Separating them keeps definitions clean and makes metrics easy to update programmatically.

## Success Criteria

The framework is successful when:

1. **Self-correction works** — Agents adapt to hook feedback without human intervention
2. **Parallel efficiency** — 2-3x speedup over sequential execution
3. **Quality maintained** — Same or better code quality vs single-agent approach
4. **Learning visible** — Metrics show improvement over sessions
5. **Blockers resolved** — Most blockers handled by unblocker agent, not humans

## Open Questions

1. **Cross-project sharing** — Should agents/validators be per-project or shared in ~/.claude?
2. **Remote execution** — Could agents run on remote machines for more parallelism?
3. **Cost tracking** — Should we track token usage per agent for optimization?
4. **Rollback** — How to handle partial failures that need rollback?

## References

- [agentic-finance-review](https://github.com/disler/agentic-finance-review) — Self-validating agent patterns
- [Claude Code Hooks](https://code.claude.com/docs/en/hooks) — Hook system documentation
- [Claude Code Subagents](https://code.claude.com/docs/en/sub-agents) — Subagent orchestration
- [Superpowers Plugin](https://github.com/obra/superpowers-marketplace) — Subagent-driven development
