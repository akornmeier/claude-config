# SVAO Phase 2: PRD Compiler & Parallel Dispatch Design

**Date:** 2026-01-20
**Status:** Draft
**Depends on:** Phase 1 (validators, agent definitions, single-agent orchestrator)

## Executive Summary

Phase 2 extends SVAO with parallel agent dispatch, a PRD compiler that transforms OpenSpec into executable task graphs, and an intelligent checkpoint system for adaptive orchestration. Key design decisions:

- **Immutable/mutable separation** — `prd.json` (spec) is never modified after compilation; `prd-state.json` tracks execution
- **Strict OpenSpec format** — Compiler validates and fails fast on malformed input
- **Dependency inference** — Multi-signal inference with confidence scoring; high-confidence auto-applied, low-confidence flagged for review
- **Adaptive failure recovery** — Same agent retry → alternate agent → unblocker → human escalation
- **Configurable checkpoints** — Per-project settings for checkpoint types and frequency

## File Structure

```
openspec/changes/<change-id>/
├── proposal.md          # Human-authored (input)
├── tasks.md             # Human-authored (input)
├── design.md            # Human-authored (optional input)
├── prd.json             # Compiler output (IMMUTABLE)
├── prd-state.json       # Orchestrator managed (MUTABLE)
└── progress.md          # Append-only learning log
```

### Immutable vs Mutable

| File | Owner | Contents | Mutability |
|------|-------|----------|------------|
| `prd.json` | Compiler | Task definitions, dependencies, success criteria | IMMUTABLE after creation |
| `prd-state.json` | Orchestrator | Status, queue, assignments, retries, metrics | MUTABLE |

The orchestrator **never writes to prd.json**. This ensures the original spec is honored and prevents scope creep during execution.

## PRD Compiler

### Command

```bash
.claude/svao/orchestrator/compile.sh <change-id> [options]

Options:
  --dry-run         Show what would be generated without writing
  --skip-inference  Don't infer dependencies, only use explicit
  --strict          Fail on any validation warning
```

### Input Format (Strict)

The compiler requires strict OpenSpec format in `tasks.md`:

```markdown
# Feature Name

## 1. Section Name

- [ ] 1.1 Task description (files: path/to/file.ts)
- [ ] 1.2 Another task (files: path/a.ts, path/b.ts)
- [ ] 1.3 Task with explicit dep (files: x.ts) (depends: 1.1)
- [ ] 1.4 Complex task (files: y.ts) (agent: test-writer) (complexity: high)

## 2. Next Section

- [ ] 2.1 Task description (files: component.vue)
```

**Required elements:**
- Numbered sections: `## N. Name`
- Task IDs matching section: `N.X`
- Checkbox format: `- [ ]` or `- [x]`
- Files annotation: `(files: path1, path2)`

**Optional elements:**
- Explicit dependencies: `(depends: 1.1, 1.2)`
- Agent override: `(agent: test-writer)`
- Complexity hint: `(complexity: high)`

### Dependency Inference Engine

The compiler infers dependencies using multiple signals with confidence scoring:

| Signal | Confidence | Example |
|--------|------------|---------|
| Explicit `(depends: X.Y)` | 100% | Author-specified |
| File pattern match | 85% | `types/User.ts` → `UserCard.vue` |
| Package boundary | 75% | `@app/web` imports `@app/types` |
| Keyword matching | 50% | Task mentions "mutation", earlier task is "schema" |
| Section order | 25% | Section N depends on N-1 (fallback) |

**Application rules:**
- Confidence ≥70%: Applied automatically
- Confidence <70%: Flagged for human review

### Compiler Output

**prd.json** (immutable spec):

```json
{
  "$schema": ".claude/svao/schemas/prd.schema.json",
  "version": "1.0.0",
  "change_id": "add-stache-collections",
  "compiled_at": "2026-01-20T14:00:00Z",
  "source_hash": "sha256:abc123...",

  "context": {
    "summary": "Add collections feature for organizing saved articles",
    "proposal_file": "proposal.md",
    "design_file": "design.md"
  },

  "success_criteria": {
    "tests_pass": "pnpm test",
    "lint_clean": "pnpm lint",
    "type_check": "pnpm type-check"
  },

  "sections": [
    {
      "number": 1,
      "name": "Schema & Types",
      "tasks": [
        {
          "id": "1.1",
          "description": "Define Collection schema in Convex",
          "files": ["packages/convex/convex/schema.ts"],
          "agent_type": "api-builder",
          "complexity": "low",
          "depends_on": [],
          "blocks": ["1.2", "2.1", "2.2"]
        }
      ]
    }
  ],

  "dependencies": {
    "explicit": [
      { "from": "1.2", "to": "1.1" }
    ],
    "inferred": [
      { "from": "3.2", "to": "2.1", "confidence": 85, "reason": "file pattern: CollectionCard uses Collection type" }
    ],
    "pending_review": [
      { "from": "4.1", "to": "2.3", "confidence": 45, "reason": "keyword match: both mention 'relationship'" }
    ]
  },

  "summary": {
    "total_sections": 4,
    "total_tasks": 11,
    "explicit_dependencies": 8,
    "inferred_dependencies": 6,
    "pending_review": 2
  }
}
```

