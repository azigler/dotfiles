---
description: Max-effort, fresh-eyes re-examination of FINISHED work — the generative twin of /scrutinize. Where /scrutinize is a critical/adversarial gate hunting for what's WRONG, /elevate is an opportunity gate hunting for what was MISSED: the novel opportunity, the non-obvious connection, the thing worth building that a baseline-effort pass walked past. Runs fresh, unpolluted subagents at effort:'max' via Workflow so the re-read isn't anchored to the original (often lower-effort) framing. Two modes — targeted (elevate one project/exploration/decision) and sweep (the WEEKLY compendium-wide opportunity-finder + review touchpoint, pulse-elevate.timer, Fri). The weekly sweep also carries the explore loop's structural-review function (it re-reads the week's new explorations and flags any that need Zig's eyes) — vibe-explore delegates its per-tick review here.
when_to_use: An exploration / finding / design / decision is "done" but you suspect a baseline pass under-thought it; the user says "elevate X", "look at this with fresh eyes on max", "what opportunity did we miss here"; or the weekly pulse-elevate sweep fires. NOT for first-pass research (use /explore). It is the OPPORTUNITY gate, not the correctness gate — for a pure correctness review use /scrutinize (the weekly sweep DISPATCHES /scrutinize on any week's exploration that looks like it drifted/overclaimed).
argument-hint: "<target: a path / project / exploration / 'sweep'>"
---

# /elevate — max-effort fresh-eyes re-examination

Most work in this harness is produced at the default `high` effort, and a
lot of the explore compendium was produced on `1/day` pulse ticks in
*convergent* "catalog it" mode. That mode scopes to what was asked and
greps the average (AGENTS.md "Effort — the intelligence dial"). `/elevate`
is the deliberate counter-move: take finished work and **re-examine it with
maximum intelligence and fresh, unpolluted eyes**, hunting specifically for
the *upside* a baseline pass missed.

It is the **generative twin of `/scrutinize`**:

| | `/scrutinize` | `/elevate` |
|---|---|---|
| Asks | "what's WRONG / unverified?" | "what was MISSED / what's the opportunity?" |
| Stance | critical, adversarial, skeptical | divergent, generative, opportunity-seeking |
| Output | killed/confirmed findings | novel opportunities, connections, builds |
| Gate on | correctness before shipping | upside before moving on |

## The two non-negotiables

1. **Max effort.** The whole point is to beat baseline thinking, so the
   re-examination agents run at **`effort:'max'`**. The bare `Agent` tool
   has no effort param (it inherits the session level), so `/elevate`
   dispatches through a **Workflow** `agent(prompt, {effort:'max'})`.
   Running this at default effort defeats it entirely.
2. **Fresh + unpolluted.** Use *new* subagents with clean context — never
   continue the agent (or the session) that produced the original work, or
   it re-treads the same groove. Give them the source material but NOT the
   original conclusions framed as settled. Divergent lenses (2+ different
   angles) beat one.

## Where the upside can land — lead with curiosity, not a tie-back

`/elevate` hunts upside — but its FIRST job is to be **curious**, not to find a
home for the finding on this machine. **Over-anchoring to Andrew's real projects
is how the novel opportunity gets missed** (Zig, 2026-07-13): if every finding
has to cash out as "a move for LinearB / the harness / a live `~/` arc," the
re-read collapses to the modal tie-back and the genuinely new idea — the whole
point of a max-effort fresh pass — never gets said. Range across **all** of the
following with **no default ranking**; do not privilege the active-arc one.
(Mirrors `/explore`'s "Where the opportunity can land"; keep the two in sync.)

- **An entirely NEW idea.** Net-new — a thing worth building or exploring that
  the re-read *sparked*, tied to nothing already here. First-class output, not a
  consolation prize.
- **An interlink that forms a deeper context.** Connect the re-examined work to
  *other explorations* **and to open-ended beads** (proposed-but-not-done ideas
  in `br` — `explore:` / `elevate:` / `human:` threads). Two half-ideas that meet
  become one bigger opportunity; a finding that hands an open bead its missing
  piece is worth more than either alone. The sweep's cross-cluster hunt (Mode B)
  is exactly this — run it over **beads too**, not only FINDINGS.
- **An application to Andrew's active work — when it's real.** Derive the active
  set empirically by recency each run (git activity + mtimes across `~/`,
  `~/explore`, `~/linearb`, `~/explore/aaif`; usual hot arcs: LinearB /
  `~/explore/aaif` / the harness / recently-touched `~/explore`). When a finding
  genuinely lands there, name the concrete move — but it's **one** valid landing,
  not the preferred one. (Empirical over aspirational — trust `ls -lt` / `git
  log`, not this paragraph's dated list.)
- **Interesting for its own sake.** Clarifying, beautiful, or worth
  understanding on its own terms. Say *that*; don't force a build.

**Three guards stay hard:**

- **Don't manufacture a tie-back.** A forced connection to LinearB / the harness
  / a `~/` project is worse than an honest "new idea, no home yet" or "this
  stands on its own."
- **"NO adopt" is not "NO build" — hold the two questions apart.** "Don't adopt
  *this artifact*" (an immature repo, a WASM lib, a commercial tool, a runtime
  mismatch) must NOT silently become "there's nothing to build here." Ask
  *separately*: is there a transferable **method, pattern, or primitive** worth
  building that dodges the artifact's runtime wall? A wall for the tool is rarely
  a wall for the pattern. The tell: a verdict that jumps "runtime mismatch" →
  "no build" without weighing the method. (Caught 2026-07-13 by the curiosity
  re-exam: reflexive "NO harness build" buried ~3 buildable experiments.)
- **The build PROJECTS are tabled — the CONCEPTS are not.** The **Hermes /
  MUD-golem / local-coding-models / Hermes-local BUILD PROJECTS** are tabled
  (2026-06-29): don't frame an opportunity as advancing or reviving *them*. But
  the tabling is about those named projects + local models — **not the concepts**
  (agent-sim / simulation / memory / loops) they touched, which stay **active**
  even though the golem also did them. Route such a finding to a general harness
  move or a net-new build, never the tabled bucket. (Tell you've over-tabled:
  "tabled *agent-sim* arc," or calling a sim/pet build "not a live destination"
  — Zig flagged this on `subterrans`, 2026-07-13.) The golem/MUD stays a *source*
  to reason from; frontier-model versions (subscription, no local model) dodge
  the tabling entirely.

## Mode A — targeted elevate (`/elevate <target>`)

Re-examine one thing: an exploration folder, a project, a finding, a
design, a decision.

1. Identify the target + its source material (the FINDINGS/specs/code/repo).
2. Run a small Workflow: 2-3 **max-effort** fresh agents with *divergent
   lenses* (e.g. "what to build / resume," "what to learn / connect," "what
   would a skeptic-of-the-skeptic see"), then a max-effort synthesis agent.
3. The orchestrator layers its own judgment on the synthesis and reports to
   Andrew — name it as an elevate result, with a clear verdict and the
   single highest-leverage next move.
4. If it surfaces something worth doing, **file a bead** for it (typed
   `note`/`task`); don't let the insight evaporate.

## Mode B — the sweep (`/elevate sweep`, weekly, Fri)

The compendium-wide opportunity-finder **AND the explore loop's weekly
review touchpoint**. Fires on `pulse-elevate.timer` (weekly, Fri 10:00 PT),
or on demand. It carries two jobs: the opportunity hunt (its historical
purpose) and — since `~/explore` delegated `vibe-explore`'s per-tick
structural review here (superseding the old every-5-`done` count nudge,
2026-07-15) — a **review touchpoint** over the week's new explorations
that keeps Andrew capable of saying "no" before comprehension rot sets in.

1. Enumerate the explore compendium (`~/explore/*/FINDINGS.md` etc.) and
   any other finished-work corpus in scope. **The compendium is a commonplace
   book / zettelkasten of intrigue, not a should-I-adopt catalogue** — read the
   FINDINGS bodies for CONTENT, but take the *connection map* from the clean
   `CHILDREN.md` / `INDEX.md` essences, and do **not** imitate the bodies'
   accumulated house-style (the reflexive "…and the harness move is"). Lead with
   what each thing is on its own terms. **Identify THIS WEEK's new work** — the
   explorations added or updated since the last sweep (the `vibe-explore` ledger
   `done` rows since the last `elevate` row) — they get the review lens in step 2b;
   the rolling opportunity backfill over older explorations continues underneath.
2. Fan out **max-effort** fresh agents over slices (by cluster/theme), each
   hunting: (a — OPPORTUNITY) cross-exploration clusters **and interlinks with
   open-ended beads** (a finding that completes a proposed-but-not-done `br`
   idea), **entirely new ideas the corpus sparks** (tied to nothing yet — novelty
   is first-class), novel "you should build X" opportunities, non-obvious
   connections to Andrew's active work, and "what did the per-card baseline pass
   miss"; **(b — REVIEW, on THIS WEEK's new explorations only)** does any read as
   **drifted, overclaimed, or thin** — a conclusion the sources don't support, a
   forced tie-back, a card that got a shrug not a crawl? This is the
   structural-review function `vibe-explore` delegates here: **flag any such
   exploration for Andrew's eyes, and DISPATCH a `/scrutinize` on it** (elevate is
   the opportunity gate; scrutinize is the correctness gate — hand off, don't
   improvise). Then a max-effort synthesis.

   **Bead context: progressive, not a bomb.** The interlinks live at the
   FINDINGS↔bead seam, so agents DO need bead context — but feed it the way a
   careful reader loads tabs, never as a corpus dump. **NEVER `br list --json`
   the backlog into an agent** — its JSON inlines every bead's full
   `description` (~250 KB / ~60k tokens for ~100 open explore beads), which
   blows the budget AND, because every body is dense with the same tie-backs
   (`iaf`/`len0`/`cdby`/…), *manufactures* the over-anchoring this sweep exists
   to avoid (an agent that ingested 100 bead bodies ties everything back to the
   same handful). Instead: pass each slice the **titles index** (`br list`
   text, filtered to the slice's theme where possible), and let the agent
   `br show <id>` **only the specific beads its findings actually touch** —
   pulled progressively, on demand, one interlink candidate at a time. Titles
   in; bodies only when a real seam appears.

   **Bound + aim the hunt (the corpus is ~100 explorations and growing — an
   unbounded full-compendium remix every Friday blows the budget or silently thins
   per-exploration attention).** Split the two lenses by scope: the **REVIEW lens**
   (2b) stays mandatory over the week's NEW explorations (it must pace intake); the
   **OPPORTUNITY hunt** rotates over **2–3 `INDEX.md` clusters per sweep** (track the
   cursor in the sweep narrative, step 5b), with a full-compendium hunt only on
   demand (`/elevate sweep --full`). And **aim it**: each sweep consumes ONE edge
   from `INDEX.md`'s hand-authored "Biggest unconnected opportunities" seed list as
   an explicit slice-agent remix target, strikes drawn/tabled edges, and the
   synthesis proposes replacement edges — so that seed list becomes a live work queue
   the loop both consumes and replenishes (today nothing consumes it, and it skews
   toward the tabled MUD arc). (Accepted latency property: a drifted FINDINGS can
   seed interlinks for up to a week before this review catches it — acceptable
   because per-tick `/scrutinize` already fact-gates each card; don't re-litigate it.)
3. **Deliver the weekly FRIDAY BRIEF to Andrew** (session/push notification;
   PushNotification / remote control). The sweep is the loop's one **DRAIN** — it
   must counter the structural write-heavy/drain-light imbalance (the research side
   runs 4 cards/day; the human-review side has no counter, so `📬` cards, unworked
   cards, and standing `elevate:` beads pile up invisibly — comprehension rot inside
   the exact checkpoint built to prevent it). The brief, in this order:
   a. **REVIEW digest** (the door left open) — the week's N new explorations one line
      each, and explicitly *which (if any) need his eyes / got a `/scrutinize`
      dispatched* (or "all clean, nothing flagged").
   b. **Queue health** (one line) — unworked Vibes depth, `📬`-mailboxed count,
      oldest-`📬` age, and the NAMES of any unworked cards older than ~3 weeks, so
      pruning/reordering is a one-minute decision instead of archaeology.
   c. **Mailbox digest** — a one-line verdict for each of the week's `📬` cards, so
      Andrew can complete them in a single pass rather than re-reading each.
   d. **Standing opportunities + the drain** — a titles-first re-rank of open
      `elevate:` beads (`br list` text; open bodies of only the 3–5 finalists),
      pitched partner-style with do-now/experiment/defer/drop verdicts. Lead the push
      with the **top-3 STANDING** opportunities all-time, not only this week's finds.
      **CLOSE or defer stale/superseded beads with a reason** (a real drain, not a
      re-list), and record consciously-rejected candidates in
      `~/explore/refs/vibes-candidates.md`'s **Dropped** table (or the bead
      `close_reason`) so a 'no' is durable — a dropped idea must not be re-derivable
      forever (the phantom-backlog failure). Then the opportunity headlines.
   The review digest + queue health are the door left open; do not bury them under
   the opportunities. (The auto-complete question for very-old `📬` cards is Andrew's
   call — raise it via AskUserQuestion when interactive, never a silent loop change.)
4. **Preserve the findings in beads AND wire them into the graph** — one
   `note`/`task` bead per real opportunity, prefix the title `elevate:`, in the
   explore umbrella's `.beads/`. **Do NOT put them on Asana** — beads are the
   durable store; Asana is for the Vibes research queue, not elevate output.
   **Interlink every bead you file** (explore CLAUDE.md "Beads are a crawlable
   knowledge graph"): the whole value of an interlink finding is the *edge*, so
   name the beads/explorations it connects **by id** in the body, and
   `br dep add` a real dependency when one exists (this opportunity completes
   that open bead). A sweep that files orphan beads has thrown away the graph it
   just discovered. This is also how you *crawl* on the read side — follow a
   seed bead's ids/`br dep tree` outward rather than flat-loading — and how the
   sweep's **research clusters** surface: a densely-linked bead neighborhood.
   **Self-check the edges you claimed:** after filing, grep each new bead body for
   the ids it references, `br dep add` the genuinely dependent ones, and report the
   edge count in the ledger note (`"8 beads, 11 edges"`). Zero edges on a multi-bead
   sweep is the tell that this interlink step was skipped — the graph `br ready` /
   `br dep tree` actually crawl would then be thinner than the prose claims.
5. **Write the opportunities back into the FINDINGS files** (the brain, not
   just the bead store). For each exploration the sweep examined, append (or
   refresh) a section in its `FINDINGS.md`:
   ```
   ## Novel opportunities (elevate sweep YYYY-MM-DD)
   - <opportunity> — <effort> — <risk>[ — <harness/active-arc move, ONLY if genuine>]
   ```
   The harness/active-arc move is **optional** — append it only when the tie-in is
   real. A new idea "tied to nothing yet" is first-class; do not manufacture a
   harness move just to fill the slot (mirrors `/explore`'s conditional harness note).
   This is the BACKFILL mechanism: the ~40 pre-2026-06-29 explorations were
   created before `Novel opportunities` was a required `/explore` section, so
   the sweep completes them over time, cross-cuttingly (one section per file
   it touches), rather than a one-shot per-folder blast (which is the weaker,
   non-remixing mode). Don't rewrite existing content — append the dated
   section; multiple sweeps stack dated sections so the history is legible.
5b. **Write the sweep's synthesis narrative + the cumulative field-delta (the
   TREND layer).** This is what turns a pile of dated FINDINGS into "where the field
   and the harness are heading" — and it was silently dropping out (the 2026-06-29
   sweep wrote a `refs/elevate/sweep-*.md` calling its cross-cluster
   super-opportunities "the highest-value output of the sweep"; later sweeps left
   none because the steps mandated beads/appends/ledger but never the narrative).
   Two artifacts:
   - **`~/explore/refs/elevate/sweep-<date>.md`** — the cross-cluster synthesis:
     the super-opportunities (connections BETWEEN slices, not within one), the
     week's review-digest verdicts, and the cluster-rotation cursor (which clusters
     this sweep hunted + which seed edge it consumed, step 2). This is the ledger
     row's `proof` (step 6).
   - **`~/explore/refs/elevate/field-notes.md`** (append-only) — a short **Field
     delta** block per sweep: which `INDEX.md` clusters GREW, which themes
     accelerated across the week's explorations + digest sources, new convergence
     points ("Nth independent instance of X"), and a one-line direction read. After
     ~4 sweeps this file IS the emergent trend layer — greppable, compoundable, the
     durable home for the convergence observations that currently evaporate into
     pulse-ledger note prose.
6. **Append a `pulse-ledger` row** — the sweep is a pulse loop, so it MUST
   leave a ledger row like every other (no ledger-less ticks; the dashboard
   reads it). Append one line to `~/explore/refs/pulse-ledger.jsonl` with
   `"row":"elevate"` and a `proof` token (the touched FINDINGS / filed beads):
   ```json
   {"ts":"<UTC date -u +%FT%TZ>","row":"elevate","outcome":"done","proof":{"kind":"artifact","path":"refs/elevate/sweep-<date>.md"},"note":"elevate sweep — N opportunities, M beads/E edges filed; reviewed W new explorations (F flagged); field-delta appended"}
   ```
   A sweep that found nothing new logs `"outcome":"quiet"` (no proof needed).
   Then commit + push the ledger, the beads, the touched FINDINGS files, AND the
   `refs/elevate/sweep-<date>.md` + `refs/elevate/field-notes.md` artifacts.

The sweep is autonomous (scheduled): it never blocks on AskUserQuestion —
it notifies + files beads + ends, exactly like a `/pulse` tick.

## The loop seam — opportunities re-enter the research queue

The point of the explore+elevate double loop is that it's a LOOP: explore
compresses sources into the brain, elevate (and explore's own `Novel
opportunities` pass) extracts "you should build/explore X" — and those Xs
should become FUTURE explorations, not just beads that gather dust. The
audit (2026-06-28, `explore-doj`) found the seam open: opportunities landed
in beads but never returned to the Vibes queue, so the two loops ran
parallel and never fed each other.

Closing it (the seam):

1. **Always file the bead** (as today — typed `note`/`task`, prefix
   `elevate:`). The bead is the durable record.
2. **Mark genuine "go research/build this" opportunities as Vibes
   candidates.** Add a `📌 candidate Vibes card: <crisp card title>` line to
   the bead so it's a one-step promotion, not a re-derivation.
3. **Promotion is HUMAN-GATED — never auto-write the Vibes board.**
   - In an **interactive** session, offer (AskUserQuestion) to add the card,
     then add it on a yes.
   - In the **autonomous sweep**, do NOT create cards — list the candidates
     in the push notification ("3 candidate Vibes cards: …") and let Andrew
     promote. Auto-spawning research cards from a scheduled loop is exactly
     the token-blowout / comprehension-rot debt the four loop costs warn
     about; the steering wheel stays in Andrew's hands.
   - Mechanical note: the fleet proxy has **no section-add route**, so a
     card can't be dropped straight into the Vibes section programmatically
     anyway — promotion goes through Andrew (or a future proxy route). Until
     then, the candidate list in the notification IS the promotion UI.

This makes the loop close without ceding the queue: opportunities surface,
Andrew chooses which become the next explorations, and the brain compounds.

## Anti-patterns

- ❌ **Running it at baseline effort** — the entire value is the `max` lift;
  a `high`-effort re-read is just a second average pass.
- ❌ **Reusing the original agent/session** — it's anchored; you'll get the
  same conclusions back. Fresh context only.
- ❌ **Using it for correctness** — that's `/scrutinize`. Elevate looks for
  upside, not bugs.
- ❌ **Letting findings evaporate** — always land real opportunities as
  beads (and notify, for the sweep). An un-captured insight is a no-op.
- ❌ **Sweeping output onto Asana** — beads + notification, not the Vibes
  board.

## See also

- AGENTS.md "Effort — the intelligence dial" — the policy this enforces
- `/scrutinize` — the critical twin
- `/explore` — first-pass research (elevate re-examines its output)
- `pulse-elevate.timer` / `.service` (machine-local) — the weekly sweep (Fri)
