---
description: Session entrypoint -- discover state, honor any pending offboard, classify work, route to next action. Paired with /offboard.
when_to_use: Start of every orchestrator session (mandatory), and immediately after context compaction. Step 0 retroactively honors a prior session's .offboard-pending marker.
---

# /onboard

Run at the start of every session. Discovers current state from live
sources (no hardcoded refs), honors any pending `/offboard` from a
prior session, and surfaces what to work on.

Paired with `/offboard` (run at session end or before context compaction).
Together they bracket every orchestrator session.

## Step 0: Honor any pending offboard

Before doing anything else, check for the offboard-pending marker:

```bash
if [ -f .offboard-pending ]; then
  echo "Prior session ended without /offboard — running it retroactively first."
  # Stop and run /offboard with the prior session's ID, then come back.
fi
```

If the marker exists, the previous session ended (or compacted) without
`/offboard` running. The session JSONL for that prior session is still
on disk (compaction only affects live context, not the log). Run
`/offboard` against it before continuing.

## Step 0.5: Detect a first-session-on-a-new-project

Before reading the foundation, check whether this is genuinely a
fresh project — none of the usual artifacts exist:

```bash
[ ! -f CLAUDE.md ] && [ ! -d .beads ] && [ ! -f refs/session-handoff.md ] \
  && [ ! -f .claude/plans/session-handoff.md ] \
  && [ "$(git log --oneline 2>/dev/null | wc -l)" -le 1 ] \
  && echo "FIRST_SESSION"
```

If FIRST_SESSION:

1. **Don't error on missing files** — they're expected.
2. **Skip Steps 4 (find current position) and 6 (check blockers)** — there's
   no plan and nothing to be blocked on.
3. **Offer the bootstrap menu** before any work happens:

   ```
   ## New project — first session

   No CLAUDE.md, no beads, no plan files. Before we work, want to set up:

   - **CLAUDE.md** — project conventions doc. Run /init (Claude Code
     built-in) to bootstrap one from a codebase scan.
   - **beads** — task tracking. `br init` creates `.beads/` so the
     orchestrator + subagents have a shared task store.
     [/beads](../beads/SKILL.md)
   - **cost-tracking** — per-session token-cost ledger.
     `cp ~/.claude/skills/cost-tracking/reference/ledger-template.md refs/cost-tracking.md`
     then `/offboard` will auto-log each session.
     [/cost-tracking](../cost-tracking/SKILL.md)

   Then choose a starting move:

   - **Defined project**: run /spec to write the first specification bead
     (typed `spec`); orchestrator then dispatches /check → /test → /impl
   - **Exploratory work**: run /grok on the existing tree to understand
     what's there; persist findings as a `-t note` bead
   - **Just iterating**: skip the bootstrap and start working — but the
     next session will have less continuity

   What's the goal for this project?
   ```

4. **Don't auto-run** any of `br init`, the cost-tracking copy, or
   `/init` — ASK the user which they want. They may want all three,
   none, or a subset depending on the project's nature (research,
   personal site, infra, throwaway prototype, etc.).

Otherwise (the normal case), continue to Step 1.

## Step 1: Read the foundation

Read these in order, in the main conversation, absorbing each before
continuing:

1. **`CLAUDE.md`** at the repo root — project definition, file layout,
   conventions, architecture decisions
2. **`MEMORY.md`** if present — user preferences, operational lessons
3. **`refs/session-handoff.md`** (legacy: `.claude/plans/session-handoff.md`
   — migrate via `git mv` on first touch) if present — the prior
   session's handoff note. Pick up from where we left off

## Step 2: Load the toolkit digest — in the main session

Read `~/.claude/skills/TOOLKIT.md` with the Read tool, in THIS
conversation. It is the per-skill digest — job, fire-when,
prereqs/side-effects, and the single load-bearing anti-pattern for
every global skill — at ~3k tokens.

(History: until 2026-06-09 this step mandated reading every SKILL.md
body and claimed the cost was "a few-thousand tokens." Measured:
59,929 words ≈ 75–85k tokens per session start, re-paid after every
compaction. The digest preserves the orchestrator-knows-its-toolkit
property at ~4% of that cost; full bodies still load on invocation.)

Also check for project-local skills the digest doesn't cover:

```bash
ls ./.claude/skills/*/SKILL.md 2>/dev/null
```

Read project-local INDEX.md / skill descriptions if present.

Then load FULL bodies selectively, up front, for the 1–3 skills
today's classified work (Step 5) actually leans on — e.g. read
/impl + /dispatch bodies before an implementation session, /talk
before deck work. Everything else loads when invoked.

