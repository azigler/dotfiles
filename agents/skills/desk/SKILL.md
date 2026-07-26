---
description: The research lab's ALLOCATOR — a weekly whole-corpus pass that emits a <=1,200-word chief-of-research resourcing memo to Andrew: what to fund, what to stop, what the corpus knows that no single tick can see.
when_to_use: The weekly desk pass fires (pulse-desk.timer, Fri); or Andrew asks "what should the lab work on next", "run the desk", "what's ripe in the compendium". NOT first-pass research (use /dive). NOT one-subject fresh eyes (use /elevate). NOT correctness (use /scrutinize).
argument-hint: "[project dir, default ~/explore] [--full]"
---

# /desk — the lab's allocator

**A desk is a place you sit to decide what gets funded.** Three unrelated
industries reached for the same word independently — the newsroom
assignment desk, the trading desk, the director's desk — because a place
commissions acts without anyone having to explain the hierarchy. That is
the whole naming argument: **the allocator is a PLACE, the executor is a
TRANSITIVE VERB.** You sit at the desk; you `/dive` a lead.

`/desk` is the **READ half** of a compendium that until now had only a
write half. `~/explore` produces ~4 explorations a day and had no loop that
ever read across them. Every producer tick sees exactly one card, so
cross-exploration facts — two findings that contradict each other, an open
bead a later finding silently answered, a theme that hit critical mass —
were structurally invisible.

**"Lab" names the INSTITUTION, never a loop.** No loop may be called lab.
(Naming decision 2026-07-26, bead `explore-mqvu`; spec `explore-oodx`;
transition constraints `explore-b47q`.)

## The load-bearing requirement: a destination, not a report

Zig's words: *"I like 'lab' bc it sets a premise and proposes stuff and
researches then the idea is I can jump in the lab session to drive the next
steps based on the chief researcher's proposal."*

Two consequences that are NOT negotiable:

1. **The deliverable is a durable artifact on disk** (`refs/desk/<date>.md`),
   never conversational state. He arrives *after* the tick has ended, in a
   fresh context. A proposal that exists only in the tick's transcript is
   unreachable by design. (This is why `--fresh` on the loop is correct:
   continuity must live in the artifact.)
2. **"Sets a premise" means take a POSITION, not enumerate options.** A
   ranked menu is a status report wearing a memo's clothes. Pick, argue,
   and name the honest counter-case.

## Cost discipline — the constraint IS the spec

`dotfiles-uxj9` established that cache-read cost = context_size × turns,
and it is the dominant term (~55%). `/desk` is deliberately **BIG-CONTEXT,
FEW-TURNS**.

    HARD BUDGET: <= 20 assistant turns total.
    Load the corpus in <= 4 BULK tool calls (concatenated reads), never
    file-by-file.

A file-by-file walk over ~130 findings would be ~130 turns × ~480k context
and would cost roughly **7×** the entire weekly research loop it is meant
to summarize. If you find yourself reading one FINDINGS.md at a time, stop
— you are running the expensive version of this skill.

Measured preconditions (2026-07-25, `explore-nq1i`): corpus ≈ 127
FINDINGS.md (313k words, ~423k tok) + open bead descriptions (~60k tok) ≈
**483k tokens — one 1M context.** Cost of a pass ≈ 0.045% of the explore
slug's 30-day spend (`dotfiles-uxj9`). Revisit incremental loading only
past ~600k tokens (~18 months out at current intake).

## Input (the <= 4 bulk reads)

a. every `*/FINDINGS.md` in full
b. every open bead: id, type, priority, title, description, age
c. `refs/desk/<previous>.md` — the last memo, so you do not re-pitch a
   program he already declined (the golem phantom-backlog failure,
   memory `project_golem_phantom_backlog`). Also read the **last archived
   `refs/elevate/sweep-*.md`** on the first few runs — that is this loop's
   pre-rename history and it holds declined programs too.
d. `git log` since the last memo — what actually landed.