### Compiler CLI Output

```
$ svao.sh compile add-stache-collections

✓ Validated proposal.md
✓ Parsed tasks.md (4 sections, 11 tasks)
✓ Inferred 8 dependencies (6 high-confidence, 2 need review)
✓ Written: prd.json (sha256:abc123...)
✓ Initialized: prd-state.json

⚠️  Review suggested dependencies:
   - 3.2 → 1.1 (keyword: "types", confidence: 45%)
   - 4.1 → 2.3 (file pattern: "Collection", confidence: 62%)

Commands:
  svao.sh deps confirm add-stache-collections    # Accept all pending
  svao.sh deps review add-stache-collections     # Interactive review
  svao.sh deps reject add-stache-collections 1   # Reject specific
```

## Parallel Dispatch Engine

### Queue Management

The dispatch loop manages concurrent agents while respecting dependencies:

```
while tasks remain:
  1. Read prd.json (immutable spec)
  2. Read prd-state.json (current execution state)

  3. Build ready queue:
     ready = tasks where:
       - status == "pending"
       - all depends_on are "completed"
       - not at retry limit

  4. Check checkpoint triggers
  5. Dispatch up to (max_parallel - active_count) agents
  6. Poll status files for active agents
  7. Process completed/failed agents
  8. Update prd-state.json
  9. Sleep(poll_interval)
```

### Agent Status Files

Each agent writes structured status to `/tmp/svao/<session-id>/<task-id>.status.json`:

**Running:**
```json
{
  "task_id": "2.3",
  "agent": "api-builder",
  "pid": 12345,
  "started_at": "2026-01-20T14:30:00Z",
  "updated_at": "2026-01-20T14:32:15Z",
  "status": "running",
  "phase": "implementing",
  "files_touched": ["packages/convex/convex/collections.ts"],
  "commits": ["abc123"],
  "progress": "Writing mutation tests..."
}
```

**Completed:**
```json
{
  "status": "completed",
  "signal": "TASK_COMPLETE",
  "files_changed": ["collections.ts", "collections.test.ts"],
  "commits": ["abc123", "def456"],
  "discovered_dependencies": [],
  "duration_seconds": 185
}
```

**Failed:**
```json
{
  "status": "failed",
  "signal": "BLOCKED:TESTS",
  "error": "Test 'should create collection' failing after 3 attempts",
  "retry_count": 2,
  "last_error_output": "AssertionError: expected undefined..."
}
```

### Adaptive Failure Recovery

```
on_agent_failure(task, agent, error):

  # Stage 1: Retry with same agent (up to max_retries)
  if retry_count < max_retries:
    respawn_agent(task, agent, context=error)
    return

  # Stage 2: Try alternate agent
  alternate = find_alternate_agent(task, excluding=agent)
  if alternate and not tried(task, alternate):
    spawn_agent(task, alternate, context=error)
    return

  # Stage 3: Escalate to unblocker
  if not tried(task, "unblocker"):
    spawn_unblocker(task, error, original_agent=agent)
    return

  # Stage 4: Mark blocked, trigger checkpoint
  mark_blocked(task, error)
  trigger_checkpoint("blocker-resolution", task)
```

**Alternate agent selection logic:**
- Implementation task failed → try `test-writer` (maybe tests missing)
- Test task failed → try original implementation agent
- Check capability overlap in registry

## Checkpoint System

### Configuration

In `registry.json`:

```json
{
  "orchestrator": {
    "checkpoints": {
      "enabled": true,
      "interval": 5,
      "types": {
        "queue-planning": { "enabled": true, "trigger": "interval" },
        "blocker-resolution": { "enabled": true, "trigger": "event" },
        "dependency-discovery": { "enabled": true, "trigger": "event", "auto_apply_confidence": 80 },
        "completion-review": { "enabled": true, "trigger": "event" },
        "prompt-adaptation": { "enabled": false, "trigger": "threshold", "failure_threshold": 3 },
        "conflict-detection": { "enabled": true, "trigger": "event" }
      }
    }
  }
}
```

### Checkpoint Contract

**Inputs (read-only):**
- prd.json (immutable spec)
- prd-state.json (current state)
- progress.md (history)
- metrics.json (agent performance)
- Event-specific context

