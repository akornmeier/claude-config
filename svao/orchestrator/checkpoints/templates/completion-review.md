{{BASE_TEMPLATE}}

## Completion Review Instructions

Section {{SECTION_NUMBER}} ({{SECTION_NAME}}) has all tasks completed.

**The phase-reviewer agent has already:**
- Reviewed test coverage
- Implemented additional tests for edge cases and error paths
- Flagged architecture/security issues for human review

### Section Tasks

{{SECTION_TASKS}}

### Commits Made

{{SECTION_COMMITS}}

### Files Changed

{{FILES_CHANGED}}

### Test Results

{{TEST_RESULTS}}

### Phase Reviewer Findings

{{PHASE_REVIEW_RESULTS}}

## Your Task

Based on the phase reviewer's work and the test results, decide if this section is ready.

**Output ONLY ONE of these commands (nothing else):**

- `APPROVED: {{SECTION_NUMBER}}` - If tests pass and no blocking issues
- `NEEDS_WORK: {{SECTION_NUMBER}}:<specific issue>` - If tests fail or critical issues exist

**Note:** HUMAN_REVIEW items flagged by phase-reviewer do not block approval - they are informational for the human operator.

Example valid responses:
```
APPROVED: {{SECTION_NUMBER}}
```
or
```
NEEDS_WORK: {{SECTION_NUMBER}}:Tests failing in AuthProvider
```

**Do NOT include any explanatory text, analysis, or markdown. Output only the command.**
