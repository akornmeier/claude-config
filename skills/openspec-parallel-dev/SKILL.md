---
name: openspec-parallel-dev
description: Orchestrates parallel development of OpenSpec tasks using subagents. This skill should be used when implementing multiple tasks from an OpenSpec change proposal, enabling parallel execution of non-overlapping features with TDD, code review, and automated PR creation.
---

# OpenSpec Parallel Development

Orchestrate parallel subagent development for OpenSpec change proposals. Each task gets its own branch, follows TDD, undergoes code review, and produces a PR.

## Prerequisites

- Active OpenSpec change with approved `proposal.md`
- Populated `tasks.md` with numbered checklist items
- Clean git state on main branch
- All tests passing on main

## Invocation

```
/openspec-parallel-dev <change-id>
```

Example: `/openspec-parallel-dev add-launch-features`

## Workflow Overview

```
Read tasks.md → Coordinator analyzes → Dispatch parallel batches → Task agents (TDD) → Review agents → PRs
```

---

## Phase 1: Coordinator Agent

Spawn a coordinator subagent to analyze tasks and create an execution plan.

### Coordinator Responsibilities

1. Parse `openspec/changes/<change-id>/tasks.md`
2. Extract all unchecked tasks (`- [ ]`)
3. For each task, identify:
   - Target packages (convex, web, utils, etc.)
   - Files likely touched (inferred from task + codebase scan)
   - Dependencies on other tasks
4. Build dependency graph
5. Group into parallel batches:
   - Batch 1: Tasks with no dependencies
   - Batch 2: Tasks depending only on Batch 1
   - Within batches, verify no file overlap

### Coordinator Output

```yaml
execution_plan:
  batch_1:
    - task_id: 1
      description: "Add Pocket import API"
      packages: [convex, web]
      branch: feat/pocket-import
      skills: [superpowers:test-driven-development, feature-dev:feature-dev]
    - task_id: 2
      description: "Create browser extension"
      packages: [apps/extension]
      branch: feat/browser-extension
      skills: [superpowers:test-driven-development]
  batch_2:
    - task_id: 4
      description: "Add tagging system"
      depends_on: [1]
      packages: [convex, web]
      branch: feat/tagging
      skills: [superpowers:test-driven-development, shadcn-ui, frontend-design:frontend-design]
```

---

## Phase 2: Task Agent Dispatch

For each batch, dispatch task agents in parallel using the Task tool.

### Task Agent Skills (Hardcoded)

| Skill | When Used |
|-------|-----------|
| `superpowers:test-driven-development` | Always — core TDD discipline |
| `superpowers:systematic-debugging` | When tests fail unexpectedly |
| `shadcn-ui` | When implementing UI components |
| `frontend-design:frontend-design` | When creating new UI/pages |
| `feature-dev:feature-dev` | Guided feature development |
| `feature-dev:code-architect` | When designing component architecture |

### Task Agent Workflow

Each task agent executes this sequence:

#### Step 1: Setup

```bash
git checkout main && git pull
git checkout -b feat/<task-slug>
```

Read relevant spec from `openspec/specs/<capability>/spec.md` and task description.

#### Step 2: Implementation (TDD)

Invoke `superpowers:test-driven-development`:

1. **RED**: Write failing test for first requirement
2. **GREEN**: Write minimal code to pass
3. **REFACTOR**: Clean up, eliminate duplication
4. **REPEAT**: Until all spec requirements covered

Invoke `shadcn-ui`, `frontend-design:frontend-design` as needed for UI work.

#### Step 3: Verification

Run all checks — all must pass:

```bash
pnpm turbo run test --filter=<affected-packages>
pnpm turbo run lint
pnpm turbo run typecheck
pnpm format  # if available
```

If verification fails:
- Invoke `superpowers:systematic-debugging`
- Fix issues, re-run verification
- Max 2 retry attempts before marking as blocked

#### Step 4: Handoff to Reviewer

```bash
git add -A && git commit -m "feat(<scope>): <description>"
git push -u origin feat/<task-slug>
```

Signal: "Ready for review" with branch name, changed files, spec reference.

---

## Phase 3: Review Agent

Spawn a dedicated review agent for each completed task.

### Review Agent Skills (Hardcoded)

| Skill | Purpose |
|-------|---------|
| `pr-review-toolkit:code-reviewer` | Code quality, spec compliance |
| `chrome-debug` | Visual verification, environment setup |

### Review Agent Workflow

#### Step 1: Context Gathering

