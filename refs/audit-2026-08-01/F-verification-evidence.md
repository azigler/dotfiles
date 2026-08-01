# F — Verification-layer evidence sweep

Bead `dotfiles-789w`. Read-only. Corpus: 53 bead stores (4,925 unique beads),
12 loop ledgers, 7,721 transcript JSONL files (4.8 GB, mtimes 2026-01-26 →
2026-08-01), and git history across 10 repos. Every count below is
reproducible from the command shown.

**Headline: the layer is not ceremony. 56 of 132 recorded `/scrutinize`
gates (42%) returned a non-SHIP initial verdict; 40 of 81 (49%) in the last
30 days.** Several catches were production-fatal defects that green test
suites structurally could not see. The cost is also real and larger than the
harness has ever priced: ~147 reviewer subagents in 30 days, ~142M
input-token-equivalents.

---

## 1. The verdict tally

Source of truth is the `## Scrutiny —` block that `/scrutinize` mandates be
appended to the gated bead's notes. Read directly from each repo's
`.beads/beads.db` (the JSONL export drops `notes`), deduped by bead id,
excluding worktrees and the `.beadsview-work` mirrors and the
`agents/lb-agent-accounts` nested copy of `linearb/agent-factory`.

| Verdict (worst initial verdict on the bead) | n | share |
|---|---:|---:|
| SHIP (first pass, clean) | 55 | 42% |
| FIX-FIRST → fixed → SHIP | 39 | 30% |
| FIX-FIRST, still open / routed to a fix wave | 12 | 9% |
| REJECT → re-worked → SHIP | 3 | 2% |
| REJECT (standing) | 2 | 2% |
| OVERRIDE (gate deliberately not run) | 14 | 11% |
| unclassifiable block (truncated / non-verdict) | 7 | 5% |
| **total recorded gates** | **132** | |

**Non-SHIP initial verdict: 56/132 = 42%.**

By window and by kind of deliverable:

| Slice | gates | non-SHIP | rate |
|---|---:|---:|---:|
| All time | 132 | 56 | 42% |
| Last 30 days (≥ 2026-07-02) | 81 | 40 | 49% |
| Code repos (harnessd, agent-factory, dashboard-DI, andrewzigler3, picod, dotfiles, autonoveld, weekly-reporting, imp, vs14, investd, local-coding-models) | 74 | 26 | 35% |
| Prose/research (`~/explore` dive ticks) | 58 | 30 | 52% |

**Reproduce:** load every `.beads/beads.db` read-only, select
`title,description,design,notes,acceptance_criteria,close_reason`, regex
`##\s*Scrutiny[^\n]*(?:\n(?!##)[^\n]*)*`, classify on
`FIX-FIRST|NEEDS-WORK|REJECT|SHIP|OVERRIDE`. Cross-check on the JSONL exports
gives 130 (two beads whose block lives only in `notes`).

### The denominator problem — state it plainly

`AGENTS.md` says the gate is hook-enforced for `-t impl` beads. Measured:
**83 closed `impl` beads fleet-wide; only 26 carry a `## Scrutiny` block.**
That reads like a 69% bypass, and part of it was: `pre-bead-close.sh`'s own
comment records that the gate's `case` glob matched only commands *starting*
with `br close`, while the fleet's dominant idiom is a two-line `cd …` then
`br close`, so **1,043 of 1,044 bypassed closes were that newline form** —
"bypass rate rose 0% (Feb) → 48% (May/Jun) → 81% (Jul)", fixed 2026-07-26.
The rest is migration: `-t impl` is nearly dead (1 closed in July, 62 in May),
and the gate moved to the `scrutinize-required` label (33 beads, 30 closed,
24 with an accepted verdict) plus `## Scrutiny` blocks in
`~/explore/<topic>/FINDINGS.md`. **`impl` is no longer the right denominator;
the 132 recorded gates are the real population.**

### Live hook denials (transcript-measured, 2026-04-26 → 2026-08-01)

Counting only `PreToolUse:Bash hook error: […]` tool_results, i.e. an actual
blocked call, not documentation quoting the message:

| Gate | live denials | last 30d | first .. last |
|---|---:|---:|---|
| `pre-bead-close.sh` bead-template lint | 232 | 65 | 2026-04-26 .. 2026-08-01 |
| `pre-bead-close.sh` worktree guard | 63 | 46 | 2026-05-24 .. 2026-08-01 |
| `pre-bead-close.sh` **scrutiny gate** | **20** | **7** | 2026-05-23 .. 2026-07-31 |
| `pre-commit-checks.sh` **pulse done-proof** | **4** | **4** | 2026-07-27 .. 2026-08-01 |

**Reproduce:** `rg -l -F "<marker>" ~/.claude/projects`, then for each
matching JSONL line require `type=="user"` and
`"PreToolUse:Bash hook error"` in the message content.

---

## 2. The catches — what was actually caught

I read all 56 non-SHIP blocks. They are not uniform. Below, the ones where I
judge the defect would plausibly have shipped, then the ones that would not.

### Would plausibly have shipped broken

**`bd-tjpw.1.3`, 2026-06-09, agent-factory — the single strongest catch.**
> "Bolt middleware signature mismatch… the handler signature is
> `(event: SlackMessageEvent)` while Bolt invokes with an args object…
> `event.channel` is undefined at runtime → **every production event silently
> dropped**… **All 14 handler tests call the handler directly with a bare
> event so the suite structurally cannot catch it.**"

A total production outage, sitting behind a suite the reviewer independently
re-ran at 232/232 green. This is precisely the class no amount of self-checking
finds, because the author's mental model *is* the bug.

**`bd-tjpw.1.8`, 2026-06-09.** "cron route exports only POST; Vercel crons
invoke via GET → 405 every tick, **loop dead in production**" — plus the same
latent bug spotted in a sibling agent's weekly cron.

**`bd-kp9p`, 2026-07-21, REJECT (23-agent panel).** "autoRenderWorkflow
(auto-render.ts:525) has **ZERO production callers**… FASTLANE_PDF-on rounds
**freeze in 'rendering' forever** → render/deliver/learn tail dead."

**`explore-161v`, 2026-07-08 — latent-catastrophic secret leak.** The vault's
runtime push path had no "only `*/memory/**` staged" re-assertion: "an in-tree
`.gitignore` **OVERRIDES** `core.excludesFile`… could **silently commit+push
transcripts into permanent private history**." Fixed with a regression test
(T7) that reproduces the bypass.

