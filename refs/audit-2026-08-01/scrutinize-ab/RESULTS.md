# Does the elaborate `/scrutinize` prompt beat a minimal one?

**Verdict: UNPROVEN — and the rig failed in a *new and more informative way* than
`explore-oqkq`'s.** Not a ceiling. The positive control did not merely tie: an author
rubber-stamping their own green suite **caught as much as the 1,446-word hunt list**
(5/10 vs 4/10). The pre-registered rig-validity gate failed, so the A-vs-B null is not
readable as evidence for either side, exactly as declared in advance.

Pre-registration: `PREREG.md` (frozen before any scored rollout). Answer key:
`ANSWER-KEY.md`. Per-rollout record: `results.jsonl`. Blind grades: `grades.json`.
Raw outputs: `out/`. Rig: `run.sh`, `build.py`, `blind.py`, `score.py`.

---

## 1. What was run

39 scored rollouts (cap was 40; one earlier smoke rollout is excluded and did not inform
any design choice). Each is a fresh `claude -p --model opus` → `claude-opus-5`, under its
own `HOME` with credentials **symlinked**, no `CLAUDE.md`, no skills, no hooks, no MCP,
empty cwd, the case file inlined with line numbers, no tools to look anything up with.

| arm | prompt | words |
|---|---|---:|
| **A** | current `/scrutinize` SKILL.md body, verbatim | 2,057 |
| **B** | minimal fresh-reviewer prompt written for this run | 120 |
| **Z** | **positive control**: "you wrote this, the suite passed, sign off" | 66 |

A shared 72-word output contract was appended to all three, so SHIP / FIX-FIRST / REJECT
carry identical definitions in every arm.

Corpus: 8 cases hand-picked from `bugfix-harvest/` (`explore-ldfm`) — 62 items mined from
402 closed `-t bug` beads by a script, so **nobody authored them for an eval**. 5 positives
(2 reps each) + 3 paired canaries (1 rep each). Selection criteria were declared in advance:
inferable in principle from the file alone (the floor guard `explore-lesd` demands), and in
audit-F §2's shape — a defect a passing suite structurally cannot see.

## 2. The matrix

`HIT` = named the actual defect, in the right direction, adjudicated blind against the bug
bead's own root-cause prose. Reps shown as `r1 r2`.

| case | defect | A | B | Z |
|---|---|:--:|:--:|:--:|
| **P1** `dotfiles-c7j` | ID extraction scrapes the `-r` reason string → hyphenated word false-blocks the close | – – | – **HIT** | **HIT** – |
| **P2** `hevyd-zrd` | token redaction has an uncovered verb / receiver → bearer spills | **HIT HIT** | **HIT HIT** | **HIT** – |
| **P3** `harnessd-sl6` | `data: %s` verbatim → multi-line SSE payload loses its continuation lines | **HIT HIT** | **HIT HIT** | **HIT HIT** |
| **P4** `bd-xtm9` | final log reports `CAMP_CHANGED` (intent) as "README pushed" (action) | – – | – – | – **HIT** |
| **P5** `dotfiles-0lm3` | `note()`'s `>>` append is not concurrency-safe | – – | – – | – – |
| | **catch** | **4/10** | **5/10** | **5/10** |
| | **paired false positives** | **0/3** | **0/3** | **0/3** |
| | **canary non-SHIP (raw)** | **3/3** | **3/3** | **3/3** |

**Every one of the 39 rollouts returned `FIX-FIRST`. Not one SHIP, not one REJECT, in any
arm, on any case, including all three post-fix canaries.**

## 3. The gates, in the order they were pre-registered

**Gate 1 — rig validity (positive control). FAILED.** Required `catch(A) − catch(Z) ≥ 2`
per 5 (≥ 4 per 10). Measured: **−1**. Z was told, in so many words, that it wrote the file,
that it had already run the suite, that the suite passed, and that this was the routine
sign-off. It then returned FIX-FIRST on all 13 of its rollouts with 3–8 located findings
each — and it produced the *only* catch on P4, which neither A nor B found in four attempts.

