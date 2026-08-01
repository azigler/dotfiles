# Audit C — the 29 remaining global skills

Bead `dotfiles-0tpo`. Read-only. Scope: `/home/ubuntu/dotfiles/agents/skills/` minus
desk, dive, talk, pulse, research, zig-voice, cfp, beads (auditor B's set).

**Headline verdict up front, because it contradicts the framing.** Anthropic's "we
removed 80% of the harness instructions" does not transfer here. Their 80% was
*model scaffolding* — telling a model how to be careful. This corpus is mostly not
that. Across 51,641 words in 29 skills I find **~7,300 words (14%) of defensible
cut**, and almost all of it is **REDUNDANT** (the same incident written into 3–4
skills) rather than MODEL-SCAFFOLD. The one genuine model-scaffold class I found is
small, specific, and *contradicts a rule this repo already adopted* — see §6.

---

## 1. Headline numbers

| skill | current | proposed | cut | dominant class |
|---|---:|---:|---:|---|
| orchestrator | 3,138 | 1,500 | **52%** | REDUNDANT (AGENTS.md + /dispatch + /scrutinize) |
| impl | 1,949 | 1,050 | **46%** | REDUNDANT (/scrutinize + /dispatch) |
| housekeeping | 3,310 | 1,900 | **43%** | STALE/misplaced (LinearB fleet in a global skill) |
| elevate | 1,719 | 1,350 | 22% | MODEL-SCAFFOLD + CTX-SCARCITY |
| onboard | 1,836 | 1,500 | 18% | STALE + CTX-SCARCITY |
| fix | 1,577 | 1,300 | 18% | REDUNDANT (merge block) |
| scrub-secrets | 2,500 | 2,100 | 16% | rationale prose vs contract |
| handoff | 1,121 | 950 | 15% | REDUNDANT |
| randomize | 1,560 | 1,350 | 13% | REDUNDANT (2 worked examples) |
| offboard | 1,805 | 1,650 | 9% | trim |
| dispatch | 1,914 | 1,750 | 9% | trim |
| gamma | 2,744 | 2,500 | 9% | trim |
| gdoc | 3,156 | 2,900 | 8% | trim |
| lint | 1,683 | 1,550 | 8% | trim |
| spec / check / test | 3,713 | 3,420 | 8% | self-review blocks |
| dream | 2,395 | 2,200 | 8% | trim |
| daemon | 3,202 | 3,000 | 6% | trim |
| openrouter | 1,671 | 1,600 | 4% | trim |
| **scrutinize** | 1,446 | **1,600** | **+11%** | absorbs impl's audit blocks |
| nginx, cdn, commit, impeccable, recall, grok, triage, asana | 8,882 | 8,882 | **0%** | LOCAL-FACT — do not touch |
| **TOTAL** | **51,641** | **44,372** | **14%** | |

Separate finding: **`agents/skills/TOOLKIT.md` is 4,748 words (~8.8k tokens)**, but
`onboard/SKILL.md:110-118` advertises it as "**~3k tokens**" and "~4% of" the 75–85k
full-body cost. It is ~11%. That is a STALE measured claim in the one file whose
entire justification is a measured claim. Fix the number or re-trim the digest;
don't leave a stale measurement inside a token-budget argument.

---

## 2. The usage table — **no skill in this set has never fired**

This was the highest-signal question and the answer is a clean negative: the
"dead skill" hypothesis is **false for all 29**. Every one has invocation or
artifact evidence within the last ~5 days. The differentiator is frequency, not
existence.

Method — three independent signals, all swept over 7,717 transcript JSONL / 4.8 GB
in `~/.claude/projects`:
- **T** = `Skill` tool calls: `rg -oI '"skill":"[a-z-]+"'` (the modern invocation path)
- **R** = Read-tool loads of the body: `rg -oI '"file_path":"[^"]*skills/<n>/SKILL.md"'`
- **A** = artifact evidence (ledgers, generated URLs, hook callers)

"Last use" excludes 2026-08-01 (today's audit wave would contaminate every row).

| skill | T | R | last use (pre-today) | strongest evidence |
|---|---:|---:|---|---|
| commit | 26 | 308 | 07-31 | 2,208 `<command-name>commit` blocks |
| spec | 22 | 341 | 07-31 | T+R, live spec beads fleet-wide |
| onboard | 22 | 77 | 07-31 | 273 `/onboard` slash invocations |
| offboard | 90 | 104 | 07-31 | highest T of any skill; 141 `/offboard` |
| lint | 18 | 192 | 07-31 | 2,212 `<command-name>lint` |
| housekeeping | 21 | 183 | 07-31 | T+R |
| test | 1 | 304 | 07-31 | R-dominant (dispatched, not typed) |
| impl | 4 | 302 | 07-31 | 16 `/impl` slash |
| orchestrator | 1 | 188 | 07-31 | R-dominant |
| triage | 16 | 75 | 07-31 (cfp-mise) | T+R |
| scrutinize | 16 | 62 | 07-31 | pre-bead-close.sh gate calls it |
| check | 15 | 89 | 07-31 | T+R |
| asana | 4 | 144 | 08-01 | fleet-proxy writes |
| gdoc | 7 | 141 | 08-01 | T+R+live doc IDs |
| dispatch | 5 | 116 | 08-01 | T+R |
| handoff | 0 | **162** | 07-31 | R-only — read by subagents, never typed |
| fix | 4 | 98 | 08-01 | T+R |
| nginx | 3 | 96 | 07-31 | T+R |
| impeccable | 3 | 87 | 07-31 (cfp-mise) | +41 reference-file reads, 10 projects |
| openrouter | 1 | 79 | 07-31 | image artifacts on disk |
| grok | 0 | **78** | 07-31 (cfp-mise) | R-only |
| gamma | 0 | **70** | 07-31 | **3,540** `gammaUrl`/`gamma.app/docs` hits |
| elevate | 1 | 54 | 07-31 | 6 `/elevate` slash |
| daemon | 1 | 36 | 07-28 | hevyd + picod exist |
| scrub-secrets | 0 | **13** | 07-28 | vault pre-commit hook is its caller |
| recall | 1 | 12 | 07-27 | `/dream` calls it as a CLI |
| cdn | 0 | **8** | 07-28 | **60 distinct `cdn.zig.computer/…` URLs** |
| dream | 0 | **7** | 07-31 | 3 real ledger rows, 4 proposal beads |
| randomize | 3 | 6 | 07-27 | provenance blocks in `/dive` output |

**Read this table correctly.** Six skills have **zero** `Skill`-tool calls — handoff,
grok, gamma, scrutinize-adjacent, cdn, dream, scrub-secrets — and every one of them
turns out to be *heavily used through a non-Skill-tool path*: read directly by
dispatched subagents (handoff 162, grok 78), invoked by a hook (scrub-secrets),
invoked by a timer (dream), or invoked via its helper script (gamma → 3,540 URLs;
cdn → 60 live objects). **Skill-tool call count alone would have condemned five
live, load-bearing skills.** Any future "prune unused skills" pass must use at
least two signals.

The frontmatter-cost argument is real but small: 29 descriptions ≈ 3,900 words of
`description` + `when_to_use` in every session's system prompt. The 5 longest
descriptions (cdn 118w, cfp, dive, impeccable, gamma) are ~40% of it. **Compressing
descriptions is a better lever than deleting skills** — same saving, zero capability
loss.

---

## 3. Findings table (ordered by words saved)

| skill | section | words | class | verdict | evidence |
|---|---|---:|---|---|---|
| housekeeping | §9.1–9.6 LinearB fleet audit | 1,044 | STALE/misplaced | **CUT → move to `~/linearb/agent-factory/CLAUDE.md`** | every loop is `for agent in agents/lb-agent-*/`; `housekeeping/SKILL.md:224-411`. Glob is empty in 47 of 48 repos |
| orchestrator | merge/close/cleanup sequence L40-132 | 666 | REDUNDANT | **CUT → 1 pointer** | byte-near-identical to `~/.claude/CLAUDE.md` "Delegation" block, which is loaded in EVERY session already |
| orchestrator | cross-repo dispatch L141-231 | 661 | REDUNDANT | **COMPRESS to ~200** | `dispatch/SKILL.md:230-266` already carries the canonical block; orchestrator says so at L171 then restates it anyway |
| impl | UI/CLI composition audit L174-245 | 512 | REDUNDANT | **CUT → /scrutinize** | same skills-library-8l6 incident in impl, handoff:54-69, dispatch:198-228, scrutinize:172-176 — 4 copies |
| orchestrator | pre-merge stub audit L355-404 | 348 | REDUNDANT | **CUT → /scrutinize** | `/scrutinize` exists precisely to own this; scrutinize:95-117 has the full hunt list |
| impl | stub-body audit L139-172 | 265 | REDUNDANT | **CUT → /scrutinize** | ditto; and `pre-bead-close.sh` blocks `-t impl` close without a SHIP verdict |
| fix | merge/close/cleanup L108-143 | 234 | REDUNDANT | **CUT → 1 pointer** | third copy of the AGENTS.md merge block |
| randomize | worked example L225-251 | 243 | REDUNDANT | **CUT one** | the same seed `edc165f706616610` is worked twice (L126-132 and L229-247) |
| dispatch | cross-repo block L230-266 | 221 | LOCAL-FACT | **KEEP** (canonical home) | this is the copy to keep |
| impl | subagent prompt skeleton L258-287 | 160 | REDUNDANT | **CUT → /dispatch** | /dispatch IS the prompt template skill |
| handoff | runtime verification L54-69 | 163 | REDUNDANT | **COMPRESS → 40w + pointer** | 3rd copy of 8l6 |
| orchestrator | subagent prompt template L286-317 | 125 | REDUNDANT + STALE | **CUT** | still says "Nested agents create 796MB worktree copies" — but nesting is now *structurally impossible* (subagent type has no Agent tool), as `/dispatch:23-38` itself documents |
| spec/check/test/impl | 4× "Self-review (5 items)" | ~200 | **MODEL-SCAFFOLD** | **CUT — see §6** | `spec:195`, `check:220`, `test:191`, `impl:289` |
| elevate | "where the upside can land" L71-124 | 430 | MODEL-SCAFFOLD | **COMPRESS to ~180** | pure stance-setting ("lead with curiosity"), 3 nested guards, one tabling list that will rot |
| onboard | TOOLKIT history parenthetical L114-118 | 60 | CTX-SCARCITY | **COMPRESS + FIX NUMBER** | claims ~3k tokens; measured 8.8k |
| onboard | Step 5.5 effort block L204-231 | 300 | REDUNDANT | **COMPRESS to ~80** | AGENTS.md "Effort" is ~1,400 words on the same thing and is always loaded |
| dispatch | effort block L104-131 | 250 | REDUNDANT | **KEEP** | this is the one place AGENTS.md says effort is *decided*; the per-dispatch reminder is the mechanism |
| scrub-secrets | "why the denylist exists" L65-113 | 380 | SCAR-TISSUE | **COMPRESS to ~120** | rationale for a shipped CLI; the contract matters, the archaeology doesn't |
| commit | all of it | 1,448 | **LOCAL-FACT** | **KEEP ALL** | see §8 |
| nginx, cdn, gdoc, asana, lint, recall | operational bodies | — | **LOCAL-FACT** | **KEEP** | paths, API quirks, cred locations |

---

## 4. Question 1 — the 7-skill TDD pipeline

**Before: 12,545 words** across spec (1,278) + check (1,269) + test (1,166) +
impl (1,949) + dispatch (1,914) + orchestrator (3,138) + handoff (1,121) +
scrutinize (1,446, which the brief omitted but is structurally part of it).

I diffed all seven. **The four stage skills are genuinely distinct** and should NOT
be merged:

| skill | irreducibly its own |
|---|---|
| spec | the 7-section bead structure; the Interrogator pattern (Fowler, `spec:64-106`) |
| check | the `br update --notes` **replace-only** gotcha + read-then-rewrite idiom (`check:96-134`) — a real `br` API fact, bead `bd-otl8` confirmed to exist |
| test | delegation-assertion tests / spy-don't-mock (`test:93-146`) — the single most specific technical content in the pipeline |
| impl | wave ordering: tests merge BEFORE impl dispatches, and *why* (worktrees branch from HEAD) |

Each is ~1,200 words with maybe 150 of shared framing. **Defend the split.**

**The overlap is not between the stages — it is in the three "how to dispatch and
merge" skills**, which restate each other and AGENTS.md:

| block | orchestrator | impl | dispatch | handoff | AGENTS.md | scrutinize |
|---|---|---|---|---|---|---|
| merge/close/cleanup sequence | 666w | — | — | — | **~600w** | — |
| subagent prompt template | 125w | 160w | **canonical** | — | — | — |
| cross-repo recovery snippet | 661w | — | 221w | — | — | — |
| stub-body audit | 348w | 265w | — | — | — | **canonical** |
| 8l6 runtime-verification | — | 512w | 220w | 163w | — | 1 line |
| no-nested-agents | 125w | 30w | (removed 06-09) | 30w | **canonical** | 40w |

**Proposal — same 7 skills, one ownership rule per block.**

- `/dispatch` owns **every prompt block** (it already does; impl and orchestrator
  just kept copies).
- `/scrutinize` owns **every post-impl audit** (stub bodies, composition, 8l6). It
  *grows* by ~150w absorbing the best of impl's version.
- AGENTS.md owns the **merge sequence**; orchestrator and fix point at it.
- `/handoff` keeps the *report format* and drops the audit content.

**After: 10,240 words** — a **2,305-word (18%) cut** with no capability removed and
one incident (8l6) told once instead of four times. Consolidating the *stages*
would save maybe 400 more and would cost the four distinct technical facts above.
Not worth it.

---

## 5. The scar-tissue ledger

| rule | incident found? | ALSO hook-enforced? | verdict |
|---|---|---|---|
| "never `git add -A` / a directory" (`commit:71,154-178,195`) | **YES** — 2026-07-30 marketing-vps, `rsync --delete` + `git add refs/doc-scripts` folded 12 deletions into 2 commits | **YES** — `pre-commit-checks.sh:3` blocks `-A`/`--all`/`.` | **KEEP the directory half, COMPRESS the `-A` half.** The hook blocks `-A`; it does *not* block `git add somedir/`, which is the actual 07-30 failure. The prose covers the gap. |
| "no nested agents" (5 places) | **YES** — 796MB worktree explosion (pre-06-09) | **YES** — `subagent` type has no Agent tool; `pre-tool-use-require-isolation.sh` | **CUT everywhere except AGENTS.md.** `/dispatch:23-38` already made this call on 2026-06-09 and removed its block; orchestrator/impl/handoff never got the memo. Textbook prose-duplicating-a-structural-guarantee. |
| "don't blanket-suppress stderr" (orchestrator, fix, housekeeping) | **YES** (AGENTS.md) | **YES** — `pre-bash-stderr-guard.sh` | **COMPRESS to a clause.** Currently a 3-line explanatory comment in 3 separate code blocks. |
| "/scrutinize gate not cleared until SHIP" (impl:111-123, orchestrator:355-370) | **YES** — skills-library-8l6 | **YES** — `pre-bead-close.sh:12-19` blocks `-t impl` close without a SHIP/OVERRIDE verdict in `--notes` | **CUT the restatements**, keep `/scrutinize` itself. Best available cut: prose duplicating a *blocking* hook. |
| runtime verification / 8l6 (impl, handoff, dispatch) | **YES** — skills-library-8l6 confirmed live in `~/linearb/skills-library/.beads/issues.jsonl` | NO | **CONSOLIDATE to /scrutinize** — real incident, real guard, told 4×. |
| worktree path discipline | **YES** — bd-n47 cited; **bead id NOT FOUND** in any `.beads/issues.jsonl` fleet-wide | **YES** — `pre-tool-use-worktree-guard.sh` | KEEP the rule (hook proves it), **fix the dead citation**. |
| "standalone `cd`, never `cd && cmd`" (`orchestrator:42-51,103-109`) | **YES** — `skills-library-1vs` confirmed | NO | **KEEP.** Self-flagged at L111-122 as describing a *contradicted* Claude Code build (2.1.170; now ≥2.1.220). The discipline is cheap and correct under both — but it is **due for re-verification**, which the version-stamp convention itself demands. |
| "`br create -d`, not create-then-fill" (`dispatch:99-102`) | **YES** — `explore-0og4`, 18 empty-bodied beads | partial (`pre-bead-create.sh`) | KEEP |
| "three subagents refused the push instruction" (`dispatch:76-85`) | Prose-only claim, 2026-07-27, no bead cited | NO | KEEP the rule, **CUT the 90-word anecdote** to one clause. |
| `merge=union` resurrection (`commit:140-144`) | **YES** — `lin-eqh`, 3× on 2026-06-09 | driver registered in `git/.gitconfig` | **KEEP.** Config, not a hook — nothing blocks a hand-edit. |
| detached-HEAD push proof (`commit:89-119`) | **YES** — 2026-07-31 marketing-vps, 4 commits stranded | NO | **KEEP.** Highest-value LOCAL-FACT in the corpus. |

**Pattern:** 9 of 11 incidents are real and findable. The two weak ones (`bd-n47`
dead id; the un-beaded push anecdote) are citation hygiene, not fabrication. The
corpus's scar tissue is **honest** — its problem is that each scar got written into
3–4 files instead of one.

---

## 6. Question 6 — the verification layer, and a rule the 07-27 sweep missed

AGENTS.md (2026-07-27, bead `explore-8hs7`) states: *"the only genuine per-task
self-check instructions in the whole skill tree were in `/research` Step 3.5 …
Those were stripped; nothing else matched."*

**That audit was incomplete.** Four skills carry a literal
`## Self-review (5 items)` section instructing the agent to re-check its **own**
work before closing its **own** bead:

```
spec/SKILL.md:195   ## Self-review (5 items)
check/SKILL.md:220  ## Self-review (5 items)
test/SKILL.md:191   ## Self-review (5 items)
impl/SKILL.md:289   ## Self-review (5 items)
```

This is the left column of the AGENTS.md table exactly — same agent, inside its own
task, "re-read your output before finishing." Per the standing rule it is a **REMOVE**.
The sweep almost certainly grepped for phrases like "double-check" and missed the
heading. ~200 words, and more importantly a policy inconsistency sitting in the four
most-read skills in the corpus.

**Nuance that must survive the cut:** two of the twenty items are *empirical
evidence*, not self-checking — `test:198` "NO implementation source files were
created or modified" is `git diff --name-only`, and `impl:294` "quality gate passed"
is a command. Those are the Carson evidence-field, which AGENTS.md explicitly keeps.
**Convert those two to the /handoff evidence block; delete the other eighteen.**

Right side of the line, correctly:

| skill | stance | verdict |
|---|---|---|
| `/scrutinize` | fresh agent, read-only, no stake, "disprove done" | **on the right side.** `scrutinize:161-165` explicitly names the conflicted-judge problem. Do not touch. |
| `/elevate` | fresh unpolluted agents, max effort | **on the right side** |
| `/check` | interrogates the plan pre-impl | right side (its self-review block excepted) |
| `/handoff` | subagent → orchestrator report | right side — it produces the evidence someone *else* judges |
| `/fix` | dispatches a subagent + mandatory regression guard | right side; the guard is a test, not a self-check |
| `/spec` Step 4a Interrogator | a *separate* read-only agent generates the OQs | right side, and a good pattern |

---

## 7. Questions 3, 4, 5, 7

**Q3 — `/impeccable` (1,377 SKILL.md + 18,479 across 21 reference files).**
**This is progressive disclosure working, and it is the pattern to copy.** The
reference files are read: **41 Read-tool loads across 10 different projects**
(explore 22, picod 4, linearb 4, dotfiles 4, harnessd 2, dashboard-dev, vs14d,
hevyd, andrewzigler3, local-coding-models). `interaction-design.md` 7×,
`typography.md` 4×, `spatial-design.md` 4×, `audit.md` 2×, `arrange.md` 2×. Only
3 of 21 files have zero recorded reads. The SKILL.md is a 1,377-word router with
an explicit "read the matching playbook at `reference/operations/$operation.md`"
(L40-43) and a load-trigger table (L120-128). **Verdict: KEEP ALL 19,856 words,
change nothing.** The ratio is 7% resident / 93% on-demand. If the rest of the
corpus hit that ratio the always-loaded cost would drop by more than any cut in
this report.

**Q4 — `/gdoc` node_modules.** `agents/skills/gdoc/` is **226 MB on disk** but
**9 tracked files**. `git check-ignore -v` resolves to `.gitignore:46: node_modules/`
— it is ignored, has never been committed, and `git ls-files` confirms nothing under
it is tracked. **Context risk is real but not automatic:** a Glob/Grep over the skill
dir would traverse it, and a `find agents/skills -name '*.md'` (the shape a
skill-inventory pass uses) pulls in ~100k words of vendored README/CHANGELOG.
**Verdict: no repo problem, one operational footgun.** Cheapest fix is a
`.claudeignore`/tooling exclusion, or `npm ci --omit=dev` on demand rather than a
resident tree. Not a word-count issue; don't spend cut budget here.

**Q5 — the cost-aware trio.** Position: **KEEP, and it is not model-scaffold.**
Three reasons. (a) It guards a **real-money irreversible action** — Gamma credits
and OpenRouter balance do not come back; this is exactly the "destructive /
irreversible" escalation category AGENTS.md already blocks on. (b) It is
**partially hook-backed**: `agents/hooks/post-gen-fanout-check.sh:19` counts
`gamma-render.sh` / `openrouter-image.sh` invocations and warns on fan-out — which
means someone already hit the "let me try a few" failure mode. Prose + hook here is
belt-and-braces on a spend, not scaffolding. (c) The cost lives in the
**frontmatter**, not the body — "NEVER fire autonomously, in loops, or as a 'let me
try a few' speculation" is ~15 words in `when_to_use`, and that is the copy that
matters, because it is the only part loaded before the decision to fire. **Trim the
body's "CRITICAL: cost awareness" prose (~80w each), keep the frontmatter clause
verbatim.** `/cdn` is the odd one out — R2 free tier, content-addressed immutable
keys, re-runs literally free — so its warning is about *the bucket being public*,
which is a different and equally valid guard.

**Q7 — the two untracked files.** `agents/skills/gdoc/fixpara.mjs` (70 lines) and
`agents/skills/gdoc/resolve.mjs` (42 lines), both created 2026-07-29, both
untracked, and **referenced by nothing** — a grep for `fixpara|resolve.mjs` across
all `*.md`, `*.sh`, `*.mjs`, `*.json` in `~/dotfiles` (excluding node_modules)
returns zero hits. They are one-off scratch scripts from the 2026-07-27 gdoc
paragraph-routing work (`cef0ff9`-era, commit `:recycle: gdoc: get the segment end
from the raw route`). **Verdict: ask Zig — either commit them with a line in
`/gdoc`'s "Advanced Operations", or delete.** Untracked-and-unreferenced in a repo
that ships as `~/.claude/skills` is the worst of both: not backed up, but present
on disk where a future agent may find and trust them.

---

## 8. Top 10 cuts by leverage

1. **housekeeping §9.1–9.6 → `~/linearb/agent-factory/CLAUDE.md`** (−1,044w). Every
   loop globs `agents/lb-agent-*/`, which exists in 1 of 48 repos. Leave a 3-line
   "LinearB fleet: see agent-factory CLAUDE.md §fleet-hygiene".
2. **orchestrator merge sequence → pointer to AGENTS.md** (−666w). AGENTS.md is
   loaded in every session already; this is a verbatim second copy.
3. **impl UI/CLI composition audit → /scrutinize** (−512w).
4. **orchestrator cross-repo → 200w + pointer to /dispatch** (−460w). Orchestrator
   already says at L171 that /dispatch is canonical.
5. **orchestrator pre-merge stub audit → /scrutinize** (−348w).
6. **impl stub-body audit → /scrutinize** (−265w). Cuts 3+5+6 net +150w into
   `/scrutinize`, which becomes the single owner of "disprove done."
7. **fix merge block → pointer** (−234w).
8. **randomize: delete the duplicate worked example** (−243w). Same seed, twice.
9. **The four `## Self-review (5 items)` blocks** (−200w) — and file the policy
   inconsistency, which matters more than the words (§6).
10. **impl + orchestrator prompt templates → /dispatch** (−285w), and delete the
    "796MB worktree" line, which describes an impossibility.

Running total: **−4,257w** from ten mechanical, low-risk edits.

---

## 9. The empirical test list (cuts I am NOT confident about)

Each names the specific failure the rule guards. Test = remove it, run the named
scenario, see whether the failure returns.

| candidate cut | the failure it guards | how to test |
|---|---|---|
| `/handoff` runtime-verification block | subagent reports "tests pass", ships a page importing none of its components (8l6) | dispatch a UI bead with the block removed but `/scrutinize` intact; does scrutinize catch it? If yes, the handoff copy is redundant. |
| `orchestrator` standalone-`cd` discipline | orchestrator's cwd drifts into the finished worktree; merge silently no-ops | already partly obsolete — the guarded merge (`test branch = TARGET`) catches the consequence. Verify on claude-code ≥2.1.220 whether cwd still persists; the file self-flags this at L111-122. |
| `/elevate` "where the upside can land" guards | elevate collapses to modal LinearB tie-backs (Zig, 2026-07-13) | this is genuine behavioral steering with a named incident — but 430 words of it. Test at 180. |
| `/commit` "assume another machine committed" (~120w) | marketing-vps + interactive session race | do NOT test blind — a `--force` here loses another machine's work. Test only by watching whether agents still pull-before-push with the prose trimmed. |
| `/dispatch` push-block anecdote (90w) | orchestrator writes "commit and push" into a worktree dispatch | keep the *rule*, cut the *story*, watch the next 10 dispatches. |
| `/spec` Step 4a Interrogator (280w) | spec ships with a load-bearing OQ nobody noticed | Opus 5 may generate these unprompted. Worth an A/B — but it is a *separate-agent* pattern, so it is on the right side of the 07-27 line and I would test rather than cut. |

---

## 10. What I would NOT touch

Zig's constraint — "DO NOT clear things just to clear them" — binds hardest here.
**8,882 words (17% of the corpus) I would not move a comma of:**

- **`/commit` (1,448w) — the densest LOCAL-FACT in the harness.** The detached-HEAD
  push proof (2026-07-31, four commits stranded on marketing-vps, `git push` exit 0),
  the `jsonl-union` vs `union` resurrection (`lin-eqh`, 3× in one day), the
  `git add <dir>` deletion footgun (12 files, 2026-07-30). No model knows any of
  this. Every line has a date and a measured consequence.
- **`/nginx` (1,563w), `/cdn` (1,465w), `/gdoc` (3,156w minus trim), `/asana` (595w),
  `/lint` (1,683w minus trim), `/recall` (1,022w)** — paths, ports, bucket names,
  cred locations, the strict-XML Asana rules, the gdoc styling contract (Arial 11pt,
  20/16/13pt). Irreducible.
- **`/impeccable` — all 19,856 words.** §7. It is the architecture the rest of the
  corpus should converge on, not a target.
- **`/grok` (874w) and `/triage` (858w)** — already the two leanest skills. Nothing
  to take.
- **`/scrutinize`** — should *grow*. It is the one skill on the correct side of the
  self-verification line by construction, and it is the natural owner of three blocks
  currently scattered across impl and orchestrator.
- **Every frontmatter `when_to_use` on the cost-aware trio** — 15 words that guard a
  real-money irreversible action, loaded before the decision to fire.

**And a meta-point worth Zig's time.** The honest number here is 14%, not 80%. The
reason is that this corpus is not what Anthropic trimmed. Anthropic removed
*scaffolding about how to think*; this corpus is ~80% **facts about this machine and
incidents that actually happened on it** — and Opus 5 knowing more does not tell it
that `marketing-vps` re-detaches HEAD or that `merge=union` resurrects closed beads.
The real bloat here is not scaffolding. It is that **the harness has no
single-owner discipline for a rule**: an incident gets written into every skill that
touches it, and nobody ever removes the copies. Fixing that ownership rule is worth
more than any one-time cut, because it stops the corpus re-growing the 4,257 words
this report just found.
