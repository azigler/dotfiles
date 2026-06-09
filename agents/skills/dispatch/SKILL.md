---
description: Canonical subagent prompt template. Renders the no-nested-agents rule, bead ID, merge target, wave-position context, and verification gates into a consistent prompt skeleton — so each subagent dispatch starts with the same disciplined framing rather than ad-hoc orchestrator drift.
when_to_use: The orchestrator is about to dispatch a worktree subagent (via `subagent_type: "subagent"`, `isolation: "worktree"`). Before composing the prompt freehand, render via /dispatch so nothing critical gets dropped.
---

# /dispatch — Subagent prompt template

The orchestrator dispatches subagents constantly. Each prompt must
include certain load-bearing instructions or the subagent fails
predictably (nested agents, wrong merge target, missing verification).
This skill is the canonical template so dispatches don't drift across
sessions.

## When to fire

Before EVERY worktree-subagent dispatch. The template is short
enough to inline; the discipline is having it on hand so you don't
forget pieces.

Skip for built-in agent types (`Explore`, `Plan`) — those don't write
code and don't have the same risk profile.

## Enforced by structure — don't paste these (changed 2026-06-09)

Two invariants that used to be mandatory prompt blocks are now
enforced by the harness itself:

- **No nested agents** — the `subagent` agent type's tool list has no
  Agent tool, and its definition (`claude/agents/subagent.md` Hard
  Rule 4) states the rule. Spawning is impossible, not just forbidden.
- **Worktree path discipline** — `pre-tool-use-worktree-guard.sh`
  blocks main-root writes (bd-n47), and subagent.md Hard Rule 3
  states the rule.

Paste the old CRITICAL blocks only when dispatching a NON-standard
agent type to write code (rare — prefer fixing the agent definition
instead). Every dispatch prompt now carries only task-specific
content.

## Mandatory blocks (every dispatch)

```
Your bead is `<bead-id>`. Include `Bead: <bead-id>` in your commit trailer.
Merge target: `<branch>` (NOT main, unless project doesn't use /branch).

## Task
[1-3 sentences: what to build/fix/test/spec/check, with the bead ID for context]

## Context
- Spec: <bead-id or specs/NN.md path>
- Decisions: <bead-id from /check>
- Tests file (if impl): <path>
- Files to read first: <list>
- Files to NOT modify: <list — e.g., test files for impl agents>

## Acceptance criteria
[Copy from the bead's --acceptance-criteria, OR reference: "see bead <id>"]

## Pre-commit verification
- All tests pass
- Lint clean (see /lint)
- [Project-specific quality gate per CLAUDE.md]
- /handoff checklist clears

## Final summary format
[Reference /handoff Step 4 — the message the orchestrator parses on return]
```

## Type-specific additions

### For test agents

Add:
```
## CRITICAL: tests-only output
You write ONLY test files. Do NOT create or modify implementation
source files. Imports point at real module paths even if the modules
don't exist yet — see /test SKILL Step 1 for the import strategy.
```

### For impl agents

Add:
```
## CRITICAL: do not modify tests
The test file at <path> is the contract. Adapt your implementation
to satisfy what tests import. If a test seems wrong, flag it; do NOT
rewrite it.
```

### For spec agents

Add:
```
## Spec output: bead --description (NOT a file)
Write the spec content to bead `<bead-id>` --description, typed `spec`.
See /spec SKILL Step 4 for the section structure.
```

### For check agents

Add:
```
## Output: append decisions to spec bead --notes
Walk OQs from spec bead `<spec-bead-id>` --description Section 6.
Record each decision in --notes (NOT --description; spec agent owns
that). See /check SKILL Step 3.
```

### For fix agents

Add:
```
## CRITICAL: regression guard mandatory
After the fix lands, EITHER update an existing test that should have
caught the bug OR add a new test that fails on the buggy state and
passes on the fixed state. The fix without the guard is incomplete.
See /fix SKILL Step 2 Phase B.
```

### For scrutinize agents

Dispatched as `general-purpose` or `Explore` (read-only review — NOT
worktree subagents). Add:
```
## CRITICAL: read-only and adversarial
You write nothing. You are not a fixer. Your job is to disprove
"done" — find where the impl wave's claims are false. Assume the
self-report is optimistic and the tests are weaker than they look.
Verdict: SHIP / FIX-FIRST / REJECT, every finding with file:line
evidence. "Found nothing" is a valid, honest verdict — do not invent
issues. See /scrutinize SKILL for the full hunt list.
```

### For impl agents on user-facing surfaces (web page, CLI, HTTP API)

