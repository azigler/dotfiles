---
description: The research lab's ALLOCATOR — a weekly two-pass whole-corpus review that emits a <=1,200-word chief-of-research resourcing memo to Andrew: what to fund, what to stop, what the corpus knows that no single tick can see.
when_to_use: The weekly desk pass fires (pulse-desk.timer, Fri); or Andrew asks "what should the lab work on next", "run the desk", "what's ripe in the compendium". NOT first-pass research (use /dive). NOT one-subject fresh eyes (use /elevate). NOT correctness (use /scrutinize).
argument-hint: "[project dir, default ~/explore] [--wide]"
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
bead a later finding silently answered, a confirmed defect no bead tracks —
were structurally invisible.

**"Lab" names the INSTITUTION, never a loop.** No loop may be called lab.
(Naming decision 2026-07-26, bead `explore-mqvu`; spec `explore-oodx`;
transition constraints `explore-b47q`. The spec review's OQ1 answer of
`/lab` and OQ4's `pulse-lab.timer` are **superseded** by that rename — the
loop is `/desk` and the live unit is `pulse-desk.timer`.)

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

## The architecture: WIDE proposes, NARROW verifies and writes

This is the load-bearing mechanism, and it is the one thing about this
skill that was rewritten after review (`refs/lab-open-questions.md`,
Amendment 2). The original design asked **one** context to load the corpus,
compare it, judge it, *and* write the memo. That is wrong for two
independent reasons, and only one of them is about cost.

**Pass A — WIDE. Proposes. Never writes.**
Fresh agent, no history. Loads the corpus in ≤4 bulk reads — **by the mechanism
in "How Pass A actually loads the corpus" below; do not improvise it.** Emits
**only** a structured candidate list — ids, paths, **quoted spans**, ~2k tokens.
No prose, no memo, no beads, no verdicts. ~6 turns.

**The one carve-out from "no prose."** Pass A may also return exactly ONE
`FIELD DELTA` block of **≤5 lines** — `INDEX.md` clusters that grew, themes that
accelerated, new convergence points, the A2 cluster cursor. Counts and names
only, no judgment. It exists because step 7's field-notes layer is **not
derivable** from a candidate list and Pass B holds no corpus, so without this
carve-out that layer gets fabricated. Anything longer than 5 lines, or anything
that reads as a verdict, is Pass A doing Pass B's job — reject it with the rest.

**Pass B — NARROW. Verifies and writes. Never holds the corpus.**
A **fresh** agent holding **no corpus**. Reads the candidate list and the
axis register, then opens *only* the specific files each candidate names,
re-reads the quoted span in place, and writes the memo. ~40 turns against a
~40k context.

**Why the split is forced, not merely permitted:**

- **Cost.** Cache-read = context × turns, the dominant term (`dotfiles-uxj9`).
  Verifying inside Pass A costs 483k × 40 ≈ **19.3M**; split, it is
  (483k × 6) + (40k × 40) ≈ **4.5M** core. **The load-bearing number is the
  ~4× ratio, not the absolutes** — the spec's `<15M` line (test 14 of
  `explore-oodx`) is a *stipulated* ceiling with no derivation behind it, so
  "over the gate" is not an argument, and this bullet does not rest on it.
  *Cheaper and verified.* `refs/warm-session-collapse.md` corroborates: a
  fresh context costs a median **40,352** tokens of cache-creation; a warm one
  re-creates a median **478k**. Two fresh contexts beat one long-lived session doing both
  jobs.
- **Over-anchoring — the reason that matters more.** `~/explore/CLAUDE.md`
  prohibits loading every bead body precisely because they are dense with the
  same handful of tie-backs (`iaf` / `len0` / `cdby` / …), and loading them
  all is *the mechanical cause* of the over-anchoring this compendium keeps
  fighting. Under the split, **the agent that writes the memo never holds the
  corpus.** It cannot reflexively anchor to attractors it has not read. This
  is "crawl, don't dump" applied at *verification* time — Pass B is a
  crawler, following exactly the edges Pass A pointed at.

**The honest cost of the split** (state it; do not pretend it is free): one
more place to fail, and **Pass B is structurally unable to notice anything
Pass A did not propose** — a weak Pass A silently caps the memo's ceiling.
That is a *visible* failure against a design whose failures were previously
invisible, which is why it is accepted.

**What would overturn this.** A measurement that a single Opus-5 pass over
483k tokens *reliably* recovers a planted cross-cluster, zero-shared-
vocabulary contradiction — run three times with the pair rotated, scored on
landing in the top 3 rather than merely being findable when asked directly.
Nobody has run it; it is one afternoon. Until then Amendment 2 is the
design, and this paragraph is the standing invitation to falsify it.

## The axis register — closed questions, not open synthesis

`refs/desk/axes.md` (Amendment 1). A small, durable, rotating set of
**claim-types the corpus repeatedly takes positions on** — e.g. *"may an
opaque learned representation drive a harness decision?"*, *"what must a
no-build verdict establish?"*

Pass A answers these **closed**: *"list every finding that takes a position
on axis A, quote it, flag disagreement."* That is a linear scan with an
accumulator — what long-context attention genuinely does well — and it is
**checkable**. An *open* question over this corpus returns `iaf` / `len0` /
`cdby` every single week.

