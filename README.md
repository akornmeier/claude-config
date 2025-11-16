# Claude Code Configuration

Personal configuration for Claude Code, including custom hooks, skills, and settings.

## Overview

This repository contains my Claude Code configuration directory (`~/.claude`), which customizes the Claude Code experience with:

- **Hooks**: Event-triggered automation using `claudio` for audio feedback
- **Skills**: Specialized knowledge and workflows for various technologies and methodologies
- **Settings**: Plugin configurations and preferences
- **Project Management**: Session data, todos, and shell snapshots

## Directory Structure

```
.claude/
├── settings.json          # Claude Code settings and enabled plugins
├── package.json          # Package metadata
├── skills/              # Custom skills library
├── plugins/             # Installed plugins cache
├── projects/            # Project-specific configurations
├── debug/               # Debug logs and outputs
├── todos/               # Task tracking data
├── session-env/         # Session environment snapshots
├── shell-snapshots/     # Shell state captures
├── file-history/        # File change history
├── history.jsonl        # Conversation history
└── ide/                # IDE integration settings
```

### Key Directories

- **skills/**: Collection of specialized knowledge modules for different technologies
- **settings.json**: Configures hooks and enabled plugins
- **plugins/**: Cached plugin data from enabled marketplaces (superpowers, code-review, etc.)
- **todos/**: TodoWrite tracking files for task management

## Hooks

Hooks are event-triggered commands that run during Claude Code's lifecycle. All hooks in this configuration use `claudio` - a custom tool that plays system sounds to provide audio feedback during Claude's operations.

### Configured Hooks

- **SessionStart**: Audio notification when a Claude session begins
- **Stop**: Audio notification when a session ends
- **SubagentStop**: Audio notification when a subagent completes
- **UserPromptSubmit**: Audio feedback when you submit a prompt
- **PreToolUse**: Sound before Claude uses a tool
- **PostToolUse**: Sound after a tool completes
- **PreCompact**: Audio notification before context compaction
- **Notification**: General notification sounds

### Claudio Tool

Located at `/Users/tk/Code/go/bin/claudio`, this tool provides real-time audio feedback:
- Plays sounds while Claude thinks
- Audio cues during typing/output
- Notification sounds for prompt submissions

This creates an auditory UI layer that makes Claude's activity more perceptible and engaging.

## Skills

Skills are specialized knowledge modules that Claude loads dynamically to improve performance on specific tasks. Each skill contains instructions, examples, and guidelines for completing particular types of work.

### Installed Skills

#### Cloud Platforms & Infrastructure

- **cloudflare**: Building applications on Cloudflare's edge platform (Workers, D1, R2, KV, Durable Objects, AI features)
- **cloudflare-workers**: Serverless applications with Cloudflare Workers (JavaScript/TypeScript/Python/Rust)
- **cloudflare-browser-rendering**: Headless browser automation for screenshots, PDFs, scraping, and testing
- **cloudflare-r2**: S3-compatible object storage with zero egress fees
- **docker**: Containerization platform for building, running, and deploying applications
- **mongodb**: Document database with CRUD operations, aggregation, indexing, replication, and sharding

#### Frameworks & UI Libraries

- **better-auth**: Framework-agnostic authentication and authorization for TypeScript
- **nuxt-ui**: NuxtUI v4.1+ component library with Tailwind CSS and Reka UI
- **nuxt-ui-tdd**: Building Vue 3 components with NuxtUI using strict TDD methodology
- **tailwindcss**: Utility-first CSS framework for rapid UI development
- **turborepo**: High-performance build system for JavaScript/TypeScript monorepos

#### Development Tools

- **postgresql-psql**: PostgreSQL interactive terminal client for database management
- **mcp-builder**: Creating MCP (Model Context Protocol) servers for LLM-service integration
- **skill-creator**: Guide for creating effective custom skills
- **template-skill**: Basic template as a starting point for new skills

#### Problem Solving & Debugging

- **debugging/systematic-debugging**: Four-phase framework for understanding bugs before fixing
- **debugging/root-cause-tracing**: Tracing errors backward through call stacks to find triggers
- **debugging/verification-before-completion**: Requires running verification before claiming success
- **debugging/defense-in-depth**: Multi-layer defensive programming strategies
- **problem-solving/when-stuck**: Strategies for getting unstuck on difficult problems
- **problem-solving/simplification-cascades**: Breaking complex problems into simpler components
- **problem-solving/collision-zone-thinking**: Identifying where different concerns intersect
- **problem-solving/meta-pattern-recognition**: Recognizing patterns across different domains
- **problem-solving/inversion-exercise**: Solving problems by inverting the question
- **problem-solving/scale-game**: Thinking about problems at different scales

## Enabled Plugins

The following plugins are enabled via the Claude Code marketplace:

- **superpowers@superpowers-marketplace**: Advanced workflows including TDD, systematic debugging, git worktrees, brainstorming, and plan execution
- **superpowers-developing-for-claude-code@superpowers-marketplace**: Documentation and workflows for Claude Code plugin development
- **code-review@claude-code-plugins**: Code review capabilities for pull requests
- **security-guidance@claude-code-plugins**: Security best practices and vulnerability detection

## Usage

This configuration is automatically loaded when Claude Code starts. The `.claude` directory in your home folder is where Claude Code stores all its settings, history, and customizations.

### Restoring This Configuration

If you need to restore this configuration on a new machine:

1. Clone this repository to `~/.claude`
2. Ensure `claudio` is installed at `/Users/tk/Code/go/bin/claudio`
3. Restart Claude Code to load the configuration

### Adding New Skills

To add new skills:

1. Create a new directory in `skills/`
2. Add a `SKILL.md` file with frontmatter (name, description) and instructions
3. Reference the skill in conversations or let Claude discover it automatically

See the [template-skill](skills/template-skill/) for a starting point.