Add:
```
## CRITICAL: tests passing is necessary but not sufficient

You are shipping a USER-FACING surface. Unit tests cover components in
isolation against mocks — they do NOT prove the final artifact (page,
binary, route) composes those parts into a working whole.

Before declaring done, you MUST runtime-verify the artifact:

- Web app: start `npm run dev` (or equivalent), curl the rendered HTML,
  grep for signature markers of every component the bead requires.
  Every component the visitor should see must appear in the output.
- CLI: invoke the canonical happy-path command(s); confirm exit 0 and
  expected output.
- HTTP API: hit every documented endpoint; confirm a real handler runs
  (not a 501 / placeholder).

Include the runtime-verification output in your /handoff summary under
a "Runtime verification" block. Without that block, the orchestrator
treats your handoff as artifact-shaped (i.e. tests-pass-only) and will
refuse to merge until you demonstrate the artifact actually works.

Real precedent (2026-05-18, skills-library-8l6): a sandbox impl shipped
5 React components + 84 passing unit tests + clean validate.sh + clean
tsc — every artifact-shaped criterion green — but the root page was
a static skeleton that didn't import any of the components. Runtime
verification would have caught it in 60 seconds. Don't repeat it.
```

### For cross-repo dispatch (orchestrator anchored in a different repo)

When the orchestrator's project root is NOT the target repo for this
dispatch — dotfiles orchestrator → vacation-station-14; cfp/mise →
cfp/talk-mise-en-place; linearb fleet → agent clones — the harness
places the worktree in the ORCHESTRATOR's repo, not the target. The
subagent must self-recover. Paste this as the FIRST CRITICAL block,
with `TARGET_REPO` filled in to the target repo's absolute path:

```
## CRITICAL: cross-repo recovery (your worktree may be in the wrong repo)

The orchestrator's anchor repo is NOT your target. The harness's
worktree placement follows the orchestrator's persistent cwd, not the
`cd` in the dispatch message. Run this as your FIRST Bash call before
any other work — detect mis-placement and recover. The check is
anchor-agnostic, so it stays correct regardless of which repo the
orchestrator is in:

TARGET_REPO="/home/ubuntu/<target-repo-absolute-path>"
CURRENT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ "$CURRENT_TOPLEVEL" != "$TARGET_REPO"* ]]; then
  WT="/tmp/$(basename "$TARGET_REPO")-agent-$(basename "$CURRENT_TOPLEVEL")"
  cd "$TARGET_REPO"
  git worktree add "$WT" -b "worktree-agent-$(basename "$CURRENT_TOPLEVEL")"
  cd "$WT"
  rm -rf .beads && ln -s "$TARGET_REPO/.beads" .beads
fi
# All subsequent work happens here.
```

The orchestrator's post-merge step then runs from `$TARGET_REPO`, not
its own anchor, and may need `git cherry-pick` instead of `git merge`
if the pre-merge-worktree.sh hook trips on cross-repo-branch state.

See [/orchestrator](../orchestrator/SKILL.md) "Cross-repo dispatch"
for full background, symptoms, and worked examples.

## Wave-position context

Include this when the dispatch is part of a multi-wave flow (TDD,
spec→check→test→impl, etc.):

```
## Wave position
This is wave <N> of <total>. Prior waves merged: <list>.
Subsequent waves blocked on this completing: <list>.
```

The subagent doesn't need to act on this, but knowing where it sits
in the flow helps it write better commit messages and `/handoff`
summaries.

## Output (orchestrator side)

After composing the prompt:

1. Verify all mandatory blocks are present
2. Dispatch via Agent tool with `subagent_type: "subagent"` + `isolation: "worktree"`
3. Note the bead ID and worktree branch name in your local task tracker
4. Wait for return; parse the `/handoff` Step 4 summary

## Anti-patterns

- ❌ **Dispatching code-writing work to built-in agent types**
  (Explore / general-purpose) — the no-nested-agents and
  path-discipline protections only exist on
  `subagent_type: "subagent"`; built-ins lack the definition's Hard
  Rules and the lint/commit hooks.
- ❌ **Ambiguous merge target** — "merge into main" when project uses
  `/branch` causes integration nightmares. Always be explicit.
- ❌ **No acceptance criteria reference** — the subagent doesn't know
  when it's done; it'll over-build or under-build.
- ❌ **Dispatching test + impl in the same wave** — see /orchestrator
  Wave Ordering. Tests merge BEFORE impl dispatches.
- ❌ **Including the full `/dispatch` SKILL in the prompt** — the
  subagent doesn't need this skill; it needs the rendered prompt.

## See also

- [/orchestrator](../orchestrator/SKILL.md) — wave ordering and worktree hygiene
- [/handoff](../handoff/SKILL.md) — the return-side counterpart
- [/spec](../spec/SKILL.md), [/check](../check/SKILL.md), [/test](../test/SKILL.md), [/impl](../impl/SKILL.md), [/fix](../fix/SKILL.md) — type-specific guidance