**The register is also the dedup `/elevate` never had, and it is the reason
the memo does not repeat.** Salience is stable: week 2's top-salience pair
is week 1's. Enumeration matters not for one memo but for a memo *series*.
**Once an axis is resolved it is struck**, and the next pass is forced below
the waterline.

Maintenance rules:
- An axis is added only when Pass A finds ≥2 findings taking positions on it.
- An axis is struck when its question has a recorded answer — with the memo
  date that resolved it, so the strike is auditable.
- The register is hand-maintained and **can rot** — the same class of object
  `context-engineering-claude-5` §3 flags as "a conflict generator by
  construction." Re-read it against reality on every `--wide` pass.

## Cadence — weekly memo, monthly wide pass (OQ2)

**Split by section, not by memo.**

| Sections | Refreshed from | Cadence |
|---|---|---|
| §1 ASK, §2 STOP, §4 CONNECTION, §5 DOOR | the week's delta + the standing axis register | **weekly** |
| §3 SIGNALS FROM THE FLOOR | a full-corpus **wide** Pass A | **monthly** (carried as a standing register in between) |

The arithmetic: ~26 new explorations/week ≈ 96k words ≈ 130k tokens —
roughly **a quarter of the corpus by volume**, so the weekly delta is *not*
thin, and "what to fund / what to stop" are genuinely weekly decisions. What
*is* thin weekly is §3's corpus-level structure: contradictions between
2026-05 findings do not change because 26 new ones landed. Hence the split —
which also cuts the wide-pass cost ~4×.

**Trigger the wide pass** when `--wide` is passed, or when `refs/desk/axes.md`
records no wide refresh in the last 28 days. Weekly runs reuse the standing
register and read only the delta.

## Pass A — the wide proposal pass

Two lenses, dispatched as **parallel fresh agents**, both emitting candidate
lists only.

**A1 — the axis scan.** Whole corpus (on a wide run) or the week's delta
(weekly), against `refs/desk/axes.md`. Closed questions, linear scan,
`effort:'high'` — this is an accumulator, not a divergence problem, and max
effort buys nothing here while costing a great deal at 483k.

**A2 — the opportunity lens.** The `/elevate` technique — fresh unpolluted
agents at **`effort:'max'` via Workflow** (the bare `Agent` tool has no
effort param), divergent lenses over the week's delta plus **2–3 rotating
`INDEX.md` clusters**. Track the cursor in the memo. **Aim it**: consume one
edge from `INDEX.md`'s "Biggest unconnected opportunities" seed list each
run, strike drawn/tabled edges, propose replacements — so that list is a
live work queue the loop both drains and replenishes.

A2 runs at max on a *small* context (~130k, not 483k), which is what makes
max affordable here. Full cost model, weekly vs monthly:

    A1 wide    483k ctx × ~6 turns   ≈ 2.9M    (monthly only)
    A2         ~130k ctx × ~10 turns ≈ 1.3M
    Pass B     ~40k ctx  × ~40 turns ≈ 1.6M
    refuter    small                 ≈ 0.3M
    ------------------------------------------
    weekly     ≈ 3.2M        monthly ≈ 6.1M     (stipulated spec ceiling: <15M)

**Bead context is the one place to be careful.** `br list` (text, titles
only) is the cheap index — use it freely. **NEVER `br list --json` the
backlog into an agent**: its JSON inlines every bead's full description
(~250 KB / ~60k tokens for ~145 open explore beads), which blows the budget
AND, because every body is dense with the same handful of tie-backs,
*manufactures* the over-anchoring this loop exists to counter. Titles in;
bodies (`br show <id>`) only for the beads a real seam actually touches.

Pass A's other bulk inputs: `refs/desk/<previous>.md` (so you do not re-pitch a
program he already declined — the golem phantom-backlog failure, memory
`project_golem_phantom_backlog`; on early runs also the last archived
`refs/elevate/sweep-*.md`, this loop's pre-rename history); `refs/desk/axes.md`;
`refs/desk/signals.md`; and `git log` since the last memo.

### How Pass A actually loads the corpus — do not improvise this

**The obvious way silently fails.** `cat */FINDINGS.md` does NOT deliver the
corpus: the tool-output cap truncates it to a ~2 KB preview plus a
persisted-output path, and the result is **success-shaped**. Measured
2026-07-26: the corpus is **2,210,890 bytes / 23,394 lines**, and a `cat` of just
*two* findings already returns 31,847 bytes — past the inline cap. A Pass A that
runs "concatenate the corpus" as a shell pipe receives roughly **0.1% of it** and
no error.

Nothing downstream can catch that. Pass B holds no corpus *by design*, so the few
quotes Pass A did emit verify fine; the refuter passes; the ledger proof passes;
the row logs `done`. That is precisely the silent-failure shape this loop exists
to surface — occurring inside the loop built to surface it.

**The mechanism that works:**

1. Concatenate to a FILE, so nothing flows through a tool result — and **strip
   this loop's own prior appends while you do it** (see below):
   ```bash
   awk 'FNR==1{skip=0} /^## Novel opportunities \((desk pass|elevate sweep)/{skip=1; next} /^## /{skip=0} !skip' \
     */FINDINGS.md > /tmp/desk-corpus-<date>.md
   ```
   ⚠️ **This form deliberately contains NO bare `$0`, and must stay that way.** The
   earlier version tested `($0 ~ /^## Novel opportunities …/)`; when `/desk` is invoked
   **with an argument**, skill-argument substitution rewrites `$0` in the rendered body
   to that argument, yielding `(/home/ubuntu/explore ~ /^## …/)` — an awk **`division by
   zero` fatal**, a ~2 KB corpus, and a pass that looks like it ran. Verified 2026-07-31:
   the file on disk was correct; only the *rendered* copy was corrupt, so this is
   invisible to anyone reading the source. Any `$N` in a skill's shell block is exposed
   to the same rewrite — prefer pattern-matching idioms over field references here.

