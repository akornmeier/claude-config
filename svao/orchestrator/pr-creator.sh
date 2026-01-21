#!/bin/bash
# ─────────────────────────────────────────────────────────────
# SVAO Section PR Creator
# Manages PRs for sections: draft on first task, ready on completion
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# All log functions write to stderr to avoid polluting stdout when called via
# command substitution (e.g., branch_name=$(...) should only capture the branch name)
log() { echo -e "$*" >&2; }
log_info() { echo -e "${BLUE}i${NC} $*" >&2; }
log_success() { echo -e "${GREEN}✓${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}!${NC} $*" >&2; }
log_error() { echo -e "${RED}x${NC} $*" >&2; }

# Get the default branch name (main, master, etc.)
get_default_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main"
}

# ─────────────────────────────────────────────────────────────
# Branch/PR Initialization (First Task of Section)
# ─────────────────────────────────────────────────────────────

init_section_branch() {
  local prd_file="$1"
  local state_file="$2"
  local section_num="$3"

  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")
  local branch_name="svao/${change_id}/section-${section_num}"

  # Check if branch already exists (locally or remote)
  if git rev-parse --verify "$branch_name" &> /dev/null; then
    log_info "Branch $branch_name already exists locally"
    echo "$branch_name"
    return 0
  fi

  if git ls-remote --exit-code --heads origin "$branch_name" &> /dev/null; then
    log_info "Branch $branch_name exists on remote"
    # Fetch without checkout - agent will checkout when it runs
    # (redirect all output to avoid polluting stdout, log failures)
    if ! git fetch origin "$branch_name:$branch_name" &>/dev/null; then
      log_warn "Failed to fetch $branch_name from remote (may be auth or network issue)"
    fi
    echo "$branch_name"
    return 0
  fi

  # Create new branch WITHOUT checking it out (don't disturb user's working directory)
  log_info "Creating section branch: $branch_name"
  local main_branch
  main_branch=$(get_default_branch)

  # Create branch from main without checkout using git branch
  # (redirect all output to avoid polluting stdout, log failures)
  if ! git fetch origin "$main_branch" &>/dev/null; then
    log_warn "Failed to fetch $main_branch from remote (may be auth or network issue)"
  fi
  git branch "$branch_name" "origin/$main_branch" &>/dev/null || {
    # If branch creation fails, it might already exist
    log_warn "Could not create branch locally, agent will create on first push"
    echo "$branch_name"
    return 0
  }

  # Push to remote without checkout (redirect all output to avoid polluting stdout)
  git push -u origin "$branch_name" &>/dev/null || {
    log_warn "Could not push branch, agent will push on first commit"
  }

  log_success "Created branch: $branch_name (not checked out)"
  echo "$branch_name"
}

