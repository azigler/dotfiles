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
br query save <name> [flags]      # save the CURRENT filter flags, not a
                                  # query-language string — e.g. `br query
                                  # save ready-p1s --status open
                                  # --priority-max 1 --sort priority -d
                                  # "P0/P1 open work, triage's first stop"`
br query run <name>              # `br query run ready-p1s --format toon`
                                  # reruns those exact flags — reusable
                                  # instead of retyping the filter each time
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

**Multi-ID `br` calls are a different axis from "one bead = one commit" —
the two are compatible, not contradictory.** `br close` (and several other
subcommands) accept multiple IDs in one invocation — `br close bd-1 bd-2
bd-3` (verified: `br help close` shows `[IDS]... Issue IDs to close`) — and
that is fine to use when it's genuinely one atomic transaction (e.g.
closing a batch of duplicates found by the same `/triage` sweep). "One bead
= one commit" above is a **git-commit-boundary rule**: don't let one commit
carry the close of beads whose work is otherwise unrelated, because the
commit message and the `Bead:` trailer can only tell one coherent story.
It says nothing about how many IDs one `br` invocation may name. So a
single `br close bd-1 bd-2 bd-3` followed by ONE commit whose message and
`Bead:` trailers cover all three (because they really are one unit of
work — e.g. a `/triage` cleanup batch) is the compatible case; using a
multi-ID close to bundle unrelated beads into a commit that then reads as
if it did one thing is the anti-pattern the commit rule is actually
guarding against.

**A hook block kills the WHOLE Bash call — never chain bead mutations.**
A PreToolUse rejection (`pre-bead-create.sh`, `pre-bead-close.sh`, …)
aborts the entire Bash invocation, not just the flagged command — so
`br update X && br close Y` runs **neither** when the gate fires on
either half. Run each bead mutation (`br create`, `br update`,
`br close`) as its own standalone Bash call, never chained behind
another command with `&&`, `;`, or a pipe. Measured recurrence: 4
repos, ~12 sessions, 2026-06-19 → 2026-08-04, still recurring (Audit N,
bead `dotfiles-fdvs`).

## Bead fields (use the right field, not just description)

`br update` accepts these as separate fields. Putting design notes in
the `--description` field is sloppy — split them properly:

| Field | What goes here | When updated |
|---|---|---|
| `--title` | One-line subject (`scope: action`) | At create |
| `--description` / `--body` | The "what + why" (context + task framing) | At create + as scope evolves |
| `--design` | Design notes — interfaces, data structures, algorithm sketches | When design decisions are made |
| `--acceptance-criteria` / `--acceptance` | Concrete pass/fail bullets the next agent verifies. **Caveat**: `br lint` reads the `--description` body ONLY (verified br 0.2.16), so this field does NOT clear a `Missing: ## Acceptance Criteria` warning or the `br close` gate — put the literal `## Acceptance Criteria` heading in the description too. | At create OR after `/check` |
| `--notes` | **Curated summary only** — not a running log. A short, hand-composed digest (readiness summary, supersession pointer, handoff signature) written once or a few times per bead, not appended to on every event. **Caveat**: `br update --notes <text>` is REPLACE-only (verified br 0.2.5 → 0.2.15, behavior unchanged) — the rare cases where a curated summary must be extended still require reading the existing notes first and re-submitting the full body (see the read-then-rewrite pattern below); `test/test-notes-replace-behavior.sh` guards this claim against `br`-version drift. | Occasionally, as a curated digest |
| `--external-ref` | Link to Asana / Linear / Jira / Slack thread | When relevant |
| `--parent` | Parent bead ID (for epic-style parent/child) | At create or via update |
| `--deps` | Dependencies (`blocks:bd-X,relates-to:bd-Y`) | At create OR via `br dep add` |

**Why this matters**: a bead with everything stuffed into `--description`
is a wall of text. A bead with `--description` (context), `--design`
(how), `--acceptance-criteria` (done means), `--notes` (curated summary)
is a **handoff packet** the next agent reads cold and immediately knows
what to do.

### Running/investigation logs go to `br comments add`, not `--notes`

