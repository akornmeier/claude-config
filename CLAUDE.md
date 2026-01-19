# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Claude Code configuration repository (`~/.claude`) that contains custom hooks, skills, plugins, and settings. It is a Git repository hosted at `github.com:akornmeier/claude-config.git`.

## Architecture

### Configuration Files

- **settings.json**: Main configuration file containing enabled plugins, hooks, and preferences
- **package.json**: Node.js package metadata (uses pnpm@10.14.0)

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `skills/` | Custom skill definitions (SKILL.md files with YAML frontmatter) |
| `plugins/` | Installed plugins from marketplaces |
| `projects/` | Project-specific configurations and session data |
| `todos/` | TodoWrite task tracking files |
| `session-env/` | Session environment snapshots |
| `shell-snapshots/` | Shell state captures |

### Plugin System

Plugins are organized through three marketplaces configured in `plugins/known_marketplaces.json`:
- `claude-code-plugins` → `anthropics/claude-code`
- `superpowers-marketplace` → `obra/superpowers-marketplace`
- `claude-plugins-official` → `anthropics/claude-plugins-official`

Installed plugins are cached in `plugins/cache/<marketplace>/<plugin>/<version>/` and tracked in `plugins/installed_plugins.json`.

### Skills Structure

Skills are markdown files with YAML frontmatter:

```yaml
---
name: skill-name
description: What the skill does and when to use it
license: MIT (optional)
allowed-tools: [] (optional, for Claude Code)
---

# Instructions in Markdown
```

Skills are organized by category:
- `debugging/` - Systematic debugging, root-cause tracing, verification
- `problem-solving/` - Strategies for complex problems (when-stuck, simplification, inversion)
- Root level - Technology-specific skills (cloudflare, nuxt-ui, docker, mongodb, etc.)

## Hooks

All hooks use `claudio` (audio feedback tool) located at `/Users/tk/Code/go/bin/claudio`. Install with:

```bash
go install claudio.click/cmd/claudio@latest
claudio install
```

Configured events: Notification, UserPromptSubmit, SessionStart, Stop, SubagentStop, PreToolUse, PostToolUse, PreCompact

## Working with This Repository

### Adding a New Skill

1. Create a directory in `skills/` matching the skill name
2. Add a `SKILL.md` file with required frontmatter (`name`, `description`)
3. Skills are discovered automatically on next Claude Code session

### Updating Plugin Marketplaces

Plugin marketplaces are Git submodules in `plugins/marketplaces/`. Updates are tracked via timestamps in `plugins/install-counts-cache.json`.

## Commit Message Format

Follow conventional commit format:

```
type(scope?): subject

body (optional, bullet points for multiple changes)
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `style`, `perf`, `ci`, `build`, `revert`
