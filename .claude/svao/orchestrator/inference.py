#!/usr/bin/env python3
"""
Dependency Inference Engine
Infers task dependencies using multiple signals with confidence scoring.
"""

import re
from dataclasses import dataclass


@dataclass
class InferredDependency:
    from_task: str
    to_task: str
    confidence: int
    reason: str


def extract_stem(filepath: str) -> str:
    """Extract meaningful stem from filepath for matching."""
    # Remove extension and path
    name = filepath.split('/')[-1]
    name = re.sub(r'\.(ts|tsx|js|jsx|vue|py|go)$', '', name)
    # Convert to lowercase for matching
    return name.lower()


def extract_keywords(description: str) -> set[str]:
    """Extract meaningful keywords from task description."""
    # Common development keywords
    keywords = set()
    desc_lower = description.lower()

    patterns = {
        'schema': ['schema', 'model', 'table', 'entity'],
        'type': ['type', 'interface', 'typedef'],
        'mutation': ['mutation', 'create', 'update', 'delete', 'write'],
        'query': ['query', 'read', 'fetch', 'get', 'list'],
        'component': ['component', 'view', 'page', 'ui'],
        'test': ['test', 'spec', 'coverage'],
        'api': ['api', 'endpoint', 'route', 'handler'],
    }

    for category, words in patterns.items():
        if any(word in desc_lower for word in words):
            keywords.add(category)

    return keywords


def infer_from_file_patterns(tasks: list[dict]) -> list[InferredDependency]:
    """Infer dependencies from file naming patterns."""
    dependencies = []

    # Build stem -> task mapping
    stem_to_task: dict[str, list[str]] = {}
    for task in tasks:
        for filepath in task.get('files', []):
            stem = extract_stem(filepath)
            if stem not in stem_to_task:
                stem_to_task[stem] = []
            stem_to_task[stem].append(task['id'])

    # Find tasks with shared stems
    for stem, task_ids in stem_to_task.items():
        if len(task_ids) > 1:
            # Sort by task ID (earlier tasks are dependencies)
            sorted_ids = sorted(task_ids, key=lambda x: tuple(map(int, x.split('.'))))
            for i, later_task in enumerate(sorted_ids[1:], 1):
                for earlier_task in sorted_ids[:i]:
                    dependencies.append(InferredDependency(
                        from_task=later_task,
                        to_task=earlier_task,
                        confidence=85,
                        reason=f"file pattern: shared stem '{stem}'"
                    ))

    return dependencies


def infer_from_keywords(tasks: list[dict]) -> list[InferredDependency]:
    """Infer dependencies from keyword relationships."""
    dependencies = []

    # Keyword dependency rules
    keyword_deps = {
        'mutation': ['schema', 'type'],
        'query': ['schema', 'type'],
        'component': ['type', 'query', 'mutation'],
        'test': [],  # Tests don't create dependencies
        'api': ['schema', 'type'],
    }

    # Build keyword -> tasks mapping
    keyword_to_tasks: dict[str, list[str]] = {}
    task_keywords: dict[str, set[str]] = {}

    for task in tasks:
        keywords = extract_keywords(task.get('description', ''))
        task_keywords[task['id']] = keywords
        for kw in keywords:
            if kw not in keyword_to_tasks:
                keyword_to_tasks[kw] = []
            keyword_to_tasks[kw].append(task['id'])

    # Find dependencies based on keyword relationships
    for task in tasks:
        task_kws = task_keywords.get(task['id'], set())
        for kw in task_kws:
            required_kws = keyword_deps.get(kw, [])
            for req_kw in required_kws:
                if req_kw in keyword_to_tasks:
                    for dep_task_id in keyword_to_tasks[req_kw]:
                        if dep_task_id != task['id']:
                            # Check if dep_task is earlier
                            dep_parts = tuple(map(int, dep_task_id.split('.')))
                            task_parts = tuple(map(int, task['id'].split('.')))
                            if dep_parts < task_parts:
                                dependencies.append(InferredDependency(
                                    from_task=task['id'],
                                    to_task=dep_task_id,
                                    confidence=50,
                                    reason=f"keyword: '{kw}' typically depends on '{req_kw}'"
                                ))

    return dependencies


def infer_from_section_order(sections: list[dict]) -> list[InferredDependency]:
    """Infer coarse-grained dependencies from section order."""
    dependencies = []

    for i, section in enumerate(sections[1:], 1):
        prev_section = sections[i - 1]
        # Last task of previous section blocks first task of current section
        if prev_section.get('tasks') and section.get('tasks'):
            prev_last = prev_section['tasks'][-1]['id']
            curr_first = section['tasks'][0]['id']
            dependencies.append(InferredDependency(
                from_task=curr_first,
                to_task=prev_last,
                confidence=25,
                reason=f"section order: section {section['number']} after section {prev_section['number']}"
            ))

    return dependencies


def infer_dependencies(parsed_data: dict, confidence_threshold: int = 70) -> dict:
    """
    Run all inference strategies and categorize results.

    Returns:
        {
            "auto_apply": [...],  # confidence >= threshold
            "pending_review": [...]  # confidence < threshold
        }
    """
    all_tasks = []
    for section in parsed_data.get('sections', []):
        all_tasks.extend(section.get('tasks', []))

    # Collect all inferences
    all_deps: list[InferredDependency] = []
    all_deps.extend(infer_from_file_patterns(all_tasks))
    all_deps.extend(infer_from_keywords(all_tasks))
    all_deps.extend(infer_from_section_order(parsed_data.get('sections', [])))

    # Deduplicate (keep highest confidence)
    unique_deps: dict[tuple[str, str], InferredDependency] = {}
    for dep in all_deps:
        key = (dep.from_task, dep.to_task)
        if key not in unique_deps or dep.confidence > unique_deps[key].confidence:
            unique_deps[key] = dep

    # Categorize by confidence
    auto_apply = []
    pending_review = []

    for dep in unique_deps.values():
        dep_dict = {
            "from": dep.from_task,
            "to": dep.to_task,
            "confidence": dep.confidence,
            "reason": dep.reason
        }
        if dep.confidence >= confidence_threshold:
            auto_apply.append(dep_dict)
        else:
            pending_review.append(dep_dict)

    return {
        "auto_apply": auto_apply,
        "pending_review": pending_review
    }


if __name__ == "__main__":
    import json
    import sys

    # Read parsed JSON from stdin or file
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            data = json.load(f)
    else:
        data = json.load(sys.stdin)

    result = infer_dependencies(data)

    print(f"✓ Inferred {len(result['auto_apply'])} high-confidence dependencies")
    print(f"⚠ {len(result['pending_review'])} dependencies need review")
    print(json.dumps(result, indent=2))
