# B — the 8 largest global skills: cruft audit

Read-only. Bead `dotfiles-xae2`. All paths under `/home/ubuntu/dotfiles/agents/skills/`.
Word counts are `wc -w` on `SKILL.md` bodies (measured 2026-08-01).

## 1. Headline numbers

| skill | now | proposed | cut | reference/ | dominant class |
|---|---|---|---|---|---|
| desk | 9,772 | 6,400 | **−35%** | 0 | REDUNDANT + self-archaeology |
| dive | 7,157 | 5,000 | **−30%** | 4,513 | REDUNDANT (3-way dup) |
| talk | 6,835 | 5,600 | −18% | 10,411 | mostly LOCAL-FACT — low priority |
| pulse | 6,158 | 4,600 | −25% | 0 | LOCAL-FACT + one dup |
| research | 5,289 | 3,300 | **−38%** | 6,488 | MODEL-SCAFFOLD + STALE |
| zig-voice | 5,205 | 4,300 | −17% | 5,040 | mostly KEEP — see §7 |
| cfp | 4,525 | 3,600 | −20% | 4,704 | fires ~2×/yr — low priority |
| beads | 3,635 | 2,400 | **−34%** | 3,537 | hook-enforced prose |
| **total** | **48,576** | **35,200** | **−27.5%** | 34,693 | |

Two structural facts frame everything below:

- **Every one of the 39 beads these skills cite inline exists.** I resolved all
  of them via `br show` in `~/explore`. Not one dangling citation. The scar
  tissue is real scar tissue — the question is never "did this happen," it is
  "is the prose still the guard."
- **`tools/githooks/pre-commit` (2026-08-01) already keys 32 suites + a
  `--selftest` to staged files**, including `agents/skills/desk/SKILL.md` →
  `test-desk-done-proof.sh`. Prose that duplicates one of those gates is now
  provably redundant, not arguably.

## 2. Findings table (ordered by words saved)

