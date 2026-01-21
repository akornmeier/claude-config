{{BASE_TEMPLATE}}

## Queue Planning Instructions

Analyze the ready queue and decide which tasks to dispatch. Consider:

1. **Dependency chains** - Prioritize tasks that unblock the most downstream work
2. **File overlap** - Avoid dispatching tasks that touch the same files concurrently
3. **Agent metrics** - Consider agent success rates from metrics
4. **Complexity balance** - Mix high/low complexity tasks when possible

### Ready Queue

{{READY_QUEUE}}

### Currently In Progress

{{IN_PROGRESS}}

### Agent Metrics

{{AGENT_METRICS}}

### File Overlap Analysis

{{FILE_OVERLAP}}

## Your Task

Output DISPATCH commands for tasks that should be started (up to {{MAX_PARALLEL}} total active).
If the queue is empty or all ready tasks have file conflicts, output WAIT with reason.

**Output ONLY commands (nothing else):**

```
DISPATCH: 2.3:api-builder:task
DISPATCH: 3.1:frontend-coder:task
```

Or if waiting:
```
WAIT: All ready tasks have file conflicts with in-progress tasks
```

**Do NOT include any explanatory text, analysis, or markdown. Output only commands.**
