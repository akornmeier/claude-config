# Pre-commit Hooks & CI Alignment Plan

## Problem
CI fails frequently because pre-commit hooks don't catch all issues that CI checks for.

### Root Causes
| Issue | Current | Expected |
|-------|---------|----------|
| CI lint command | `pnpm lint` (uses `--fix`) | `pnpm lint:check` (fail on issues) |
| Type-check in hooks | Not run | Should run before push |
| lint-staged pattern | `"*"` (too broad) | Specific file extensions |

## Changes

### 1. Fix CI lint command
**File:** `.github/workflows/ci.yml:42`
```diff
- run: pnpm lint
+ run: pnpm lint:check
```
Why: `--fix` silently fixes issues instead of failing. CI should detect, not auto-fix.

### 2. Add pre-push hook for type-check
**File:** `package.json` (simple-git-hooks section)
```diff
  "simple-git-hooks": {
-   "pre-commit": "pnpm lint-staged"
+   "pre-commit": "pnpm lint-staged",
+   "pre-push": "pnpm type-check"
  }
```
Why: Type-check is slower (~10-30s uncached), better suited for pre-push than pre-commit.

### 3. Fix lint-staged file patterns
**File:** `package.json` (lint-staged section)
```diff
  "lint-staged": {
-   "*": [
-     "oxfmt --write",
-     "oxlint --fix"
-   ]
+   "*.{ts,tsx,js,jsx,mjs,cjs}": [
+     "oxfmt --write",
+     "oxlint --fix"
+   ],
+   "*.{json,md,yml,yaml,css}": [
+     "oxfmt --write"
+   ]
  }
```
Why: Only lint JS/TS files; format config/docs files without linting.

### 4. Regenerate git hooks
```bash
pnpm prepare
```

## Verification
1. Stage `.ts` file with lint error → pre-commit fails
2. Stage file with bad formatting → pre-commit auto-fixes
3. Introduce TS type error → `git push` fails
4. Push clean code → CI passes (lint:check detects no issues)

## Files to Modify
- `package.json` - lint-staged patterns, simple-git-hooks config
- `.github/workflows/ci.yml` - line 42: `pnpm lint` → `pnpm lint:check`

## Decisions Made
- Pre-push: Type-check only (tests run in CI)
- File types: TS/JS/JSON/MD/YAML/CSS (current plan sufficient)