```bash
git checkout feat/<task-slug>
git diff main..HEAD
```

Read relevant spec and original task description.

#### Step 2: Static Review

Invoke `pr-review-toolkit:code-reviewer`:

- Spec compliance — all requirements addressed?
- Test coverage — scenarios from spec have tests?
- Code quality — no duplication, clear naming
- Security — no vulnerabilities, proper validation
- Style — matches project conventions

#### Step 3: Visual Review (if UI changes)

Invoke `chrome-debug`:

- Start dev server if needed (configure environment)
- Navigate to affected routes
- Take screenshots of key states
- Verify renders correctly, no visual regressions
- Check responsive behavior, dark mode if applicable

#### Step 4: Feedback Report

Output structured feedback:

- **CRITICAL**: Must fix before merge (blocks approval)
- **IMPORTANT**: Should fix, but not blocking
- **SUGGESTION**: Nice-to-have improvements

Verdict: `APPROVED` or `CHANGES_REQUESTED`

### Review Feedback Loop

```
Review Agent: CHANGES_REQUESTED (N critical issues)
     ↓
Task Agent resumed: Reads feedback, fixes issues
     ↓
Task Agent: Re-runs verification, commits, signals ready
     ↓
Review Agent (pass 2): Re-reviews changed areas
     ↓
If APPROVED → Create PR
If still CRITICAL issues → Escalate to NEEDS_INTERVENTION
```

**Max 2 review passes** — after that, escalate.

---

## Phase 4: PR Creation

For approved tasks:

```bash
gh pr create \
  --title "feat(<scope>): <task-description>" \
  --body "## Summary
- <bullet points of changes>

## Spec Reference
openspec/specs/<capability>/spec.md

## Test Coverage
- <list of test files added/modified>

## Review Notes
<any notes from review agent>"
```

For tasks needing intervention:

```bash
gh pr create --draft \
  --title "[WIP] feat(<scope>): <task-description>" \
  --body "## Summary
<changes made>

## Requires Manual Attention
<unresolved critical issues>

## Review History
<feedback from review passes>"
```

---

## Phase 5: Completion

After all batches complete:

### Collect Results

Gather status from all task agents:
- `COMPLETED` — PR created and ready
- `NEEDS_INTERVENTION` — Draft PR with issues
- `BLOCKED` — Failed after retries

### Update tasks.md

```markdown
- [x] 1. Completed task (PR #142)
- [x] 2. Another completed task (PR #143)
- [ ] 3. Task needing intervention (Draft PR #144)
- [ ] 4. Blocked task
```

Commit update to main.

### Final Report

```markdown
## OpenSpec Parallel Dev Complete: <change-id>

### Completed (<N>/<total> tasks)
| Task | Branch | PR |
|------|--------|-----|
| 1. Description | feat/branch | #142 |

### Needs Intervention (<N> tasks)
| Task | Issue | Draft PR |
|------|-------|----------|
| 3. Description | <issue summary> | #144 (draft) |

### Blocked (<N> tasks)
| Task | Failure Reason |
|------|----------------|
| 4. Description | <failure summary> |

### Next Steps
- Review draft PRs and resolve flagged issues
- Merge completed PRs in dependency order
- Run `/openspec-parallel-dev <change-id>` again for remaining tasks
```

---

## Failure Handling

| Failure Type | Response | Max Retries |
|--------------|----------|-------------|
| Tests fail | Invoke `systematic-debugging`, fix, retry | 2 |
| Lint/typecheck fail | Auto-fix if possible, else debug | 2 |
| Build fails | Analyze error, fix dependencies | 2 |
| Task agent stuck | Spawn fresh agent with error context | 2 |
| Review critical issues | Fix and re-review | 2 |
| All retries exhausted | Escalate to NEEDS_INTERVENTION | — |

---

## Implementation Notes

### Dispatching Parallel Agents

Use the Task tool with multiple invocations in a single message to run agents in parallel:

```
[Task tool: task 1 agent]
[Task tool: task 2 agent]  <- Same message = parallel execution
[Task tool: task 3 agent]
```

### Agent Prompts

Each task agent prompt should include:

1. Task description from tasks.md
2. Relevant spec section
3. Branch name to create
4. Skills to invoke (from coordinator's analysis)
5. Verification commands for the project
6. Instructions to signal "Ready for review" when done

### Resuming Agents

If a task agent needs fixes after review, resume it using the agent ID:

```
[Task tool with resume: <agent-id>]
```

Provide the review feedback in the prompt.
