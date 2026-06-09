---
description: Explicit "I'm done with my piece, here's what the next agent needs" wrap-up. Verifies the bead is genuinely handed-off-ready (acceptance criteria checked, --notes carry forward investigation, design decisions captured) before the orchestrator merges and dispatches the next wave. Subagents fire this BEFORE their final commit.
when_to_use: A subagent is wrapping up its work. Run before the final commit, not after — the handoff verification IS part of the work. Orchestrators can also fire this on themselves before /offboard to ensure the session leaves clean state for the next.
---

# /handoff — Wrap up cleanly

A subagent's last job is making sure the next agent can pick up cold.
This skill is the checklist that turns "I finished the work" into
"the work is genuinely handed off."

Run BEFORE the final commit. The handoff IS work — finding it
incomplete after committing means re-opening the bead.

## Step 1: Read your own bead

```bash
br show <your-bead-id>
```

Re-read what you committed to deliver. Compare to what's in your
working tree.

## Step 2: Walk the handoff checklist

| Field | Question | Action |
|---|---|---|
| `--description` | Is the WHY still accurate? | Update if scope shifted |
| `--acceptance-criteria` | Is every box checked? | Check via `br update --acceptance "..."` |
| `--design` | Are interface / data-structure decisions captured? | Append if missing |
| `--notes` | What did you learn that the next agent needs? | Append findings, gotchas, suspect areas |
| `--external-ref` | Is the upstream issue / Slack thread linked? | Add if missing |

If any acceptance-criteria box is unchecked, you're not done.
Either finish the work, or split the unchecked items into a
follow-up bead.

## Step 3: Verify deliverables

Different bead types verify differently:

| Type | Verify before handoff |
|---|---|
| `spec` | All sections populated, ≥10 test cases, OQs explicit |
| `decision` | Every P1 OQ has DECIDED status, conflicts RESOLVED, Implementation Readiness summary in --notes |
| `test` | Spec Section 5 cases all have tests, ≥5 edge/error tests, no source-file changes |
| `impl` (library / non-user-facing) | All tests pass, lint clean, doc comments on public API |
| `impl` (user-facing surface — web page, CLI, HTTP API) | Everything above PLUS runtime verification: run the artifact (`npm run dev` + curl, CLI invocation, etc.) and confirm every required component / subcommand / endpoint appears in the live output. Include the runtime output in the handoff summary. See "Runtime verification" below. |
| `bug` (fix) | Root cause documented, regression test added/updated, fix tested |
| `eval` | Evaluator runs in the eval suite, fails on the buggy state, passes on the fixed state |
| `epic` | All children closed, epic-level acceptance met |
| `note` | Findings clear enough that the next agent doesn't repeat the walk |

### Runtime verification (mandatory for user-facing impls)

If your bead produced a user-facing surface, tests passing is necessary
but not sufficient. Unit tests cover components in isolation against
mocks; they don't prove the final artifact actually composes the parts
into a working whole. Before commit:

- **Web page**: `npm run dev &` then `curl -s http://localhost:3000 > /tmp/rendered.html`. Grep for signature markers of every component the bead requires. Capture the markers + their grep result in the handoff "Runtime verification" block.
- **CLI**: invoke the canonical happy-path command. Capture stdout / exit code in the handoff block.
- **HTTP API**: hit every endpoint with `curl`. Capture response shape + status in the handoff block.

Without a Runtime verification block in your handoff, the orchestrator
treats your delivery as artifact-shaped only and may refuse to merge
until you demonstrate the artifact actually works. (Precedent:
skills-library-8l6, 2026-05-18 — passed every artifact-shaped check
but shipped a static skeleton page; cost a full second wave to fix.)

## Step 4: Pre-merge handoff message (subagent → orchestrator)

In your final summary to the orchestrator, include:

```
## Done — bead <id>

**Branch**: worktree-agent-XXXX
**Commits**: <hash> (and any others)

**What I shipped**:
- <bullet>
- ...

**What I learned (for the next agent)**:
- <gotcha or design note>
- ...

**Open follow-ups** (not blocking this bead's close):
- bd-YYYY: <new bead I created for spillover>
- (or: "none")

**Verification I ran**:
- Tests: <pass/fail counts>
- Lint: <clean / N errors>
- Project quality gate: <pass/fail>

**Runtime verification** (mandatory for user-facing impls; omit if not applicable):
- Command run: <e.g. `npm run dev` + `curl localhost:3000`, or `./bin/foo --help`>
- Output excerpt: <enough to prove the artifact composes correctly — grep results showing each required component / subcommand / endpoint is present in the live output>
- Verdict: <"all required components present" / "missing: X, Y">

**Ready to merge**: yes / no (and why if no)
```

This is the message text the orchestrator sees on subagent return.
The clearer this is, the faster the orchestrator can merge + dispatch
the next wave.

## Step 5: Commit

The handoff verification is the prerequisite for the commit. If
Step 2 found gaps, fix them, then Step 5.

```bash
git add <specific-files>
git add .beads/issues.jsonl
git commit -m "<gitmoji> <scope>: <subject>

<body — what changed and why>

Bead: <your-bead-id>
Co-Authored-By: ..."
```

Do NOT push from a worktree (the orchestrator handles merge + push).
See `/commit` "Worktree exception."

## Orchestrator-level handoff (across sessions)

When the orchestrator runs `/handoff` on itself (before
`/offboard`), the checklist is similar but cross-bead:

- All in-flight subagents have either returned or been documented as in-flight
- Worktrees with closed beads are cleaned up
- Next session's plan is in `refs/session-handoff.md` (written by `/offboard`)

This is mostly redundant with `/offboard` — fire it explicitly only
when you want a sanity-check before context compaction.

## Anti-patterns

- ❌ **Marking acceptance criteria checked without verifying** — if
  the box says "tests pass" and you didn't run the tests, you didn't
  hand off cleanly
- ❌ **Push from a worktree subagent** — orchestrator merges; pushing
  from worktrees creates stale remote branches
- ❌ **Empty `--notes`** when you encountered surprises — those are the
  bytes the next agent needs most
- ❌ **Closing the bead inside `/handoff`** — `/handoff` is for the
  subagent; the orchestrator closes the bead after merge

## See also

- [/beads](../beads/SKILL.md) — fields and discipline
- [/commit](../commit/SKILL.md) — commit conventions
- [/offboard](../offboard/SKILL.md) — session-level handoff (orchestrator)
- [/orchestrator](../orchestrator/SKILL.md) — merge / cleanup post-handoff
