---
description: Task tracking with beads-rust (br) — agent-first issue tracker (SQLite + JSONL). Orchestrator creates and closes beads; subagents claim and reference them. One bead = one commit. Beads carry the full handoff context another agent needs to pick up cold (description, design, acceptance criteria, notes — separate fields, all populated).
argument-hint: "[list|create|close|show|update|sync|ready|dep|epic]"
allowed-tools: Bash(br *)
---

# /beads — Task Tracking

`br` is the binary. Run `br --help` to see all subcommands; run
`br <subcmd> --help` to see all flags for that subcommand. **Do this
BEFORE any non-trivial operation** — the README in this skill doesn't
list every flag. Discovering `--claim` (atomic assign + in_progress)
or `--design` (separate field for design notes) makes you a better
bead user instantly.

## Quick reference

```bash
br ready                                 # what's next to work on (open + unblocked + not deferred)
br list                                  # everything open
br list --type spec                      # filter by type (e.g. spec/plan/decision/note)
br show <id>                             # full bead detail
br create -t spec -p 2 "scope: title"    # create with type marker (see Bead Types)
br update <id> --description "..."       # MANDATORY: every bead has a description
br update <id> --claim                   # atomic: assignee=you + status=in_progress
br close <id>                            # close after work + commit
br sync --flush-only                     # export DB → JSONL (for git tracking)
br sync --import-only                    # import JSONL → DB (after pull)
br q "scope: quick capture"              # one-liner: create + print ID (default type=task)
```

## Power-user commands (run `br <subcmd> --help` for full flags)

```bash
br orphans                       # beads referenced in commits but still open (handoff failures)
br stale --days 14               # beads with no activity in 14+ days (for /triage)
br defer <id> "v0.4 cycle"       # not now, but later — removes from `br ready`
br undefer <id>                  # bring back from defer
br lint <id>                     # check for missing template sections (use as pre-close gate)
br doctor                        # diagnose + repair DB / JSONL drift
br comments add <id> "..."       # per-event log entries with author metadata
br audit                         # append-only JSONL of agent interactions (orchestrator visibility)
br query save "<name>" "<query>" # save a frequently-run filter
br query run <name>              # run a saved query
br graph                         # text-art dep graph
br stats                         # high-level project counts
br epic status                   # epics + close-eligibility
```

The discoverability discipline: **before reaching for an unfamiliar
operation, run `br <subcmd> --help`**. The CLI surface is wider than
this skill documents.

## Core principle: one bead = one commit

- Close beads BEFORE committing (so JSONL diff reflects closed state)
- Every commit message includes a `Bead: <id>` trailer (see `/commit`)
- Never batch multiple bead closures into one commit
- Pre-commit hook warns if the `Bead:` trailer is missing

## Bead fields (use the right field, not just description)

`br update` accepts these as separate fields. Putting design notes in
the `--description` field is sloppy — split them properly:

| Field | What goes here | When updated |
|---|---|---|
| `--title` | One-line subject (`scope: action`) | At create |
| `--description` / `--body` | The "what + why" (context + task framing) | At create + as scope evolves |
| `--design` | Design notes — interfaces, data structures, algorithm sketches | When design decisions are made |
| `--acceptance-criteria` / `--acceptance` | Concrete pass/fail bullets the next agent verifies | At create OR after `/check` |
| `--notes` | Append-only working log — investigation notes, links, partial findings | Any time during work |
| `--external-ref` | Link to Asana / Linear / Jira / Slack thread | When relevant |
| `--parent` | Parent bead ID (for epic-style parent/child) | At create or via update |
| `--deps` | Dependencies (`blocks:bd-X,relates-to:bd-Y`) | At create OR via `br dep add` |

**Why this matters**: a bead with everything stuffed into `--description`
is a wall of text. A bead with `--description` (context), `--design`
(how), `--acceptance-criteria` (done means), `--notes` (live log) is a
**handoff packet** the next agent reads cold and immediately knows what
to do.

## Priority levels

| Priority | Flag | Use for |
|---|---|---|
| P1 | `-p 1` | Critical — production issues, security, blockers |
| P2 | `-p 2` | Important — current sprint work, active features |
| P3 | `-p 3` | Backlog — nice-to-have, future work, tech debt |

P0 and P4 exist (`br create -p 0` / `-p 4`) but are rarely used. P0 is
"all hands stop." P4 is "nice idea, no commitment."

## Bead types (use `-t <type>` to mark kind)

`br` accepts arbitrary type strings on `--type` / `-t`. Use them as
the marker for what kind of bead this is — the type appears in
brackets in `br list` output (`[spec]`, `[plan]`, `[decision]`),
making the kind scannable at a glance, and `br list --type spec`
filters cleanly.

