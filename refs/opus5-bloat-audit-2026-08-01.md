# The Opus-5 bloat audit — findings and a decision menu

Bead `dotfiles-w8xw` (epic), under `dotfiles-b9ii`. 2026-08-01.
Six parallel read-only auditors + an orchestrator-built hook map + a live ablation.
Full working files: `/tmp/claude-1000/-home-ubuntu-dotfiles/64bce900-f1f7-47da-917c-c1f1e6326e43/scratchpad/audit/`

---

## 0. The bottom line

**The premise is half right, and the half that's wrong matters.**

You asked me to audit on the theory that Anthropic stripped ~80% of Opus 5's harness
instructions because it doesn't need them, and that our corpus is similarly bloated.
I fetched the live vendor guide and measured the whole corpus. The result:

- **Anthropic's actual remove-list is narrow and specific**, not 80%. Six named
  classes. Their guide opens by saying Opus 5 "performs well out of the box on
  existing Claude Opus 4.8 prompts." What they removed was *scaffolding about how to
  think*.
- **This corpus is not mostly that.** Across four independent audits the defensible
  cut lands at **14–27% per corpus, not 80%.** The reason is consistent and was
  reached independently by every auditor: this harness is overwhelmingly **facts about
  this machine and incidents that happened on it**. Opus 5 being smarter does not tell
  it that `marketing-vps` re-detaches HEAD, that `merge=union` resurrects closed beads,
  or that a 403 through WebFetch is a fact about the tool.
- **The scar tissue is honest.** Audit B resolved all 39 bead ids cited inline across
  the eight largest skills. **27 of 27 scar-tissue rules trace to a real, confirmed
  incident. Not one dangling citation.** I went in expecting invented ceremony and did
  not find it.

**So the win is not "delete 80%." The win is three different things**, and they're
worth more than the token savings:

1. **Four live defects** where the harness currently instructs agents wrongly — two of
   them steering toward destructive or invisible outcomes. These are worth fixing
   regardless of any bloat decision.
2. **Duplication, not invention.** The same real incident written into 3–4 files, then
   drifting apart. ~11,000 words of recoverable duplication fleet-wide.
3. **A structural gap: the corpus has an accrual mechanism and no drain.** AGENTS.md
   went 1,194 → 5,525 words in 72 days, monotonically — **no commit in its history
   ever made it smaller.** Without a rule change, anything cut today regrows.

---

## 1. What the vendor guide actually says

Fetched live 2026-08-01 from the Opus 5 prompting guide. Recorded as bead `dotfiles-ec32`.

**Remove (their list, verbatim in substance):** explicit verification instructions;
self-correction / re-check instructions; **"use a subagent to verify"**; prompt-side
vision workarounds; any rule telling the model not to think; carried-over effort
defaults. **Add:** conciseness, written-deliverable length calibration, scope
constraint, delegation caps.

Three sentences land directly on us:

**(a) The verification sentence is stronger than AGENTS.md records.** Verbatim:

> "If your prompt contains explicit verification instructions ('include a final
> verification step for any non-trivial task,' **'use a subagent to verify'**), remove
> them... **The same applies to legacy harness scaffolding that adds separate
> verification steps.**"

AGENTS.md's 2026-07-27 entry keeps `/scrutinize` on the reading that the guide "never
measures" separate fresh-context adversarial review. That claim is **not supportable as
written** — "use a subagent to verify" and "legacy harness scaffolding that adds
separate verification steps" are both named. The conflicted-judge counter-argument in
AGENTS.md is an *incentive* argument the vendor never addresses, and it may well be
right. But it should be settled by evidence, not by re-reading the guide. See §5.

**(b) Opus 5 is itself a cause of the bloat.** "Files that Claude Opus 5 writes to disk
are often longer than on prior models." `/desk` at 9,772 words and the noted
1,460→2,190-word memo growth are that behavior. A one-line length-calibration
instruction in the always-loaded tier is the cheap structural fix.

**(c) Our dominant instructional idiom may be the weaker one.** "Positive examples of
the communication style you want tend to be more effective than instructions about what
not to do." This harness is overwhelmingly anti-pattern-driven — every SKILL.md carries
a large ❌ block, and TOOLKIT.md is *keyed* on anti-patterns. Flagged as a hypothesis
worth testing, not a conclusion; the guide states it in a narrower context.

---

## 2. The corpus, measured

The important correction first: **most of the corpus is not always-loaded**, and one
headline number was an artifact.

