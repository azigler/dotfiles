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

**Re-anchor cwd FIRST. Single standalone `cd` command. Always.** The
harness shares shell state across orchestrator and subagent sessions —
when a worktree subagent finishes, the orchestrator's Bash-tool cwd
may have shifted into the just-finished `.claude/worktrees/agent-XXXX/`.
If you skip step 0, the merge silently no-ops ("Already up to date")
because you're checked out on the subagent's branch instead of main,
and the bead close records against the wrong branch. The failure mode
is silent and recurring. See bead `skills-library-1vs` for the
investigation + simplification (removed a failed defensive hook in
favor of this discipline).

```bash
# Step 0 (MANDATORY): standalone cd to project root. One command, no compound.
cd /home/ubuntu/<project>     # absolute path OR: cd "$(git -C <known> rev-parse --show-toplevel)"
```

Then proceed with the merge sequence:

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

**Why standalone cd, not `cd && cmd` compound:** the orchestrator's
shell state lives across Bash calls. A standalone `cd` cleanly
updates that persistent cwd; the subsequent commands see the
corrected state. A `cd && cmd` compound runs in a single call where
the hook layer reads cwd from stdin (pre-cd state) — defensive hooks
based on stdin.cwd will still trigger on the compound's downstream
command. Keep them separate.

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

## Cross-repo dispatch — subagent self-recovers worktree placement

If the dotfiles orchestrator (or any orchestrator that drives work across
multiple repos: cfp managing per-conference repos, the linearb fleet
managing agent clones, etc.) dispatches a worktree subagent for work in
a DIFFERENT repo than the orchestrator's project root, the worktree gets
created in the orchestrator's project — not the target. The
`WorktreeCreate` hook resolves cwd from the orchestrator's persistent
project context, NOT from `cd` commands in the most recent Bash call
(the harness resets Bash cwd to project root between calls; verified
2026-05-24 — the "Shell cwd was reset to ..." reminder after every
Bash run is literal, not cosmetic).

Symptoms when this misfires:
- Subagent's branch lives in the wrong repo (e.g., a dotfiles branch for
  vs14 work)
- `.beads/` symlink points at the wrong project's beads
- Orchestrator's post-merge step fails because the branch doesn't exist
  in the orchestrator's repo

Since the harness does NOT honor a cd-before-Agent pattern (the cd
doesn't persist past the Bash call), the actual fix lives in the
**dispatch prompt**: tell the subagent to detect-and-recover by
creating their OWN worktree in the target repo at session start.

```bash
# In the prompt CRITICAL block:
if [[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "/home/ubuntu/dotfiles"* ]]; then
  cd /home/ubuntu/<target-repo>
  WT="/tmp/<target>-agent-$(basename "$OLDPWD")"
  git worktree add "$WT" -b worktree-agent-$(basename "$OLDPWD")
  cd "$WT"
fi
# All subsequent work happens from $WT (the target-repo worktree).
```

The orchestrator's post-merge step then runs from the target repo
(NOT dotfiles), and the branch is in the target's git. Use `git
cherry-pick` instead of `git merge` if the pre-merge-worktree.sh hook
trips on cross-repo-branch-not-in-orchestrator (the hook reads from
the orchestrator's cwd-pinned project root and can't see the target's
branches).

Worked example (vs-4h1 → vs-q7m, 2026-05-24): the dotfiles orchestrator
dispatched the SS14 C# patches for `~/vacation-station-14`. First
attempt the subagent improvised a `/tmp/vs14-agent-...` recovery
worktree without the prompt asking; second attempt (vs-q7m) baked the
recovery into the prompt's CRITICAL block so it's deterministic.
Orchestrator merged via cherry-pick (the pre-merge-worktree.sh hook
blocked direct merge because it checked main..branch FROM the dotfiles
cwd where the branch doesn't exist as a real branch).

Longer-term fix (out of scope here): the `WorktreeCreate` hook could
accept a target-repo arg via env var or prompt convention. Filing as
a separate improvement bead when worth the lift.

## Submodules must be absorbed before subagent dispatch

If you dispatch a worktree subagent from inside a submodule whose `.git` is a
real directory (not a gitlink file), Claude Code's worktree heuristic walks up to
the parent and places the worktree in the parent's `.claude/worktrees/` — not
the submodule's. The `.beads/` symlink then points at the parent's beads (wrong
project), and `git merge worktree-agent-XXX` from the submodule's main fails
because the branch lives in the parent's git.

`git submodule add` registers an entry but does NOT move the local `.git/` into
the parent's `.git/modules/`. The second step is `git submodule absorbgitdirs
<path>` — easy to forget. The `post-bash-submodule-absorb-check.sh` hook now
auto-detects this after every `git submodule add` and warns. The session-start
hook also detects unabsorbed-submodule state when you enter such a directory.

If you see the warning, run it from the parent before dispatching subagents:

```bash
cd <parent>
git submodule absorbgitdirs <submodule-path>
# Verify: <submodule>/.git should now be a file containing "gitdir: ..."
```

If you discover after subagents already ran, the salvage path is: copy
deliverables from `<parent>/.claude/worktrees/agent-XXX/...` into the submodule
directly, commit with the original `Bead: <id>` trailer, then
`git worktree remove -f -f` + `git branch -D` on the parent, then
`git submodule absorbgitdirs` so future dispatches land right.

### Both absorption and the WorktreeCreate hook are required

Absorption is necessary — it gets the submodule's gitdir into the proper
`<parent>/.git/modules/<sub>/` location and replaces `<sub>/.git` with a
gitlink file. But absorption alone doesn't fix subagent worktree
placement; Claude Code's default heuristic still walks up to the parent.

The proper fix is the `WorktreeCreate` command-hook at
`~/.claude/hooks/worktree-create.sh` (wired in settings.json under
`hooks.WorktreeCreate`). It receives `{name, cwd, hook_event_name}` on
stdin and runs `git -C "$(git rev-parse --show-toplevel)" worktree add`
so the worktree lands in whichever git context the orchestrator's cwd
resolves to. For an absorbed submodule that's the submodule. The hook
logs to `/tmp/worktree-create-hook.log` for diagnosis.

Verified working 2026-05-18 across multiple dispatches. If you see
misplaced worktrees again, check that log first.

**One subagent-prompt convention worth keeping**: tell agents to
`cd "$WT_PATH"` (or whatever the canonical worktree path is) at session
start. The harness's shell-spawn doesn't auto-cd into the new worktree —
the agent's initial cwd is the orchestrator's cwd, not the worktree.
That's a one-line directive in the prompt, not a hook concern.

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

## Pre-merge Audit: the /scrutinize gate

**Tests passing is necessary but not sufficient.** Mock-heavy contract
tests can be satisfied by stub bodies that return the right shape but
do no real work. An impl agent's "All tests pass ✓" is a green flag
on the test runner, not on the implementation.

Run this audit as a **named gate** — [`/scrutinize`](../scrutinize/SKILL.md).
After an impl wave merges, before the quality gate / branch-to-main /
bead-close, dispatch a dedicated read-only adversarial reviewer
(`general-purpose` or `Explore`, never a worktree subagent). The
orchestrator does NOT scrutinize its own wave inline — a separate
agent with no stake in the wave completing is the point; the
orchestrator is structurally incented to declare the wave done. The
verdict is SHIP / FIX-FIRST / REJECT; the gate is not cleared until
SHIP. The checklist below is what that reviewer hunts for.

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