| Type | Use for |
|---|---|
| `task` (default) | Generic work item |
| `bug` | Bug fix |
| `feature` | New capability |
| `epic` | Umbrella with child beads (see [reference/epics.md](reference/epics.md)) |
| `spec` | Formal specification (see `/spec`) |
| `decision` | Decisions log walking spec OQs (see `/check`) |
| `test` | Test-writing work for a spec (see `/test`) |
| `impl` | Implementation against tests (see `/impl`) |
| `eval` | Evaluator for the fix→eval pattern (see below) |
| `plan` | Roadmap, phase plan, milestone plan |
| `note` | Working notes, investigation, scratch |
| `rfc` | Design RFC, request-for-comment |
| `receipt` | Receipt-of-work ticket (post-shipping) |

```bash
br create -t spec -p 2 "spec: auth subsystem"
br create -t plan -p 2 "plan: v0.3 phases"
br create -t decision -p 1 "decision: storage backend choice"
br list --type spec                  # all specs across the project
br ready --type plan                 # plans that are unblocked + actionable
br search "auth" --type spec         # type filter + free-text
```

The title prefix (`scope: title`) is for human readability; the type
is for categorization + filtering. Use BOTH — they're orthogonal.

This also means **`.claude/plans/`, root `PLAN.md`, separate
`DECISIONS.md` files are unnecessary** — those concerns live in beads
typed accordingly. Pre-existing files in those locations stay; new
work uses beads.

## Bead titles

Use a `scope: action` prefix matching the area of work. Combine with
`-t <type>` for full categorization:

```bash
br create -t feature -p 2 "auth: add JWT token refresh"
br create -t bug -p 1 "api: fix rate limit bypass"
br create -t test -p 2 "auth: integration coverage for payments"
```

Anti-patterns: bare verbs ("Fix bug"), file paths ("src/foo.ts"),
WIP markers ("WIP: ...").

## Mandatory: every bead has a description

Add the description IMMEDIATELY after create. A bead without a
description is broken handoff — the next agent has nothing to read.

```bash
br update <id> --description "$(cat <<'EOF'
## Context
Brief background on why this work is needed.

## Task
What specifically needs to be done.

## Acceptance Criteria
- [ ] Concrete deliverable
- [ ] Another deliverable
EOF
)"
```

For pipeline-stage-specific templates (spec / check / test / impl
beads), see [reference/handoff-templates.md](reference/handoff-templates.md).

## Handoff discipline

A good bead description means **another agent can pick up cold and
work without asking questions**. Test it before closing your own
bead: would Future-You (or another agent) understand from the bead
alone what was done and what's next?

Pre-handoff checklist:
- [ ] `--description` answers WHY this work exists
- [ ] `--acceptance-criteria` lists concrete pass/fail bullets
- [ ] `--design` notes any decisions / interfaces / sketches
- [ ] `--notes` includes any partial findings the next agent needs
- [ ] Dependencies declared via `--deps` or `br dep add`
- [ ] Linked external issues set via `--external-ref`

## Atomic sizing

Before creating, ask: **can one agent complete this in one session?**

- 1–3 acceptance criteria, 1–3 files = good atomic bead
- 4+ criteria or 4+ files = split into multiple beads
- Multiple "and then..." = definitely split, OR make it an epic
  (see [reference/epics.md](reference/epics.md))

## Agent protocol

### Orchestrator at start
```bash
br create -p 2 "scope: title"
br update <id> --description "..." --acceptance-criteria "..."
br update <id> --claim          # atomic assignee + in_progress
```
Pass `<id>` to the subagent prompt with: *"Your bead is `<id>`. Include
`Bead: <id>` in your commit trailer."*

### Subagent during work
- Reads the bead via `br show <id>`
- Logs investigation in `--notes` if useful: `br update <id> --notes "..."`
- Does NOT call `br close` or `br update --status` — orchestrator owns that
- References `Bead: <id>` in every commit trailer

### Orchestrator after merge
```bash
br close <id>                  # close BEFORE committing
br sync --flush-only           # export to JSONL
git add .beads/issues.jsonl    # stage closed-state JSONL
git commit -m ":card_file_box: beads: close <id>"
```

## Fix-and-guard pattern → see `/fix`

When stakeholder feedback or an audit surfaces a bug, **fire `/fix`**.
That skill creates a typed `bug` bead, dispatches a subagent to fix
it, and ensures a regression test exists (either updated or new) so
the bug can't regress silently.

LinearB / Phoenix-tracing projects have an additional `eval` pattern
on top of `/fix` (Phoenix evaluator that guards the regression in
production traces). That's project-specific — see the project's
CLAUDE.md.

## Anti-patterns

- ❌ **Bead without a description** — pure handoff failure
- ❌ **Description as brain-dump** — separate `--description` from `--design`
  and `--notes`
- ❌ **Vague title** — "fix the bug" doesn't say which bug
- ❌ **Too many P1s** — if everything's critical, nothing is. P1 should be
  rare and genuinely production-blocking