**Allowed outputs:**
| Command | Description |
|---------|-------------|
| `DISPATCH: task:agent:isolation` | Dispatch agent to task |
| `REORDER: t1, t2, t3` | Change execution priority |
| `REASSIGN: task:agent` | Change assigned agent |
| `ADD_DEPENDENCY: from:to:confidence` | Add discovered dependency |
| `UNBLOCK: task:strategy` | Attempt to unblock |
| `APPROVED` / `NEEDS_WORK` | Section review result |
| `WAIT: reason` | Hold dispatch |

**Forbidden outputs (rejected by orchestrator):**
- `MODIFY_TASK` — Cannot change task definitions
- `DELETE_TASK` — Cannot remove tasks
- `CHANGE_CRITERIA` — Cannot alter success criteria
- `ADD_TASK` — Cannot add new tasks

### Checkpoint Types

**Queue Planning** (interval)
- Decides which agents to dispatch
- Considers agent metrics, file overlap, dependency chains
- Output: DISPATCH commands

**Blocker Resolution** (event: agent BLOCKED)
- Analyzes failure and suggests recovery
- Output: UNBLOCK strategy or ESCALATE

**Dependency Discovery** (event: agent reports DISCOVERED_DEPENDENCY)
- Validates and applies discovered dependencies
- Output: ADD_DEPENDENCY or reject

**Completion Review** (event: section complete)
- Reviews completed work against spec
- Output: APPROVED or NEEDS_WORK

**Prompt Adaptation** (threshold: N failures)
- Adjusts agent prompts based on failure patterns
- Output: Updated prompt context

**Conflict Detection** (event: file overlap detected)
- Resolves when two agents touch same files
- Output: WAIT, REORDER, or merge strategy

## prd-state.json Schema

```json
{
  "$schema": ".claude/svao/schemas/prd-state.schema.json",
  "version": "1.0.0",
  "change_id": "add-stache-collections",
  "prd_file": "prd.json",
  "prd_hash": "sha256:abc123...",

  "session": {
    "id": "svao-20260120-143000",
    "started_at": "2026-01-20T14:30:00Z",
    "updated_at": "2026-01-20T15:45:00Z",
    "iteration": 28,
    "status": "running"
  },

  "tasks": {
    "1.1": {
      "status": "completed",
      "assigned_to": "api-builder",
      "assigned_at": "2026-01-20T14:30:05Z",
      "completed_at": "2026-01-20T14:35:22Z",
      "duration_seconds": 317,
      "commits": ["abc1234"],
      "retries": 0
    },
    "2.3": {
      "status": "in_progress",
      "assigned_to": "api-builder",
      "assigned_at": "2026-01-20T15:40:00Z",
      "isolation": "task",
      "pid": 45678,
      "status_file": "/tmp/svao/svao-20260120-143000/2.3.status.json",
      "retries": 1,
      "retry_history": [
        { "agent": "api-builder", "error": "BLOCKED:TESTS", "timestamp": "2026-01-20T15:38:00Z" }
      ]
    }
  },

  "queue": {
    "ready": ["2.4", "3.2"],
    "in_progress": ["2.3"],
    "blocked": ["3.1", "3.3", "4.1"],
    "completed": ["1.1", "1.2", "2.1", "2.2"]
  },

  "discovered_dependencies": [
    {
      "from": "3.2",
      "to": "2.1",
      "confidence": 85,
      "reason": "file pattern: CollectionCard uses Collection type",
      "discovered_at": "2026-01-20T15:20:00Z",
      "discovered_by": "api-builder",
      "status": "applied"
    }
  ],

  "checkpoints": {
    "last_queue_planning": "2026-01-20T15:40:00Z",
    "last_iteration_at_checkpoint": 25,
    "history": []
  },

  "metrics": {
    "tasks_completed": 4,
    "tasks_failed": 1,
    "total_retries": 2,
    "agents_used": {
      "api-builder": { "completed": 3, "failed": 1 },
      "frontend-coder": { "completed": 1, "failed": 0 }
    },
    "avg_task_duration_seconds": 285,
    "parallel_utilization": 1.8
  },

  "summary": {
    "total_tasks": 11,
    "completed": 4,
    "in_progress": 1,
    "blocked": 3,
    "ready": 2,
    "pending": 1,
    "progress_percent": 36.4
  }
}
```

## Execution Flow

