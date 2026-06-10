---
description: Create git commits following gitmoji conventions with bead integration. Claude commits autonomously at natural checkpoints (bead closure, file created, test passing) — this is expected, not an extra confirmation step.
argument-hint: "[message]"
allowed-tools: Bash(git add *) Bash(git commit *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git push) Bash(git push *) Bash(br close *) Bash(br sync *)
when_to_use: Autonomous-OK at natural checkpoints (bead closure, test pass, config update); also when the user asks for a specific commit. Runs AFTER bead closure and selective staging.
---

# /commit - Git Commit Convention

## When to Commit

- **Every bead closure** triggers a commit + push. One bead = one commit.
- **Natural checkpoints** between beads: file created, test passing, config updated.
- **Never batch** multiple beads into one commit.
- **Always push** after committing -- unless you're in a worktree (branch starts with `worktree-agent-`).

## Commit Message Format

```
<emoji> scope: short description

optional body explaining WHY

Bead: <bead-id>
Co-Authored-By: <the trailer your harness specifies>
```

Use a scope prefix that matches the area of the codebase you changed. Get the bead
ID from your task prompt or `br list`. Close the bead BEFORE committing (see `/beads`).

**Co-Authored-By:** your harness states the exact trailer for the
model you're running as (in the git guidance of your system prompt,
e.g. `Co-Authored-By: Claude <model> <noreply@anthropic.com>`). Use
that line verbatim. Do NOT copy a model name from this file or from
old commits — skills outlive model versions, and a hardcoded name
misattributes every commit made under a newer model (this file pinned
"Opus 4.6" until 2026-06-09).

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

## Workflow

### 1. Close bead, analyze, stage

```bash
br close <bead-id>
br sync --flush-only
git status && git diff
git add <specific-files>                       # NEVER git add -A
git add .beads/issues.jsonl                    # ONLY on the default branch — see Bead-state exception
```

### 2. Commit with HEREDOC

```bash
git commit -m "$(cat <<'EOF'
:sparkles: auth: add JWT token refresh

Prevents session expiry during long-running operations.

Bead: bd-xxx
Co-Authored-By: <the trailer your harness specifies>
EOF
)"
```

### 3. Push

```bash
git push
```

**Worktree exception:** If you are working in a git worktree (your branch name
starts with `worktree-agent-`), do NOT push. The orchestrator handles merging
and pushing after your work is complete. Pushing from a worktree creates stale
remote branches.

**Bead-state exception:** stage `.beads/issues.jsonl` ONLY when committing on
the default branch (main). On a feature branch, leave it unstaged — bead-state
commits on branches fork the ledger, and git later auto-merges the two
versions "cleanly" while silently keeping BOTH sides' line for the same bead.
A duplicate id makes the JSONL invalid to `br` (caught live 2026-06-09,
dashboard-dev-interrupted PR #9: bd-dtz duplicated as in_progress + closed).
The `post-bash-beads-merge-check` hook flags the artifact after merges;
remediation is `git checkout <default-branch> -- .beads/issues.jsonl` or
`br sync --merge`, then `br doctor`. Don't create the artifact in the first
place. (In worktrees, `.beads/` is a symlink to the main checkout — never
stage anything under it; see /handoff Step 5.)

## Safety

- Stage specific files -- never `git add -A` or `git add .`
- Never commit `.env`, credentials, or secrets
- Create NEW commits -- don't amend unless explicitly asked
- If a pre-commit hook blocks, fix the errors and retry (see `/lint`)
