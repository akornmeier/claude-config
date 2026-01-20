{{BASE_TEMPLATE}}

## Completion Review Instructions

Section {{SECTION_NUMBER}} ({{SECTION_NAME}}) has all tasks completed. Review the work against the spec.

### Section Tasks

{{SECTION_TASKS}}

### Commits Made

{{SECTION_COMMITS}}

### Files Changed

{{FILES_CHANGED}}

### Test Results

{{TEST_RESULTS}}

## Your Task

Review whether this section meets the specification. Output either:

- `APPROVED: {{SECTION_NUMBER}}` - If work meets spec and tests pass
- `NEEDS_WORK: {{SECTION_NUMBER}}:<specific issue>` - If rework is needed

Be specific about what needs fixing if not approved.