- ❌ **Closing without verifying acceptance criteria** — re-read the bead's
  `--acceptance-criteria` and check each box before `br close`
- ❌ **Subagent calling `br close` or `br update --status`** — only the
  orchestrator does that; subagents only commit with the bead trailer
- ❌ **Not running `br --help <subcmd>`** before complex ops — flags like
  `--claim`, `--design`, `--external-ref`, `--ephemeral` are easy to miss
- ❌ **Stuffing the daily bead-log work into the development bead's
  description** — those are different artifacts (see asana integration)

## Repo hygiene: ignore `.beads/.br_history/`

`br` writes timestamped snapshots to `.beads/.br_history/` on every
significant operation (~300–500 KB each, for local recovery only).
These are NOT for version control — git history IS the authoritative
record via `Bead:` trailers.

The shipped `.beads/.gitignore` doesn't include `.br_history/` (upstream
oversight). Add to any beads-using repo's `.beads/.gitignore`:

```gitignore
.br_history/
```

If a beads repo has lingering dirty `git status` with no apparent
cause, this is almost certainly why.

## Visualization & triage analysis with `bv`

`bv` ([beads_viewer](https://github.com/Dicklesworthstone/beads_viewer)) is
a graph-aware triage engine that reads the same `.beads/issues.jsonl` the
`br` CLI writes. It computes PageRank, betweenness, critical path, cycles,
HITS, eigenvector, and k-core metrics — useful for "what should I work on
next?" beyond plain `br ready`.

**CRITICAL: never run bare `bv` — it launches an interactive TUI that
blocks the agent session.** Always use the `--robot-*` JSON flags.

The session-start hook already prints a `Top pick:` line via
`bv --robot-next` when bv is installed; the orchestrator-action hook
nudges with the next pick after `br close` / worktree merge. Reach for
the deeper commands when those nudges aren't enough.

| Command | When to reach for it |
|---|---|
| `bv --robot-next` | One-line top pick — the question "what next?" |
| `bv --robot-triage` | Mega-command: ranked recommendations, quick wins, blockers, project health |
| `bv --robot-plan` | Parallel execution tracks (multi-agent dispatch ordering) |
| `bv --robot-insights` | Graph metrics (PageRank, betweenness, cycles) — find structural blockers |
| `bv --robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `bv --robot-suggest` | Hygiene: duplicate beads, missing deps, label suggestions |
| `bv --robot-graph --graph-format=mermaid` | Render the dep graph for spec / planning docs |
| `bv --robot-history` | Bead-to-commit correlations from git history |

```bash
# Common patterns
bv --robot-triage | jq '.recommendations[0]'        # top recommendation w/ reasons
bv --robot-triage | jq '.quick_wins'                # low-effort high-impact
bv --robot-triage | jq '.blockers_to_clear'         # unblocks the most downstream work
bv --robot-plan --label backend                     # scope to a label's subgraph
bv --recipe high-impact --robot-triage              # pre-filter by top-PageRank
```

**bv vs `br ready`**: `br ready` is a flat list of unblocked + open beads.
`bv --robot-next` ranks them by graph impact and surfaces *one*
recommendation with the claim command attached. Use `br ready` for "show
me everything"; use `bv --robot-next` / `--robot-triage` for "tell me
what to do."

**Discovery**: run `bv --robot-help` and `bv --robot-docs commands` for
the current command surface. The `bv` agent interface is intentionally
stable, but new flags get added — re-check those two if a command in
this skill feels off.

**Per-project AGENTS.md prompts**: when bv first runs in a new repo it
asks whether to inject a guidance blurb into `AGENTS.md`. Decline ("don't
ask again") — this skill is the global single source of truth and the
orchestrator already has the context. Records of decline live at
`~/.config/bv/agent-prompts/`.

See [reference/bv.md](reference/bv.md) for the deeper flag reference,
output schema details, and `jq` recipes.

## See also

- [reference/handoff-templates.md](reference/handoff-templates.md) — bead description templates per pipeline stage (spec / check / test / impl / eval)
- [reference/epics.md](reference/epics.md) — when and how to use epics; `br epic status` workflow
- [reference/dependencies.md](reference/dependencies.md) — `br dep` family for cross-bead blocking
- [reference/asana-integration.md](reference/asana-integration.md) — LinearB-only: daily bead-log subtasks via the fleet proxy
- [reference/bv.md](reference/bv.md) — `bv` (beads_viewer) graph-aware triage analysis: full robot-flag reference + jq recipes
- [/fix](../fix/SKILL.md) — fix-and-guard for bugs (creates `-t bug` bead + regression test)
- [/triage](../triage/SKILL.md) — bead-state hygiene (uses `br orphans`, `br stale`, `br epic close-eligible`)
- [/handoff](../handoff/SKILL.md) — pre-commit handoff verification (subagent → orchestrator)
