#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
model=$(echo "$input" | jq -r '.model.display_name')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir')

# Get pre-calculated context usage percentage
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used_pct" ]; then
    used_pct=$(printf "%.0f" "$used_pct")
fi

# Get context window information
context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

# Calculate current tokens from current_usage if available
current_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
cache_creation=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')

current_tokens=$((current_input + cache_read + cache_creation))

# Convert to K format
if [ "$current_tokens" -gt 0 ]; then
    current_k=$((current_tokens / 1000))
else
    current_k=0
fi

if [ "$context_window_size" -gt 0 ]; then
    max_k=$((context_window_size / 1000))
else
    max_k=0
fi

total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# ANSI color codes
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
BLUE='\033[34m'
GRAY='\033[90m'
RESET='\033[0m'

# Build status line parts
parts=""

# 1. Model name (Cyan)
parts="${parts}$(printf "${CYAN}%s${RESET}" "$model")"

# 2. Progress Bar (for context usage) & 3. Context usage display
# Color based on usage: Green (<50%), Yellow (50-75%), Red (>75%)
if [ -n "$used_pct" ]; then
    if [ "$used_pct" -lt 50 ]; then
        bar_color="$GREEN"
    elif [ "$used_pct" -lt 75 ]; then
        bar_color="$YELLOW"
    else
        bar_color="$RED"
    fi

    # Create a progress bar (20 characters wide)
    bar_width=20
    filled=$(printf "%.0f" $(echo "$used_pct * $bar_width / 100" | bc -l 2>/dev/null || echo "0"))
    empty=$((bar_width - filled))

    bar="["
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty; i++)); do bar="${bar}░"; done
    bar="${bar}]"

    parts="${parts} $(printf "${GRAY}|${RESET}") $(printf "${bar_color}%s${RESET}" "$bar") $(printf "${GRAY}|${RESET}") $(printf "${MAGENTA}%sK${RESET}" "$current_k")$(printf "${GRAY}/${RESET}")$(printf "${MAGENTA}%sK${RESET}" "$max_k")"
else
    parts="${parts} $(printf "${GRAY}|${RESET}") $(printf "${GREEN}%s${RESET}" "[░░░░░░░░░░░░░░░░░░░░]") $(printf "${GRAY}|${RESET}") $(printf "${MAGENTA}%sK${RESET}" "$current_k")$(printf "${GRAY}/${RESET}")$(printf "${MAGENTA}%sK${RESET}" "$max_k")"
fi

# 4. Git Branch with dirty indicator
# Green (clean), Yellow (dirty)
git_info=""
if git -C "$current_dir" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$current_dir" branch --show-current 2>/dev/null || echo "")
    if [ -n "$git_branch" ]; then
        # Check for dirty status (uncommitted changes)
        if ! git -C "$current_dir" diff --quiet 2>/dev/null || ! git -C "$current_dir" diff --cached --quiet 2>/dev/null; then
            git_info="$(printf "${YELLOW}%s*${RESET}" "$git_branch")"
        else
            git_info="$(printf "${GREEN}%s${RESET}" "$git_branch")"
        fi
    fi
fi

if [ -n "$git_info" ]; then
    parts="${parts} $(printf "${GRAY}|${RESET}") ${git_info}"
fi

# 5. Project Name (Blue)
project_name=$(basename "$project_dir")
parts="${parts} $(printf "${GRAY}|${RESET}") $(printf "${BLUE}%s${RESET}" "$project_name")"

# Output the status line
echo -e "$parts"