create_draft_pr() {
  local prd_file="$1"
  local state_file="$2"
  local section_num="$3"

  # Check if gh is available
  if ! command -v gh &> /dev/null; then
    log_warn "GitHub CLI (gh) not found - skipping draft PR"
    return 0
  fi

  # Check if authenticated
  if ! gh auth status &> /dev/null; then
    log_warn "Not authenticated with GitHub - skipping draft PR"
    return 0
  fi

  # Check if PR already exists for this section
  local existing_pr
  existing_pr=$(jq -r --arg n "$section_num" '.section_prs[$n] // ""' "$state_file")
  if [[ -n "$existing_pr" ]]; then
    log_info "Draft PR already exists: $existing_pr"
    echo "$existing_pr"
    return 0
  fi

  # Get section info
  local section_name
  section_name=$(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .name
  ' "$prd_file")

  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")
  local branch_name="svao/${change_id}/section-${section_num}"

  # Build PR title and body
  local pr_title="[WIP] feat(${change_id}): Section ${section_num} - ${section_name}"

  local pr_body
  pr_body=$(cat <<EOF
## Summary

🚧 **Work in Progress** - Section ${section_num}: **${section_name}**

This PR will be updated as tasks complete.

### Tasks
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[] | "- [ ] \(.id): \(.description)"
' "$prd_file")

### Expected Files
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[].files[]
' "$prd_file" 2>/dev/null | sort -u | sed 's/^/- /' || echo "- (files will be added)")

---

🤖 Generated by SVAO (Self-Validating Agent Orchestra)
EOF
)

  # Create draft PR
  log_info "Creating draft PR for section $section_num..."
  local pr_url
  local base_branch
  base_branch=$(get_default_branch)
  pr_url=$(gh pr create \
    --title "$pr_title" \
    --body "$pr_body" \
    --base "$base_branch" \
    --head "$branch_name" \
    --draft 2>&1) || {
    if echo "$pr_url" | grep -q "already exists"; then
      log_info "PR already exists for this branch"
      pr_url=$(gh pr view "$branch_name" --json url -q '.url' 2>/dev/null || echo "")
    else
      log_warn "Failed to create draft PR: $pr_url"
      return 0
    fi
  }

  if [[ -n "$pr_url" ]]; then
    log_success "Draft PR created: $pr_url"

    # Record PR in state
    local tmp_file="${state_file}.tmp.$$"
    jq --arg section "$section_num" --arg url "$pr_url" '
      .section_prs = (.section_prs // {}) |
      .section_prs[$section] = $url
    ' "$state_file" > "$tmp_file"
    mv "$tmp_file" "$state_file"

    echo "$pr_url"
  fi
}

get_section_branch() {
  local prd_file="$1"
  local section_num="$2"

  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")
  echo "svao/${change_id}/section-${section_num}"
}

# ─────────────────────────────────────────────────────────────
# PR Finalization (Section Completion)
# ─────────────────────────────────────────────────────────────

mark_pr_ready() {
  local prd_file="$1"
  local state_file="$2"
  local section_num="$3"

  # Check if gh is available
  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) not found"
    return 1
  fi

  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")
  local branch_name="svao/${change_id}/section-${section_num}"

  # Get section info
  local section_name
  section_name=$(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .name
  ' "$prd_file")

  # Update PR title (remove WIP)
  local pr_title="feat(${change_id}): Section ${section_num} - ${section_name}"

  # Build updated PR body with completed tasks
  local pr_body
  pr_body=$(cat <<EOF
## Summary

✅ **Ready for Review** - Section ${section_num}: **${section_name}**

### Tasks Completed
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[] | "- [x] \(.id): \(.description)"
' "$prd_file")

### Files Changed
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[].files[]
' "$prd_file" 2>/dev/null | sort -u | sed 's/^/- /' || echo "See commits")

### Phase Review
$(jq -r --arg n "$section_num" '
  if .phase_reviews[$n].human_reviews then
    "**Issues flagged for human review:**\n" +
    (.phase_reviews[$n].human_reviews | map("- " + .) | join("\n"))
  else
    "No issues flagged."
  end
' "$state_file" 2>/dev/null || echo "Phase review data not available.")

---

🤖 Generated by SVAO (Self-Validating Agent Orchestra)
EOF
)

  # Update PR: remove draft status, update title and body
  log_info "Marking PR as ready for review..."

  gh pr edit "$branch_name" \
    --title "$pr_title" \
    --body "$pr_body" 2>/dev/null || log_warn "Failed to update PR body"

  gh pr ready "$branch_name" 2>/dev/null || {
    log_warn "PR may already be marked ready or doesn't exist"
  }

  local pr_url
  pr_url=$(gh pr view "$branch_name" --json url -q '.url' 2>/dev/null || echo "")

  if [[ -n "$pr_url" ]]; then
    log_success "PR ready for review: $pr_url"
    echo "$pr_url"
  fi
}

# ─────────────────────────────────────────────────────────────
# Legacy: Full PR Creation (backwards compatibility)
# ─────────────────────────────────────────────────────────────

create_section_pr() {
  local prd_file="$1"
  local state_file="$2"
  local section_num="$3"

  # Check if gh is available
  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) not found. Install with: brew install gh"
    return 1
  fi

  # Check if authenticated
  if ! gh auth status &> /dev/null; then
    log_error "Not authenticated with GitHub. Run: gh auth login"
    return 1
  fi

  # Get section info
  local section_name
  section_name=$(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .name
  ' "$prd_file")

  if [[ -z "$section_name" || "$section_name" == "null" ]]; then
    log_error "Section $section_num not found in PRD"
    return 1
  fi

  local change_id
  change_id=$(jq -r '.change_id' "$prd_file")

  # Get completed tasks in section
  local tasks
  tasks=$(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .tasks[].id
  ' "$prd_file" | tr '\n' ', ' | sed 's/,$//')

  if [[ -z "$tasks" ]]; then
    log_error "Section $section_num has no tasks"
    return 1
  fi

  # Get commits from tasks
  local commits=""
  for task_id in $(jq -r --arg n "$section_num" '
    .sections[] | select(.number == ($n | tonumber)) | .tasks[].id
  ' "$prd_file"); do
    local task_commits
    task_commits=$(jq -r --arg id "$task_id" '.tasks[$id].commits // [] | .[]' "$state_file" 2>/dev/null || echo "")
    commits="$commits $task_commits"
  done

  commits=$(echo "$commits" | xargs)  # Trim whitespace

  if [[ -z "$commits" ]]; then
    log_warn "No commits found for section $section_num - creating PR anyway"
  fi

  # Build PR title and body
  local branch_name="svao/${change_id}/section-${section_num}"
  local pr_title="feat(${change_id}): Section ${section_num} - ${section_name}"

  local pr_body
  pr_body=$(cat <<EOF
## Summary

This PR completes Section ${section_num}: **${section_name}** of the ${change_id} feature.

### Tasks Completed
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[] | "- [x] \(.id): \(.description)"
' "$prd_file")

### Files Changed
$(jq -r --arg n "$section_num" '
  .sections[] | select(.number == ($n | tonumber)) | .tasks[].files[]
' "$prd_file" | sort -u | sed 's/^/- /')

---

🤖 Generated by SVAO (Self-Validating Agent Orchestra)
EOF
)

  # Ensure branch exists (without checkout - don't disturb user's working directory)
  if ! git rev-parse --verify "$branch_name" &> /dev/null; then
    # Check if it exists on remote
    if git ls-remote --exit-code --heads origin "$branch_name" &> /dev/null; then
      log_info "Fetching branch from remote: $branch_name"
      git fetch origin "$branch_name:$branch_name" 2>/dev/null || true
    else
      # Create branch without checkout
      log_info "Creating branch: $branch_name"
      local default_branch
      default_branch=$(get_default_branch)
      git fetch origin "$default_branch" 2>/dev/null || true
      git branch "$branch_name" "origin/$default_branch" 2>/dev/null || {
        log_error "Failed to create branch: $branch_name"
        return 1
      }
    fi
  fi

  # Push branch to remote (without checkout)
  log_info "Pushing branch to remote..."
  git push -u origin "$branch_name" 2>/dev/null || {
    # Push might fail if branch already exists and is up to date, that's ok
    log_info "Branch already on remote or no changes to push"
  }

  # Create PR using --head flag (no checkout needed)
  log_info "Creating pull request..."
  local pr_url
  local base_branch
  base_branch=$(get_default_branch)
  pr_url=$(gh pr create \
    --title "$pr_title" \
    --body "$pr_body" \
    --head "$branch_name" \
    --base "$base_branch" 2>&1) || {
    # Check if PR already exists
    if echo "$pr_url" | grep -q "already exists"; then
      log_warn "PR already exists for this branch"
      pr_url=$(gh pr view "$branch_name" --json url -q '.url')
    else
      log_error "Failed to create PR: $pr_url"
      return 1
    fi
  }

  log_success "PR created: $pr_url"

  # Record PR in state
  local tmp_file="${state_file}.tmp.$$"
  jq --arg section "$section_num" --arg url "$pr_url" '
    .section_prs = (.section_prs // {}) |
    .section_prs[$section] = $url
  ' "$state_file" > "$tmp_file"
  mv "$tmp_file" "$state_file"

  echo "$pr_url"
}

# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

main() {
  local action="${1:-}"

  case "$action" in
    init-branch)
      [[ $# -lt 4 ]] && log_error "Usage: pr-creator.sh init-branch <prd> <state> <section>" && exit 1
      init_section_branch "$2" "$3" "$4"
      ;;
    draft)
      [[ $# -lt 4 ]] && log_error "Usage: pr-creator.sh draft <prd> <state> <section>" && exit 1
      create_draft_pr "$2" "$3" "$4"
      ;;
    ready)
      [[ $# -lt 4 ]] && log_error "Usage: pr-creator.sh ready <prd> <state> <section>" && exit 1
      mark_pr_ready "$2" "$3" "$4"
      ;;
    get-branch)
      [[ $# -lt 3 ]] && log_error "Usage: pr-creator.sh get-branch <prd> <section>" && exit 1
      get_section_branch "$2" "$3"
      ;;
    create)
      # Legacy: full PR creation at completion
      [[ $# -lt 4 ]] && log_error "Usage: pr-creator.sh create <prd> <state> <section>" && exit 1
      create_section_pr "$2" "$3" "$4"
      ;;
    *)
      echo "Usage: pr-creator.sh <action> [args]"
      echo ""
      echo "Actions:"
      echo "  init-branch <prd> <state> <section>  - Create section branch (first task)"
      echo "  draft <prd> <state> <section>        - Create draft PR (first task)"
      echo "  ready <prd> <state> <section>        - Mark PR ready for review (completion)"
      echo "  get-branch <prd> <section>           - Get branch name for section"
      echo "  create <prd> <state> <section>       - Legacy: full PR creation"
      exit 1
      ;;
  esac
}

main "$@"
