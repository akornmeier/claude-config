#!/usr/bin/env python3
"""
Spec Format Validator
Ensures OpenSpec documents follow required structure.
Exit 0: pass, Exit 2: block
"""

import json
import sys
import re
from pathlib import Path


def validate_proposal(content: str) -> list[str]:
    """Validate proposal.md structure."""
    errors = []

    required_sections = ["## Problem", "## Solution", "## Impact"]

    for section in required_sections:
        if section not in content:
            errors.append(f"Missing required section: {section.replace('## ', '')}")

    # Check for empty sections
    sections = re.split(r"^## ", content, flags=re.MULTILINE)
    for section in sections[1:]:  # Skip content before first ##
        lines = section.strip().split("\n")
        if lines:
            header = lines[0].strip()
            body = "\n".join(lines[1:]).strip()

            if len(body) < 20:
                errors.append(f"Section '{header}' is too short (< 20 chars)")

    return errors


def validate_tasks(content: str) -> list[str]:
    """Validate tasks.md structure."""
    errors = []

    # Must have numbered sections
    if not re.search(r"^## \d+\.", content, re.MULTILINE):
        errors.append("No numbered sections found (expected '## 1. Section Name')")
        return errors

    # Each section should have task items
    sections = re.split(r"^## \d+\.", content, flags=re.MULTILINE)
    for i, section in enumerate(sections[1:], 1):
        if not re.search(r"^- \[[ x]\]", section, re.MULTILINE):
            section_name = section.split("\n")[0].strip() if section.strip() else f"Section {i}"
            errors.append(f"Section '{section_name}' has no task checkboxes")

    return errors


def validate_design(content: str) -> list[str]:
    """Validate design.md structure (advisory only)."""
    warnings = []

    recommended = ["architecture", "component", "data"]
    content_lower = content.lower()

    for term in recommended:
        if term not in content_lower:
            warnings.append(f"Consider discussing: {term}")

    return warnings


def main():
    # Read hook input from stdin
    try:
        input_data = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        # If not JSON, might be direct file path for testing
        sys.exit(0)

    file_path = input_data.get("tool_input", {}).get("file_path", "")

    if not file_path:
        sys.exit(0)

    path = Path(file_path)

    # Only validate openspec files
    if "openspec" not in str(path):
        sys.exit(0)

    if not path.exists():
        sys.exit(0)

    content = path.read_text()
    errors = []

    # Route to appropriate validator
    if path.name == "proposal.md":
        errors = validate_proposal(content)
    elif path.name == "tasks.md":
        errors = validate_tasks(content)
    elif path.name == "design.md":
        # Design validation is advisory, don't block
        warnings = validate_design(content)
        if warnings:
            print(f"💡 Suggestions for {path.name}:")
            for warning in warnings:
                print(f"   - {warning}")
        sys.exit(0)

    if errors:
        print(f"❌ Spec format issues in {path.name}:", file=sys.stderr)
        for error in errors:
            print(f"   - {error}", file=sys.stderr)
        sys.exit(2)

    print(f"✅ {path.name} format valid")
    sys.exit(0)


if __name__ == "__main__":
    main()