| Tier | Words | When it costs you |
|---|---:|---|
| **ALWAYS-LOADED** | | |
| `agents/AGENTS.md` (global) | 5,525 | every session, every project, forever |
| 37 skill frontmatter blocks | ~3,558 | auto-injected into every system prompt |
| project `CLAUDE.md` (this repo) | 782 | every dotfiles session |
| `MEMORY.md` index | 504 | every session (bodies are **not** loaded) |
| **always-loaded subtotal** | **~10,400** | **≈14k tokens per session** |
| **ON DEMAND (progressive disclosure)** | | |
| 37 `SKILL.md` bodies | 100,217 | only when invoked |
| legitimate `reference/*.md` | 63,895 | only when read |
| `TOOLKIT.md` | 4,748 | every `/onboard` |
| 43 project `CLAUDE.md` fleet-wide | 79,620 | only in that project |
| **ARTIFACT — not harness content** | | |
| `gdoc/node_modules/*.md` | 101,781 | **never** — see below |

**The 165,662-word "reference bloat" figure was 61% an artifact.** `gdoc/node_modules`
is 226 MB of third-party READMEs. It is **gitignored on purpose with an explanatory
comment, has never been in git history (0 bytes), and is invisible to the Grep tool**
(ripgrep honors gitignore: 11 files visible vs 3,405 with `--no-ignore`). It is also a
load-bearing self-contained dependency install, documented after a prior incident.
**Verdict: nothing to fix. Do not delete.** The only real cost is that it distorts any
`find`-based measurement of the skill tree — which is exactly how the inflated number
was produced in the first place, including in my own opening measurement.

---

## 3. Four live defects — worth fixing regardless of the bloat decision

Each independently verified by me before filing.

**① `/commit` says rebase; AGENTS.md says never rebase.** `dotfiles-mjln`, P1.
`commit/SKILL.md:15` — "**Always pull --rebase, THEN push**". `AGENTS.md:226,248` —
"merge, never rebase, NEVER stash… **NOT** `git pull --rebase`." Both are in the loaded
tier, and TOOLKIT.md propagates the rebase version into every `/onboard`. This is not
merely inconsistent: AGENTS.md's own measured table says `--rebase` fails
*obstructively* on any dirty file, and names the trap — "rebase's refusal is exactly
what tempts you toward [stash]", the one verb that succeeds destructively. **The two
rules were written for different situations** (multi-machine push races vs a second
writer in one tree), so the fix is probably to scope each, not delete one. Your call.

**② AGENTS.md points at a skill directory that doesn't exist.** `dotfiles-sj8l`, P2.
`AGENTS.md:279` → `~/explore/.claude/skills/scrub-secrets/`. It graduated to
`~/.claude/skills/` on 2026-07-08 (commit `5b7d8cf`) and the pointer was never updated.
A live instance of this repo's own rule 2 — a documented example that is executable and
wrong. An agent following it finds nothing and may conclude the guard doesn't exist.

**③ `/research` mandates a delivery channel you cannot see.** `dotfiles-8k3o`, P2.
Five `SendUserFile` mandates; `AGENTS.md:11` says file-send blocks "do NOT render for
him." The skill's "push material results to the user" step silently delivers nothing.

**④ The `row:null` ledger guard is weaker than every skill claims.** `dotfiles-775y`, P2.
`pulse-ledger-lint.py` has **no hook caller** — only `pulse-dispatch-remote.sh` runs it.
Any ledger row appended by another path is unlinted. This one matters for *this* audit:
audit B classified 13 of 27 scar-tissue rules "also hook-enforced, so the prose is
trimmable." This rule is classified PARTIAL, and **the prose is currently the only live
guard.** Trimming it first would remove the actual check.

