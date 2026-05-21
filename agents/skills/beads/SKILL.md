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
br list --type spec                      # filter by type (e.g. spec/decision/study)
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
| `--notes` | Append-only-by-convention working log — investigation notes, links, partial findings. **Caveat**: `br update --notes <text>` itself is REPLACE-only on `br 0.2.5` — to "append" you must read the existing notes first and re-submit the full body. See `/check` SKILL Step 3 for the read-then-rewrite pattern (bead bd-otl8). | Any time during work |
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
brackets in `br list` output (`[spec]`, `[decision]`, `[study]`),
making the kind scannable at a glance, and `br list --type spec`
filters cleanly.

| Type | Use for |
|---|---|
| `task` (default) | Generic work item |
| `bug` | Bug fix (`/fix`) |
| `feature` | New capability |
| `epic` | Umbrella with child beads (see [reference/epics.md](reference/epics.md)) |
| `spec` | Formal specification (see `/spec`) — has test cases, implementable |
| `decision` | Decisions log — either spec-OQ walks (see `/check`) OR standalone architectural decisions (see [reference/handoff-templates.md](reference/handoff-templates.md) "Standalone architectural decision bead") |
| `test` | Test-writing work for a spec (see `/test`) |
| `impl` | Implementation against tests (see `/impl`) |
| `study` | Investigation, research, grok output — read-only learning captured as a bead |

**Taxonomy simplification 2026-05-19**: dropped `rfc`, `plan`, and
`receipt` as types (zero or 1 empirical usage across the fleet; all
overlap semantically with the remaining types). Renamed `note` →
`study` to avoid confusion with the `--notes` field. `eval` was **not**
dropped — it is retained as a **project-specific** type for
Phoenix-tracing projects (see the `eval` note under "Fix-and-guard
pattern" below; its bead template lives in
`reference/handoff-templates.md`). The bead-type migrations were
applied across the fleet's existing beads. If a dropped pattern ever
becomes genuinely needed, add the type back deliberately:

- A multi-stakeholder RFC process → `rfc`
- A roadmap that doesn't fit as a `spec` → `plan`
- A post-shipping ticket that doesn't fit on the Asana board → `receipt`

```bash
br create -t spec -p 2 "spec: auth subsystem"
br create -t study -p 3 "study: grok the existing auth flow"
br create -t decision -p 1 "decision: storage backend choice"
br list --type spec                  # all specs across the project
br ready --type study                # studies ready to claim
br search "auth" --type spec         # type filter + free-text
```

The title prefix (`scope: title`) is for human readability; the type
is for categorization + filtering. Use BOTH — they're orthogonal.

This also means **`.claude/plans/`, root `PLAN.md`, separate
`DECISIONS.md` files are unnecessary** — those concerns live in beads
typed accordingly. Pre-existing files in those locations stay; new
work uses beads.

## Choosing a type — derive it, don't pick it

Don't choose a type off the menu. Derive it: ask **what the next agent
should DO with this bead.** The type is downstream of the action.

Every bead type is a unit of **work** — something executes, then the
bead closes. That is the boundary of the tracker. If the honest answer
to "what should I do with it?" is *"nothing — just remember it,"* it is
not a bead. Reference knowledge, standing context, notes-to-self,
people — those live in `refs/`, `docs/`, `MEMORY.md`, or a knowledge
base, never in the issue tracker.

`study` is the one deliberate boundary case: read-only investigation
captured as a bead **because a future agent needs it to act** (skip
the re-read, then build on it). Treat it as the edge, not an opening —
if you want a `note` / `topic` / `person` type, that is the signal you
need a knowledge base, not a wider bead taxonomy.

This is the positive form of the taxonomy-simplification note above:
that note says *audit before adding a type*; this says *derive the
type from the action, not the aspiration.* (Borrowed from Portent's
PORT/ENTP split — see `~/explore/portent/`.)

## Stages vs. gates — not all pipeline work gets a bead

A skill in the orchestration pipeline is either a **stage** or a
**gate**, and only stages get beads.

- A **stage** produces a forward artifact and earns a typed bead —
  the handoff packet the next stage reads. `/spec`→`spec`,
  `/check`→`decision`, `/test`→`test`, `/impl`→`impl`, `/fix`→`bug`.
- A **gate** is a pass/fail checkpoint between stages. It produces a
  *verdict on existing work*, not a new artifact — so it gets **no
  bead and no type**. It records its result on the bead it gates.
  `/scrutinize` records its verdict on the `impl` bead's `--notes`,
  and the `impl` bead does not close until the verdict is SHIP. The
  `/impl` Step 5 quality gate and `/handoff` are gates too — neither
  has a bead.