**`explore-p5uf`, 2026-07-31 — a demonstrated sandbox escape.** "`_sync_
tracking_ref` guarded the REFNAME but not the filesystem path it resolves to.
A jailed tick that symlinks `.git/refs/remotes/origin`… makes the broker,
running UNCONFINED outside the jail, follow it. **The reviewer rewrote a second
repository's branch to a foreign sha**; `git log` there returned `fatal: bad
object HEAD`." Not argued — executed.

**`explore-g9xn`, 2026-07-31.** The reviewer ran mutation testing on the fix
and "found **three guards passing 59/59 while dead**", plus two README numbers
that did not reproduce. Suite 59 → 97.

**`bd-s9u8`, 2026-07-17 — a tautological test.** "`hrefs.length < 15` claiming
it proves index scope — but `MAX_RESULTS=10`… **deleting `data-pagefind-body`
would leave the suite green**."

**`bd-eazg.2`, 2026-07-07.** "No test exercises `assembleFromPlan` with
`v2Quality:true`… **A wiring bug there would pass all 63 tests.**"

**`bd-b5x3`, 2026-07-17 — an execute-and-observe regression.** "LIVE: hard load
39/39 excerpts; **SPA nav 0 excerpts**" — invisible to the regression test,
which only read static hard-load HTML.

**`explore-xh9t`, 2026-07-26 — the loop built to catch silent failure,
containing one.** "`cat */FINDINGS.md` hits the tool-output cap… so Pass A
would receive **~0.1% of a 2,210,890-byte corpus WITH A SUCCESS-SHAPED
RESULT**, and every downstream gate would still pass green." Also F3: the
ledger proof "was VACUOUS… matched 0 and **PASSED WITH 5 ASKS against a cap of
3**." Caught days before the loop's first-ever fire.

**`explore-mm1x`, 2026-07-07.** ReDoS guard was per-line, not aggregate:
"catastrophic pattern over one real slug (49,399 lines) ≈ **27h**;
`SKILL.md:28` 'can't hang' is **FALSE**." (`explore-xjn4`, `dotfiles-571`
are two more of the same shape.)

**Fabricated quotes in research output.** `explore-980b` records the base rate
directly: *"~4 of the last 14 done ticks caught by /scrutinize re-fetching LIVE
sources."* Concrete instance (commit, 2026-07-13): "kill fabricated 'Time
saved, attention lost' quote (her heading is 'It freed my time, but at the
expense of my attention')". For a research archive the prose *is* the artifact,
so this is a shipped defect, not a nit.

### Would not have mattered much — be skeptical here too

A material share of `~/explore` dive-tick FIX-FIRSTs are editorial. Examples:
`explore-8i15`'s only required fix was *"'four VMs' overcount (Pugs = Haskell
interpreter NOT a VM)"*; `explore-77n9`'s was a "#4-vs-#3 ranking
self-contradiction"; `explore-zons`'s D3 was *"'inverse mistake' → 'same
mistake, committed not avoided'"*, explicitly labelled cosmetic. `explore-a5x1`
returned SHIP with "three wording nits, none FIX-FIRST" — the reviewer
correctly declined to inflate. That honesty cuts both ways: it means the 52%
non-SHIP rate on prose repos is *softer* than the 35% on code repos.

### False positives are real and are recorded

`bd-sfl` (picod, 2026-06-27): panel returned REJECT; the orchestrator
overrode with cause — "3 'survived' but **2 were false positives** + 1 minor…
(Both reflect the panel not modeling the orchestrator pre-merge-gate
lifecycle, not a code defect.)" `explore-koji`: "14 adopted, 1 refuted."
`bd-eazg.2`: "1 confirmed, **3 refuted**." The panel workflow's per-finding
refutation stage exists for exactly this and is doing work.

### The one honest hole in the pro-scrutinize case

`explore-oqkq` (2026-07-03) ran a shakedown to measure `/scrutinize`'s own
catch rate and **failed**: "a gutted /scrutinize caught all 5 planted defects
as well as the full hunt list, so the programmatic catch-rate gate **can't
separate two competent variants**… rig-validity walked back to UNPROVEN on the
catch-rate axis." So: *that the gate catches things* is measured (this
document). *That the elaborate hunt-list prompt beats a minimal one* is
**not measured**, and one attempt to measure it hit a ceiling effect. That is
where the vendor's "over-verification" claim could still be right — about the
prompt's size, not about the separate reviewer's existence.

---

## 3. The pulse `done`-proof gate

Fleet ledger census (12 files, `find /home/ubuntu -name '*ledger*.jsonl'`):
**249 `done` rows.** Proof tokens: `cmd` 91, `artifact` 62, `scrutinize` 4,
**none 93**.

Blocks: **4 live denials, all between 2026-07-27 and 2026-08-01** — the gate
only became enforcing (43d3e94), then floor-raised to reject
`artifact`/`commit` (404d363, `explore-len0`), in mid/late July.

Coverage was itself broken until 2026-08-01. From commit `cef0ff9`'s own body:

```
refs/pulse-ledger.jsonl    COVERED       140 done, 108 with proof (77%)
refs/digest-ledger.jsonl   NOT COVERED    33 done,   1 with proof ( 3%)
refs/dream-ledger.jsonl    NOT COVERED     3 done,   0 with proof ( 0%)
```

I independently reproduce those three numbers. That is the cleanest natural
experiment in this whole audit: **the gate is what produces the proof; prose
alone does not.** 77% vs 3% vs 0%, same fleet, same authors, same week.

Against that, the gate has **demonstrated false-accepts**:

- `dotfiles-8aj5` (2026-08-01, closed): the scrutinize branch was
  `br show "$B" | grep -q 'SHIP'`. Reproduced with a positive control —
  `'## Scrutiny — 2026-08-01: Verdict: do NOT SHIP'` → **rc 0 ALLOWED**;
  `'needs scrutiny before we SHIP this'` → **rc 0 ALLOWED**; control with no
  `SHIP` substring → rc 2 blocked. Also a whitespace-only `cmd` proof
  (`bash -c '   '` exits 0) was a free `done`.
- `dotfiles-jm1c` (2026-08-01, closed): 13 mutants against green suites,
  **3 survived** — including neutering `SCRUTINY_NEGATED_RE`, which left
  `test-pre-bead-close.sh` at **60/60 green** while `--selftest` on the same
  mutant reported `1 broken`. "**The guard that catches it exists, works, and
  has no caller.**" Fixed by `tools/githooks/pre-commit`.
- `dotfiles-2dez` (**still OPEN**): "**nothing binds the proof bead to the
  work.** The gate asks *does some bead say SHIP*. It never asks *is this the
  bead this tick worked on*… A tick with any reachable bead id gets a permanent
  `done`. That is `artifact` wearing `scrutinize` vocabulary."

So the done-proof gate is real (77/3/0) but its `kind:scrutinize` branch has
zero enforced verifier distance and has been used exactly 4 times.

---

## 4. `/handoff` and `/check`

**`/handoff` — UNMEASURABLE, and specifically: never fired as a skill.**
Across all 7,721 transcripts there are **zero** `Skill(handoff)` tool
invocations (`offboard` has 90, `scrutinize` 16, `check` 15, `impl` 16, `fix`
4). Searches for outcome language — `"handoff caught"`, `"handoff check
found"`, `"handoff incomplete"`, `"/handoff revealed"` — return **1 hit each**.
46 beads mention handoff at all. This is *not* evidence of absence of value:
`/handoff`'s prescribed output is populating `--acceptance-criteria`,
`--design`, `--notes` on the bead — **structurally indistinguishable from an
agent simply filling the bead well**. It leaves no signature by construction.
I found no evidence it changed an outcome, and no mechanism by which such
evidence could exist.