```
┌──────────────┐
│ svao.sh run  │
│ <change-id>  │
└──────┬───────┘
       │
       ▼
┌──────────────┐     ┌─────────────────┐
│ Load prd.json│────▶│ Validate hash   │
│ (immutable)  │     │ unchanged       │
└──────┬───────┘     └─────────────────┘
       │
       ▼
┌──────────────────┐
│ Load/create      │
│ prd-state.json   │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│ Build ready queue│◀────────────────────────────────┐
└──────┬───────────┘                                 │
       │                                             │
       ▼                                             │
┌──────────────────┐     ┌─────────────────┐        │
│ Checkpoint       │────▶│ Claude: queue   │        │
│ interval?        │     │ planning        │        │
└──────┬───────────┘     └────────┬────────┘        │
       │◀────────────────────────┘                  │
       ▼                                             │
┌──────────────────┐                                 │
│ Dispatch agents  │───▶ Agents write status files  │
└──────┬───────────┘                                 │
       │                                             │
       ▼                                             │
┌──────────────────┐                                 │
│ Poll status files│                                 │
└──────┬───────────┘                                 │
       │                                             │
       ├──────────────┬──────────────┐              │
       ▼              ▼              ▼              │
┌────────────┐ ┌────────────┐ ┌────────────┐       │
│ COMPLETE   │ │ FAILED     │ │ DISCOVERED │       │
└─────┬──────┘ └─────┬──────┘ └─────┬──────┘       │
      │              │              │               │
      │              ▼              ▼               │
      │       ┌────────────┐ ┌────────────┐        │
      │       │ Adaptive   │ │ Dependency │        │
      │       │ retry      │ │ checkpoint │        │
      │       └─────┬──────┘ └─────┬──────┘        │
      │             │              │               │
      ▼             ▼              ▼               │
┌─────────────────────────────────────────┐        │
│ Update prd-state.json                   │        │
└──────┬──────────────────────────────────┘        │
       │                                            │
       ▼                                            │
┌──────────────────┐     ┌─────────────────┐       │
│ Section complete?│────▶│ Claude:         │       │
│                  │     │ completion-review│       │
└──────┬───────────┘     └────────┬────────┘       │
       │◀────────────────────────┘                 │
       ▼                                            │
┌──────────────────┐                                │
│ All done?        │─── no ────────────────────────┘
└──────┬───────────┘
       │ yes
       ▼
┌──────────────────┐
│ Final summary    │
│ Update metrics   │
└──────────────────┘
```

## State Persistence

**Rules:**
1. Write prd-state.json after every status change
2. Use atomic writes (temp file + rename)
3. Validate prd.json hash on startup
4. Support resumption from crashed state

```bash
write_state() {
  local tmp_file="${STATE_FILE}.tmp.$$"
  jq '.session.updated_at = now | todate' "$STATE_FILE" > "$tmp_file"
  mv "$tmp_file" "$STATE_FILE"  # Atomic rename
}

validate_prd_unchanged() {
  local expected=$(jq -r '.prd_hash' "$STATE_FILE")
  local actual="sha256:$(sha256sum "$PRD_FILE" | cut -d' ' -f1)"

  if [[ "$expected" != "$actual" ]]; then
    log_error "prd.json modified externally! Aborting."
    exit 1
  fi
}
```

## CLI Commands (Phase 2)

```bash
# Compile OpenSpec to PRD
svao.sh compile <change-id>
svao.sh compile <change-id> --dry-run
svao.sh compile <change-id> --strict

# Manage dependencies
svao.sh deps review <change-id>      # Interactive review
svao.sh deps confirm <change-id>     # Accept all pending
svao.sh deps reject <change-id> <n>  # Reject specific

# Run orchestrator
svao.sh run <change-id>
svao.sh run <change-id> --max-parallel 3
svao.sh run <change-id> --section 2
svao.sh run <change-id> --checkpoint-interval 3

# Status and control
svao.sh status <change-id>
svao.sh pause <change-id>
svao.sh resume <change-id>

# View execution
svao.sh logs <change-id>
svao.sh logs <change-id> --task 2.3
```

## Implementation Priorities

### Phase 2a: Compiler
1. Task parser with strict validation
2. Dependency inference engine
3. prd.json generation
4. Dependency review CLI

### Phase 2b: Parallel Dispatch
5. prd-state.json management
6. Multi-process agent dispatch
7. Status file polling
8. Adaptive failure recovery

### Phase 2c: Checkpoints
9. Checkpoint prompt templates
10. Output validation (reject spec modifications)
11. Queue planning checkpoint
12. Completion review checkpoint
13. Blocker resolution checkpoint

### Phase 2d: Polish
14. Resume from crash
15. Progress visualization
16. Metrics aggregation
17. Section-based PR creation

## Open Questions

1. **Worktree strategy** — When should parallel agents use separate worktrees vs shared working directory?
2. **Checkpoint cost** — How to balance checkpoint frequency with API costs?
3. **Merge conflicts** — How to handle conflicts when merging worktree branches?
4. **Rollback** — Should failed sections be automatically rolled back?

## References

- [SVAO Phase 1 Design](./2026-01-20-self-validating-agent-orchestra-design.md)
- [Phase 1 Implementation Plan](./2026-01-20-svao-phase1-implementation.md)