This is the single most important number in the run, and it is not a fluke of one case: Z
was at or above A in both reps (3/5, 2/5 vs A's 2/5, 2/5).

**Gate 2 — catchability (floor guard). PASSED.** Best single arm 5/10 (50%); best single
arm in one rep 3/5. Two cases (P4, P5) were missed by 5 of 6 and 6 of 6 attempts
respectively, one (P1) was caught by 2 of 6, one (P2) by 5 of 6, one (P3) by 6 of 6. The
corpus spans the detection threshold cleanly — **it is neither ceilinged nor floored**, which
is what `explore-oqkq` and `explore-lesd` each asked for and neither got. The corpus is not
the problem here.

**Gate 3 — the primary comparison.** Because gate 1 failed, this is reported but **not
readable**: `A − B = −1` of 10, `A − Z = −1`, `B − Z = 0`. The co-primary false-positive
axis carries no signal either — 0/3 paired FPs in every arm, and 3/3 raw non-SHIP in every
arm. Under `/ab` Step 4c the FP axis was supposed to break a catch-rate tie; it is
saturated, so it cannot.

**So the honest reading: the rig has good resolution on the *corpus* axis and none on the
*prompt* axis.** A null produced by an instrument that cannot distinguish a skeptic from a
rubber stamp is not evidence that the hunt list is worthless. It is evidence that this
measurement cannot see whatever the hunt list does.

## 4. What did move — reported as exploratory, not as a result

Two things separate the arms cleanly. Neither was pre-registered, both are post-hoc greps
over the same 39 outputs, and both are stated here only because they point at the corpus
that would settle the question.

**Verbosity is monotone in prompt length.** Mean words per rollout: **A 1,039 · B 857 ·
Z 694.** The prompt controls how much the reviewer writes. It did not control what it found.

**Epistemic hedging is monotone in prompt length, and steeply.** Rollouts containing an
explicit "I could not verify / this is unverified / this is unproven, not false" statement:
**A 5/13 · B 1/13 · Z 0/13.** That is precisely two of A's hunt-list items firing —
*"acceptance criteria checked without evidence — for every ticked box, find the proof"* and
*"unreproducible runtime claims"*. One A rollout refused to clear six referenced symbols and
every named test because they weren't in the listing, and labelled the handoff's coverage
claim **"unproven, not false."** No Z rollout ever did this.

**And the only two rollouts that attacked the *test* rather than the code were both A.**
On P2, A (both reps) independently observed that the named test
`TestTokenNeverAppearsInErrorsOrFormatting` *"formats with five verbs — precisely the five
verbs that already work. The test is shaped to pass against the code rather than to attack
it, and it cannot catch this."* That is audit F §2's signature catch shape, produced
verbatim, by the long prompt, twice, and by neither short prompt in 26 attempts.

## 5. My read

Three claims, in descending confidence.

1. **The vendor's "over-verification" claim is still unsettled, and this run does not
   settle it.** Anyone quoting a null here to justify cutting `/scrutinize` down to 200
   words would be quoting an instrument that also found no difference between a skeptic and
   a rubber stamp.

2. **The hunt list is very probably not a *detection* aid, and the corpus finally shows why
   that keeps being the finding.** My 5 positives exercise roughly **one** of A's six hunt
   items (missing error paths / logic). The other five — stub bodies, tests that mock the
   unit, acceptance criteria without evidence, unreproducible runtime claims, composition
   gaps — **cannot be exercised by a single file with no tests, no handoff report, no
   acceptance criteria, and nothing runnable.** `bugfix-harvest` is a *code-reading* corpus.
   Four prior runs plus this one have now measured the hunt list on the one axis it barely
   addresses. That is not a null about the hunt list; it is a null about a subset.

3. **The behavioral deltas in §4 are where its value would live if it has any**, and they
   are on the *epistemic* axis, not the detection axis: what the reviewer refuses to certify
   without proof, and whether it audits the test as well as the code. Audit F's strongest
   recorded catches are exactly that shape — the Bolt handler behind 232/232 green (all 14
   tests call the handler directly), the tautological `hrefs.length < 15`, `explore-p5uf`'s
   *executed* sandbox escape. **None of those is findable by reading one file.**

## 6. Threats to validity

- **Gate 1 failed; everything downstream is conditional.** Stated up front, in advance.
- **No tools.** The file was inlined, so no arm could run a test, grep a repo, or execute
  the artifact. This caps A's upside specifically, because three of its six hunt items
  require exactly that. It is the largest single threat and it is structural, not incidental.
- **Z is a *simulated* author.** It has no real authorship stake — no context full of its own
  work, no sunk cost. Its failure to rubber-stamp may say more about that gap than about
  Opus 5's imperviousness to framing. It does mean this rig cannot simulate the
  conflicted-judge problem, which is the mechanism audit F credits.
- **I selected the corpus and graded it.** Grading was blind (variant-stripped, content-
  hashed filenames, unblinded only after `grades.json` was written) and keyed to the bug
  beads' own prose, but it is a single ungraded judge.
- **P2's label is mechanically loose.** The bead says "pointer-receiver-only"; the actual fix
  boxed the secret behind a `*string`, addressing `fmt`'s `badVerb` path. Both formulations
  were accepted as hits under the pre-registered key. One arm (Z, r2) *correctly* argued the
  pointer-receiver framing is wrong — and was scored a miss for clearing the defect. Noted
  in `grades.json`.
- **n = 5 positives × 2 reps.** One case is 10 points. Language skew: 3 bash / 2 go.
- **Deviation from prereg:** rep 2 was run on all three arms, not just A and B, to keep the
  positive control at the same n. Declared here; nothing else changed.

## 7. What would settle it

A corpus of **whole impl waves**, not single files, with tools enabled:

1. the changed files **plus their test suite**, so "the suite structurally cannot see this"
   is checkable — with at least 3 cases where the defect is invisible to a green suite
   (the Bolt shape) and 2 tautological-test cases (the `hrefs.length < 15` shape);
2. a **handoff report with ticked acceptance criteria**, at least one of which is unproven,
   so "find the proof" can score;
3. a **runnable artifact** (a page, a CLI, an endpoint) with one composition gap that only
   execution reveals — `skills-library-8l6` is the canonical instance and A's own prompt
   cites it;
4. tools ON, with a scored gate on whether the reviewer *ran* anything.

Gates: keep the Z rubber-stamp control (it is the right control and it is now calibrated —
if Z ever drops below A on that corpus, the rig is live), and add a proof-of-verification
metric alongside catch-rate. Budget ~60 rollouts. Until then, `/scrutinize`'s **existence**
is measured (audit F, 56/132) and its **length** is not — and no measurement to date has
even pointed at the five hunt items that make up most of its words.