**`/check` — sparse but non-zero, and one clear catch.** 15 `Skill(check)`
invocations; 186 beads reference `/check` or "Implementation Readiness"; **32
beads carry an OQ id together with a MODIFY / SUPERSEDES / walked-back marker**,
i.e. the walk changed the plan. The strongest single instance is `bd-hblc`
(dashboard-DI, 2026-06-29), a fresh read-only skeptic run against a spec
*before* impl:

> "**R1 — getTask has no `.parent` (FIX).** `TASK_DETAIL_OPT_FIELDS`
> (asana.ts:347) omits parent… **so OQ-08's 'derive guest from
> [taskGid].parent' does NOT work as cited.**
> **R2 — `GooglePermissionError` does not exist (FIX, supersedes §4.4/§4.5).**
> **R3 — no reusable auth gate (FIX, supersedes D10).** …the `di_session`
> cookie gate is CLIENT-SIDE only and does NOT protect API routes."

Three of the spec's decisions were built on APIs that did not exist. Caught
pre-impl, which is the cheapest possible place. `imp-wb2` is a second instance
("2 BLOCKERS fixed in-description"). Both were run as adversarial reviewers
against a spec — i.e. `/scrutinize`-shaped, at `/check`'s position in the
pipeline.

---

## 5. The cost side

Measured, not modelled: 220 subagent transcripts whose opening prompt is an
adversarial-review dispatch (`~/.claude/projects/*/*/subagents/**/*.jsonl`,
first user message matching `adversarial review`). **147 of them in the last
30 days.**

| Last 30 days | tokens |
|---|---:|
| input | 4,903,500 |
| output | 3,418,540 |
| cache creation | 53,889,230 |
| cache read | 527,889,657 |

Weighting at standard Claude ratios (cache-read ×0.1, cache-write ×1.25,
output ×5) gives **≈142M input-token-equivalents over 30 days, ≈967k per
reviewer**. Per-reviewer raw totals: median 2.53M, mean 3.59M, max 19.2M.
For reference, `~/explore/.claude/skills/ab/SKILL.md:46` measures "~40k
billable tokens *per rollout*" — the scrutiny reviewers are ~24× that,
because they re-read whole deliverables plus capture corpora rather than one
task. **Treat the 142M as an estimate**: it excludes panel-mode hunters
spawned inside a Workflow (which do not appear as `Task` dispatches in the
parent) and the orchestrator-side turns spent dispatching and folding
findings, so it is a floor. Separately, 171 scrutinize-shaped `Task`/`Agent`
dispatches appear in transcripts in the same window.

Fleet git history shows the downstream work: 146 commits whose subject
mentions scrutiny and a fix/apply/harden/finding verb (deduped across the
`explore` / `explore/local-coding-models` shared history).

**The bypass is growing.** OVERRIDE verdicts — the documented "this is a
BYPASS, not a verdict" escape — are 14/132 all-time (11%) but **13/81 (16%)
in the last 30 days**, six of them filed in one batch on 2026-07-31
(`explore-qmsy.1`–`.6`, closing already-shipped work as bookkeeping). That is
the leading indicator to watch: cost pressure showing up as override rather
than as a decision to cut the gate.