The test is the action: a stage hands the next agent something to
build ON (→ bead); a gate tells the orchestrator whether to let the
prior bead through (→ no bead; record on the gated bead).

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

### Two real gotchas you WILL hit

1. **`--acceptance-criteria` with values that start with `- `**. Clap (the CLI
   arg parser) treats `- [ ] Foo` as a flag, not a value, even after `$( ... )`
   expansion. Use the `=` form to bind the value unambiguously:

   ```bash
   # Broken (errors with: tip: to pass '- ' as a value, use '-- - '):
   br update <id> --acceptance-criteria "$(cat <<'EOF'
   - [ ] one
   - [ ] two
   EOF
   )"

   # Works (= form binds tightly):
   br update <id> --acceptance-criteria=" - [ ] one
    - [ ] two"
   ```

   Same trick applies if `--description`'s value happens to start with `- `,
   though that's rarer because descriptions usually open with a markdown
   heading.

2. **Single-quoted heredoc preserves `\"` LITERALLY.** A `<<'EOF'` heredoc
   does NO escape processing, so `\"` written in the heredoc body is two
   chars: backslash + quote. If you copy a body that escapes inner double
   quotes for JSON-style usage, drop the backslashes before passing to
   `br update`:

   ```bash
   # Wrong — 64 occurrences of literal \" landed in the bead the hard way:
   br update <id> --description "$(cat <<'EOF'
   This is a \"quoted phrase\" inside content.
   EOF
   )"

   # Right — use plain quotes; the heredoc protects you from shell expansion:
   br update <id> --description "$(cat <<'EOF'
   This is a "quoted phrase" inside content.
   EOF
   )"
   ```

   Sanity-check after update: `br show <id> | grep '\\"'` — if any output,
   you've got literal backslash-quotes in the bead body. Rewrite.

## Immutability discipline for record-keeping bead types

For bead types where the **historical record matters** — `spec`,
`decision`, `study` — apply the following discipline once a
bead is closed:

- **`--description` is read-only after close.** No edits, no typo
  fixes, no clarifications. The record stays honest about what was
  thought at the time.
- **One allowed exception**: appending a supersession pointer to
  `--notes`. Pattern (matches the existing `/check` skill workflow):

  ```bash
  EXISTING=$(br show <old-id> | awk '/^Notes:/{flag=1; next} flag')
  br update <old-id> --notes "$EXISTING

  ---
  SUPERSEDED 2026-MM-DD by bd-YYYY: <one-line reason>"
  ```

  This is needed because `br update --notes` is REPLACE-only on
  `br 0.2.5` — you must read existing, concat, re-submit.

- **The new bead's `--description`** opens with `## Supersedes bd-XXXX`
  in its Context section, so the graph is traversable both ways.

Bead types where immutability does **NOT** apply: `task`, `bug`,
`feature`, `impl`, `epic`, `test`. These are work-in-flight artifacts
that need free editing as scope shifts.

### Two more conventions borrowed from Luca's ADR discipline

When writing **any** decision-type bead (whether `/check` OQ-walk or
standalone architectural decision):

1. **Bold the decision sentence.** Use literal `**...**` markdown in
   the bead body even though it renders as plaintext. The asterisks
   make the actual decision scannable at a glance among the
   surrounding context.

2. **≥2 alternatives with honest pros/cons.** One-sided alternative
   sections are a red flag: if the section dismisses options without
   serious consideration, the decision wasn't really made. The
   exercise of writing honest pros/cons for the option you DIDN'T
   pick is where the decision gets its rigor.

These are voluntary disciplines, not mechanical gates. The reason
they earn their space is that future-you (or any agent reading the
archive) can reconstruct your reasoning without re-doing the
thinking.

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
- `~/linearb/refs/asana-integration.md` — LinearB-only: daily bead-log subtasks via the fleet proxy (private reference)
- [reference/bv.md](reference/bv.md) — `bv` (beads_viewer) graph-aware triage analysis: full robot-flag reference + jq recipes
- [/fix](../fix/SKILL.md) — fix-and-guard for bugs (creates `-t bug` bead + regression test)
- [/triage](../triage/SKILL.md) — bead-state hygiene (uses `br orphans`, `br stale`, `br epic close-eligible`)
- [/handoff](../handoff/SKILL.md) — pre-commit handoff verification (subagent → orchestrator)