Two ways this step still gets done wrong — both forbidden:

- ❌ **Delegating the TOOLKIT read to a subagent.** Its context is
  discarded when it returns — read it yourself.
- ❌ **Skipping it because the skill listing "looks sufficient."** The
  listing has descriptions; the digest has the anti-patterns and
  side-effect flags. The anti-pattern you skip is the one you needed.

If TOOLKIT.md is missing or visibly stale, fall back to reading the
full bodies and file a bead to regenerate it (post-write-skill.sh
nudges digest updates on every skill edit).

When done you can state **"Toolkit digest loaded (N skills; full
bodies: <list or none>)."** Step 7's orientation report requires that
line.

## Step 3: Discover live state

```bash
git tag --sort=-v:refname | head -5         # current version + recent tags
git log --oneline -5                        # recent commits
git branch -a | grep -v worktree            # active branches
git status --short                          # dirty files
br list                                     # open beads (if br is installed)
```

From this, determine:
- **Version**: latest tag (e.g., `v0.2.3`)
- **Active branch**: any non-main branch suggests work in flight
- **Open beads**: in-progress beads mean interrupted work to resume
- **Dirty files**: uncommitted changes need attention before new work

## Step 4: Find current position

Locate the project's roadmap or plan files. Common locations:

- `docs/ROADMAP.md`, `refs/plans/`, `TODO.md`, `PLAN.md`
- Design decision docs or ADRs
- Any plan file referenced by the prior `session-handoff.md`

Walk the plan steps. Find the first incomplete item — that's where the
work resumes.

## Step 5: Classify the work

Match the next action to a skill. Some common pipelines:

| Domain | Skill | When |
|---|---|---|
| **Spec** | `/spec` | Writing or amending a specification |
| **Check** | `/check` | Deciding open questions, resolving conflicts |
| **Test** | `/test` | Writing tests before implementation (TDD) |
| **Impl** | `/impl` | Building code until tests pass |
| **Housekeeping** | `/housekeeping` | Mechanical cleanup, doc refresh |

Some projects also use:

| Domain | Skill | When | Where |
|---|---|---|---|
| Branch | `/branch` | Versioned branch + tag workflow | Project-local (e.g. lb-agent-factory, reef) |
| Release | `/release` | Cut a tagged release with changelog + GH release | Project-local |

If the project uses a different pipeline, follow its `CLAUDE.md`.

## Step 6: Check blockers

Before routing, verify nothing is blocking:

1. **Open P1 questions** affecting the target work? → `/check` first
2. **Prior branch unmerged?** → resolve before starting dependent work
3. **Dirty git state?** → clean it up first (commit or stash)
4. **In-progress beads from a prior session?** → resume or close them
5. **`.cost-pending` from a subagent stop?** → run that project's
   cost-tracking skill (if any) to clear it

If blockers exist, surface them to the user before proceeding.

## Step 7: Present and route

Show a concise orientation report:

```
## Orientation Report

**Version**: vN.M.R
**Active branch**: <name or main>
**Toolkit**: digest loaded (N skills; full bodies: <list or none>)
**Position**: <where in the plan>
**Active plan**: <plan file path, if any>
**Open beads**: <count, with priorities>
**Blockers**: <none / list>

**Recommended next action**: <skill> / <description>
```

Then invoke the appropriate skill or wait for the user to redirect.

## Post-compaction recovery

If you're resuming after context compaction:

1. **Do NOT immediately create branches or beads.** Onboard first.
2. **Read the active plan file** if one exists. It has the phase breakdown.
3. **Compare the plan against git history and live state** to see what's
   already done. Don't redo completed work.
4. **Present findings** before taking any action. The user may have
   context that wasn't captured in the handoff note.

The most common post-compaction mistake is jumping straight to `/impl`
when the current phase actually needs `/spec` or `/check`. Always
classify the work first.

## Pair with /offboard

Every orchestrator session should end with `/offboard`. If it doesn't,
the `SessionEnd` hook (`session-end.sh`) leaves `.offboard-pending` as
a marker. The next session's `/onboard` Step 0 checks for that and runs
offboard retroactively.

## Project-specific extensions

Some projects extend `/onboard` with their own steps (cost-tracking
ledgers, custom registries, etc.). Look for:

- `refs/cost-tracking.md` (legacy: `.claude/plans/cost-tracking.md`) —
  if present, the project tracks per-session token cost. `/offboard`
  updates it.
- `refs/models-manifest.md` (legacy: `.claude/plans/models-manifest.md`)
  — model pricing reference for cost-tracking computations.

If those files don't exist, skip those steps. The core onboard /
offboard cycle works without them.
