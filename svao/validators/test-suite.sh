#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Test Suite Validator - Runs tests for modified packages
# Used as Stop hook to validate agent completed work correctly
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Allow overriding test command
TEST_CMD="${TEST_CMD:-pnpm test}"

# Get project root (git root or current dir)
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$PROJECT_ROOT"

echo "🧪 Running test suite validation..."

# Check if this is a monorepo with packages
if [[ -d "packages" ]] || [[ -d "apps" ]]; then
  # Monorepo: Find modified packages from git
  MODIFIED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only HEAD 2>/dev/null || echo "")

  if [[ -z "$MODIFIED_FILES" ]]; then
    echo "✅ No modified files detected, skipping tests"
    exit 0
  fi

  # Extract unique package paths
  PACKAGES=$(echo "$MODIFIED_FILES" | grep -E "^(packages|apps)/" | cut -d'/' -f1-2 | sort -u || echo "")

  if [[ -z "$PACKAGES" ]]; then
    echo "✅ No package changes detected, skipping tests"
    exit 0
  fi

  echo "📦 Modified packages:"
  echo "$PACKAGES" | sed 's/^/  - /'
  echo ""

  FAILED=0
  for pkg_path in $PACKAGES; do
    if [[ ! -f "$pkg_path/package.json" ]]; then
      continue
    fi

    pkg_name=$(jq -r '.name // empty' "$pkg_path/package.json" 2>/dev/null || echo "")
    if [[ -z "$pkg_name" ]]; then
      continue
    fi

    echo "🧪 Testing $pkg_name..."

    if pnpm --filter "$pkg_name" test 2>&1; then
      echo "✅ $pkg_name tests passed"
    else
      echo "❌ $pkg_name tests failed" >&2
      FAILED=1
    fi
    echo ""
  done

  if [[ $FAILED -eq 1 ]]; then
    echo "❌ Test suite failed - some packages have failing tests" >&2
    exit 2
  fi
else
  # Single package: Run tests directly
  echo "🧪 Running $TEST_CMD..."

  if $TEST_CMD 2>&1; then
    echo "✅ All tests passed"
  else
    echo "❌ Tests failed" >&2
    exit 2
  fi
fi

echo "✅ Test suite validation complete"
exit 0
