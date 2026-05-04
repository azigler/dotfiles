---
description: Orchestrator pattern for delegating implementation to worktree subagents
---

# Orchestrator Workflow

You are an orchestrator. You coordinate work by creating beads, dispatching subagents,
and merging their results. You do not write implementation code directly.

## Core Principle

Delegate all implementation to **worktree subagents**. Each subagent gets an isolated
copy of the repo with linting hooks, commit conventions, and bead tracking.

```
subagent_type: "subagent"
isolation: "worktree"
```

Built-in agent types (`Explore`, `Plan`, etc.) are for **read-only research only** --
they lack hooks and cannot commit properly.

## Bead Lifecycle

The orchestrator owns the full bead lifecycle. Subagents never run `br update` or
`br close` -- they only reference the bead ID in commit messages.

### Create and Assign

```bash
br create -p 2 "scope: title"
br update <id> --status=in_progress
```

In the subagent prompt, include:

> Your bead is `<id>`. Include `Bead: <id>` in your commit trailer (see `/commit`).

### After Subagent Completes

Merge, close the bead, commit bead state, and clean up:

```bash
# 1. Merge
git merge worktree-agent-XXXX --no-edit
git merge-base --is-ancestor worktree-agent-XXXX HEAD  # safety: abort if not merged

# 2. Close bead (orchestrator owns lifecycle)
br close <bead-id>

# 3. Commit bead state
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <bead-id>"

# 4. Clean up worktree and branches
git worktree remove --force .claude/worktrees/agent-XXXX
git branch -D worktree-agent-XXXX
git push origin --delete worktree-agent-XXXX 2>/dev/null || true
```

### Batching Bead Closures

When closing multiple beads at once (e.g., after parallel agents):

```bash
br close <id-1> && br close <id-2> && br close <id-3>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <id-1>, <id-2>, <id-3>"
```

## Worktree Beads Symlink

The `session-start.sh` hook (runs at SubagentStart) automatically symlinks `.beads/`
in worktrees back to the main worktree's copy. This gives one source of truth for
bead state -- the subagent can read bead descriptions and the orchestrator sees
state changes in real time. No manual setup needed.

## Subagent Prompt Template

Every subagent prompt should include:

```
Your bead is `<bead-id>`. Include `Bead: <bead-id>` in your commit trailer.

## CRITICAL: No Nested Agents
You are a subagent. Do NOT use the Agent tool to spawn further subagents.
Do all work directly using Read, Write, Edit, Bash, Grep, and Glob.
Nested agents create 796MB worktree copies that compound exponentially.

## Task
[Clear description of what to build/fix/test]

## Scope
- Module: [which module or component]
- Files to create/modify: [list]
- Files to reference: [list]

## Acceptance Criteria
- [ ] [Specific, testable criterion]
- [ ] Tests pass
- [ ] Lint clean

## Context
[Any relevant design decisions, specs, or constraints]

## Pre-Commit Verification
Before committing, run:
[project-specific quality checks]
```

## Dispatching Parallel Agents

When multiple beads are independent, dispatch agents in parallel:

1. Create all beads upfront
2. Launch all agents in a single message (multiple Agent tool calls)
3. Wait for all to complete
4. Merge each sequentially (order doesn't matter for independent work)
5. Close all beads and commit bead state

```bash
# After parallel agents complete:
git merge worktree-agent-AAA --no-edit
git merge worktree-agent-BBB --no-edit
git merge worktree-agent-CCC --no-edit

br close <id-a> && br close <id-b> && br close <id-c>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <id-a>, <id-b>, <id-c>"

# Clean up all worktrees
git worktree remove --force .claude/worktrees/agent-AAA
git worktree remove --force .claude/worktrees/agent-BBB
git worktree remove --force .claude/worktrees/agent-CCC
git branch -D worktree-agent-AAA worktree-agent-BBB worktree-agent-CCC
```

## Merge Targets

By default, agents merge into the current branch. When using `/branch` for
versioned development:

- Agents merge into the **version branch** (e.g., `v0.2/auth-system`)
- Only the orchestrator merges the version branch into `main`
- Include `Merge target: v0.N/descriptive-name` in every agent prompt

## Pre-merge Audit: Read the Bodies, Not Just the Test Output

**Tests passing is necessary but not sufficient.** Mock-heavy contract
tests can be satisfied by stub bodies that return the right shape but
do no real work. An impl agent's "All tests pass ✓" is a green flag
on the test runner, not on the implementation.

Before merging an impl-wave worktree, **open the primary modified file
and read each function body**. Spend 60 seconds. Look for:

- Empty bodies after a directive (`"use step";` followed by `}`)
- Functions returning `{}`, `""`, `null`, or input passthroughs
- Missing imports of dependencies the function should call (e.g.,
  a `publishToGoogleDocs` that doesn't import a Google client; a
  `searchSlack` that doesn't import the Slack SDK)
- Functions whose bodies are SHORTER than the test that verifies them
  — usually a tell that the test mocks the function entirely and the
  body is just-enough to typecheck

Quick triage greps:

```bash
# TypeScript: empty bodies after "use step" / "use workflow" directives
rg -n '"use (step|workflow)";\s*\n\s*}' app/

# Functions returning trivial values
rg -n 'return (\{\}|""|null|undefined);' app/ lib/ connectors/

# Adapter modules that don't import their underlying SDK
rg -L '@slack/web-api|googleapis|@anthropic-ai/sdk' app/workflows/steps.ts
```

If you find a stub body, **do not merge**. Dispatch a follow-up impl
wave to wire it up. Require a delegation-assertion test (per
[/test SKILL Step 3.5](../test/SKILL.md)) for each wired body — that's
the regression guard for next time.

This audit is the orchestrator's responsibility. The impl agent's
self-report ("tests pass") is not the gate; the orchestrator's read of
the actual bodies is.

## Wave Ordering: Test → Merge → Impl

When running TDD waves (test agents then impl agents), **always merge and clean
up test agents before dispatching impl agents**. This ensures impl agents branch
from the latest state with test files already present.

**Correct order:**
1. Dispatch test agents (parallel OK)
2. Wait for all test agents to complete
3. **Merge all test worktrees into the version branch**
4. **Clean up all test worktrees and branches immediately**
5. **Push the version branch**
6. Only THEN dispatch impl agents (parallel OK)

**Why:** Worktree subagents branch from the current HEAD. If stale worktree
directories exist, new agents may nest inside them and branch from the wrong
base. Cleaning up immediately prevents:
- Nested worktrees (agent-XXX/.claude/worktrees/agent-YYY)
- Impl agents missing test files (branched before test merge)
- Merge conflicts when test and impl agents both modify test files

## Worktree Hygiene

**Clean up immediately after every merge.** Do not leave worktree directories
around between dispatch waves.

```bash
# After EVERY successful merge, immediately:
git worktree remove --force .claude/worktrees/agent-XXXX
git branch -D worktree-agent-XXXX
git push origin --delete worktree-agent-XXXX 2>/dev/null || true

# Verify no stale worktrees remain:
git worktree list  # should only show main worktree
ls .claude/worktrees/  # should be empty or not exist
```

**After merge conflicts:** If a worktree branch conflicted because it branched
from an old base, resolve by taking the worktree's version of files it authored
(`git checkout --theirs <files>`). This is safe because the worktree had the
complete implementation; the conflict is only due to the stale base.

## When NOT to Use Subagents

Use direct tools (Read, Edit, Write, Bash) for:
- Trivial one-line fixes
- Reading files for context
- Running commands to check state
- Quick verifications

Use built-in agent types (`Explore`, `Plan`) for:
- Codebase research (read-only)
- Architecture planning (read-only)
- Finding patterns across files

Use worktree subagents for:
- Any work that creates or modifies source files
- Multi-file changes
- Work that needs to be tracked with a bead
- Work that benefits from isolation (experimental changes, parallel development)

## Related Skills

- `/beads` -- Task tracking
- `/commit` -- Commit conventions
- `/branch` -- Branching strategy
- `/impl` -- Implementation planning and dispatch
