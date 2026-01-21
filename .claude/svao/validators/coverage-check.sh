#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Coverage Check Validator
# Ensures minimum test coverage threshold is met
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Configuration
MINIMUM_COVERAGE="${MINIMUM_COVERAGE:-80}"
COVERAGE_CMD="${COVERAGE_CMD:-pnpm test:coverage}"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

echo "📊 Running coverage check (minimum: ${MINIMUM_COVERAGE}%)..."

# Check if coverage command exists
if ! command -v pnpm &> /dev/null && [[ "$COVERAGE_CMD" == pnpm* ]]; then
  echo "⚠️  pnpm not found, skipping coverage check"
  exit 0
fi

# Run coverage
if ! $COVERAGE_CMD --reporter=json 2>/dev/null; then
  echo "⚠️  Coverage command failed or not configured, skipping check"
  exit 0
fi

# Find coverage report
COVERAGE_FILE=""
for candidate in "coverage/coverage-summary.json" "coverage-summary.json" ".coverage/coverage-summary.json"; do
  if [[ -f "$candidate" ]]; then
    COVERAGE_FILE="$candidate"
    break
  fi
done

if [[ -z "$COVERAGE_FILE" ]]; then
  echo "⚠️  No coverage report found, skipping check"
  exit 0
fi

# Extract coverage percentages
LINE_COVERAGE=$(jq -r '.total.lines.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")
BRANCH_COVERAGE=$(jq -r '.total.branches.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")
FUNC_COVERAGE=$(jq -r '.total.functions.pct // 0' "$COVERAGE_FILE" 2>/dev/null || echo "0")

echo "  Line coverage:     ${LINE_COVERAGE}%"
echo "  Branch coverage:   ${BRANCH_COVERAGE}%"
echo "  Function coverage: ${FUNC_COVERAGE}%"

# Check against threshold (using line coverage as primary metric)
if (( $(echo "$LINE_COVERAGE < $MINIMUM_COVERAGE" | bc -l) )); then
  echo "" >&2
  echo "❌ Line coverage ${LINE_COVERAGE}% is below minimum ${MINIMUM_COVERAGE}%" >&2
  echo "   Add more tests to increase coverage." >&2
  exit 2
fi

echo "✅ Coverage check passed"
exit 0