`--notes` used to be documented as an "append-only-by-convention working
log," but it isn't append-only at all — `br update --notes` is
REPLACE-only, so every "append" is really read-existing +
concatenate-in-memory + re-submit-the-whole-body. That read-then-rewrite
dance is the exact shape of a defect: on 2026-07-26, a `br show <id>
--json` read that silently returned a LIST instead of an object
collapsed to an empty string inside the `$(...)` feeding the next
`br update --notes`, and the update still ran — clobbering a
4,722-character description (recovered from git history; see the
immutability section below for the mechanics).

`br comments add <id> "..."` is the primitive that was available the
whole time for this job: genuinely append-only, author-tagged, and
exported to JSONL, so it survives `br sync` the same way notes do —
without ever requiring a read-before-write. **Use it for every
running/investigation log entry**: per-item decisions during a
`/check` walk, findings logged mid-task, a `/scrutinize` verdict, a
`/handoff` signature. Reserve `--notes` for a **curated summary**
written once (or updated rarely, via the read-then-rewrite pattern
when it must change) — an Implementation Readiness summary, a
supersession pointer, a final digest meant to be read at a glance
without scrolling a comment thread.

```bash
br comments add <id> "OQ-03 DECIDED: single-writer per session (see rationale in thread)"
br comments list <id>                # read the running log back
```

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

## Labels — orthogonal to type, for cross-cutting queries

A **label** is not a type. Type answers "what kind of work is this"
(one per bead, drives the pipeline); a label answers "what cross-cutting
set does this belong to" (zero or more per bead, drives a query). Set
one with `br create -l <label>` or `br update <id> --add-label <label>`;
filter with `br list --label <label>`.

Convention: **`friction`** marks a bead filed from a session's Friction
section (see `/offboard` Step 2.7) — real work (usually `-t bug` or
`-t task`), just tagged so the harness-friction seam can pull the set
without grepping titles: `br list --label friction`. Don't invent a
`friction` type for this; the bead's type is still whatever kind of
work it is — the label is the cross-cutting marker.

### Label taxonomy (dotfiles-iypf, 2026-08-09)

Three label families, applied at create time, not backfilled after the
fact — the point of a label is that `br list --label <x>` and `bv -l <x>`
already have signal the moment the bead exists:

| Label | Marks | Example |
|---|---|---|
| `friction` | A bug/gotcha caught mid-session — the `/offboard` Step 2.7 Friction section, made mechanical | `br create -t bug -l friction "guard: false-positives on non-git commands"` |
| `epic:<name>` | A bead belonging to a named multi-bead campaign, keyed to the epic's short name (not its bead ID — the name outlives any one bead) | `br create -l epic:hall "hall: responsive court — mobile layout"` |
| `area:<area>` | The subsystem a piece of DESIGNED work (feature, spec, validator) touches — orthogonal to `friction`, which marks HOW it was found, not WHERE it lives | `br create -t feature -l area:hall "roster: emit agents/seats.json"` |

`friction` and `area:<x>` are not mutually exclusive in principle (a
friction bead can also name its area), but in practice pick the label
that answers the sharper question for that bead: "was this caught as a
gotcha" (`friction`) or "what part of the estate does this touch"
(`area:<x>`). Don't force both onto every bead — that's over-labeling,
not signal.

`area:<x>` values are decided per-project as the estate's subsystems
stabilize, not a fixed enum — dotfiles' first cohort (dotfiles-iypf
backfill) used `hall` (the roster/seats/court UI), `drain` (the
overnight fleet-claim machinery, 69qr/htqt), `works` (general
build/cutover/infra machinery with no sharper home), `attribution`
(gateway-spend-to-seat mapping), and `comms` (mail/channels/broadcasts).
Add a new `area:<x>` when a real cluster of beads needs one; don't
pre-declare areas nobody has beads for yet.

## Markers — `fleet:`, `fleet-model:`, `outward:` (fleet/outward eligibility)

69qr (the fleet drain spec) and htqt (the outward gate spec) both name
markers on beads — `fleet: yes`, `fleet-model: opus`, `outward: yes` — that
control machine behavior: whether the overnight drain may claim a bead at
all, which model it dispatches on, and whether the outward gate must be
consulted. br 0.2.16 has no key/value metadata verb — `--agent-context` sets
a schema-v11 governing-instructions JSON blob that is DB-ONLY, never
exported to JSONL at all (field census on this repo's own `issues.jsonl`:
zero rows carry it), so a marker stored there would not survive clone or
machine transfer. That leaves two real mechanisms, split by shape:

