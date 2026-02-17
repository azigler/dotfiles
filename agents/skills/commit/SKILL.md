---
name: commit
description: Create git commits following gitmoji conventions with bead integration
argument-hint: "[message]"
---

# /commit - Git Commit Convention

Create git commits following [gitmoji](https://gitmoji.dev/) conventions with atomic bead integration and co-authoring.

## When to Commit

- **Every bead closure** triggers a commit + push. One bead = one commit.
- **Natural checkpoints** between beads: file created, test passing, config updated.
- **Never batch** multiple beads into one commit.
- **Always push** after committing.

## Commit Message Format

```
<emoji> scope: short description

optional body explaining WHY

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

## Gitmoji Reference

| Emoji | Use for |
|-------|---------|
| :sparkles: | New feature or capability |
| :bug: | Bug fix |
| :memo: | Documentation changes |
| :recycle: | Refactoring (no behavior change) |
| :test_tube: | Tests |
| :wrench: | Configuration changes |
| :rocket: | Deployment and release |
| :fire: | Remove code or files |
| :lock: | Security fixes |
| :zap: | Performance improvements |
| :art: | Style, formatting, structure |
| :ambulance: | Critical hotfix |
| :lipstick: | UI/cosmetic changes |
| :construction: | Work in progress |
| :arrow_up: | Upgrade dependencies |
| :heavy_plus_sign: | Add dependency |
| :heavy_minus_sign: | Remove dependency |
| :truck: | Move or rename files |
| :boom: | Breaking changes |
| :package: | Chore/sync beads |

## Scope Reference

| Scope | Area |
|-------|------|
| `dashboard` | UI components, pages, hooks, styling |
| `integration` | Airtable, Asana, Slack, Google Drive, APIs |
| `content` | AI content generation, prompts |
| `config` | Project configuration, env, tooling |
| `deploy` | Vercel deployment, CI/CD |

## Workflow

### 0. Pre-Commit: Close Beads

```bash
br close <bead-id>         # Close completed beads
br sync --flush-only       # Export to JSONL
```

Close beads BEFORE committing so they're included in the commit diff.

### 1. Analyze Changes

```bash
git status
git diff --staged
git diff
```

### 2. Stage Specific Files

```bash
git add <specific-files>   # NEVER use git add -A or git add .
```

### 3. Create Commit

Always use HEREDOC for proper formatting:

```bash
git commit -m "$(cat <<'EOF'
:sparkles: integration: add Airtable read adapter

Provides read-only access to episodes and guest data
for the dashboard display layer.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

### 4. Push

```bash
git push
```

## Safety Reminders

- Stage specific files — avoid `git add -A` or `git add .`
- Never commit `.env.local` or credentials
- Create NEW commits, don't amend unless explicitly asked
- Always push after committing
- Always `br sync --flush-only` before committing
