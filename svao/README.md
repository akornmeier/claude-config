# SVAO - Self-Validating Agent Orchestra

SVAO is a parallel agent orchestration system for automated software development. It transforms human-authored task specifications into executable task graphs, then dispatches specialized AI agents to complete work in parallel while enforcing TDD practices.

## Quick Start

```bash
# 1. Create your task specification
mkdir -p openspec/changes/my-feature
vim openspec/changes/my-feature/tasks.md

# 2. Compile to PRD
svao.sh compile my-feature

# 3. Run parallel dispatch
svao.sh dispatch my-feature

# 4. Check status
svao.sh status my-feature
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SVAO Orchestrator                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Compiler   │───▶│  Dispatcher  │───▶│  Checkpoint  │      │
│  │  (prd.json)  │    │   (parallel) │    │   (Claude)   │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│          │                  │                   │               │
│          ▼                  ▼                   ▼               │
│  ┌──────────────────────────────────────────────────────┐      │
│  │                    Agent Pool                         │      │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │      │
│  │  │ frontend-  │  │   api-     │  │   test-    │     │      │
│  │  │   coder    │  │  builder   │  │  writer    │     │      │
│  │  └────────────┘  └────────────┘  └────────────┘     │      │
│  └──────────────────────────────────────────────────────┘      │
│          │                  │                   │               │
│          ▼                  ▼                   ▼               │
│  ┌──────────────────────────────────────────────────────┐      │
│  │                    Validators                         │      │
│  │  [TDD Guard]  [Test Suite]  [Coverage]  [Spec Format]│      │
│  └──────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

## Core Concepts

### OpenSpec Format

Tasks are defined in `tasks.md` using a strict markdown format:

```markdown
# Feature Name

## 1. Database Layer

- [ ] 1.1 Create User schema (files: src/db/schema/user.ts)
- [ ] 1.2 Add User migrations (files: src/db/migrations/001_user.ts) (depends: 1.1)
- [ ] 1.3 Create User repository (files: src/db/repos/user.ts) (depends: 1.1)

## 2. API Layer

- [ ] 2.1 User API types (files: src/api/types/user.ts) (depends: 1.1)
- [ ] 2.2 GET /users endpoint (files: src/api/routes/users.ts) (depends: 1.3, 2.1)
- [ ] 2.3 POST /users endpoint (files: src/api/routes/users.ts) (depends: 1.3, 2.1)

## 3. Frontend

- [ ] 3.1 UserCard component (files: src/components/UserCard.vue) (agent: frontend-coder)
- [ ] 3.2 UserList page (files: src/pages/users.vue) (depends: 3.1, 2.2)
```

**Required annotations:**
- `(files: path1, path2)` - Files this task will modify

**Optional annotations:**
- `(depends: 1.1, 1.2)` - Explicit dependencies
- `(agent: frontend-coder)` - Override agent type
- `(complexity: high)` - Hint for isolation level

### Immutable vs Mutable Files

| File | Owner | Mutability |
|------|-------|------------|
| `prd.json` | Compiler | **IMMUTABLE** - Original spec, never modified |
| `prd-state.json` | Orchestrator | **MUTABLE** - Status, queue, metrics |
| `progress.md` | Orchestrator | **APPEND-ONLY** - Human-readable log |

This separation ensures the original specification is honored and prevents scope creep during execution.

### Dependency Inference

The compiler automatically infers dependencies using multiple signals:

| Signal | Confidence | Example |
|--------|------------|---------|
| Explicit `(depends: X.Y)` | 100% | Author-specified |
| File pattern match | 85% | `types/User.ts` → `UserCard.vue` |
| Keyword matching | 50% | "mutation" task after "schema" task |
| Section order | 25% | Section N after N-1 |

- **Confidence ≥70%**: Applied automatically
- **Confidence <70%**: Flagged for human review

## Commands

### `svao.sh compile <change-id>`

Compiles OpenSpec to PRD (Product Requirements Document).

```bash
svao.sh compile my-feature
svao.sh compile my-feature --dry-run        # Preview without writing
svao.sh compile my-feature --skip-inference # No automatic dependencies
svao.sh compile my-feature --strict         # Fail on warnings
```

**Input:** `openspec/changes/<change-id>/tasks.md`
**Output:** `prd.json` + `prd-state.json`

### `svao.sh dispatch <change-id>`

Runs the parallel dispatch loop.

```bash
svao.sh dispatch my-feature
svao.sh dispatch my-feature --max-parallel 5   # Run 5 agents concurrently
svao.sh dispatch my-feature --max-iterations 100
svao.sh dispatch my-feature --resume           # Resume interrupted session
```

**What happens:**
1. Loads PRD and state
2. Identifies ready tasks (no unmet dependencies)
3. Dispatches agents in parallel (up to max-parallel)
4. Monitors completion, handles failures with retries
5. Triggers checkpoints for adaptive orchestration
6. Creates PRs for completed sections

### `svao.sh status <change-id>`

Shows current execution status.

```bash
svao.sh status my-feature
```

Output:
```
Progress: 5/12 (41.7%)
Ready: 2 | In Progress: 3 | Blocked: 2

