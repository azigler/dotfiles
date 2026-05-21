---
description: Daily/weekly bead-cleanup discipline. Walks `br ready`, `br stale`, `br orphans`, `br epic close-eligible` and decides per bead — close, defer, escalate, or actually-do-the-work. Keeps the project's bead state honest so `br ready` is trustworthy as the "what's next" source of truth.
when_to_use: User asks to "triage the beads", "clean up the bead state", "see what's stale", "review the backlog". Also auto-fire as part of weekly `/housekeeping` rhythm.
---

# /triage — Bead state hygiene

Periodic walk through the bead population to keep state honest. Run
this when:

- `br ready` is too long to scan (probably has stale items)
- A new project owner joins (they need a clean view of in-flight work)
- Before a release (orphans + stale beads should not ship)
- Weekly, as part of `/housekeeping`

## Step 1: Snapshot the populations

```bash
br stats                          # high-level counts
br ready                          # what's actionable now
br stale --days 14                # no activity for 14+ days
br orphans                        # referenced in commits but still open
br blocked                        # waiting on dependencies
br epic status                    # epics + their close-eligibility
br list --status in_progress      # claimed but not closed (zombie risk)
```

If any of these surface unexpected items, you have triage work to do.

## Step 2: Walk each population

### `br orphans` (highest priority)

A bead in `br orphans` is referenced in a `Bead: bd-XXXX` commit
trailer but its status is still `open`. This means an agent
committed work but forgot to close.

```bash
for ID in $(br orphans --json | jq -r '.[].id'); do
  br show "$ID"
  # Decide: close (work is done), or reopen with notes (work is partial)
done
```

Most orphans should just close. Rare cases where work was partial:
add a `--notes` summary of what's left, then either close or leave
open with a follow-up bead linked.

### `br stale --days 14`

Beads with no activity for 2+ weeks. Decide per bead:

- **Done but forgotten** → close
- **Still relevant but blocked** → declare the dep via `br dep add`
  so it shows in `br blocked`, not `br stale`
- **Not now, but yes someday** → `br defer <id> "v0.4 cycle"` (or
  similar). Removes from `br ready`, surfaces via `br defer --list`
- **Won't happen** → `br close <id>` with a `--notes` reason
  ("won't fix: superseded by bd-YYYY")

### `br epic status`

Epics whose children are all closed but the epic itself is still open
are noise. Run `br epic close-eligible` to list them, then close
each:

```bash
br epic close-eligible
# Manually close the ones that are truly done
br close <epic-id>
```

Epics with children in mixed states are fine — they're tracking
real in-flight work.

### `br list --status in_progress`

A bead in `in_progress` status without recent activity is a zombie —
an agent claimed it and stopped. Either:

- The work IS continuing in a worktree → leave alone, optionally
  add a `--notes` "in flight, agent X working as of <date>"
- The work was abandoned → demote to `open` so another agent can
  claim it: `br update <id> --status open --notes "released claim"`

### `br blocked`

For each blocked bead, verify the blocker is real and current:

```bash
br dep tree <blocked-id>      # see what's blocking
```

If the blocker resolved (closed) but `br ready` still doesn't show
the dependent — `br dep cycles` to check for stuck deps. `br doctor`
to repair if state drifted between DB and JSONL.

## Step 3: Documentation pass

After the walk, update the project's CLAUDE.md if you discovered
patterns worth recording:

- Repeated stale beads in one area → document why work keeps stalling
- Repeated orphans from one agent → fix the agent's commit-close discipline
- New conventions surfaced during triage → encode in CLAUDE.md

## Step 4: Commit + summary

```bash
br sync --flush-only
git add .beads/issues.jsonl
git commit -m ":broom: triage: <N> closed, <M> deferred, <K> reopened

<short summary of what was found and resolved>"
git push
```

Brief the user with the before/after `br stats` numbers. Triage's
value is measurable — if the report says "no change," you didn't
triage, you just looked.

## Triage rhythm

| Cadence | Trigger |
|---|---|
| Weekly | Part of `/housekeeping` |
| Pre-release | Before cutting a tagged release |
| On-demand | When `br ready` is too long to scan, or when onboarding a new owner |

The orchestrator can fire `/triage` autonomously when it notices `br
ready` is unmanageable. Don't gate on "should I triage?" — if the
state's drifted, fix it.

## Anti-patterns

- ❌ **Closing without `--notes`** when the reason isn't "the work
  shipped" — closure-with-rationale is searchable; closure-without is opaque
- ❌ **Triaging without committing** — if you closed 8 beads and don't
  commit the JSONL, the next session sees them open again
- ❌ **Deferring everything to escape triage** — defer is for "yes,
  but not now"; if you mean "no, never," close with rationale

## See also

- [/housekeeping](../housekeeping/SKILL.md) — broader hygiene including
  this skill as a sub-step
- [/beads](../beads/SKILL.md) — fields, types, lifecycle
- [/beads reference/dependencies.md](../beads/reference/dependencies.md) — dep handling
- [/beads reference/epics.md](../beads/reference/epics.md) — epic close-eligibility
