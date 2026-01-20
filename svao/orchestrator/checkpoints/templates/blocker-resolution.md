{{BASE_TEMPLATE}}

## Blocker Resolution Instructions

Task {{TASK_ID}} is blocked after {{RETRY_COUNT}} retries. Analyze and suggest recovery.

### Task Details

{{TASK_DETAILS}}

### Failure History

{{FAILURE_HISTORY}}

### Last Error Output

```
{{LAST_ERROR}}
```

### Available Agents

{{AVAILABLE_AGENTS}}

## Recovery Strategies

Consider these strategies in order:
1. **alternate-agent** - Try a different agent type
2. **split-task** - Suggest breaking into smaller pieces (requires human)
3. **skip-and-continue** - Mark as blocked, continue with unblocked tasks
4. **escalate** - Request human intervention

## Your Task

Output one of:
- `UNBLOCK: {{TASK_ID}}:alternate-agent:<agent-name>` - Try different agent
- `UNBLOCK: {{TASK_ID}}:skip-and-continue` - Skip this task, continue others
- `UNBLOCK: {{TASK_ID}}:escalate:<reason>` - Request human help
- `REASSIGN: {{TASK_ID}}:<agent>` - Reassign to specific agent with context
