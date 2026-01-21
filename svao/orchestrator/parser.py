#!/usr/bin/env python3
"""
OpenSpec Task Parser
Parses tasks.md into structured format with strict validation.
"""

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Task:
    id: str
    description: str
    files: list[str]
    depends_on: list[str] = field(default_factory=list)
    agent_type: str | None = None
    complexity: str = "medium"
    completed: bool = False


@dataclass
class Section:
    number: int
    name: str
    tasks: list[Task] = field(default_factory=list)


@dataclass
class ParseResult:
    sections: list[Section]
    errors: list[str]
    warnings: list[str]


def parse_tasks_md(content: str) -> ParseResult:
    """Parse tasks.md content into structured sections and tasks."""
    sections: list[Section] = []
    errors: list[str] = []
    warnings: list[str] = []

    # Pattern for section headers: ## N. Name
    section_pattern = re.compile(r'^## (\d+)\. (.+)$', re.MULTILINE)

    # Pattern for tasks: - [ ] N.M.P[a] Description (files: ...) (depends: ...) etc
    # Supports:
    #   - Two-level: 1.1, 1.2
    #   - Three-level: 1.1.1, 1.2.3
    #   - With letters: 1.1.2a, 1.1.2b
    #   - Captures checkbox state (space = incomplete, x = complete)
    task_pattern = re.compile(
        r'^- \[([ x])\] (\d+\.\d+(?:\.\d+)?[a-z]?) (.+?)(?:\s*\(files?:\s*([^)]+)\))?'
        r'(?:\s*\(depends?:\s*([^)]+)\))?'
        r'(?:\s*\(agent:\s*([^)]+)\))?'
        r'(?:\s*\(complexity:\s*([^)]+)\))?$',
        re.MULTILINE
    )

    # Split by sections
    section_matches = list(section_pattern.finditer(content))

    if not section_matches:
        errors.append("No sections found. Expected format: '## 1. Section Name'")
        return ParseResult([], errors, warnings)

    for i, match in enumerate(section_matches):
        section_num = int(match.group(1))
        section_name = match.group(2).strip()

        # Get content until next section or end
        start = match.end()
        end = section_matches[i + 1].start() if i + 1 < len(section_matches) else len(content)
        section_content = content[start:end]

        section = Section(number=section_num, name=section_name)

        # Parse tasks in this section
        for task_match in task_pattern.finditer(section_content):
            checkbox_state = task_match.group(1)
            task_id = task_match.group(2)
            description = task_match.group(3).strip()
            files_str = task_match.group(4)
            depends_str = task_match.group(5)
            agent = task_match.group(6)
            complexity = task_match.group(7)
            is_completed = checkbox_state == 'x'

            # Validate task ID matches section (first number should match section)
            task_section = int(task_id.split('.')[0])
            if task_section != section_num:
                errors.append(f"Task {task_id} in section {section_num} should start with '{section_num}.'")

            # Parse files (optional - warn if missing)
            if files_str:
                files = [f.strip() for f in files_str.split(',')]
            else:
                warnings.append(f"Task {task_id} missing (files: ...) annotation - agent routing may be less accurate")
                files = []

            # Parse dependencies
            depends_on = []
            if depends_str:
                depends_on = [d.strip() for d in depends_str.split(',')]

            # Parse complexity
            if complexity:
                complexity = complexity.strip().lower()
                if complexity not in ('low', 'medium', 'high'):
                    warnings.append(f"Task {task_id} has invalid complexity '{complexity}', using 'medium'")
                    complexity = 'medium'
            else:
                complexity = 'medium'

            task = Task(
                id=task_id,
                description=description,
                files=files,
                depends_on=depends_on,
                agent_type=agent.strip() if agent else None,
                complexity=complexity,
                completed=is_completed
            )
            section.tasks.append(task)

        if not section.tasks:
            warnings.append(f"Section {section_num} '{section_name}' has no tasks")

        sections.append(section)

    return ParseResult(sections, errors, warnings)


def validate_dependencies(sections: list[Section]) -> list[str]:
    """Validate that all dependencies reference existing tasks."""
    errors = []
    all_task_ids = {task.id for section in sections for task in section.tasks}

    for section in sections:
        for task in section.tasks:
            for dep in task.depends_on:
                if dep not in all_task_ids:
                    errors.append(f"Task {task.id} depends on unknown task '{dep}'")

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: parser.py <tasks.md>", file=sys.stderr)
        sys.exit(1)

    tasks_file = Path(sys.argv[1])
    if not tasks_file.exists():
        print(f"Error: File not found: {tasks_file}", file=sys.stderr)
        sys.exit(1)

    content = tasks_file.read_text()
    result = parse_tasks_md(content)

    # Validate dependencies
    dep_errors = validate_dependencies(result.sections)
    result.errors.extend(dep_errors)

    # Output results
    if result.errors:
        print("❌ Parsing errors:", file=sys.stderr)
        for error in result.errors:
            print(f"   - {error}", file=sys.stderr)
        sys.exit(2)

    if result.warnings:
        print("Warnings:")
        for warning in result.warnings:
            print(f"   - {warning}")

    print(f"Parsed {len(result.sections)} sections, {sum(len(s.tasks) for s in result.sections)} tasks")

    # Output JSON
    import json
    output = {
        "sections": [
            {
                "number": s.number,
                "name": s.name,
                "tasks": [
                    {
                        "id": t.id,
                        "description": t.description,
                        "files": t.files,
                        "depends_on": t.depends_on,
                        "agent_type": t.agent_type,
                        "complexity": t.complexity,
                        "completed": t.completed
                    }
                    for t in s.tasks
                ]
            }
            for s in result.sections
        ]
    }
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
