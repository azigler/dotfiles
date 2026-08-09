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

Before doing anything else, check for the offboard-pending marker. In a
multi-session project (`refs/.handoff-per-window` present) the marker is
window-scoped via `handoff-path.sh` so each session honors only its OWN
pending marker; the check honors the scoped marker AND a legacy one (for the
transition / non-opted-in projects):

```bash
_HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type offboard_pending_path >/dev/null 2>&1 || offboard_pending_path() { printf '%s/.offboard-pending' "${1:-.}"; }
PENDING=$(offboard_pending_path .)
if [ -f "$PENDING" ] || [ -f .offboard-pending ]; then
  echo "Prior session ended without /offboard — running it retroactively first ($PENDING)."
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

   Then choose a starting move:

   - **Defined project**: run /spec to write the first specification bead
     (typed `spec`); orchestrator then dispatches /check → /test → /impl
   - **Exploratory work**: run /grok on the existing tree to understand
     what's there; persist findings as a `-t note` bead
   - **Just iterating**: skip the bootstrap and start working — but the
     next session will have less continuity

   What's the goal for this project?
   ```

4. **Don't auto-run** `br init` or `/init` — ASK the user which they
   want. They may want both, neither, or one depending on the project's
   nature (research, personal site, infra, throwaway prototype, etc.).

Otherwise (the normal case), continue to Step 1.

## Step 1: Read the foundation

Read these in order, in the main conversation, absorbing each before
continuing:

1. **`CLAUDE.md`** at the repo root — project definition, file layout,
   conventions, architecture decisions
2. **`MEMORY.md`** if present — user preferences, operational lessons
3. **The session handoff note** — the prior session's resume doc; pick up
   from where we left off. Resolve the path through `handoff-path.sh`
   (window-scoped in a multi-session project, else `refs/session-handoff.md`;
   legacy `.claude/plans/session-handoff.md` migrates via `git mv` on first
   touch). `handoff_read_path` returns this session's window-scoped note; in a
   per-window project whose scoped note is MISSING it returns that (nonexistent)
   scoped path and prints a `⚠️ handoff: NO note for this window` diagnostic on
   stderr rather than serving the legacy file. Only a project that is not opted
   in resolves to the legacy single file:

   ```bash
   _HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
   type handoff_read_path >/dev/null 2>&1 || handoff_read_path() { printf '%s/refs/session-handoff.md' "${1:-.}"; }
   HANDOFF=$(handoff_read_path .); echo "handoff <- $HANDOFF"; [ -f "$HANDOFF" ] && cat "$HANDOFF"
   ```

   **If that warning fires, act on it — do not onboard from nothing.** It lists
   the scoped notes that do exist. The usual cause is a renamed tmux window: this
   session is carrying the old name while its note moved to the new one (bd-msi5 —
   a session in `di` onboarded from a month-old legacy note after `work:di` became
   `work:pulse`). Read the right scoped note by hand, or rename the window.

## Step 1.5: Who you are — the seat's office and its last laurels

A fresh context knows what it does. This is the one cheap read that tells it
**who it is**: the office it holds and the recognition that office has
accumulated (`dotfiles-qnfk` R3; constitution Art. V — seats are named,
remembered, recognized).

```bash
_SH="$HOME/dotfiles/agents/lib/seat-history.sh"
[ -r "$_SH" ] && bash "$_SH" head --laurels 3 || true
```

One file head, and it prints nothing at all when this window is not a
registered seat — which is the normal case for a scratch window, not an
incident. So there is no error to handle and nothing to suppress: **output
means you hold a seat; silence means you do not.**

If it prints, carry the office line into the Step 7 orientation report. The
laurels are read-only history — a seat never writes its own (the file is
generated by `seat-history.sh` alone and carries an integrity checksum the
commit gate re-derives). Do not quote them back at Zig as achievement; they
are context for who is working, the way a handoff note is context for what
was worked on.

## Step 2: Load the toolkit digest — in the main session

Read `~/.claude/skills/TOOLKIT.md` with the Read tool, in THIS
conversation. It is the per-skill digest — job, fire-when,
prereqs/side-effects, and the single load-bearing anti-pattern for
every global skill — at **≈9.4k tokens (measured 2026-08-01: 37,756
bytes / 5,076 words, tokens at bytes÷4)**.

(History: until 2026-06-09 this step mandated reading every SKILL.md
body and claimed the cost was "a few-thousand tokens." Measured then:
59,929 words ≈ 75–85k tokens per session start, re-paid after every
compaction. Re-measured 2026-08-01: **37 bodies, 664,599 bytes /
99,174 words ≈ 166k tokens.** The digest preserves the
orchestrator-knows-its-toolkit property at **~6% of that cost**; full
bodies still load on invocation. The `~3k` / `~4%` this paragraph
carried until 2026-08-01 were the 2026-06-09 numbers quoted as if
current — the digest had tripled underneath them. TOOLKIT.md's header
carries the measurement commands; re-run them rather than re-guessing.)

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

> **The session-start "Open beads" list is a PARTIAL, priority-capped view** (it
> exists to protect context — a big backlog would otherwise bloat every onboard).
> Don't treat it as complete. When — and only when — you're about to commit to
> something meaningful, scan the *full* backlog then (`br list` / `bv --robot-triage`)
> to catch a higher-priority or duplicate item. Pull it just-in-time, not up front:
> loading the whole list at session start is the exact cost the cap removes.

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

## Step 5.5: Confirm the effort level — and plan escalations per-dispatch

Every session must start *conscious of its effort*. The session level is
`high` and stays there; intelligence above that is bought **per dispatch**,
not by moving the session. AGENTS.md "Effort" owns the policy, the
mechanism, and the per-model envelope table — read them there, and do not
carry a copy in this skill.

```bash
echo "${CLAUDE_EFFORT:-high}"   # the interactive session's effort level
```

- **`high` is correct — say so and move on.** It is the vendor default,
  identical to omitting the parameter.
- **Anything above `high` gets a line in the orientation summary** — report
  the reading and check the envelope table before research-shaped work,
  rather than treating it as an anomaly to escalate.
- **Escalate the step, not the session.** When one delegated step needs
  more than `high` — a divergent ideation pass, a frontier synthesis — run
  *that dispatch* through a **Workflow `agent(…, {effort:'xhigh'|'max'})`**;
  the bare `Agent` tool has no effort param and inherits the session level.
- **Mechanical / well-specified / convergent** work can go *down* to
  `medium`/`low` on its dispatches. Spending less there funds the moments
  that deserve `max`.

## Step 6: Check blockers

Before routing, verify nothing is blocking:

1. **Open P1 questions** affecting the target work? → `/check` first
2. **Prior branch unmerged?** → resolve before starting dependent work
3. **Dirty git state?** → clean it up first (commit or stash)
4. **In-progress beads from a prior session?** → resume or close them

If blockers exist, surface them to the user before proceeding.

## Step 7: Present and route

Show a concise orientation report:

```
## Orientation Report

**Version**: vN.M.R
**Active branch**: <name or main>
**Toolkit**: digest loaded (N skills; full bodies: <list or none>)
**Effort**: <$CLAUDE_EFFORT> (<`high` = correct / ⚠️ above `high` — web search is broken, ask Zig to reset>)
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

Some projects extend `/onboard` with their own steps (custom registries,
project-specific state files). Check the project's CLAUDE.md for any
onboarding extensions; if none, the core onboard / offboard cycle is all
that's needed.