**Plus one class-wide issue, and I'd correct the auditor's reading of it.** Four skills
still carry `## Self-review (5 items)` blocks (`spec:195`, `check:220`, `test:191`,
`impl:289`) — the 2026-07-27 sweep grepped for phrases like "double-check" and missed
the heading. My auditor called these a clean vendor-backed CUT. **I don't fully agree.**
Their *content* is mostly acceptance criteria ("≥5 edge tests", "at least 10 test
cases") — that's the definition of done, which the vendor guide does not target. Two
items are genuine empirical evidence (`git diff --name-only`). The honest fix is
**rename and reframe as "Definition of done", migrate the two evidence items to
`/handoff`, delete the handful that are true re-read instructions** — not delete all
twenty.

---

## 4. The empirical test — stripped skills, measured

You asked me to run tests with stripped-down skills. I built a real ablation rig and ran
it. **The most important thing I have to report is that the result does not say what it
looks like it says.**

**The rig.** Three isolated `HOME`s, each with a different global `CLAUDE.md` and **no
hooks** (so it measures what the *prose* does, independent of mechanical enforcement).
Credentials symlinked, never copied. Fresh context per run via `claude -p`.

| variant | global CLAUDE.md | words |
|---|---|---:|
| **A** | the real `agents/AGENTS.md` | 5,525 |
| **B** | audit A's proposed strip | 966 |
| **C** | positive control — gutted to two sentences | 14 |

Four cases, each text-checkable: **C1** URL rendering (a KEEP-set local fact), **C2** the
contested 348-word two-writers block (push rejected + a file another process is writing),
**C3** the KEEP-set secrets rule, **C4** a false-positive canary (fix a one-word typo —
ceremony would be the failure).

**Result: 12/12 pass. Zero detectable difference across a 393× ablation.**

| case | A (5,525w) | B (966w) | C (14w) |
|---|---|---|---|
| C1 plain URL, no markdown link | PASS | PASS | PASS |
| C2 never `stash`; use fetch+merge | PASS | PASS | PASS |
| C3 secret to `~/.secrets`/`.env`, never a doc | PASS | PASS | PASS |
| C4 canary — no over-ceremony | PASS | PASS | PASS |

C2 is worth reading in detail. Variant A reproduced the AGENTS.md guard almost exactly —
fetch+merge, rebase warned as obstructive, stash named as "the one that 'works' is the one
that eats their work", plus the scoped `git stash push -- <paths>` escape and a
`rebase.autoStash` config check. Variant B matched it and **added** a pre-check for whether
the incoming merge touches the contended file, and a post-push verification step. The
**14-word control** independently derived the same hazard and went further — a throwaway
worktree, `git reset --keep` over `--hard`, and its own "Do not run these" section covering
stash, reset, and force.

**Why this is not "you can cut 82% of AGENTS.md."** The harness's own `/ab` discipline says
it plainly: *"Positive control first — before you trust any NULL. If the rig can't separate
a known-large gap, a null is meaningless (the rig is ceilinged / blind)."* My variant C
**was** the known-large gap, and it did not split. **So the rig is unvalidated and these
nulls are uninterpretable as evidence that the text is worthless.** n=1 per cell; `/ab`
specifies n≥8.

### 4a. The second run — a validated rig, and the answer

Zig authorized track 7, so I rebuilt the corpus around the thing the pilot got wrong:
**cases that require unguessable local facts**, each targeting a block track 3 proposes
cutting. 4 cases × 3 variants × 3 reps = **36 runs**.

| case | what it tests (block, words) | **A** 5,525w | **B** 966w | **C** 14w |
|---|---|:--:|:--:|:--:|
| L1 | Opus-5 400 kills WebSearch (Effort, 847w) | **3/3** | **3/3** | **0/3** |
| L2 | worktree isolation (Delegation, 945w) | 3/3 | 3/3 | 3/3 |
| L3 | record the decision (decide-and-proceed, 269w) | **3/3** | **3/3** | **1/3** |
| L4 | AskUserQuestion not prose (Surfacing, 508w) | **3/3** | **3/3** | **0/3** |
| | **total** | **12/12** | **12/12** | **4/12** |

**The rig is now validated** — the positive control splits hard (12/12 vs 4/12), which is
exactly what the pilot could not produce. So the nulls in this run *are* interpretable.

**The answer to your question: A and B are indistinguishable across 24 runs. The 82% strip
costs nothing measurable.** What the control loses is precisely the unguessable local facts:
asked how to set `max` effort for a research task, C cheerfully explains how — and adds
*"effort governs reasoning depth per turn, not how many web searches I'll run"* — which
would have silently killed WebSearch on the exact task described. B catches it verbatim.

**L2 is a finding in its own right:** even the 14-word control gets worktree isolation
right, because the **Agent tool's own schema documents `isolation`** to every variant. The
945-word Delegation section is restating something the harness already injects — the
single best-evidenced cut in the report.

**Caveat that survives:** this tests four blocks, not the whole file, and it tests
*recall of a stated fact*, not judgment under pressure. It says the strip is safe for
what it keeps. It does not license cutting a fact.

**What the first run legitimately established** — and it aligns with what all six auditors found
independently: I happened to pick four *general-competence* cases, and on those, Opus 5's
defaults already produce the behavior the rules describe. That is precisely the
MODEL-SCAFFOLD class the vendor says to strip, and this is a (weak) fourth line of evidence
for stripping it. The cases that **would** discriminate are the unguessable local facts —
the `FLEET_URL` clobber, the `jsonl-union` driver, the Opus-5 400, a port number. I did not
test those, and they are exactly what every auditor said to keep. `/ab`'s own regime note
predicted this: *"a task the deployment model is already competent at → expect a null."*

One weak positive signal: **variant B was the only run that addressed the user as "Zig."**

The rig is built and reusable at `.../scratchpad/ab/` (`run.sh`, `cases.txt`, three HOMEs)
— pointing it at local-fact cases at n≥8 is the follow-up that would actually settle this.

---

## 4b. The verification layer — settled with data, and it goes against the vendor

This was the sharpest tension in the audit: the vendor guide says remove "legacy harness
scaffolding that adds separate verification steps" and "use a subagent to verify." So I
had it measured across the entire recorded history rather than argued.

**`/scrutinize` is not ceremony. 56 of 132 recorded gates (42%) returned a non-SHIP initial
verdict — 40 of 81 (49%) in the last 30 days.**

The catches include defects a green suite structurally could not see:

- **Two total production outages.** A Bolt handler signature mismatch — "every production
  event silently dropped… **all 14 handler tests call the handler directly so the suite
  structurally cannot catch it**" — found sitting behind a suite the reviewer re-ran at
  232/232 green. And a cron route exporting POST while Vercel invokes GET: "loop dead in
  production."
- **A demonstrated sandbox escape** (`explore-p5uf`) — not argued, *executed*: the reviewer
  rewrote a second repository's branch to a foreign sha.
- **A latent secret-leak path** into permanent private history (`explore-161v`).
- **Two tautological tests** that would have stayed green with the guard deleted.

And the cleanest natural experiment in the whole audit, on the pulse done-proof gate — same
fleet, same authors, same week: **gated ledger 77% carry proof; ungated siblings 3% and 0%.**
The gate is what produces the proof. Prose alone does not.

**So the vendor's rule does not transfer here, and I'd keep the layer.** But three caveats
are real and one of them is the vendor's actual point:

1. **The cost is larger than the harness has ever priced it**: ~147 reviewer subagents in
   30 days ≈ **142M input-token-equivalents**, ~967k per reviewer — ~24× the `/ab` per-rollout
   reference. This is a floor (panel-mode hunters aren't attributable).
2. **OVERRIDE bypasses are rising: 11% all-time → 16% in the last 30 days.** That is cost
   pressure showing up as quiet bypass rather than as a decision. It's the leading indicator
   to watch.
3. **The one thing still unmeasured is exactly the vendor's claim.** Not *whether a separate
   reviewer helps* (measured: it does) but *whether the elaborate hunt-list prompt beats a
   minimal one*. `explore-oqkq` tried and hit a ceiling effect — a gutted `/scrutinize`
   caught all 5 planted defects as well as the full one. **That is where the vendor could
   still be right: about the prompt's size, not the reviewer's existence.**

Two components came back **UNMEASURABLE**, and that is a finding about instrumentation, not
a licence to cut: `/handoff` has **zero skill invocations ever** and its output is
structurally indistinguishable from an agent just filling the bead well; `/fix`'s mandatory
regression guard shows up on only 25% of bug beads with no hook enforcing it. Both could be
made greppable in a quarter for near-zero runtime cost by requiring a one-line `## Handoff —`
/ `## Guard —` block, mirroring `## Scrutiny`.

---

## 5. What the audits recommend, by corpus

| Corpus | Now | Proposed | Cut | The dominant problem |
|---|---:|---:|---:|---|
| Always-loaded tier | 11,559 | 5,649 | **−51%** | relocation, not deletion |
| 8 largest skills | 48,576 | 35,200 | −27% | 3-way duplication + self-archaeology |
| 29 remaining skills | 51,641 | 44,372 | −14% | one incident written into 3–4 files |
| 43 fleet `CLAUDE.md` | 79,620 | 66,000 | −17% | **concentrated in 4 files** |
| Project skills + refs | — | — | ~5,200 w | genuinely small |

### The always-loaded tier is where the leverage is (−51%)

And the cut list is **dominated by relocation, not deletion**. Almost nothing there is
wrong; about half of it already exists somewhere better:

- **The 750-word skill listing** re-lists 31 skills that Claude Code already injects at
  2,793 words of *higher* fidelity. It has drifted both ways — lists `/bd-to-br-migration`
  (doesn't exist), omits 6 live skills including `/pulse`, `/scrutinize`, `/research`.
  Deleting it also *fixes* both defects: no hand-maintained list, nothing to drift.
- **The 945-word Delegation section**, whose bash block is verbatim in
  `orchestrator/SKILL.md:79-93`.
- **717 of the Effort section's 847 words.** Only the Opus-5 400-error fact is
  irreducible — and it stays, because a session above `high` silently loses WebSearch.
- **Three blocks that duplicate a hook that fires at exactly the right moment**:
  Surfacing (508w), Two-writers (348w), stderr (127w).

**The repeatable pattern here — and the single most useful idea in the audit:** move
rationale *out of the always-loaded tier and into the hook's block message*, where it is
delivered exactly when it's needed and costs nothing the rest of the time.
`/dispatch` already demonstrates the target state: "No-nested-agents + path discipline
are structurally enforced (subagent definition + hooks) — prompts carry task-specific
content only."

### The fleet is not bloated — four files are

79,620 words across 43 project files, but **six files hold 39% of it**, and the problems
concentrate further:

- **`linearb/agent-dev-interrupted`** (4,475w, dormant since 2026-06-10) spends **2,529
  words teaching an orchestration model the global tier forbids**: "use tmux for
  subagents, NOT the Task tool", a 250-word **git stash protocol**, built-in agents for
  implementation, and `br new` — which errors. Worst file on the box.
- **`linearb/skills-library`** — 3,279 words of live-voice brief in a repo whose push
  remote is literally `DISABLED://repo-archived-2026-06-09`.
- **`autonoveld`** presents a four-timer pulse table as current; `systemctl` shows **all
  four disabled**. Every landing agent is programmed with a schedule that does not run.
- **`cfp/mise`** is a build plan for a paper submitted, camera-readied and tagged five
  months ago.

Also verified stale: a `linearb` nginx vhost + port that aren't live; a `romd` citation
of an `ss` measurement fixed a week later; `reef` hardcoding `Co-Authored-By: Claude
Opus 4.5`; `weekly-reporting` naming a systemd unit that doesn't exist.

**Two corrections to my own brief, which the auditor caught:** `bd-` is *not* a stale
prefix — it's the live configured prefix in four repos; do not mass-rewrite. And the
`2026-07-28` last-commit cluster across 17 repos is a mechanical beads sweep, not
activity — read those as dormant.

### What every auditor independently said not to touch

- **`/commit` (1,448w)** — the densest local fact in the harness. Detached-HEAD push
  proof (four commits stranded 2026-07-31), `jsonl-union` vs `union` resurrection, the
  `git add <dir>` deletion footgun. Every line has a date and a measured consequence.
- **`/zig-voice`'s anti-patterns and genre anatomies (3,022w)** — the best answer in the
  corpus to "what can a model not know." Cutting here is the one move that would
  *degrade* an output rather than shorten a prompt.
- **`/impeccable` — all 19,856 words.** 41 reference reads across 10 projects; 7% resident
  / 93% on-demand. **This is the architecture the rest of the corpus should converge on.**
- **Every "what NOT to do here" block** in the fleet files — each is a bright line with a
  real incident behind it (the unauthenticated `/api/transcripts` leak, the
  `SavePlaceAsync` publish-by-default trap, Tier A/B/C money guardrails).
- **`picod`, `dotfiles`, `lb-granola`** — the three best CLAUDE.md files on the box.
  `picod` says out loud that its own tick is off. These need *more* words, not fewer.

---

## 6. The structural finding — why anything you cut will regrow

Three auditors reached the same conclusion by different routes, and it outranks any
individual cut:

**The harness has no single-owner rule for a fact.** An incident happens; the lesson
gets written into every skill that touches it; nobody ever removes the copies; they
drift apart. Measured instances:

- "Where the opportunity can land" — **3 copies, 1,637 words**, all three saying *"keep
  all three in sync"*, an instruction with no mechanism. They have **already drifted**
  (dive's is 2× desk's).
- The `skills-library-8l6` runtime-verification incident — **4 copies** across impl,
  handoff, dispatch, scrutinize.
- The merge/cleanup sequence — **3 copies** (AGENTS.md, orchestrator, fix).
- "No nested agents" — **5 copies**, for something now *structurally impossible* (the
  subagent type has no Agent tool). `/dispatch` removed its copy on 2026-06-09; the other
  four never got the memo.

And the accrual curve: **AGENTS.md 1,194 → 5,525 words in 72 days, monotonic, never once
smaller.** Four of the six largest fleet files have become **changelogs in an
always-loaded file** — each wave appends a dated "LIVE as of…" paragraph and nothing ever
leaves. `refs/` already exists in all four for exactly this.

**The durable fix is a convention, not a deletion:**
> *A CLAUDE.md states the current invariants. `refs/` holds how they got that way.
> A rule has exactly one owner; every other mention is a pointer. Rationale for a
> hook-enforced rule lives in the hook's block message.*

---

## 7. The decision menu

Ranked by (value ÷ risk). Nothing below has been applied — the working tree is unchanged
except for this file and the beads.

| # | Move | Saves | Risk | Bead |
|---|---|---|---|---|
| **1** | **Fix the 4 live defects.** Not a bloat decision — the harness is currently instructing agents wrongly, and two of them steer toward destructive or invisible outcomes. | — | none | `mjln` `sj8l` `8k3o` `775y` |
| **2** | **Fix the 4 fleet files.** `agent-dev-interrupted` (−3,000w, actively teaches stashing + tmux subagents + `br new`), `skills-library` (−3,000w, archived repo), `autonoveld`'s dead timer table, `cfp/mise`. | ~7,400w | low — all dormant or verified-wrong | new |
| **3** | **Strip the always-loaded tier.** 5,525 → ~1,900. Mostly *relocation*: delete the drifted skill listing (the system prompt already carries it at higher fidelity), point at `/orchestrator` for the merge block, keep the Opus-5 400 fact, move hook rationale into hook block messages. | ~3,600w × every session forever | **medium** — §4's rig could not validate this; do it as a reviewable diff, not a rewrite | new |
| **4** | **Adopt the single-owner rule** and dedup: extract the 3-copy "opportunity can land" block to `_shared/`, `/scrutinize` becomes sole owner of post-impl audits, `/dispatch` sole owner of prompt blocks. | ~11,000w fleet-wide | low | new |
| **5** | **Instrument the unmeasurables** — one-line `## Handoff —` / `## Guard —` blocks; bind the scrutinize proof to the work (`dotfiles-2dez`, still open). | — | none | `2dez` + new |
| **6** | **Act on the graduation debt.** `zig-zone` (4 cross-umbrella loads) and `daily-digest` (3) have met the documented criterion and haven't graduated. The harness is measuring correctly and not acting. | — | low | new |
| **7** | **Run the real A/B** at n≥8 on local-fact cases, and settle the one open vendor question: does the elaborate `/scrutinize` prompt beat a minimal one? | potentially large | none (measurement) | new |

**My recommendation:** do 1 and 2 now (they're corrections, not cuts), then 4 and 5 — the
structural fixes that stop regrowth. Hold 3 until it can be reviewed as a diff; it's the
biggest number but the least validated, and §4 is honest that the rig didn't earn the right
to assert it.

**What I would not do:** a broad "cut 80%" pass. Four independent audits and a live
ablation all landed in the same place — this corpus is not padded with nonsense, it is
**thick with its own history**. `/commit`'s detached-HEAD proof, `/zig-voice`'s genre
anatomies, `/pulse`'s three-valued check, every "what NOT to do here" block in the fleet:
each was paid for once, none is inferable, and `/impeccable` (7% resident / 93% on-demand)
is the architecture the rest should converge on rather than a target.

---

## 8. Appendix — where the working files are

```
/tmp/claude-1000/-home-ubuntu-dotfiles/64bce900-f1f7-47da-917c-c1f1e6326e43/scratchpad/
  audit/A-always-loaded.md         the always-loaded tier
  audit/B-big-skills.md            the 8 largest skills + the scar-tissue ledger
  audit/C-rest-skills.md           the other 29 + the usage table
  audit/D-fleet-claudemd.md        43 fleet CLAUDE.md + the staleness table
  audit/E-project-skills.md        56 project skills + references + the toybox
  audit/F-verification-evidence.md the verification-layer tally
  audit/G-hook-enforcement-map.md  what the 28 hooks mechanically enforce
  audit/variant-B-AGENTS.md        the stripped tier used in the ablation
  ab/{run.sh,cases.txt,home-{A,B,C},out/}   the reusable ablation rig
```

Beads: epic `dotfiles-w8xw`; audits `499d xae2 0tpo 563j ctse 789w` (closed);
defects `mjln sj8l 8k3o 775y t40m`; vendor-guide finding `ec32`.