- **`fleet` and `outward` are booleans** — presence IS the value — so as of
  dotfiles-pcdq they are **label-backed**: `br label add <id> -l fleet` /
  `-l outward`. This is the canonical, current form: `br list --label
  fleet`, `bv -l fleet` scoping, and `BV_ROBOT_NOT_READY_LABELS`
  claimability gating all read it directly, no marker parsing needed.
- **`fleet-model` needs an arbitrary VALUE** (`opus`, `sonnet`, …), so a
  flat label is the wrong shape for it — it stays a plain-text line inside
  the bead's `--description`, one marker per line, **strict grammar**:

```
<Key>: <token>
```

`<Key>` matched case-insensitively but the colon must follow it IMMEDIATELY
(`Fleet:` never matches a `Fleet-Model:` line; `Fleetish:` never matches
`Fleet:`). `<token>` is `[A-Za-z0-9_-]+` — no spaces. Boolean markers
(`fleet`, `outward`) are true iff the token is EXACTLY `yes`
(case-insensitive) — `fleet: yesterday` is a well-formed line with a real
value, it is just not a *true* one.

The description-line form for `fleet`/`outward` is **read-fallback only**,
kept so beads marked before the migration (or by a writer that hasn't moved
to labels yet) still resolve — `marker_is_fleet` / `marker_is_outward` check
the label first and only consult the description line if the label is
absent. Full grammar + implementation:
[`agents/lib/bead-markers.sh`](../../lib/bead-markers.sh) (`marker_get`,
`marker_set`, `marker_is_fleet`, `marker_is_outward` — the ONE shared
implementation the drain and the outward guard both import; do not
hand-roll a second grep or label check for this).

**Who may set each marker** (the contract; the library only implements the
grammar, it does not enforce authorship):

| Marker | Set by | Removed by |
|---|---|---|
| `fleet: yes` | the orchestrator, Zig, or dream's approval pipeline (69qr R9) — never the marshal itself, never inferred from readiness | whoever set it, or the orchestrator |
| `fleet-model: opus` | same as `fleet:`, set at marking time (69qr R2 — "the marker decides, not the marshal at 3am") | same as `fleet:` |
| `outward: yes` | **any** agent, on any bead whose work reaches outside the estate (htqt R1) | **no one**, without a `-t decision` bead recording why the outward classification no longer applies |

Bead types dh89 (this marker plumbing) and its consumers (the drain,
the outward guard) are tracked separately — this section documents the
convention only; do not read it as "these are wired up yet."

## Stages vs. gates — not all pipeline work gets a bead

A skill in the orchestration pipeline is either a **stage** or a
**gate**, and only stages get beads.

- A **stage** produces a forward artifact and earns a typed bead —
  the handoff packet the next stage reads. `/spec`→`spec`,
  `/check`→`decision`, `/test`→`test`, `/impl`→`impl`, `/fix`→`bug`.
- A **gate** is a pass/fail checkpoint between stages. It produces a
  *verdict on existing work*, not a new artifact — so it gets **no
  bead and no type**. It records its result on the bead it gates.
  `/scrutinize` records its verdict as a `br comments add` entry on
  the `impl` bead (a gate can run more than once — FIX-FIRST, a fix
  wave, re-scrutinize — so the verdict trail is a running log, not a
  single curated write), and the `impl` bead does not close until the
  latest verdict is SHIP. The `/impl` Step 5 quality gate and
  `/handoff` are gates too — neither has a bead.

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

  This is needed because `br update --notes` is REPLACE-only
  (verified br 0.2.5 → 0.2.15) — you must read existing, concat, re-submit.

  ⚠️ **`br show <id> --json` returns a LIST, not an object** (br 0.2.16).
  `json.load(sys.stdin)['description']` therefore raises `TypeError: list
  indices must be integers`. If that read is inside a `$(...)` whose output
  feeds the very `br update` that follows, the failure is **silent and
  destructive**: the substitution collapses to the empty string, the command
  still runs, and the field is replaced by only the new text. This clobbered a
  4,722-character description on 2026-07-26 and was recovered from git history.
  Index `[0]` (or `rows[0] if isinstance(rows, list) else rows`), and prefer
  writing the read to a file you can inspect before the update runs. The same
  trap applies to `--description` and `--design`, not just `--notes`.

