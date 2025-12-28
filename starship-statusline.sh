#!/bin/bash
# Starship-style status line for Claude Code
# Mimics Starship's default prompt with directory and git info

# Read JSON input from stdin
input=$(cat)

# Extract current directory from JSON input
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')

# Colors (using printf for ANSI codes)
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
PURPLE='\033[35m'
BOLD='\033[1m'
RESET='\033[0m'

# Start building the prompt
prompt=""

# Add directory (in cyan, bold)
dir_name=$(basename "$cwd")
prompt+="$(printf "${BOLD}${CYAN}%s${RESET}" "$dir_name")"

# Git information (if in a git repo)
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  # Get branch name
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  if [ -n "$branch" ]; then
    # Check git status
    git_status=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)

    # Determine color based on status
    if [ -z "$git_status" ]; then
      # Clean - green
      git_color="${GREEN}"
      status_symbol=""
    else
      # Dirty - yellow/red
      git_color="${RED}"
      status_symbol="*"
    fi

    # Add git branch with symbol
    prompt+=" $(printf "on ${BOLD}${PURPLE}%s${RESET}" " $branch")$(printf "${git_color}%s${RESET}" "$status_symbol")"
  fi
fi

# Context window information
total_tokens=$(echo "$input" | jq -r '.context_window.total_input_tokens + .context_window.total_output_tokens')
context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size')

context_info=""
context_info_length=0

if [ "$total_tokens" != "null" ] && [ "$context_window_size" != "null" ] && [ "$context_window_size" -gt 0 ]; then
  # Calculate percentage
  percentage=$((total_tokens * 100 / context_window_size))

  # Determine color based on usage
  if [ "$percentage" -lt 50 ]; then
    ctx_color="${GREEN}"
  elif [ "$percentage" -lt 75 ]; then
    ctx_color="${YELLOW}"
  else
    ctx_color="${RED}"
  fi

  # Format tokens with K suffix for readability
  tokens_k=$((total_tokens / 1000))
  window_k=$((context_window_size / 1000))

  # Build context window info string
  context_info=$(printf "${ctx_color}[%sK/%sK ${BOLD}%s%%${RESET}${ctx_color}]${RESET}" "$tokens_k" "$window_k" "$percentage")

  # Calculate visible length (without ANSI codes)
  context_info_length=$(printf "[%sK/%sK %s%%]" "$tokens_k" "$window_k" "$percentage" | wc -c | tr -d ' ')
fi

# Calculate visible length of left side (without ANSI codes)
left_visible=$(echo -e "$prompt" | sed 's/\x1b\[[0-9;]*m//g' | wc -c | tr -d ' ')

# Get terminal width (default to 80 if not available)
term_width=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}

# Calculate spacing needed for right alignment
if [ "$context_info_length" -gt 0 ]; then
  # Add 1 for the space we'll add, and subtract 1 because wc -c counts newline
  spacing=$((term_width - left_visible - context_info_length - 1))

  # Ensure spacing is at least 2 (minimum gap between left and right)
  if [ "$spacing" -lt 2 ]; then
    spacing=2
  fi

  # Add spacing and context info
  prompt+="$(printf "%${spacing}s" "")$context_info"
fi

# Output the final prompt (without trailing $ or >)
echo -e "$prompt"