**Bead context is the one place to be careful.** `br list` (text, titles
only) is the cheap index — use it freely. **NEVER `br list --json` the
backlog into a subagent**: its JSON inlines every bead's full description
(~250 KB / ~60k tokens for ~100 open explore beads), which blows the budget
AND, because every body is dense with the same handful of tie-backs,
*manufactures* the over-anchoring this loop exists to counter. Titles in;
bodies (`br show <id>`) only for the beads a real seam actually touches.

## Output — `refs/desk/YYYY-MM-DD.md`, HARD CAP 1,200 words

Register: chief of research pitching the lab owner on a resourcing
decision. Urgency, signal, expected return, ROI, honest risk. Not a
summary. Not a status report. Assume he does not know the premise; explain
it from scratch, briefly (memory: `pitch-as-partner`,
`plain-language-explanations`).

**§1 THE ASK** — always first. 1–3 programs to fund next week. Each with
all five fields: *what it is | the signal that it's ripe | expected return |
honest risk | the concrete ask* (a Vibes card? a build? an hour of Zig's
time?).

**§2 WHAT TO STOP** — MANDATORY, ≥1 candidate to defund / close / table,
with reasoning. A chief who only proposes new programs is not doing the
job. This section is the loop's real **drain**.

**§3 SIGNALS FROM THE FLOOR** — the whole-corpus facts no tick can see:
- **contradictions** — two findings that now disagree (cite both paths)
- **beads silently answered** — open beads a later finding already
  resolved, listed by id with a proposed close (this is how accumulation
  becomes closure). **Propose, never auto-close**: closure is an allocation
  call and allocation is the owner's job.
- **clusters at critical mass** — a theme heavy enough to write up, build,
  or pitch.

**§4 THE ONE CONNECTION** — exactly ONE non-obvious link between distant
explorations. Not a list. Lists are how the rot started.

**§5 THE DOOR** — the human checkpoint, kept terse so it is never buried:
- the week's N new explorations, one line each, and explicitly **which (if
  any) need his eyes** — anything that reads drifted, overclaimed, or thin
  (a conclusion the sources don't support, a forced tie-back, a card that
  got a shrug not a crawl). **DISPATCH a `/scrutinize` on any such
  exploration** — `/desk` is the opportunity gate, `/scrutinize` is the
  correctness gate; hand off, don't improvise. "All clean, nothing flagged"
  is a valid and welcome line.
- **queue health**, one line: unworked Vibes depth, `📬`-mailboxed count,
  oldest-`📬` age, and the NAMES of any unworked card older than ~3 weeks.
- **mailbox digest**: a one-line verdict per `📬` card of the week, so he
  can complete them in one pass instead of re-reading each. (Auto-completing
  old `📬` cards was **declined by Andrew 2026-07-17** — human-gated stays.
  His 2026-06-12 `📬`-not-complete decision stands.)

**§6 PORTFOLIO STATE** — ≤5 lines of numbers: corpus size, new this week,
open programs, backlog delta, token spend vs last week.

## Anti-overclaim — the gate that protects trust

Every factual claim cites a FINDINGS path or a bead id **inline**. A claim
with no citation is a spec violation. A bad pitch spends the owner's trust,
which costs more than a missed opportunity (`explore-grjy`).

Before delivery, run **ONE refuter pass**: a fresh agent at `effort:'max'`,
prompted to argue that the **§1 top program is NOT worth funding**. If it
lands a hit, demote or reframe the ask. Scope the refuter to §1 only — that
keeps the gate cheap while covering the one section that spends trust.
Record its verdict in the memo footer.

## Where the opportunity can land — lead with curiosity, not a tie-back

**Over-anchoring to Andrew's real projects is how the novel opportunity
gets missed** (Zig, 2026-07-13). If every finding has to cash out as "a
move for LinearB / the harness / a live `~/` arc," the pass collapses to the
modal tie-back. Range across **all** of the following with **no default
ranking**. (Mirrors `/dive`'s and `/elevate`'s section of the same name;
keep all three in sync.)

