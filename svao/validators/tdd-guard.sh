#!/bin/bash
# ─────────────────────────────────────────────────────────────
# TDD Guard - Blocks edits to implementation files without tests
# Exit 0: pass, Exit 2: block
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# Read tool input from stdin (Claude Code hook format)
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check Edit/Write operations
[[ "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "Write" ]] && exit 0

# Skip if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# ─────────────────────────────────────────────────────────────
# Files that DON'T need tests (config, types, etc.)
# ─────────────────────────────────────────────────────────────
is_exempt() {
  local file="$1"
  case "$file" in
    *.test.ts|*.spec.ts|*.test.tsx|*.spec.tsx) return 0 ;;
    *.test.js|*.spec.js|*.test.jsx|*.spec.jsx) return 0 ;;
    *.d.ts) return 0 ;;
    */types/*|*/types.ts|*/@types/*) return 0 ;;
    *.config.*|*.config) return 0 ;;
    *.json|*.md|*.css|*.scss|*.yaml|*.yml) return 0 ;;
    */__mocks__/*|*/fixtures/*|*/__fixtures__/*) return 0 ;;
    */.claude/*|*/openspec/*) return 0 ;;
    *.sh|*.py) return 0 ;;  # Scripts don't need tests
    */index.ts|*/index.js) return 0 ;;  # Re-export files
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Check if this is an implementation file that needs tests
# ─────────────────────────────────────────────────────────────
needs_tests() {
  local file="$1"
  case "$file" in
    */src/*.ts|*/src/*.tsx|*/src/*.js|*/src/*.jsx) return 0 ;;
    */components/*.vue|*/components/*.ts|*/components/*.tsx) return 0 ;;
    */composables/*.ts|*/hooks/*.ts) return 0 ;;
    */lib/*.ts|*/utils/*.ts|*/services/*.ts) return 0 ;;
    */packages/*/src/*) return 0 ;;
    */apps/*/src/*|*/apps/*/components/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────
# Find corresponding test file
# ─────────────────────────────────────────────────────────────
find_test_file() {
  local impl_file="$1"
  local dir=$(dirname "$impl_file")
  local base=$(basename "$impl_file")
  local name="${base%.*}"
  local ext="${base##*.}"

  # Common test file locations
  local candidates=(
    "${dir}/${name}.test.${ext}"
    "${dir}/${name}.spec.${ext}"
    "${dir}/${name}.test.ts"
    "${dir}/${name}.spec.ts"
    "${dir}/__tests__/${name}.test.${ext}"
    "${dir}/__tests__/${name}.spec.${ext}"
    "${dir}/test/${name}.test.${ext}"
  )

  # Also check parallel test directory structure
  local test_dir="${dir/\/src\//\/test\/}"
  candidates+=(
    "${test_dir}/${name}.test.${ext}"
    "${test_dir}/${name}.spec.${ext}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# ─────────────────────────────────────────────────────────────
# Check that test file has actual test cases
# ─────────────────────────────────────────────────────────────
has_test_cases() {
  local test_file="$1"

  # Look for common test patterns
  if grep -qE '(describe|it|test)\s*\(' "$test_file" 2>/dev/null; then
    return 0
  fi

  return 1
}

# ─────────────────────────────────────────────────────────────
# Main logic
# ─────────────────────────────────────────────────────────────

# Check if exempt
if is_exempt "$FILE_PATH"; then
  exit 0
fi

# Check if this file needs tests
if ! needs_tests "$FILE_PATH"; then
  exit 0
fi

# Find corresponding test file
TEST_FILE=$(find_test_file "$FILE_PATH") || true

if [[ -z "$TEST_FILE" ]]; then
  echo "❌ TDD Guard: No test file found for $FILE_PATH" >&2
  echo "" >&2
  echo "Expected test file at one of:" >&2
  echo "  - $(dirname "$FILE_PATH")/$(basename "${FILE_PATH%.*}").test.ts" >&2
  echo "  - $(dirname "$FILE_PATH")/$(basename "${FILE_PATH%.*}").spec.ts" >&2
  echo "" >&2
  echo "Write the test first, then implement." >&2
  exit 2
fi

if ! has_test_cases "$TEST_FILE"; then
  echo "❌ TDD Guard: Test file exists but has no test cases" >&2
  echo "   File: $TEST_FILE" >&2
  echo "" >&2
  echo "Add at least one test case (describe/it/test) before editing implementation." >&2
  exit 2
fi

# All checks passed
echo "✅ TDD Guard: Test file found at $TEST_FILE"
exit 0