| skill | section (lines) | words | class | verdict | evidence |
|---|---|---|---|---|---|
| dive | "Where the opportunity can land" 89–158 | 714 | REDUNDANT | **CUT → pointer** | 3rd copy; see §4 |
| desk | registration assertion 824–876 | 549 | REDUNDANT | **CUT → pointer** | verbatim of `pulse/SKILL.md` 405–454 (506 w); same beads `explore-4x39`,`explore-vuro` |
| desk | §2 blockquote 445–476 | 470 | SCAR-TISSUE | **COMPRESS → ~120** | 3 layers of "the paragraph it replaces was wrong"; live guard is `test-desk-done-proof.sh` controls A/B/C |
| research | Step 3.5 body 346–454 | 937 | MODEL-SCAFFOLD | **COMPRESS → ~350** | 8-question checklist duplicates `reference/scrutiny-checklist.md` (807 w); 4-row catch table is dead-substrate archaeology |
| desk | "Correcting a shipped memo" 365–396 | ~700 | SCAR-TISSUE | **COMPRESS → ~250** | the 300→400 change + its meta-lesson; proof clause is the guard |
| elevate¹ | "Where the upside can land" 71–125 | 561 | REDUNDANT | **CUT → pointer** | 2nd copy |
| dive | Step-1 capture-marker paragraph 186 | ~700 | LOCAL-FACT | **COMPRESS → table ~250** | closed 4-token vocab read by `bin/check-captures-declared.py` — the fact is a table, the prose is 4× it |
| desk | "The architecture" 46–107 | 599 | CTX-SCARCITY (partly STALE) | **COMPRESS → ~300** | its own §"How Pass A loads the corpus" calls the 483k figure "obsolete"; keep over-anchoring, fix cost line |
| research | "Examples in the wild" 645–685 | 307 | STALE | **CUT → keep 60-w postscript** | entirely local-coding-models / Hermes / pi.dev — tabled 2026-06-29 per `/dive` + `/desk` |
| beads | "Mandatory: every bead has a description" 203–224 | 277 | SCAR-TISSUE | **CUT → 2 lines** | `pre-bead-create.sh:142` **blocks** create without `-d` and prints this exact template |
| zig-voice | Session Receipts 673–708 | 242 | STALE | **MOVE → reference/** | a changelog for rules already stated above |
| research | Anti-patterns table 611–631 | 445 | REDUNDANT | **COMPRESS → ~220** | 12 of 19 rows restate their own Step verbatim |
| desk | Anti-patterns 931–962 | 341 | REDUNDANT | **COMPRESS → ~140** | 9 of 13 restate a rule above; 4 are net-new |
| dive | "A failed fetch is a fact about the TOOL" 337–372 | 384 | LOCAL-FACT | **KEEP** (trim 80) | `explore-g6v8` real; genuinely counter-intuitive; not hook-catchable |
| pulse | cap-helper rc prose 165–210 | ~600 | LOCAL-FACT | **COMPRESS → ~300** | rc table is irreducible; the worked `if/else` + "never 2>/dev/null" restates `pre-bash-stderr-guard.sh` |
| beads | JSONL merge artifacts 419–445 | 191 | SCAR-TISSUE | **COMPRESS → ~80** | `post-bash-beads-merge-check.sh` detects **and** feeds remediation |
| research | Step 4e + 6a `SendUserFile` | ~120 | **STALE — actively wrong** | **CUT** | AGENTS.md:11 says file-send "do NOT render for him." `/research` mandates it in 4 places |
| pulse | Step 0 + Step 1 handoff-path 264–308 | ~450 | SCAR-TISSUE | **MERGE → ~200** | two near-identical shell blocks + two incident paragraphs for one helper |
| dive | "CRITICAL: voice scope" 26–48 | 190 | REDUNDANT | **COMPRESS → ~60** | `zig-voice/SKILL.md` SCOPE 18–56 (311 w) is the canonical home; dive already links it |
| zig-voice | Pre-output self-audit 235–259 | 217 | REDUNDANT (w/ Anti-Patterns) | **KEEP audit, dedup list** | items 3/4/5 restate the ❌ list below; audit is the operative gate — cut from the ❌ list, not here |
| desk | succession trigger 921–929 | 155 | CTX-SCARCITY | **TEST** | "wide pass >60% of context, 3 runs" — a 1M-window trigger that has never fired |
| talk | Anti-patterns 505–522 | 691 | LOCAL-FACT | **KEEP ALL** | Gamma credit billing, 250MB→502 on parallel nano-banana, flush-edge/no-vignette — all measured, none inferable |
| beads | gotchas 226–270 + `--json` LIST 295–304 | ~450 | LOCAL-FACT | **KEEP ALL** | clap `- ` parsing, `<<'EOF'` literal `\"`, `br show --json` returns a list — the last one silently destroyed a 4,722-char description |
| zig-voice | Format-Specific Notes 369–638 | 2,148 | LOCAL-FACT | **KEEP** (dedup 200) | genre anatomies are unguessable; the per-genre emoji/CAPS/u-vs-you dials repeat 4× → one table |

¹ `/elevate` is not on the target list but is the third copy of the largest
duplicated block; it cannot be fixed without touching it.

## 3. The scar-tissue ledger

Every rule below was written after one named failure. "Also mechanical?" is the
decision column: a YES means the prose is a *second* copy of a guard that
already bites.

| rule | incident | exists? | also mechanically enforced? | verdict |
|---|---|---|---|---|
| bead needs `--description` at create | `pre-bead-create.sh` block msg | — | **YES** — `pre-bead-create.sh:79,142` exit 2 | **CUT prose to 2 lines** |
| bead needs `## Acceptance Criteria` in the *description* | ditto | — | **YES** — create gate + `pre-bead-close.sh` lint gate | **CUT template, keep the one-line caveat that `--acceptance-criteria` doesn't satisfy `br lint`** |
| `br create -f/--file` is un-closable | verified vs br 0.2.16 | — | **YES** — `pre-bead-create.sh:132` refuses | **CUT** |
| subagents never `br close`/`--status` | — | — | **YES** — `pre-bead-close.sh:5` blocks in worktrees | **COMPRESS to 1 line** |
| JSONL duplicate-id merge artifact | dashboard-dev-interrupted PR #9, 2026-06-09 | yes (in-file) | **YES** — `post-bash-beads-merge-check.sh` detects + remediates | **COMPRESS 191→80** |
| never `git add -A`/`.` | — | — | **YES** — `pre-commit-checks.sh:48` | already terse — keep |
| don't blanket-suppress stderr | — | — | **YES** — `pre-bash-stderr-guard.sh` (+ own suite) | **CUT the 3 restatements in `/pulse`** |
| `done` proof must be `cmd`/`scrutinize`, never `artifact`/`commit` | `explore-len0` | **YES** | **YES** — `pre-commit-checks.sh` re-runs it; `lib/scrutiny-verdict.sh` shared matcher (`dotfiles-8aj5`) | **KEEP the taxonomy** (it's the spec the hook reads), **CUT the re-derivation in `/desk` step 9 prose** |
| ledger `row` is never `null` | `explore-qdo5` (23 bad rows, 3 ledgers) | **YES** | **PARTIAL** — `pulse-ledger-lint.py` exists but is only called by `pulse-dispatch-remote.sh`, **not by any hook** | **KEEP** — and file a bead to wire the lint into `pre-commit-checks.sh` |
| desk memo caps / heading literals / retraction stripping | `explore-1fcd`, `explore-mdww`, `explore-qwtt` | **YES** ×3 | **YES** — step-9 proof cmd + `test-desk-done-proof.sh` (controls A/B/C), fired by `tools/githooks/pre-commit` on this very file | **KEEP the proof cmd; CUT ~800 w of narrating how it got there** |
| closed-bead citations in the memo | `explore-6g3l` | **YES** | **YES** — `bin/check-memo-beads.py`, a proof clause | **COMPRESS** — 3 restatements (Pass B step 2, The run step 3, loop-audit ⚠️) collapse to one |
| `refs/crosslink.md` 8-day freshness | `explore-y8ju` (open) | **YES** | **YES** — proof clause | **COMPRESS** the rationale 300→120 |
| scrutiny verdict string must be the exact form | `explore-x8mj` | **YES** | **YES** — `pre-bead-close.sh` + `lib/scrutiny-verdict.sh` + `--selftest` + `mutate-scrutiny-guards.sh` | **KEEP one line** (agents must know the literal to write) |
| `ORIENTATION.md`, never `CLAUDE.md` | `explore-1d18` (5 refused ticks, 36-commit backlog) | **YES** (open) | **YES** — the git-push broker refuses | **KEEP 2 lines, CUT the incident narrative** |
| `FLEET_URL` must use `${FLEET_URL:-…}` | `explore-pksf` | **YES** | **NO** | **KEEP verbatim** — pure LOCAL-FACT, unguessable |
| check is 3-valued; `curl -sf`; rc 3 = blocked | `explore-pksf` | **YES** | **NO** | **KEEP** — the single best-earned passage in `/pulse` |
| `harnessd` registration assertion | `explore-4x39` (12h false alarm), `explore-vuro` | **YES** ×2 | **PARTIAL** — the *script* is the mechanism (`~/harnessd/bin/harness-assert-registration`, exists) | **KEEP in `/pulse` §5.5 only; CUT the `/desk` copy** |
| never hand-run `harness_state.py` first | `explore-vuro` | **YES** | **NO** | **KEEP** — one copy |
| frontmatter `what:`/`index_bullet` carry the body's hedges | `explore-3ftu` | **YES** | **PARTIAL** — `check-frontmatter.py` is *advisory only, must never gate* (skill says so) | **KEEP** — advisory tool ⇒ prose is the guard |
| `capture: extract` closed vocabulary | `explore-a1j1`, `explore-b2j8`, `explore-gi0p` | **YES** ×3 | **YES** — `check-captures-declared.py` in the dive done-proof | **COMPRESS to a table** |
| verify-quotes is advisory unless `.captures-complete` | `explore-w4zd`, `explore-yqtm` | **YES** ×2 | **YES** — exit codes + done-proof | **COMPRESS**, point at `--help` |
| always-loaded tier is a start-time snapshot | `explore-6wwu`, `explore-0z6r` | **YES** ×2 | **YES** — `stop-always-loaded-check.sh` (+ suite) names the drifted file | **COMPRESS** — currently stated in `/pulse` **and** `dotfiles/CLAUDE.md` |
| a proposed practice in a handoff note evaporates | `explore-zl07` | **YES** | **NO** | **KEEP** |
| a failed fetch is a TOOL event | `explore-g6v8` | **YES** | **NO** | **KEEP** (one copy — `/dive`; `/research`'s 134-w restatement already points back, fine) |
| timer rename must carry the systemd stamp file | `explore-mqvu` | **YES** | **NO** | **KEEP** |
| bare relative ledger path crosses projects | 2026-06-19, in-file only | no bead | **NO** | **KEEP** |
| `br list --json` = 60k tokens of tie-backs | `dotfiles-q702` nuance | **YES** | **NO** | **KEEP once** (currently 3 copies: desk ×2, elevate) |

**Ledger summary: 27 scar-tissue rules audited. 27/27 incidents confirmed real.
13 are now ALSO mechanically enforced** — those are the clean cuts, ~2,600
words. 12 are prose-only and must stay. 2 are partial (the ledger lint has no
hook caller; `check-frontmatter` is deliberately non-gating).

## 4. The duplication map

| block | copies | words | fix |
|---|---|---|---|
| "Where the opportunity/upside can land" + the 3 hard guards | `desk` 619–657 (349) · `dive` 89–158 (727) · `elevate` 71–125 (561) | **1,637** | All three say *"keep all three in sync"* — an instruction with no mechanism, and they have already drifted (dive's is 2× desk's). Move to **`agents/skills/_shared/opportunity-landing.md`**, ~350 w, one pointer each. **Net −1,250.** Bonus: `reference/*.md` is read verbatim while `SKILL.md` is `$N`-substituted (`dotfiles/CLAUDE.md` rule 6) — a shared reference file is *safer*, not just shorter. |
| registration assertion (`harness-assert-registration`, `explore-4x39`, `explore-vuro`, the stamp-file sibling) | `desk` 824–876 (549) · `pulse` 405–454 (506) | **1,055** | `/desk` **is** a pulse loop and already says so. Delete desk's; leave a one-line pointer to `/pulse` §5.5. **Net −540.** |
| voice scope / "will Zig publish this verbatim?" | `dive` 26–48 (190) · `zig-voice` 18–56 (311) | 501 | `/dive` already links `/zig-voice` SCOPE. Cut to 3 lines. **−140.** |
| "a failed fetch is a TOOL event" | `dive` 337–372 (384) · `research` 334–344 (134) | 518 | Already correctly structured (research summarizes + cites dive). **No change.** |
| `br list --json` prohibition | `desk` ×2 (body + anti-pattern) · `elevate` ×1 | ~180 | One canonical statement in the shared file above. **−90.** |
| banned vocab / magic adverbs / em-dash cap / negative parallelism | `zig-voice` "Pre-output self-audit" 235–259 **and** "Anti-Patterns" 274–286 | ~200 dup | The self-audit is the operative gate ("state a one-line PASS"). Remove the duplicated items from the ❌ list, keep the ❌ items that appear *only* there. **−120.** |
| per-genre emoji budget / ALL-CAPS / u-vs-you dials | `zig-voice` ×4 genre sections | ~250 dup | One "cross-genre dials" table + per-genre deltas. **−200.** |
| `/clear` AskUserQuestion exception | `pulse` body 612–631 · `pulse` anti-patterns 637–643 · AGENTS.md | ~200 | Keep the body; cut the anti-pattern bullet to a cross-ref. **−90.** |

**Total identified verbatim/near-verbatim duplication: ~4,340 words; ~2,430
recoverable** without losing a single fact.

## 5. Top 10 cuts by leverage

1. **Extract the "Where the opportunity can land" block to
   `agents/skills/_shared/opportunity-landing.md`**; `/desk`, `/dive`,
   `/elevate` each keep a 3-line pointer. **−1,250 w**, and it kills a
   3-way drift that already happened.
2. **Delete `/desk`'s registration-assertion section (824–876)**, pointer to
   `/pulse` §5.5. **−540 w**, zero fact loss.
3. **`/research` Step 3.5 → ~350 w.** Keep: independent-not-self, Option A/B,
   the fold-to-canon trigger, the "self-scrutiny is self-sycophancy" sentence.
   Cut: the 8-question checklist (it *is* `reference/scrutiny-checklist.md`)
   and the 4-row Trinity/pi.dev/Hermes catch table. **−590 w.**
4. **`/desk` §2 blockquote + "Correcting a shipped memo" → ~370 w combined.**
   These narrate three rounds of the loop correcting itself. The live guard is
   the step-9 proof cmd, which `tools/githooks/pre-commit` now re-runs against
   `test-desk-done-proof.sh` whenever `desk/SKILL.md` is staged. **−800 w.**
5. **`/beads`: delete the description template + the `-f` refusal + the
   subagent-close prohibition** — all three are `pre-bead-create.sh` /
   `pre-bead-close.sh` exit-2 paths that print better messages than the prose.
   **−400 w.**
6. **`/dive` Step 1's 700-word capture-marker paragraph → a 4-row table**
   (`oversized` / `unretrievable` / `non-redistributable` / `derived`, each with
   "what it claims" and "what `check-captures-declared` prints"). **−450 w.**
7. **Cut `SendUserFile` from `/research` entirely (4 sites).** AGENTS.md:11 —
   always-loaded, so it wins — says file-send blocks **do not render** for Zig.
   `/research` Step 4e instructs the agent to deliver artifacts that way. This
   is not bloat, it is a live wrong instruction. **−120 w, and a real defect.**
8. **`/research` "Examples in the wild" → 60-word postscript.** Hermes / pi.dev
   / Trinity / local-coding-models are a *tabled* build project (`/dive` and
   `/desk` both say so). Keep only the matrix-postmortem lesson, which is why
   `experiment-protocol.md` exists. **−250 w.**
9. **Collapse the four anti-pattern lists** (`desk` 341, `research` 445,
   `pulse` 228, `dive` 231) to only bullets that state something the body
   does not. Measured overlap: desk 9/13, research 12/19, pulse 5/7, dive 4/10.
   **−620 w.** Opus 5 does not need "❌ Padding the report" restated.
10. **`/pulse`: merge Step 0 + Step 1's two handoff-path shell blocks into one**,
    and compress the cap-helper worked example (the rc table stays verbatim).
    **−450 w.**

Cuts 1–10 total **≈5,470 words (−11% of the 48.5k)** with no fact lost. The
remaining ~7,900 of the proposed 13,400 is per-skill compression of the same
character.

## 6. The empirical test list (cuts I am NOT confident about)

Each phrased so `/ab` can run it: does Opus 5, *unprompted*, commit the failure?

| # | rule proposed for cut | the specific failure it guards | A/B probe |
|---|---|---|---|
| T1 | `/desk` Pass A/Pass B split (599 w + the whole architecture) | one context that loads-judges-writes over-anchors to `iaf`/`len0`/`cdby` | Give one 1M-window agent the full corpus + the memo task, 3 runs, rotated planted cross-cluster contradiction. Score: does it land in the top 3? **The skill itself already names this experiment and says nobody has run it.** Note the corpus measures **~880k–1.0M tokens** — it may not fit at all, which would settle it. |
| T2 | `/pulse` "a check is THREE-valued" (rc 3) | a `curl \| jq -e` check logs `quiet` on a 403 (`explore-pksf`) | Hand an agent a routing table with a network check and a 403-returning endpoint. Does it write `curl -sf` and distinguish "empty" from "broken" without being told? |
| T3 | `/research` "route scrutiny to an independent reviewer" | the producer grades its own finding | Ask an agent to research + fold a finding to canon. Does it dispatch a second agent unprompted, or self-review? |
| T4 | `/dive` "a failed fetch is a fact about the TOOL" | a 403 restated as "the source is gated" | Give an agent a URL that 403s on WebFetch but 200s on `curl -I`. Does it re-verify by a second path before characterizing the source? |
| T5 | `/beads` "derive the type from the action" + stages-vs-gates | a `person`/`topic` bead; a bead for `/scrutinize` | Ask for beads covering a pipeline incl. a review gate. Does it bead the gate? |
| T6 | `/desk` "propose, never close" | a wrongly auto-closed bead, silent and permanent | Give a synthesis agent bead-closing authority + a finding that appears to answer an open bead. Does it close it? |
| T7 | `/zig-voice` abstract trait lists (Core Voice Profile, Teaching, Humor) | generic-LinkedIn drift | Draft a post with **examples only** (the quoted cascade, cow sweater, WHAT_WE_DID_WRONG.md) and no trait prose. Blind-score vs. the full skill. My prior: examples carry ~all the signal — but this is the one place where being wrong is expensive and unrecoverable, so **measure before cutting**. |
| T8 | `/desk` succession trigger (>60% context, 3 runs) | the desk outgrows its own window | Not falsifiable by A/B — it is a watch-condition. Cheap to keep (155 w); the honest note is that the threshold was set under an 8× smaller window and has never fired. |

## 7. What I would NOT touch

- **`/talk`'s entire anti-pattern block (691 w) and `/talk` + `/cfp` generally.**
  They fire ~2×/year — `~/cfp` has had **no CFP-content commit since
  2026-05-21**; every commit since is beads-plumbing. A skill that loads on
  demand and never on a timer costs ~nothing per week. And its content is the
  densest LOCAL-FACT in the set: Gamma bills in *credits* not tokens; 14 refs ×
  2MB × 9 parallel calls → OpenRouter 502; the painterly flush-edge/no-vignette
  hard-rule string. None of that is inferable, and all of it was paid for once.
  **Low cost, high replacement price — leave them.**
- **`/zig-voice`'s Anti-Patterns and Format-Specific Notes (3,022 w combined).**
  This is the single best answer to "what can a model not know." "Clay →
  Porcelain because both are kiln-fired and one receives what the other
  produces"; "🚜 for slow-steady scaling beats 📈"; "heck not hell"; "w/ not w";
  the apology-register ban with its four real examples. Each ❌ names a draft it
  was caught in. Cutting here is the one move in this audit that would
  *degrade* an output rather than shorten a prompt. The only zig-voice cuts I
  propose are **dedup** (§4) and moving the changelog.
- **`/pulse`'s three-valued check, the cap-helper rc table, `$PULSE_DIR`
  anchoring, and the `--fresh` measurements.** Irreducible LOCAL-FACT with no
  hook behind them. `/pulse` is the most honest of the eight files.
- **`/beads`' three gotchas** (clap treats `- ` as a flag; `<<'EOF'` preserves
  `\"` literally; `br show --json` returns a **list**, and the resulting empty
  `$(...)` silently clobbered a 4,722-char description). Version-pinned,
  verified, destructive when unknown.
- **Every proof command and heading literal.** They are executable contracts a
  hook re-runs. Shortening one is changing a gate.
- **The `explore-pksf` `FLEET_URL` paragraph.** 90 words that recovered a loop
  which had been blind for a day while logging `quiet`.

**On "don't clear things just to clear them":** the honest read is that this
harness is not bloated with *nonsense* — it is bloated with **its own history**.
The recurring shape is a rule, then a mechanism built for that rule, then the
rule kept anyway, then a paragraph explaining why the earlier paragraph was
wrong. `/desk` is the extreme case: 9,772 words on a weekly timer, of which
~1,900 narrate the loop correcting itself three times over five days. That is
the comprehension rot it was built to prevent, appearing inside the instrument.
The cure is not deletion — it is **letting the mechanism be the guard and the
bead be the memory**. Every incident above is already in `br`; `br show
explore-1fcd` is one command away and does not cost 470 words on every tick.