- **An entirely NEW idea** the corpus sparked, tied to nothing already here.
  First-class output, not a consolation prize.
- **An interlink that forms a deeper context** — between explorations AND
  with open-ended beads (`explore:` / `desk:` / legacy `elevate:` /
  `human:` threads). A finding that hands an open bead its missing piece is
  worth more than either alone.
- **An application to Andrew's active work — when it's real.** Derive the
  active set empirically each run (git activity + mtimes across `~/`,
  `~/explore`, `~/linearb`, `~/explore/aaif`). One valid landing, not the
  preferred one.
- **Interesting for its own sake.** Say *that*; don't force a build.

**Three guards stay hard:**

- **Don't manufacture a tie-back.** Honest "new idea, no home yet" beats a
  forced connection.
- **"NO adopt" is not "NO build."** "Don't adopt *this artifact*" (immature
  repo, WASM lib, commercial tool, runtime mismatch) must not silently
  become "nothing to build here." Ask *separately* whether a transferable
  method / pattern / primitive dodges the artifact's wall. A wall for the
  tool is rarely a wall for the pattern. (Caught 2026-07-13: reflexive "NO
  harness build" buried ~3 buildable experiments.)
- **The build PROJECTS are tabled — the CONCEPTS are not.** Hermes /
  MUD-golem / local-coding-models are tabled (2026-06-29); the concepts they
  touched (agent-sim, simulation, memory, loops) are **active**. Never write
  "tabled *agent-sim* arc" or call a sim/pet build "not a live destination."

## The run

1. **Bulk-load** the four inputs (≤4 calls). Note the turn count as you go.
2. **Opportunity pass** — fan out max-effort fresh agents over slices
   (by `INDEX.md` cluster), using the `/elevate` technique: Workflow
   `agent(…, {effort:'max'})`, unpolluted context, divergent lenses. Rotate
   **2–3 clusters per pass** and track the cursor in the memo; a
   full-compendium remix runs only on `--full`. **Aim it**: consume ONE edge
   from `INDEX.md`'s "Biggest unconnected opportunities" seed list each run,
   strike drawn/tabled edges, and propose replacements — so that list is a
   live work queue the loop both drains and replenishes.
3. **Write the memo** (§1–§6, ≤1,200 words, every claim cited).
4. **Refuter pass** on §1. Record the verdict in the footer.
5. **File + interlink the beads.** One bead per real opportunity, title
   prefix `desk:`, in the umbrella's `.beads/`. **Not Asana** — beads are
   the durable store. **Interlink every bead**: name the beads/explorations
   it connects **by id**, and `br dep add` real dependencies. Report the
   edge count in the ledger note (`"8 beads, 11 edges"`). Zero edges on a
   multi-bead pass is the tell that this step was skipped.
   Record consciously-rejected candidates in
   `~/explore/refs/vibes-candidates.md`'s **Dropped** table (or the bead
   `close_reason`) so a "no" is durable and not re-derivable forever.
6. **Append the field delta.** `refs/desk/field-notes.md` (append-only): a
   short block per pass — which `INDEX.md` clusters GREW, which themes
   accelerated, new convergence points ("Nth independent instance of X"),
   and a one-line direction read. After ~4 passes this file IS the emergent
   trend layer.
7. **Write opportunities back into the FINDINGS files** — for each
   exploration examined, append (never rewrite) a dated section:
   ```
   ## Novel opportunities (desk pass YYYY-MM-DD)
   - <opportunity> — <effort> — <risk>[ — <harness/active-arc move, ONLY if genuine>]
   ```
   The harness move is **optional**; a new idea tied to nothing is
   first-class. This is the BACKFILL for the ~40 pre-2026-06-29
   explorations that predate the required-section rule.
