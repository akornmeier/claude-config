# TDD Guard Troubleshooting

Common error messages from tdd-guard and how to resolve them.

## Error: "Premature implementation"

**Message:** `Premature implementation - adding [feature] without a failing test`

**Cause:** Attempting to edit production code before a failing test exists.

**Solution:**
1. Write a test first that exercises the feature
2. Run the test suite to register the failure
3. Then proceed with the implementation

## Error: "Multiple test addition violation"

**Message:** `Multiple test addition violation - adding N new tests simultaneously`

**Cause:** Writing more than one new `it()` or `test()` block at a time.

**What counts as "multiple tests":**
```typescript
// VIOLATION: Two new it() blocks added at once
it('first new test', () => { ... });    // ← test 1
it('second new test', () => { ... });   // ← test 2

// NOT a violation: One it() inside a new describe()
describe('new suite', () => {
  it('one test', () => { ... });        // ← only one test
});

// NOT a violation: Multiple describe() blocks with one test total
describe('suite A', () => {
  describe('nested', () => {
    it('one test', () => { ... });      // ← only one test
  });
});
```

**Solution:**
1. Keep only ONE new `it()` or `test()` block
2. Comment out or delete the other tests temporarily
3. Run the single test to register failure
4. Implement to pass that test
5. Uncomment/add the next test and repeat

## Error: "Over-implementation violation"

**Message:** `Over-implementation violation. Test fails with [error], indicating [condition]. Should [minimal action] first`

**Cause:** Adding more code than necessary to address the current test failure.

**Solution:**
1. Read the specific failure message
2. Implement only what's needed to address that exact failure
3. For new methods: start with an empty stub `method(): void {}`
4. Run tests to see the next specific failure
5. Address one failure at a time

## Error: "expected undefined to be function"

**Context:** Test expects a method to exist, but it doesn't.

**Minimal fix:** Add an empty method stub:
```typescript
myMethod(): void {}
```

Then run tests again to see the next failure.

## Reporter Not Detecting Test Results

**Symptoms:**
- tdd-guard blocks edits even after running failing tests
- tdd-guard doesn't recognize test state changes

**Causes and Solutions:**

### 1. Reporter not installed
```bash
npm list tdd-guard-vitest
# If missing:
npm install --save-dev tdd-guard-vitest
```

### 2. Reporter not configured in vitest.config.ts
```typescript
import { VitestReporter } from 'tdd-guard-vitest';

export default defineConfig({
  test: {
    reporters: ['default', new VitestReporter('/path/to/repo/root')],
  },
});
```

### 3. Wrong path to VitestReporter (most common in monorepos)
The path must resolve to the **repository root**, not the package directory.

**Wrong (in monorepo):**
```typescript
new VitestReporter('.')  // Points to packages/my-package, not repo root
```

**Correct:**
```typescript
import { resolve } from 'path';
new VitestReporter(resolve(__dirname, '../..'))  // Resolves to repo root
```

### 4. Test not actually running
Verify the test file path is correct:
```bash
pnpm test -- path/to/actual/test.test.ts
```

## Test Passes Immediately (Should Fail)

**Symptom:** New test passes without implementing the feature.

**Causes:**
1. Testing existing behavior (not new behavior)
2. Test assertion is wrong
3. Test is not actually testing what you think

**Solution:** Review the test. A proper RED test must fail because the feature doesn't exist yet.

## tdd-guard State Seems Stale

**Symptom:** tdd-guard references old test state.

**Solution:** Re-run the test suite to update the reporter state:
```bash
pnpm test -- path/to/test.test.ts
```

The reporter writes state after each test run. Running tests again will update the state file.