Ready tasks:
  - 2.3
  - 3.1

In progress:
  - 2.1 (api-builder)
  - 2.2 (api-builder)
  - 1.3 (api-builder)
```

### `svao.sh run <agent-type> <task>`

Run a single agent with a task description (useful for testing).

```bash
svao.sh run frontend-coder "Create a Button component with hover states"
svao.sh run api-builder "Add GET /users/:id endpoint"
svao.sh run test-writer "Write tests for UserRepository"
```

### `svao.sh checkpoint <type> <change-id>`

Manually invoke a checkpoint.

```bash
svao.sh checkpoint queue-planning my-feature --dry-run
svao.sh checkpoint completion-review my-feature --section 2
svao.sh checkpoint blocker-resolution my-feature --task 2.3
```

### `svao.sh pr <change-id> <section>`

Create a PR for a completed section.

```bash
svao.sh pr my-feature 1
```

### `svao.sh list`

List available agents and validators.

### `svao.sh validate <file>`

Run validators on a file (useful for testing hooks).

### `svao.sh test-hooks`

Test that SVAO validators are working correctly.

## Agents

### frontend-coder

Implements UI components with strict TDD practices.

**Capabilities:** Vue, React, TypeScript, CSS, animations
**File patterns:** `src/components/**`, `src/composables/**`, `apps/web/**`
**Keywords:** UI, component, frontend, styling

### api-builder

Builds backend APIs, database schemas, and server-side logic.

**Capabilities:** REST APIs, GraphQL, database schemas, migrations
**File patterns:** `src/api/**`, `src/db/**`, `server/**`
**Keywords:** API, endpoint, schema, mutation, query

### test-writer

Creates comprehensive test suites.

**Capabilities:** Unit tests, integration tests, E2E tests
**File patterns:** `**/*.test.ts`, `**/*.spec.ts`, `tests/**`
**Keywords:** test, spec, coverage

## Validators

### TDD Guard (`tdd-guard.sh`)

**Hook:** PreToolUse on Edit/Write

Enforces test-first development:
- Blocks editing implementation files without corresponding tests
- Exempts type definitions, configs, and test files themselves

### Test Suite (`test-suite.sh`)

**Hook:** Stop

Runs test suite when agent stops to verify work.

### Coverage Check (`coverage-check.sh`)

Verifies test coverage thresholds.

### Spec Format (`spec-format.py`)

Validates OpenSpec proposal.md format.

## Checkpoints

Checkpoints are Claude-powered decision points that adapt orchestration:

### queue-planning

**Trigger:** Every N iterations (configurable)

Decides which tasks to dispatch next, considering:
- File conflicts between parallel tasks
- Agent availability and performance
- Task priorities and dependencies

**Commands issued:**
- `DISPATCH: task-id:agent:isolation`
- `REORDER: task-id, task-id, ...`

### completion-review

**Trigger:** When all tasks in a section complete

Reviews section work before creating PR:
- Verifies tests pass
- Checks code quality
- Approves or requests rework

**Commands issued:**
- `APPROVED: section-number`
- `NEEDS_WORK: section-number:reason`

### blocker-resolution

**Trigger:** When a task fails after max retries

Decides how to handle blocked tasks:
- Try alternate agent
- Skip and continue
- Escalate to human

**Commands issued:**
- `UNBLOCK: task-id:alternate-agent:agent-name`
- `UNBLOCK: task-id:skip-and-continue`
- `UNBLOCK: task-id:escalate:reason`

## Directory Structure

```
openspec/changes/<change-id>/
├── proposal.md          # Human-authored problem/solution
├── tasks.md             # Human-authored task list (OpenSpec format)
├── design.md            # Human-authored design (optional)
├── prd.json             # Compiler output (IMMUTABLE)
├── prd-state.json       # Orchestrator state (MUTABLE)
└── progress.md          # Append-only execution log

.claude/svao/
├── orchestrator/
│   ├── svao.sh          # Main entry point
│   ├── compile.sh       # PRD compiler
│   ├── dispatch.sh      # Parallel dispatch loop
│   ├── parser.py        # Task parser
│   ├── inference.py     # Dependency inference
│   ├── pr-creator.sh    # PR creation
│   ├── progress-writer.sh
│   ├── status-writer.sh
│   └── checkpoints/
│       ├── invoke.sh    # Checkpoint invoker
│       ├── parser.sh    # Output validator
│       └── templates/   # Prompt templates
├── agents/
│   ├── registry.json    # Agent configuration
│   ├── metrics.json     # Global metrics
│   ├── frontend-coder.md
│   ├── api-builder.md
│   └── test-writer.md
├── validators/
│   ├── tdd-guard.sh
│   ├── test-suite.sh
│   ├── coverage-check.sh
│   └── spec-format.py
└── schemas/
    ├── prd.schema.json
    ├── prd-state.schema.json
    └── registry.schema.json
```

## Configuration

### registry.json

Configure agents, orchestrator settings, and validators:

```json
{
  "agents": {
    "frontend-coder": {
      "definition": ".claude/svao/agents/frontend-coder.md",
      "enabled": true,
      "isolation_default": "task"
    }
  },
  "orchestrator": {
    "max_parallel_agents": 3,
    "checkpoint_interval": 5
  }
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_PARALLEL` | 3 | Maximum concurrent agents |
| `MAX_ITERATIONS` | 50 | Maximum dispatch iterations |
| `MAX_RETRIES` | 3 | Retries before marking blocked |
| `POLL_INTERVAL` | 5 | Seconds between status checks |
| `CHECKPOINT_INTERVAL` | 5 | Iterations between checkpoints |

## Example Workflow

```bash
# 1. Define your feature in OpenSpec format
cat > openspec/changes/user-auth/tasks.md << 'EOF'
# User Authentication

## 1. Database

- [ ] 1.1 Create sessions table (files: src/db/schema/session.ts)
- [ ] 1.2 Add session repository (files: src/db/repos/session.ts) (depends: 1.1)

## 2. API

- [ ] 2.1 Login endpoint (files: src/api/auth/login.ts) (depends: 1.2)
- [ ] 2.2 Logout endpoint (files: src/api/auth/logout.ts) (depends: 1.2)
- [ ] 2.3 Auth middleware (files: src/middleware/auth.ts) (depends: 1.2)

## 3. Frontend

- [ ] 3.1 LoginForm component (files: src/components/LoginForm.vue) (agent: frontend-coder)
- [ ] 3.2 Auth composable (files: src/composables/useAuth.ts) (depends: 2.1, 2.2)
- [ ] 3.3 Protected route wrapper (files: src/components/ProtectedRoute.vue) (depends: 3.2)
EOF

# 2. Compile to PRD
svao.sh compile user-auth

# 3. Review inferred dependencies
cat openspec/changes/user-auth/prd.json | jq '.dependencies'

# 4. Start parallel execution
svao.sh dispatch user-auth --max-parallel 3

# 5. Monitor progress
svao.sh status user-auth

# 6. PRs are created automatically for completed sections
```

## Troubleshooting

### "Change directory not found"

Ensure your change is in one of these locations:
- `openspec/changes/<change-id>/`
- `.claude/changes/<change-id>/`

### "PRD not found"

Run `svao.sh compile <change-id>` first.

### "Detected interrupted session"

Use `--resume` to continue or re-compile to start fresh:
```bash
svao.sh dispatch my-feature --resume
# or
svao.sh compile my-feature && svao.sh dispatch my-feature
```

### Agent keeps failing

Check the task's status file in `/tmp/svao/<session-id>/<task-id>.status.json` for error details. The orchestrator will try alternate agents after max retries.

## License

MIT