---

## 6. Verdict per component

| Component | Verdict | Basis |
|---|---|---|
| **`/scrutinize`** | **LOAD-BEARING** | 56/132 non-SHIP (42%); ≥13 catches that green suites structurally could not see, including two total production outages, a demonstrated sandbox escape, and a latent secret-leak path. Cost is real (~142M tok-eq/30d) and should be scoped, not eliminated. |
| **pulse `done`-proof gate (`pre-commit-checks.sh`)** | **LOAD-BEARING for `kind:cmd`; CEREMONY for `kind:scrutinize`** | The gated-vs-ungated ledger comparison (77% / 3% / 0%) is a clean natural experiment that the gate causes the proof. But `kind:scrutinize` has 4 uses, a reproduced false-accept history (`dotfiles-8aj5`), and **zero enforced binding between the proof bead and the work** (`dotfiles-2dez`, open). Keep the gate; either bind the scrutinize branch or drop that kind. |
| **`/handoff`** | **UNMEASURABLE** | 0 skill invocations ever; ~1 hit for every outcome phrase searched. Its output is indistinguishable from ordinary bead hygiene. Do **not** cut on this evidence — instrument first (below). |
| **`/check`** | **LOAD-BEARING, thinly** | 15 invocations, 32 OQ-reversal beads, but one unambiguous catch (`bd-hblc`: three spec decisions resting on APIs that did not exist) caught at the cheapest point in the pipeline. Low volume, high leverage. |
| **`/fix`'s mandatory regression guard** | **UNMEASURABLE (compliance unknown)** | 637 bug beads; only **158 (25%)** — 144/521 (28%) of closed ones — carry regression-test / guard language. Either the mandate is ~72% unfollowed, or it is followed and unrecorded. Nothing in the harness distinguishes those. No hook enforces it. |

---

## 7. What I could not determine, and why

1. **Whether the elaborate `/scrutinize` prompt beats a minimal one.** This is
   the vendor's actual claim ("over-verification"), and it is the one thing
   the corpus does not answer. `explore-oqkq` tried and hit a ceiling effect;
   its own conclusion is "rig-validity walked back to UNPROVEN on the
   catch-rate axis." **Settle it with `/ab` on the corpus v2 that bead
   specifies** (defects near an Opus reviewer's detection threshold), requiring
   `A_catch − B_catch ≥ 3`. `explore-ldfm` (the bugfix-harvest corpus, 62
   items) appears to be that work in flight.
2. **True denominator: how many merges happened *without* a gate.** There is no
   fleet-wide record of "an impl wave completed", only of gates that ran. I can
   bound it (83 closed impl beads, 132 gates, and the measured 81% close-gate
   bypass before 2026-07-26) but not compute it. **Instrument:** have the
   merge/close path emit a row per wave with `gated: true|false`.
3. **`/handoff` and `/fix`'s guard leave no signature.** **Instrument
   cheaply:** require `/handoff` to append a one-line
   `## Handoff — <date>: <n> criteria verified, <n> split` block (mirroring
   `## Scrutiny`), and have `/fix` write `## Guard — <path>:<test>` on the bug
   bead. Both are greppable in one quarter and cost nothing at runtime. Then
   re-run this audit.
4. **Panel-mode true cost.** Workflow-spawned hunters/refuters (5–23 agents per
   gate in the panel path) are not attributable from the parent transcript, so
   §5 is a floor, not a total.
5. **Transcript survivorship.** Files go back to 2026-01-26 and none appear
   pruned, but the harness has no guarantee of that; the pre-May hook-denial
   counts should be treated as lower bounds.

**On search difficulty:** this was hard, and the difficulty is itself a
finding. Verdicts live in three incompatible places (bead `notes` in SQLite
but not in the JSONL export, `FINDINGS.md` blocks in `~/explore`, and free
prose in commit subjects), in at least five formats (`**Verdict**: SHIP`,
`## Scrutiny — <date> — SHIP`, `Verdict: FIX-FIRST → addressed → SHIP`, …).
The hook's own matcher accepts only some of them — running
`scrutiny_verdict_ok` over the historical corpus accepts **16 of 83** closed
impl beads that visibly contain human-readable verdicts. That is a recording
problem, not a reviewing problem, but it is why "is this layer working?" took
a day to answer instead of a query.