8. **Append the pulse-ledger row.** `/desk` is a pulse loop, so it MUST
   leave a row (no ledger-less ticks; the dashboard reads it). Append to
   `~/explore/refs/pulse-ledger.jsonl` with `"row":"desk"` and a `kind:cmd`
   proof the commit hook RE-RUNS (bare `artifact` is rejected fleet-wide,
   `explore-len0`):
   ```json
   {"ts":"<date -u +%FT%TZ>","row":"desk","outcome":"done","proof":{"kind":"cmd","cmd":"test $(wc -w < refs/desk/<date>.md) -le 1200 && grep -q '## §1 THE ASK' refs/desk/<date>.md && grep -q '## §2 WHAT TO STOP' refs/desk/<date>.md"},"note":"desk pass — N asks, M beads/E edges; reviewed W new explorations (F flagged); field-delta appended"}
   ```
   A pass that found nothing new logs `"outcome":"quiet"` (no proof needed)
   — but see the empty-week rule below: "nothing to report" is a failure,
   not a quiet tick.
9. **Deliver.** Commit + push the memo, field-notes, beads, ledger, and any
   touched FINDINGS. Then `PushNotification` naming the **top ask + the
   file PATH** (Zig is on SSH+tmux — no clickable links, no file-send). On
   *"Mobile push not sent (Remote Control inactive)"* the push did NOT
   reach him; because `/desk` is autonomous it does **not** escalate to
   AskUserQuestion — file a P1 `human:` bead instead and end the pass.

## Rules that bite

- **An empty week still produces a valid memo.** With no new findings, the
  signal comes from corpus-level facts — contradictions, silently-answered
  beads, aging programs. Degrading into "nothing to report" is a failure of
  the pass, not a property of the week.
- **`/desk` never blocks on AskUserQuestion.** It is a scheduled loop: it
  notifies, files beads, and ends.
- **Word cap is enforced, not aspirational.** The predecessor sweep grew
  1,460 → 1,666 → 2,190 words and became part of the comprehension-rot
  problem it was built to prevent (`explore-jdgk`). The proof command in
  the ledger row checks it.
- **The ledger row is `desk`, and it starts fresh.** The archived `elevate`
  rows stay under their old name as history — they key the old cap counters
  and must not be rewritten (`explore-b47q`). Never migrate them.

## The succession trigger (watch for it, don't act on it)

The deferred `lab-<moniker>` lineage plan (`~/explore/refs/lab-lineage-plan.md`)
has exactly one evidence gate: **a desk pass whose input exceeds 60% of
context on three consecutive runs.** That is the point at which the desk can
no longer see the whole portfolio — which is the only thing it is for. Log
the input-context fraction in §6 PORTFOLIO STATE every run so the trigger is
observable. When it fires three times, say so in §1 and let Zig decide;
do not start a new repo autonomously.

## Anti-patterns

- ❌ **File-by-file corpus reads** — ~7× the cost of the loop it summarizes.
- ❌ **`br list --json` on the whole backlog** — 60k tokens of tie-backs
  that manufacture over-anchoring.
- ❌ **A memo with no §2** — a chief who only proposes is not allocating.
- ❌ **A ranked menu instead of a position** — that's a status report.
- ❌ **Auto-closing the silently-answered beads** — propose; allocation is
  the owner's job.
- ❌ **Uncited claims** — a bad pitch spends trust that costs more than a
  missed opportunity.
- ❌ **Migrating the old `elevate` ledger rows** — archived history, left
  alone.
- ❌ **Output onto Asana** — beads + the memo + a push, never the Vibes
  board (the fleet proxy has no section-add route anyway).

## See also

- `/dive` — the executor this desk allocates to
- `/elevate` — max-effort fresh eyes on ONE finished thing; its technique
  is what step 2 dispatches
- `/scrutinize` — the correctness gate §5 hands off to
- `~/explore/refs/pulse.md` — the routing table (row `desk`)
- `~/explore/refs/lab-lineage-plan.md` — the deferred lineage design and
  its trigger
- `refs/elevate/sweep-*.md` — archived pre-rename history of this loop