2. Record the true size: `wc -c < /tmp/desk-corpus-<date>.md` **and `wc -l`.**
3. **Read it as a 4-way parallel map-reduce, NOT as ≤4 reads in one context.**
   Measured 2026-07-31: the corpus is ~36–55 tokens/**line** (the Read tool's own error
   reports 6,900 lines = **252,489 tokens**), so against Read's ~25k-token cap the real
   ceiling is **~220–1,000 lines per call** — roughly **55 calls** for a 27k-line corpus,
   not 4. A single context cannot hold it: at 2.6 MB the corpus measures **~880k–1.0M
   tokens** against the skill's obsolete 483k estimate.

   The shape that works: split the line range into 4 contiguous slices, dispatch one
   fresh agent per slice, and have each read **its own slice only**, reporting
   `slice_lines_received`. ⚠️ **Then run an explicit cross-slice reduce** — the 2026-07-31
   pass read 27,387/27,387 lines and *still* missed regression control 1, because its
   pair (`honcho` ↔ `cactus-hybrid`) straddles two slices and nothing compared across
   them. Coverage is not recall; budget a reduce step or the map buys you less than it
   appears to.

**Why the filter, not a plain `cat`.** Step 8 writes a
`## Novel opportunities (desk pass <date>)` section into the FINDINGS files, so
without the filter each pass ingests **its own predecessors' opportunity prose as
corpus** — measured 2026-07-26: 129 such sections / ~23,300 words already, from
four prior passes. That is a self-anchoring channel: the loop re-reads what it
wrote and proposes it back. The filter removes ~168 KB (~7.6%) of the read and,
more importantly, removes the feedback edge. Human-written
`## Novel opportunities` sections (no dated pass tag) are **kept** — they are
corpus.

**The self-check that makes a short read impossible to miss.** Pass A MUST report
`corpus_bytes_received` alongside its candidate list, and Pass B MUST compare it
to `wc -c` on the file. A shortfall is a FAILED pass — log `outcome:"blocked"`,
not `done`, and say so in the memo. §6 logs the number every run.

This is the one observable that converts "Pass B cannot notice what Pass A missed"
from an *invisible* ceiling into a *visible* one — which is the ground on which
the architecture accepts that trade at all.

## Pass B — the narrow verify-and-write pass

Fresh. **Holds no corpus.** Its inputs are the candidate list, the axis
register, and `refs/desk/<previous>.md`.

1. **Verify every candidate.** Open only the file the candidate names.
   Re-read the quoted span *in place*. A candidate whose quote does not
   verify is **dropped**, and the drop is noted in the memo footer with a
   count. This is the step that makes citation real rather than decorative.

   **Normalize before comparing — a naive `grep -F` drops GOOD candidates.**
   The corpus is markdown, so a span quoted as *"the control flow branches on
   it"* is stored as `the *control flow branches on it*` and a fixed-string
   match returns 0. Strip `*`, `_` and backticks, collapse whitespace
   (including newlines), straighten curly quotes, and drop leading/trailing
   ellipses and trailing `,.;:` — applied **identically** to the quote and the
   haystack. `bin/verify-quotes.py`'s `normalize()` is the reference
   implementation; import it rather than re-deriving it. Case is preserved
   deliberately: a re-cased quote *has* been altered. Skipping this inflates
   the footer's drop count into noise (`explore-yqtm`: 14 FAILs on
   `strands-shell`, all false positives).
2. **Dedup** every surviving candidate against open bead titles *and* the
   axis register, before anything is written. **Then verify-first on carried
   signals:** every §3 item carried in `refs/desk/signals.md` that names a bead
   gets a `br show <id>` before it is re-emitted — **drop the ones already
   closed or actioned.** Zig executes §3's proposals *between* memos, so
   without this check weeks 2–4 re-propose closes he already ran. That is the
   golem phantom-backlog failure verbatim (`project_golem_phantom_backlog`),
   whose recorded fix was exactly this verify-first protocol.
3. **Apply the artifact caps** (below) — they bind before the word cap does.
4. **Write the memo.**

## Output — `refs/desk/YYYY-MM-DD.md`

**Two caps, and the second is the one that actually binds.**

    HARD CAP: 1,200 words
    HARD CAP: <= 3 asks · <= 1 stop · <= 1 connection · <= 2 new beads

Word count is the wrong governor for the failure this loop was built to
prevent: **a 1,200-word memo can file 65 beads a quarter.** The binding
constraint is on *durable artifacts emitted* (Amendment 3 / OQ7). **A memo
that wants to file a third bead must retire one instead.**

1,200 words is right and stays: ~26 explorations/week ≈ 96k words → **80:1**,
the right neighbourhood of `explore-jdgk`'s 100:1 target. And every prior
artifact in this family that was allowed to grow, did — the predecessor
sweep went **1,460 → 1,666 → 2,190** words and became part of the
comprehension rot it was built to prevent.

Register: chief of research pitching the lab owner on a resourcing decision.
Urgency, signal, expected return, ROI, honest risk. Not a summary. Assume he
does not know the premise; explain it from scratch, briefly (memory:
`pitch-as-partner`, `plain-language-explanations`).

**The heading convention is MANDATORY** — it is what makes the caps machine-
checkable, and an uncheckable cap is decoration. Exactly these forms, uppercase:
`## §1 THE ASK`, then one `### ASK n` per program; `## §2 WHAT TO STOP` with one
`### STOP` per candidate; `### CONNECTION` under §4; `### CANDIDATE QUEUE` and
`### EVIDENCE LAYER` under §5. The ledger proof greps these literals, so a memo
that free-styles its headings fails its own gate.

⚠️ **`### CANDIDATE QUEUE` was added 2026-07-27 (`explore-qwtt`) and it is the
reason to distrust "the skill says so" as an enforcement story.** The §5
candidate-queue report shipped the day before as skill prose only — and §5 had
no mandated literal, so there was nothing to grep even in principle. A pass could
omit the whole Pending report and still log `done` against a passing proof. That
is the *exact* write-half/read-half asymmetry the report was filed to fix
(`explore-00qa`), reappearing one layer up at the proof. The lesson generalizes
past this line: **when you add an instruction to a loop, ask what would notice if
it silently stopped happening** — if the answer is "nothing," you have written
documentation, not a mechanism. `### EVIDENCE LAYER` (`explore-b2j8`, the day
after) is the same lesson applied on the way in: the read half and its grep
clause landed in one change, because a reader with no gate is the bug.

**§1 THE ASK** — always first. 1–3 programs to fund next week, each under its own
`### ASK n`. Each with all five fields: *what it is | the signal that it's ripe |
expected return | honest risk | the concrete ask* (a Vibes card? a build? an hour
of Zig's time?).

**§2 WHAT TO STOP** — MANDATORY, ≥1 candidate to defund / close / table,
with reasoning. A chief who only proposes new programs is not doing the job.
This section is the loop's real **drain**. It explicitly admits
**per-exploration stop candidates**: a week's exploration that drifted or
overclaimed is a defunding candidate in exactly this register (OQ3). `/desk`
**retains the authority to dispatch a `/scrutinize`** on such an
exploration — `/desk` is the opportunity gate, `/scrutinize` is the
correctness gate; hand off, don't improvise. Without this paragraph the
delegated structural review (`refs/pulse.md`) has no home at all.

**§3 SIGNALS FROM THE FLOOR** — the whole-corpus facts no tick can see.
Refreshed monthly by a wide pass; carried between passes in
**`refs/desk/signals.md`** — the memo is 1,200-word capped, so without that
carrier everything §3 pushed below the waterline is unrecoverable in weeks 2–4.
**All three sub-items are BIDIRECTIONAL:**
- **contradictions** — two findings that now disagree (cite both paths, quote
  both sides). Resolution is often *"the axis is under-specified,"* not
  *"pick a side"* — say so when that is the honest read.
- **beads silently answered** — open beads a later finding already resolved
  — **AND confirmed defects with no bead**: something a finding *raised*,
  confirmed at a `/scrutinize` gate, that `br ready` and `/triage` cannot
  see because it exists only as prose inside one FINDINGS.md. The spec looked
  in one direction only and missed the live instance; both directions are
  required.
- **clusters at critical mass** — a theme heavy enough to write up, build,
  or pitch.

**§4 THE ONE CONNECTION** — exactly ONE non-obvious link between distant
explorations. Not a list. Lists are how the rot started.

**§5 THE DOOR** — the human checkpoint, kept terse so it is never buried:
- the week's N new explorations, one line each, and explicitly **which (if
  any) need his eyes** — anything that reads drifted, overclaimed, or thin.
  "All clean, nothing flagged" is a valid and welcome line.
- **queue health**, one line: unworked Vibes depth, `📬`-mailboxed count,
  oldest-`📬` age, and the NAMES of any unworked card older than ~3 weeks.
- **candidate queue** — under the MANDATORY literal heading `### CANDIDATE QUEUE`
  (the proof greps it; see the heading convention above). One line: the read half
  of `~/explore/refs/vibes-candidates.md`, which nothing else reads — the
  **Pending** row count, the oldest row's date + age, and the NAMES of any row
  older than ~3 weeks. Those named rows are the
  go/no-go set — put them to Zig **inside §1's ≤3 asks** (a Pending row is a
  program seeking funding, so it competes for an `### ASK n` slot like any
  other), **never as extra asks stapled on after the cap**. A week with nothing
  past the threshold reports the counts and stops. Promotion stays human-gated:
  the pass never creates the Asana card. A "no" goes to **Dropped** (run step 6).
- **evidence layer** — under the MANDATORY literal heading `### EVIDENCE LAYER`
  (the proof greps it too). One line, from `python3 bin/check-captures-declared.py
  --corpus` (run it; do not estimate): how many entries have **settled** their
  capture claim vs are **unsettled**, the qualifier distribution, and the NAMES of
  any **majority-derived** entry — one holding more `(derived)` files than real
  captures, i.e. an entry built mostly from agent-synthesized secondary research
  rather than mirrors of sources. That is a *different evidence claim* from a
  partial mirror, and until `explore-b2j8` nothing in the fleet read `*/refs/*`
  across the corpus at all: `/desk` reads the FINDINGS layer, `/dream` reads
  transcripts, and the evidence layer had **no reader**. It is a REPORT — the
  script always exits 0, changes no verdict, and names no defect. Report the
  numbers; a named majority-derived entry is a §2 stop-candidate or a
  `/scrutinize` dispatch only if the memo genuinely judges it so.
- **mailbox digest**: a one-line verdict per `📬` card of the week, so he can
  complete them in one pass instead of re-reading each. (Auto-completing old
  `📬` cards was **declined by Andrew 2026-07-17** — human-gated stays. His
  2026-06-12 `📬`-not-complete decision stands.)

**§6 PORTFOLIO STATE** — ≤5 lines of numbers: corpus size, new this week,
open programs, backlog delta, token spend vs last week, **and the input-
context fraction** (for the succession trigger below).

**Footer** — the refuter verdict, the count of candidates dropped for failing
quote verification, and the A2 cluster cursor.

## Propose, never close (OQ6)

§3's silently-answered beads and §2's stop candidates are **proposals**. The
usual reason given — "allocation is the owner's job" — is true but too weak;
if it governed, `/triage` would be illegitimate too. The reason that actually
holds is the unattended-loop rule from `context-engineering-claude-5` §6:

> prefer a prohibition wherever a wrong call is (i) silent, (ii) consumes a
> bounded resource, or (iii) **writes to shared durable state that a later
> tick will read as fact.**

A wrongly-closed bead is (i) and (iii) exactly: the idea disappears and
**nothing ever notices**. Worse, *"a later finding answered this bead"* is a
semantic judgment made by the same pass that is optimising to produce a
satisfying memo — the self-grading nodding loop. The known failure direction
of this family is documented (the golem phantom-backlog re-proposed
already-shipped work); the inverse — closing unshipped work — is strictly
worse and strictly less visible.

**Required form of every proposal:** bead id + FINDINGS path + the **quoted
span** that answers it, rendered as a copy-pasteable `br close` block Zig
runs in one line. Proposing without paying the citation cost is how a
propose-only loop degenerates into a rubber stamp.

## Anti-overclaim — the gate that protects trust

Every factual claim cites a FINDINGS path or a bead id **inline**. A claim
with no citation is a spec violation. A bad pitch spends the owner's trust,
which costs more than a missed opportunity (`explore-grjy`).

**Do not claim to have enumerated what you sampled.** A drift-over-time claim
across dozens of documents cannot be exhaustively resolved in one memo; land
the *axis* plus 2–3 verified instances and let the register carry the rest
below the waterline. A memo claiming it resolved all of them is exhibiting
the exact failure this design was rewritten to prevent.

Before delivery, run **ONE refuter pass**: a fresh agent at `effort:'max'`,
prompted to argue that the **§1 top program is NOT worth funding**. If it
lands a hit, demote or reframe the ask. Scope it to §1 only — that keeps the
gate cheap while covering the one section that spends trust. Record its
verdict in the footer.

## Where the opportunity can land — lead with curiosity, not a tie-back

**Over-anchoring to Andrew's real projects is how the novel opportunity gets
missed** (Zig, 2026-07-13). If every finding has to cash out as "a move for
LinearB / the harness / a live `~/` arc," the pass collapses to the modal
tie-back. Range across **all** of the following with **no default ranking**.
(Mirrors `/dive`'s and `/elevate`'s section of the same name; keep all three
in sync.)

- **An entirely NEW idea** the corpus sparked, tied to nothing already here.
  First-class output, not a consolation prize.
- **An interlink that forms a deeper context** — between explorations AND
  with open-ended beads (`explore:` / `desk:` / legacy `elevate:` / `human:`
  threads). A finding that hands an open bead its missing piece is worth more
  than either alone.
- **An application to Andrew's active work — when it's real.** Derive the
  active set empirically each run (git activity + mtimes across `~/`,
  `~/explore`, `~/linearb`, `~/explore/aaif`). One valid landing, not the
  preferred one.
- **Interesting for its own sake.** Say *that*; don't force a build.

**Three guards stay hard:**

- **Don't manufacture a tie-back.** Honest "new idea, no home yet" beats a
  forced connection.
- **"NO adopt" is not "NO build."** "Don't adopt *this artifact*" (immature
  repo, WASM lib, commercial tool, runtime mismatch) must not silently become
  "nothing to build here." Ask *separately* whether a transferable method /
  pattern / primitive dodges the artifact's wall. A wall for the tool is
  rarely a wall for the pattern. (Caught 2026-07-13: reflexive "NO harness
  build" buried ~3 buildable experiments. 44 of 128 findings carry a
  no-build/no-adopt verdict, phrased ~15 different ways — that is a measure of
  **presence**, not of miscalibration, and establishing the second is the work.
  Which is why this is now a standing axis rather than prose.)
- **The build PROJECTS are tabled — the CONCEPTS are not.** Hermes /
  MUD-golem / local-coding-models are tabled (2026-06-29); the concepts they
  touched (agent-sim, simulation, memory, loops) are **active**. Never write
  "tabled *agent-sim* arc" or call a sim/pet build "not a live destination."

## The run

1. **Decide the shape.** Wide (`--wide`, or no wide refresh in
   `refs/desk/axes.md` for 28 days) or weekly-delta. Note which in §6.
2. **Dispatch Pass A** — A1 (axis scan, `effort:'high'`) and A2 (opportunity
   lens, `effort:'max'` via Workflow) in parallel, both fresh. Each returns a
   **candidate list only**: id / path / quoted span / axis, **plus the one
   ≤5-line `FIELD DELTA` block** carved out above (step 7's only source).
   Reject any Pass A return that contains prose verdicts, or a FIELD DELTA that
   has grown past 5 lines into judgment — that is Pass A doing Pass B's job.
3. **Pass B** — fresh, corpus-free. Verify every quote in place (normalizing
   markdown emphasis first); drop what does not verify; dedup against open bead
   titles + the axis register; `br show` every carried `signals.md` bead and
   drop the closed ones; run `python3 bin/check-captures-declared.py --corpus`
   for §5's evidence-layer line (one cheap read, no subprocess fan-out, always
   exits 0); apply the artifact caps; write §1–§6.
4. **Refuter pass** on §1. Record the verdict in the footer.
5. **Update the two registers.** `axes.md`: add axes that earned entry (≥2
   positions), strike resolved ones with the memo date, record the wide-refresh
   date. `signals.md`: park §3 items the memo could not fit, strike the ones
   Zig actioned. Neither register is a place to grow output — both exist so the
   memo can stay capped.
6. **File + interlink the beads** — **≤2**, title prefix `desk:`, in the
   umbrella's `.beads/`. **Not Asana.** **Interlink every bead**: name the
   beads/explorations it connects **by id**, and `br dep add` real
   dependencies. Report the edge count in the ledger note (`"2 beads, 5
   edges"`). Zero edges on a multi-bead pass is the tell that this step was
   skipped. Record consciously-rejected candidates in
   `~/explore/refs/vibes-candidates.md`'s **Dropped** table (or the bead
   `close_reason`) so a "no" is durable and not re-derivable forever. **Read
   that file's Pending table on the same visit** — it has no other reader — and
   report it per §5's *candidate queue* line; any Pending row you want promoted
   spends one of §1's ≤3 ask slots, it does not add a fourth.
7. **Append the field delta.** `refs/desk/field-notes.md` (append-only), written
   **from Pass A's `FIELD DELTA` block plus a one-line direction read** — do not
   synthesize it from the candidate list, which cannot support it. Clusters that
   GREW, themes that accelerated, new convergence points ("Nth independent
   instance of X"), direction read. After ~4 passes this file IS the emergent
   trend layer. (It carries four `/elevate`-era passes already — the file moved
   here from `refs/elevate/` on 2026-07-26 so the trend clock did not restart.)
8. **Write opportunities back into the FINDINGS files** — **only into the
   explorations a SURVIVING candidate names**, never "every exploration
   examined" (Pass A examines the whole corpus; Pass B verified a handful).
   Append, never rewrite, a dated section:
   ```
   ## Novel opportunities (desk pass YYYY-MM-DD)
   - <opportunity> — <effort> — <risk>[ — <harness/active-arc move, ONLY if genuine>]
   ```
   The harness move is **optional**; a new idea tied to nothing is
   first-class. This is the BACKFILL for the ~40 pre-2026-06-29 explorations
   that predate the required-section rule.

   **This step is the loop's largest durable emission and the artifact caps do
   not reach it** — measured 2026-07-26, four prior passes wrote ~23,300 words
   here against a 1,200-word capped memo, i.e. the caps governed under a fifth
   of what the loop actually emitted. Scoping to surviving candidates is what
   binds it to the caps. The dated `(desk pass …)` tag is load-bearing: it is
   what the Pass A corpus filter greps to keep the loop from re-ingesting its
   own prose. **Never write this section without the dated tag.**
9. **Append the pulse-ledger row.** `/desk` is a pulse loop, so it MUST leave
   a row (no ledger-less ticks; the dashboard reads it). Append to
   `~/explore/refs/pulse-ledger.jsonl` with `"row":"desk"` and a `kind:cmd`
   proof the commit hook RE-RUNS (bare `artifact` is rejected fleet-wide,
   `explore-len0`):
   ```json
   {"ts":"<date -u +%FT%TZ>","row":"desk","outcome":"done","proof":{"kind":"cmd","cmd":"D=refs/desk/<date>.md; test $(wc -w < $D) -le 1200 && grep -qF '## §1 THE ASK' $D && grep -qF '## §2 WHAT TO STOP' $D && test $(grep -c '^### ASK ' $D) -le 3 && test $(grep -c '^### ASK ' $D) -ge 1 && test $(grep -c '^### STOP' $D) -le 1 && test $(grep -c '^### STOP' $D) -ge 1 && test $(grep -c '^### CONNECTION' $D) -le 1 && grep -qF '### CANDIDATE QUEUE' $D && grep -qF '### EVIDENCE LAYER' $D && test $(git diff HEAD~1 -- .beads/issues.jsonl | grep -c '\"title\":\"desk:') -le 2"},"note":"desk pass (wide|delta) — N asks, M beads/E edges; C candidates dropped on quote-verify; corpus_bytes N of M; reviewed W new explorations (F flagged); field-delta appended"}
   ```
   A pass that found nothing new logs `"outcome":"quiet"` (no proof needed) —
   but see the empty-week rule below: "nothing to report" is a failure, not a
   quiet tick.
#### The registration assertion — run it right after appending the row

Appending a well-formed row is **not** the same as the row being *readable*. Every gate
in this stack checks the row you WRITE — `pulse-ledger-lint.py` checks the name is
canonical, `pre-commit-checks.sh` re-runs the `done` proof — and **nothing checks that the
dashboard can find it.** A registration defect (a `harness-manifest.json` entry whose
`ledger_row` does not match what this loop actually writes, or a `null` there) is
invisible while every local gate passes green: `ledger_streak.load_rows(path, None)`
returns **zero** rows, so the loop reads `stale` / *"no ledger row within grace (exit-0
lie)"* immediately after writing one.

That is not a cosmetic desync. On 2026-07-26 the digest loop correctly logged
`outcome:"blocked"` with a P1 `human:` bead — a genuine parked-on-Zig signal — and the
dashboard rendered it as an infrastructure alarm for 12 hours because its manifest entry
had `ledger_row: null`. **A needs-Zig signal was masked as a plumbing failure.** Bug
`explore-4x39`.

So assert it, every run, immediately after the append:

```bash
LOOP_ID=pulse-desk   # the systemd timer stem
ROW=desk                          # the row THIS loop writes

python3 ~/harnessd/bin/harness_state.py >/dev/null
python3 - "$LOOP_ID" "$ROW" <<'PYEOF'
import json, sys
loop_id, row = sys.argv[1], sys.argv[2]
state = json.load(open('/home/ubuntu/.local/state/harness/state.json'))
m = [l for l in state['loops'] if l['id'] == loop_id]
assert m, f"REGISTRATION GAP: {loop_id} is not in harness-manifest.json at all"
l = m[0]
assert l['ledger_row'] == row, (
    f"REGISTRATION GAP: manifest says ledger_row={l['ledger_row']!r}, "
    f"this loop writes {row!r} — the dashboard is reading nothing")
assert l['last_ledger_ts'], (
    f"REGISTRATION GAP: {loop_id} reads no ledger row despite one just being written")
print(f"registration OK: {loop_id} row={row} state={l['state']} — {l['detail']}")
PYEOF
```

**⚠️ The manual regen is a FALSE GREEN if you just edited the manifest.** `harnessd` is a
running daemon (`systemctl --user is-active harnessd`) that loads
`harness-manifest.json` **at service start** and regenerates `state.json` on its own
cadence from that in-memory copy. Running `harness_state.py` by hand re-reads the file
fresh, so **your assertion passes while the dashboard keeps publishing the broken
value.** Verified 2026-07-27: a hand run reported `daily-digest / blocked` (correct) while
the daemon, started 44 minutes before the manifest edit, kept emitting
`ledger_row: null / stale` into the same file minutes later. This is the always-loaded-tier
staleness class (`explore-0z6r`) one layer down.

So if you touched the manifest, **restart the daemon and then assert against what IT
publishes** — not against your own regen:

```bash
systemctl --user restart harnessd
# wait for the daemon's OWN next regen, then confirm state.json is newer than the manifest
until [ "$(stat -c %Y ~/.local/state/harness/state.json)" -gt "$(stat -c %Y ~/harnessd/refs/harness-manifest.json)" ]; do sleep 10; done
```
…and only then run the assertion block above.

**⚠️ The manual regen is a FALSE GREEN if you just edited the manifest.** `harnessd` is a
running daemon (`systemctl --user is-active harnessd`) that loads
`harness-manifest.json` **at service start** and regenerates `state.json` on its own
cadence from that in-memory copy. Running `harness_state.py` by hand re-reads the file
fresh, so **your assertion passes while the dashboard keeps publishing the broken
value.** Verified 2026-07-27: a hand run reported `daily-digest / blocked` (correct) while
the daemon, started 44 minutes before the manifest edit, kept emitting
`ledger_row: null / stale` into the same file minutes later. This is the always-loaded-tier
staleness class (`explore-0z6r`) one layer down.

So if you touched the manifest, **restart the daemon and then assert against what IT
publishes** — not against your own regen:

```bash
systemctl --user restart harnessd
# wait for the daemon's OWN next regen, then confirm state.json is newer than the manifest
until [ "$(stat -c %Y ~/.local/state/harness/state.json)" -gt "$(stat -c %Y ~/harnessd/refs/harness-manifest.json)" ]; do sleep 10; done
```
…and only then run the assertion block above.

A failure here is **not** a reason to rewrite the row — the row is fine. Fix
`~/harnessd/refs/harness-manifest.json` (it lives in a *different repo*, which is why it
is the piece most easily forgotten), re-run, and commit the manifest with the run.

**The sibling failure, for a row that is new rather than mis-registered:** a brand-new row
name has no history behind it, so a carried-over systemd stamp file makes `last_fire` point
at the *predecessor* loop's run with zero rows of its own — reading `stale` before it has
ever fired. The fix is the seed row the `/pulse` relocation checklist already prescribes:
append one `outcome:"quiet"` row saying exactly that, *before* the first real fire. This is
what bit `desk` after the 2026-07-26 rename.

10. **Deliver.** Commit + push the memo, axes, signals, field-notes, beads, ledger, and
    any touched FINDINGS. Then `PushNotification` naming the **top ask + the
    file PATH** (Zig is on SSH+tmux — no clickable links, no file-send). On
    *"Mobile push not sent (Remote Control inactive)"* the push did NOT reach
    him; because `/desk` is autonomous it does **not** escalate to
    AskUserQuestion — file a P1 `human:` bead instead and end the pass.

## Regression controls

`refs/desk/controls.md` freezes the **real** cases this design was validated
against — not fixtures. A fixture tests that the mechanism finds a
contradiction *you planted*, which is a much weaker claim; this compendium
already paid for that lesson when the `/ab` rig's validity check failed
because both variants scored 5/5 on planted cases that were too easy to
discriminate (`refs/elevate-proposals-review.md`).

The controls are frozen so a later change to `/desk` is **re-measured rather
than re-argued**. Re-run them after any change to the run sequence.

⚠️ **`controls.md` NEVER goes into a Pass A context, and neither do its
contents.** Every control's PASS condition is that a pass finds the case
*unaided*; showing Pass A the answer converts each control into a tautology a
grep-only design would pass, which is the `/ab` planted-case failure one level
up. The same prohibition is why `refs/desk/axes.md`'s seeded axes carry their
question only — see the withholding notes there, and do not "helpfully" restore
the worked examples to either file. **The orchestrator scores the controls
against Pass A's return; Pass A never reads them.**

## Rules that bite

- **An empty week still produces a valid memo.** With no new findings, the
  signal comes from corpus-level facts — contradictions, silently-answered
  beads, aging programs. Degrading into "nothing to report" is a failure of
  the pass, not a property of the week.
- **`/desk` never blocks on AskUserQuestion.** It is a scheduled loop: it
  notifies, files beads, and ends.
- **Both caps are enforced, not aspirational.** The proof command in the
  ledger row checks them.
- **The ledger row is `desk`, and it starts fresh.** The archived `elevate`
  rows stay under their old name as history — they key the old cap counters
  and must not be rewritten (`explore-b47q`). Never migrate them.

## The succession trigger (watch for it, don't act on it)

The deferred `lab-<moniker>` lineage plan (`~/explore/refs/lab-lineage-plan.md`)
has exactly one evidence gate: **a wide pass whose input exceeds 60% of
context on three consecutive runs.** That is the point at which the desk can
no longer see the whole portfolio — which is the only thing it is for. Log the
input-context fraction in §6 every run so the trigger is observable. When it
fires three times, say so in §1 and let Zig decide; do not start a new repo
autonomously.

## Anti-patterns

- ❌ **One context that loads, judges, AND writes** — ~4× the cache-read, and
  the writer anchors to what it read. This is the design that was rejected on
  review; do not quietly restore it.
- ❌ **A Pass A that returns verdicts or prose** — Pass A proposes candidates
  with quoted spans. Judgment is Pass B's job, after verification.
- ❌ **A Pass B that opens the corpus** — the moment it does, the
  over-anchoring defense is gone and so is the cost model.
- ❌ **File-by-file corpus reads** — ~7× the cost of the loop it summarizes.
- ❌ **`br list --json` on the whole backlog** — ~60k tokens of tie-backs that
  manufacture over-anchoring.
- ❌ **Open synthesis instead of closed axis questions** — returns the same
  three attractors every week.
- ❌ **A memo with no §2** — a chief who only proposes is not allocating.
- ❌ **A ranked menu instead of a position** — that's a status report.
- ❌ **Auto-closing the silently-answered beads** — propose; a wrong close is
  silent and permanent.
- ❌ **Uncited claims, or claiming enumeration over a sample** — a bad pitch
  spends trust that costs more than a missed opportunity.
- ❌ **Migrating the old `elevate` ledger rows** — archived history, left
  alone. (Scoped to **ledger rows**. `refs/desk/field-notes.md` was correctly
  moved out of `refs/elevate/` — the trend layer is live state, not history.)
- ❌ **Filling a seeded axis in from the design review** — quoting the worked
  pair into `axes.md` hands Pass A the answer and **spends the regression
  control** that exists to prove a body-level read was necessary. A grep-only
  design then "passes." Leave seeded axes as questions.
- ❌ **A step-8 append with no dated `(desk pass …)` tag, or one written for
  every exploration examined** — the first re-enters the corpus as anchor
  fodder; the second is the uncapped emission channel.
- ❌ **Output onto Asana** — beads + the memo + a push, never the Vibes board
  (the fleet proxy has no section-add route anyway).

## See also

- `refs/lab-open-questions.md` — the review that produced this design, the
  three amendments, and the seven OQ decisions (bead `explore-oodx`)
- `refs/desk/axes.md` — the axis register (seeded axes carry questions only);
  `refs/desk/signals.md` — the §3 standing carrier;
  `refs/desk/field-notes.md` — the append-only cross-pass trend layer (moved
  from `refs/elevate/` 2026-07-26, history preserved);
  `refs/desk/controls.md` — frozen regression controls, **not a Pass A input**
- `/dive` — the executor this desk allocates to
- `/elevate` — max-effort fresh eyes on ONE finished thing; its technique is
  what Pass A's A2 lens dispatches
- `/scrutinize` — the correctness gate §2 and §5 hand off to
- `~/explore/refs/pulse.md` — the routing table (row `desk`)
- `~/explore/refs/lab-lineage-plan.md` — the deferred lineage design and its
  trigger
- `refs/elevate/sweep-*.md` — archived pre-rename history of this loop
