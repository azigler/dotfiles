---
name: beads
description: Task tracking with beads-rust (br) for managing development work
argument-hint: "[list|create|close|show|update|sync]"
---

# /beads - Task Tracking with beads-rust

Track development tasks using the `br` command from [beads-rust](https://github.com/Dicklesworthstone/beads_rust).

## Quick Reference

```bash
br list                                  # List all open beads
br create -p 2 "Title"                  # Create a new bead
br update <id> --description "..."       # Add description (ALWAYS do this after create)
br show <id>                             # Show bead details
br update <id> --status=...              # Update bead status
br close <id>                            # Close a completed bead
br delete <id>                           # Tombstone a bead (wrong/invalid)
br sync --flush-only                     # Export to JSONL for git tracking
```

## Core Principle: One Bead = One Commit

This is non-negotiable. Every bead maps to exactly one atomic commit:
- Close beads BEFORE committing (so closure is in the commit diff)
- Never batch multiple bead closures into one commit
- The git log maps 1:1 to bead closures

## Priority Levels

| Priority | Flag | Use For |
|----------|------|---------|
| P1 | `-p 1` | Critical - production issues, security, blockers. Never open overnight. |
| P2 | `-p 2` | Important - current sprint work, active features. |
| P3 | `-p 3` | Backlog - nice-to-have, future work, tech debt. Fine to leave open for weeks. |

## Bead Title Convention

Use a scope prefix matching the project area:

| Scope | Area |
|-------|------|
| `dashboard:` | UI components, pages, hooks, styling |
| `integration:` | Airtable, Asana, Slack, Google Drive, APIs |
| `content:` | AI content generation, prompts |
| `config:` | Project configuration, env, tooling |
| `deploy:` | Vercel deployment, CI/CD |

Examples:

```bash
br create -p 2 "integration: Add Airtable read adapter"
br create -p 1 "deploy: Fix Vercel build failure"
br create -p 3 "dashboard: Improve episode list layout"
```

## Bead Descriptions (MANDATORY)

Every bead MUST have a description. Add it immediately after creation. No exceptions.

```bash
br create -p 2 "integration: Add Asana task adapter"
br update <id> --description "$(cat <<'EOF'
## Context
Need read-only access to Asana tasks for production tracking.

## Task
Create adapter that fetches tasks from designated Asana projects.

## Files
- Create: src/services/adapters/asana.ts
- Modify: src/types/adapters.ts

## Acceptance Criteria
- [ ] Fetches tasks from configured project
- [ ] Returns typed response
- [ ] Build passes
EOF
)"
```

## Subagent Protocol

### At Start
```bash
br list                              # Check existing beads
br show <id>                         # If your task has a bead
br update <id> --status=in_progress  # Claim it
```

### During Work
Create beads for discovered subtasks:
```bash
br create -p 3 "Discovered: need to refactor X"
```

### At Completion
```bash
br close <id>                  # Mark complete
br sync --flush-only           # Export to JSONL
# Then commit and push (see /commit)
```

## Atomic Sizing

**Before creating a bead, ask: can one agent complete this in one session?**

- 1-3 acceptance criteria, 1-3 files = good atomic bead
- 4+ acceptance criteria or 4+ files = split into epic
- Multiple "and then..." = definitely needs epic split

## Closing vs Deleting

- **Close** (`br close <id>`): Work is done, bead completed successfully
- **Delete** (`br delete <id>`): Bead was wrong, invalid, or superseded. Tombstones it.
