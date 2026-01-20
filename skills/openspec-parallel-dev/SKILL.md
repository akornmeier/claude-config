---
name: openspec-parallel-dev
description: Adapter for executing OpenSpec change proposals using subagent-driven-development. Parses OpenSpec structure, groups tasks by phase, and creates one PR per phase.
---

# OpenSpec Development Adapter

Converts OpenSpec change proposals into executable plans and delegates implementation to `superpowers:subagent-driven-development`.

## Prerequisites

- Active OpenSpec change with approved `proposal.md`
- Populated `tasks.md` with tasks organized by phase
- Clean git state on main branch

## Invocation

```
/openspec-parallel-dev <change-id>
```

Example: `/openspec-parallel-dev add-launch-features`

## Workflow

```
Parse OpenSpec → Extract phases → Per phase: branch + subagent-driven-dev + PR
```

---

## Step 1: Parse OpenSpec Structure

Read and extract from `openspec/changes/<change-id>/`:

1. **proposal.md** — identify phases/milestones
2. **tasks.md** — extract tasks, group by phase

```markdown
# Example tasks.md structure
## Phase 1: Core API
- [ ] Add user authentication endpoint
- [ ] Create data validation layer

## Phase 2: UI Components
- [ ] Build login form component
- [ ] Add dashboard layout
```

Extract unchecked tasks (`- [ ]`) grouped by their phase heading.

---

## Step 2: Execute Each Phase

For each phase with unchecked tasks:

### 2a. Create Phase Branch

```bash
git checkout main && git pull
git checkout -b feat/<change-id>-phase-N
```

### 2b. Prepare Plan for Subagent-Driven-Development

Convert phase tasks into a plan format:

```markdown
# Phase N: <Phase Name>

## Context
OpenSpec change: <change-id>
Spec reference: openspec/specs/<capability>/spec.md

## Tasks
1. <Task description from tasks.md>
2. <Task description from tasks.md>
...
```

### 2c. Invoke Subagent-Driven-Development

Follow the `superpowers:subagent-driven-development` workflow:
- Dispatch implementer subagent per task (sequential)
- Two-stage review: spec compliance → code quality
- Use TDD discipline throughout

The subagent-driven-development skill handles:
- Implementer prompts and self-review
- Spec compliance review
- Code quality review
- Retry loops for issues

### 2d. Create PR for Phase

When all phase tasks complete:

```bash
gh pr create \
  --title "feat(<change-id>): Phase N - <phase name>" \
  --body "## Summary
<bullet points of changes>

## OpenSpec Reference
- Change: openspec/changes/<change-id>/proposal.md
- Tasks: Phase N from tasks.md

## Test Coverage
<list of test files added/modified>"
```

---

## Step 3: Sync Progress to Source tasks.md

**Critical:** Keep `openspec/changes/<change-id>/tasks.md` updated as the source of truth.

### After Each Task Completes

When a task passes both reviews in subagent-driven-development:

1. Update the source file `openspec/changes/<change-id>/tasks.md`
2. Change `- [ ]` to `- [x]` for the completed task
3. Commit the update to the phase branch

```bash
# Example: mark task complete in source file
# In openspec/changes/add-launch-features/tasks.md:
# - [ ] Add user authentication endpoint  →  - [x] Add user authentication endpoint
git add openspec/changes/<change-id>/tasks.md
git commit -m "chore(openspec): mark task complete - <task description>"
```

### After Phase PR Created

Add PR reference to completed tasks:

```markdown
## Phase 1: Core API
- [x] Add user authentication endpoint (PR #142)
- [x] Create data validation layer (PR #142)
```

### Why This Matters

- **Resumability:** If execution stops mid-phase, progress isn't lost
- **Visibility:** Anyone can check `tasks.md` to see current status
- **Idempotency:** Re-running the skill skips already-completed tasks (`- [x]`)

---

## Step 4: Final Report

After all phases:

```markdown
## OpenSpec Development Complete: <change-id>

| Phase | Branch | PR | Status |
|-------|--------|-----|--------|
| Phase 1: Core API | feat/change-id-phase-1 | #142 | Ready |
| Phase 2: UI Components | feat/change-id-phase-2 | #143 | Ready |

### Next Steps
- Review and merge PRs in phase order
- Run again if tasks were added or skipped
```

---

## Integration

This skill is a thin adapter that delegates to:

| Skill | Purpose |
|-------|---------|
| `superpowers:subagent-driven-development` | Task execution, reviews, retry loops |
| `superpowers:test-driven-development` | TDD discipline (used by implementers) |
| `superpowers:finishing-a-development-branch` | Final cleanup if needed |

**Do not duplicate** the implementation/review logic from subagent-driven-development.