- **The new bead's `--description`** opens with `## Supersedes bd-XXXX`
  in its Context section, so the graph is traversable both ways.

Bead types where immutability does **NOT** apply: `task`, `bug`,
`feature`, `impl`, `epic`, `test`. These are work-in-flight artifacts
that need free editing as scope shifts.

### Decision-bead conventions

Any decision-type bead — `/check` OQ-walk or standalone architectural
decision — earns its keep two ways: **bold the decision sentence** (so
the actual choice is scannable in the plaintext bead view), and give
**≥2 alternatives with honest pros/cons** (writing the pros/cons for
the option you DIDN'T pick is where the decision gets its rigor).
Voluntary disciplines, not mechanical gates. The full standalone-ADR
bead template — Context / Decision / Options / Consequences — is in
[reference/handoff-templates.md](reference/handoff-templates.md).

## Handoff discipline

A good bead description means **another agent can pick up cold and
work without asking questions**. Test it before closing your own
bead: would Future-You (or another agent) understand from the bead
alone what was done and what's next?

Pre-handoff checklist:
- [ ] `--description` answers WHY this work exists
- [ ] `--acceptance-criteria` lists concrete pass/fail bullets
- [ ] `--design` notes any decisions / interfaces / sketches
- [ ] Partial findings the next agent needs are on `br comments add` (the
      running log); `--notes` carries only a curated summary, if any
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
br create -p 2 -l friction "scope: title"    # add -l friction / epic:<name> / area:<x> at CREATE time — see Labels above
br update <id> --description "..." --acceptance-criteria "..."
br update <id> --claim          # atomic assignee + in_progress
```
Pass `<id>` to the subagent prompt with: *"Your bead is `<id>`. Include
`Bead: <id>` in your commit trailer."*

Label at create time, not as a later backfill pass — a label decided in
the moment (was this a Friction-section catch? does it belong to a
named epic or subsystem?) is cheap and accurate; a label applied weeks
later is a guess from the title alone. dotfiles-iypf backfilled ~30
unlabeled beads from a single founding session precisely because none
of them were labeled going in.

### Subagent during work
- Reads the bead via `br show <id>`
- Logs investigation as it happens via `br comments add <id> "..."` (the
  running log — append-only, no read-before-write needed)
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

## Repo hygiene: JSONL merge artifacts (silent duplicate ids)

git auto-merges `.beads/issues.jsonl` across branches "cleanly" (no
conflict markers) while silently keeping BOTH sides' line for a bead
that both branches touched — e.g. a feature branch carrying the bead as
`in_progress` merged with the default branch carrying it `closed`. A
duplicate id makes the JSONL INVALID to `br` (`ERROR jsonl.parse:
Duplicate issue id`), bricking bead operations until repaired. Caught
live 2026-06-09 (dashboard-dev-interrupted PR #9).

Defense in depth, in order:

1. **Don't fork the ledger.** Stage `.beads/issues.jsonl` only on the
   default branch (see `/commit` "Bead-state exception"). Worktree
   subagents never stage `.beads/` at all (it's a symlink).
2. **The `post-bash-beads-merge-check` hook** (PostToolUse:Bash, global)
   checks for duplicate ids after every successful merge-ish command and
   feeds remediation back if it finds the artifact.
3. **Remediation** when it happens anyway:
   - `git checkout <default-branch> -- .beads/issues.jsonl` (the default
     branch's ledger usually wins), or
   - `br sync --merge` — a real three-way merge using the
     `.beads/beads.base.jsonl` anchor (written by sync flush on current
     `br` versions); semantic conflicts need `--force-db` /
     `--force-jsonl` / `--force` (newer timestamp wins)
   - verify: `jq -r '.id' .beads/issues.jsonl | sort | uniq -d` is empty,
     then `br doctor` (its `jsonl.duplicate_ids` detector confirms)

## New project: init with a UNIQUE id prefix (never the `bd` default)

`br init` defaults the id prefix to `bd` when `--prefix` is omitted. Fine
within one project — but across the fleet it means many projects
independently mint `bd-<id>` ids that **collide**. That breaks any
cross-project view (a fleet-wide `bv` workspace, a merged export) and
makes cross-project references ambiguous. (Verified 2026-07-08: **16
projects** shared the `bd` default → 651 colliding ids.)

**Rule: always `br init --prefix <unique>` — never accept the `bd`
default.** Derive a short, globally-unique prefix from the project dir,
and check it isn't already taken before init:

```bash
proj=$(basename "$PWD")                 # or a hand-picked short tag
# is this prefix already used anywhere under ~? (must print nothing)
find ~ -path '*/.beads/config.yaml' -exec grep -lE "issue_prefix:\s*${proj}\b" {} +
br init --prefix "$proj"
```

Existing `bd`-prefixed projects keep working: the fleet-aggregate `bv`
**workspace** namespaces each repo by a per-repo prefix (`reef/bd-10b0`),
so a one-time re-prefix is **optional, not required** — and note there is
no `br` re-prefix command (it would be a custom id + dep-ref rewrite +
DB resync). Prevention (this rule) beats cleanup.
(Stronger enforcement — a PreToolUse hook that rejects `br init` without a
unique `--prefix` — is a candidate follow-up; see `feedback_editorial_vs_mechanical_enforcement`.)

## Visualization & triage analysis with `bv`

`bv` ([beads_viewer](https://github.com/Dicklesworthstone/beads_viewer)) is
a graph-aware triage engine that reads the same `.beads/issues.jsonl` the
`br` CLI writes. It computes PageRank, betweenness, critical path, cycles,
HITS, eigenvector, and k-core metrics — useful for "what should I work on
next?" beyond plain `br ready`.

**CRITICAL: never run bare `bv` — it launches an interactive TUI that
blocks the agent session.** Always use the `--robot-*` JSON flags.

The session-start hook already prints a `Top pick:` line via
`bv --robot-next`; the orchestrator-action hook nudges after `br close`
/ worktree merge. Reach for `bv` directly when those nudges aren't
enough: `--robot-next` (one-line top pick), `--robot-triage` (ranked
recs + quick wins + blockers + health), `--robot-plan` (multi-agent
dispatch order), `--robot-insights` (cycles, structural blockers). Use
`br ready` for "show me everything"; `bv` for "tell me what to do."

**BANNED as a pre-edit gate: `--robot-file-hotspots`, `--robot-impact`,
`--robot-file-beads`** (dotfiles-ri8b, 2026-08-09). Upstream #184 (the three
surfaces contradicting each other on one path) is fixed as of v0.19.0 —
re-verified empirically: all three now agree on a shared `data_hash`. The ban
stays anyway, because the join is **commit-SHA-based by design**: an open bead
that hasn't produced commits yet is invisible to all three, so
`--robot-impact` said "low risk" on a file that 5 open beads were actively
discussing (probe: `agents/scheduler/pulse-inject.sh`). A false "safe to
proceed" is worse than no check. Use them for retrospective archaeology only,
never to gate an edit; machinery (the marshal build) must not consume them.

[reference/bv.md](reference/bv.md) has the full command surface, the
`jq` recipes, the output schema, and the discovery commands
(`bv --robot-help` / `bv --robot-docs commands`). One gotcha worth
keeping in mind: when `bv` first runs in a repo it offers to inject
guidance into `AGENTS.md` — **decline** ("don't ask again"); this skill
is the single source of truth.

## See also

- [reference/handoff-templates.md](reference/handoff-templates.md) — bead description templates per pipeline stage (spec / check / test / impl / eval)
- [reference/epics.md](reference/epics.md) — when and how to use epics; `br epic status` workflow
- [reference/dependencies.md](reference/dependencies.md) — `br dep` family for cross-bead blocking
<!-- private-start -->
- `~/linearb/refs/asana-integration.md` — LinearB-only: daily bead-log subtasks via the fleet proxy (private reference)
<!-- private-end -->
- [reference/bv.md](reference/bv.md) — `bv` (beads_viewer) graph-aware triage analysis: full robot-flag reference + jq recipes
- [/fix](../fix/SKILL.md) — fix-and-guard for bugs (creates `-t bug` bead + regression test)
- [/triage](../triage/SKILL.md) — bead-state hygiene (uses `br orphans`, `br stale`, `br epic close-eligible`)
- [/handoff](../handoff/SKILL.md) — pre-commit handoff verification (subagent → orchestrator)
