# E — Project skills, reference material, and the toybox

Read-only audit, bead `dotfiles-ctse`, 2026-08-01. No files modified.
Evidence base: 7,721 transcript JSONL files across 103 project slugs,
spanning 2026-01-26 → 2026-08-01 (`find /home/ubuntu/.claude/projects -name '*.jsonl' | wc -l`).

---

## 1. Headline numbers

### Global skills (`/home/ubuntu/dotfiles/agents/skills/`, symlinked as `~/.claude/skills`)

| Corpus | Words | Note |
|---|---|---|
| 37 × `SKILL.md` | **100,217** | the on-demand-loaded bodies |
| `TOOLKIT.md` | **4,748** | the digest `/onboard` reads instead of all bodies |
| Legitimate `reference/` material | **63,895** | 63 files, 10 skills |
| **`gdoc/node_modules/` third-party `.md`** | **101,781** | 135 files — **not this repo's content** |
| Reported "reference" total | 165,676 | `find . -name '*.md' ! -name 'SKILL.md' \| xargs wc -w` |

**The 165,662-word figure in the brief is 61.4% an artifact of one
gitignored dependency tree.** The real reference corpus is **63,895 words**,
and it is in far better shape than the raw number suggested.

### Project-local skills (56 skills, 10 repos)

| Repo | Skills | Total words | `SKILL.md` words | Reference/data words |
|---|---:|---:|---:|---:|
| explore | 9 | 219,442 | 36,844 | 182,598 |
| linearb | 9 | 185,174 | 28,252 | 156,922 |
| aaif | 11 | 14,678 | ~14,600 | ~80 |
| autonoveld | 8 | 13,426 | 13,426 | 0 |
| vs14d | 9 | 9,298 | 9,298 | 0 |
| investd | 2 (+1 symlink) | 6,016 | ~5,200 | ~800 |
| picod | 3 | 5,856 | 5,856 | 0 |
| hevyd | 1 | 5,133 | 5,133 | 0 |
| harnessd | 2 | 4,381 | 4,381 | 0 |
| andrewzigler3 | 2 | 4,379 | ~1,100 | ~3,280 |
| **Total** | **56** | **467,783** | **~124,000** | **~343,000** |

Two entries dominate and both are **data corpora, not prose**:
`explore/ab/evals/` (108 files of committed A/B eval cases, 173,695 w) and
`linearb/lb-demo-flow-builder/references/` (screenshot catalogs + platform
spec, 129,779 w). Excluding those two, all 56 project skills total
**~128,263 words** — smaller than the global set.

### Dead weight, totalled

| Item | Words | Class |
|---|---:|---|
| `gdoc/node_modules/` `.md` | 101,781 | DEAD WEIGHT (see §2 — mostly *inert*) |
| 4 toybox skills never loaded cross-umbrella | 12,157 | DEAD WEIGHT by the harness's own criterion |
| `autonoveld/heartbeat` retired stub | 1,103 | STALE (deliberate tombstone) |
| 10 reference files with 0 Read-tool hits in 6 months | 8,545 | unread bulk — see §3 |

---

## 2. The gdoc `node_modules` verdict

**Verdict: NOT a git problem. A minor filesystem-hygiene and
Bash-tool-hazard item only. Do not "fix" it by deleting.**

Evidence, command by command:

| Question | Command | Answer |
|---|---|---|
| Committed to git? | `git -C /home/ubuntu/dotfiles ls-files agents/skills/gdoc/node_modules \| wc -l` | **0** |
| Ever in history? | `git log --oneline --all -- 'agents/skills/gdoc/node_modules'` | **empty** (never) |
| Any `node_modules` ever committed? | `git log --oneline --all --diff-filter=A -- '*node_modules*'` | **empty** |
| Gitignored? | `git check-ignore -v agents/skills/gdoc/node_modules` | **yes** — `.gitignore:46:node_modules/` |
| Deliberately? | `grep -n node_modules .gitignore` | **yes** — line 45 is a comment naming this exact path |
| Size on disk | `du -sh agents/skills/gdoc/node_modules` | **226 MB**, 3,394 files |
| Size in git history | (never committed) | **0 bytes** |

So the repo is already correct: ignored on purpose, with an explanatory
comment, and zero history contamination. `.git` is 117 MB and contains
none of it.

### Can it reach a model's context?

Partially — and the dangerous path is already closed:

- **Grep tool (ripgrep backend): NO.** Measured:
  `rg --files agents/skills/gdoc/` returns **11** files;
  `rg --files --no-ignore agents/skills/gdoc/` returns **3,405**.
  ripgrep honors `.gitignore`, so the 101,781 words are invisible to Grep.
- **Bash `find` / `ls`: YES.** `find agents/skills/gdoc -name '*.md' | wc -l`
  returns **136** (vs 1 real). Any agent that inventories the skill tree with
  `find`/`ls`/`du` — exactly what this audit did — pulls the tree into view.
- **Skill loading: NO.** Claude Code loads `SKILL.md` frontmatter, not
  sibling directories. `node_modules` is never auto-injected.

**Net context cost in normal operation: ~zero.** The cost is real but
narrow: it distorts every `find`-based measurement of the skill tree
(it produced the 165,662 figure in this very brief), and it inflates
`dotfiles` on disk by 226 MB of 563 MB.

### Should it be deleted?

**No — it is a load-bearing runtime dependency.** `gdoc/SKILL.md` line 32-38
documents it explicitly: `render_styled_blocks.mjs` requires a
**self-contained** `node_modules` so module resolution never depends on a
global store or a `$HOME`-level install, and line 45 notes a prior incident
(`dotfiles-1ag`) where a `$HOME/package.json` caused silent digest failures.
`package.json` pins `googleapis@173.0.0` with a committed `package-lock.json`.
Deleting it breaks `/gdoc` until someone re-runs `npm install`.

**Recommended remediation — prune, don't delete** (NOT RUN):

```bash
# Reclaim ~half the tree by dropping docs/tests from the dependency install.
# Regenerable at any time via: cd ~/.claude/skills/gdoc && npm install
cd /home/ubuntu/dotfiles/agents/skills/gdoc && npm prune --omit=dev && \
  find node_modules -type f \( -iname '*.md' -o -iname 'CHANGELOG*' \
    -o -iname 'AUTHORS*' -o -iname '*.map' \) -delete
```

If Zig prefers zero cleverness, the honest alternative is **do nothing** —
the git posture is already correct and the context leak is confined to
`find`-based introspection.

**Classification: LOCAL-FACT (KEEP).** The `.gitignore` entry and the
SKILL.md paragraph explaining why the install is local are both irreducible
facts about how `/gdoc` runs.

---

## 3. Reference-material table

Every reference file's "cited?" column was checked with
`grep -F "<relpath>" <skill>/SKILL.md`; "reads" is actual Read-tool
invocations,
`grep -rhoF '"file_path":"/home/ubuntu/.claude/skills/<rel>"' --include='*.jsonl' ~/.claude/projects | wc -l`
(both symlink and real-path forms summed).

| Skill | Ref words | Files | Cited from SKILL.md? | Read-tool hits (6 mo) | Verdict |
|---|---:|---:|---|---:|---|
| **gdoc** | 101,781 | 135 | n/a — all `node_modules` | 0 | DEAD WEIGHT, inert (§2) |
| **impeccable** | 18,479 | 21 | yes (foundations by name; operations via `reference/operations/$operation.md` wildcard, SKILL.md:41) | 7 foundations: 1–7 each; 6 ops: 1–2; **8 ops: 0** | **progressive-disclosure win**, partially unexercised |
| **talk** | 10,411 | 9 | yes — all 9 by full path | 1–3 each | progressive-disclosure win |
| **research** | 6,488 | 9 | yes — all 9 by full path | 2–8 each | progressive-disclosure win |
| **zig-voice** | 5,040 | 4 | yes — all 4 | 1–4 each | progressive-disclosure win |
| **cfp** | 4,704 | 5 | yes — all 5 by full path | 4–7 each | progressive-disclosure win |
| **dive** | 4,513 | 3 | yes — all 3 by full path | asana-cheatsheet 1; **report-template 0; social-post-flow 0** | mixed — see note |
| **daemon** | 3,899 | 5 | 4 by path/name; `templates/service-api.md` uncited | 3–10 each (incl. service-api 4) | progressive-disclosure win |
| **beads** | 3,537 | 4 | yes — all 4 by full path | 3–21 each | **best-in-class** |
| **gamma** | 1,956 | 2 | yes — both | 2–3 each | progressive-disclosure win |
| `scrub-secrets`/`recall`/`dream` | 120 | 3 | no — `.pytest_cache/README.md` | 0 | test-runner litter, ignore |

**The 10 files with zero Read-tool hits in six months** (8,545 w):
`impeccable/reference/operations/{overdrive,optimize,normalize,harden,extract,critique,colorize,clarify}.md`
and `dive/reference/{report-template,social-post-flow}.md`.

Two important caveats before calling these dead:
1. `/impeccable` dispatches operations by name — 6 of 14 ops *have* been read,
   proving the mechanism works. The other 8 are unexercised **inventory**, not
   broken wiring. Cost is zero until invoked; that is the whole point of
   progressive disclosure.
2. `dive`'s two zero-read files are cited by full path in its SKILL.md and
   `/dive` is an active scheduled loop. Zero Read-tool hits with a live
   consumer is more likely an inlined path than genuine death.

**Bottom line: the legitimate 63,895-word reference corpus is essentially
all correctly wired.** 63 of 63 files are reachable; 53 have been read at
least once. This is the pattern to expand, not cut.

---

## 4. Project-skill table (overlap with the 37 global skills)

"Transcripts" = files mentioning `skills/<name>/SKILL.md`.

| Repo | Skill | Words | Overlaps global | Transcripts | mtime | Verdict |
|---|---|---:|---|---:|---|---|
| aaif | housekeeping | 333 | `/housekeeping` — **supplements, not duplicates** (aaif-specific index-drift lint only) | 140 | 07-17 | LOCAL-FACT, KEEP |
| aaif | aaif-{blog,brand}-guidelines | 1,685 | `/zig-voice` (different byline — AAIF org voice) | 14–16 | 06-29 | LOCAL-FACT |
| aaif | aaif-radar / aaif-review / submission / research-paper | 6,297 | partial `/cfp`, `/dive` | 10–28 | 07-16→25 | LOCAL-FACT |
| aaif | agentgateway / amplify / camp-publish / storybook-header | 6,363 | none | 5–17 | 07-09→17 | LOCAL-FACT |
| linearb | apex, imc, bootstrap-imc, campaign-builder | 20,530 | none (LinearB GTM) | 12–122 | 07-17→30 | LOCAL-FACT |
| linearb | linearb-brand / linearb-positioning / lb-editorial-brief-builder | 25,859 | `/zig-voice` (corp voice ≠ Zig's byline — correctly separate) | 41–123 | 07-17 | LOCAL-FACT |
| linearb | lb-demo-flow-builder | 133,855 | none | 39 | 07-10 | **progressive-disclosure win** (4,076 w SKILL.md over 129,779 w refs) |
| linearb | vps | 4,930 | `/nginx` partial | 37 | 07-31 | LOCAL-FACT |
| explore | ab | 175,504 | none (1,809 w SKILL.md + 173,695 w eval corpus) | 74 | 07-17 | **progressive-disclosure win** |
| explore | daily-digest | 10,172 | `/pulse` (specialised pulse) | 112 | 08-01 | LOCAL-FACT, **graduation candidate** |
| explore | zig-zone | 7,192 | none | 61 | 07-26 | LOCAL-FACT, **graduation candidate** |
| explore | graduate / databases / pico-serve / zettel-search | 12,157 | none | 5–37 | 07-08→08-01 | DEAD WEIGHT by toybox criterion (§5) |
| explore | pico-audit / zig-computer-audit | 9,624 | none | 43–69 | 07-08→26 | LOCAL-FACT |
| autonoveld | **heartbeat** | 1,103 | **`/pulse` — explicitly superseded** | 66 | 07-26 | **STALE** (retired stub, self-labelled) |
| autonoveld | write / mail / daily / conceive / learn / learn-voice / feedback | 12,323 | `learn-voice` ↔ `/zig-voice` (fictional-character voice — distinct) | 10–26 | 04-25→07-28 | LOCAL-FACT; `feedback` (297 w, mtime **04-25**) is the oldest artifact in the fleet |
| vs14d | 9 skills | 9,298 | `vs14-voice` ↔ `/zig-voice` (product voice); `changelog` ↔ `/commit` (partial) | 10–33 | 07-27 | LOCAL-FACT |
| picod | ha-{config,serve,ssh} | 5,856 | `pico-serve` in toybox — **near-overlap** | 22–27 | 07-26→27 | REDUNDANT risk — see cut #6 |
| andrewzigler3 | zettelkasten | 3,264 | none | 25 | 06-28 | LOCAL-FACT |
| investd | zettelkasten | — | **symlink** → `andrewzigler3` | 25 | 06-28 | **correct engineering — zero duplication** |
| investd | investd-{coach,review} | 6,016 | none | 4–5 | 07-31→08-01 | LOCAL-FACT (new) |
| harnessd | harness-monitor / harnessd-contrib | 4,381 | none | 4–28 | 07-16→31 | LOCAL-FACT |
| hevyd | coach | 5,133 | none | 23 | 07-27 | LOCAL-FACT |

**The overlap finding is a good-news finding.** I expected duplication and
found almost none. The one true cross-repo duplicate candidate
(`zettelkasten` in two repos) is a **symlink**, verified by
`diff -rq` (`IDENTICAL TREES`) plus `ls -la` showing
`zettelkasten -> ../../../andrewzigler3/.claude/skills/zettelkasten`.
The voice skills (`zig-voice` / `linearb-brand` / `vs14-voice` /
`learn-voice` / `aaif-brand-guidelines`) look redundant by name but are five
genuinely different bylines — correctly separate per `/zig-voice`'s own
"never for work artifacts" scope rule.

Only **one** genuine REDUNDANT/STALE item surfaced: `autonoveld/heartbeat`,
which is a self-labelled retired stub whose own frontmatter reads
`RETIRED 2026-07-26 — do not invoke`.

---

## 5. The toybox report

### Is the tracking hook firing? **YES.**

- Hook exists: `/home/ubuntu/dotfiles/agents/hooks/toybox-usage.sh` (1,358 b).
- Wired in **both** `~/.claude/settings.json:66` and
  `dotfiles/claude/settings.json:66` as a PostToolUse command.
- Logic reviewed: fires on `Read` whose `file_path` matches
  `$HOME/explore/.claude/skills/*/SKILL.md`, and **excludes** reads whose
  `cwd` is inside `~/explore` ("home turf is not usage"). Correct
  implementation of the documented criterion.
- **Most recent entry: `2026-08-01 ab <- /home/ubuntu/dotfiles`** — today.
  The mechanism is live and the graduation criterion remains measurable.

This was the flagged risk in the brief; it is **not** a finding. The
mechanism works.

### `USAGE.log` analysis (10 entries)

| Toybox skill | Cross-umbrella loads | Consumers | Verdict |
|---|---:|---|---|
| zig-zone | 4 | vs14d | **graduation candidate** |
| daily-digest | 3 | linearb ×3 | **graduation candidate** |
| ab | 1 | dotfiles (2026-08-01) | watch |
| pico-audit | 1 | vs14d | watch |
| zig-computer-audit | 1 | vs14d | watch |
| **databases** | **0** | — | DEAD WEIGHT by stated criterion |
| **graduate** | **0** | — | DEAD WEIGHT by stated criterion |
| **pico-serve** | **0** | — | DEAD WEIGHT by stated criterion |
| **zettel-search** | **0** | — | DEAD WEIGHT (but created 2026-08-01 — too new to judge) |

Caveat worth stating plainly: the log has only 10 rows and the hook dates to
2026-06-09. A 0 means "no *recorded* cross-umbrella read," and the two audit
skills are inherently single-consumer. Treat 0 as *no evidence of demand*,
not as *proof of uselessness*.

### Is `INDEX.md` accurate? **YES — 9/9, exactly.**

`ls -d ~/explore/.claude/skills/*/` yields
`ab, daily-digest, databases, graduate, pico-audit, pico-serve,
zettel-search, zig-computer-audit, zig-zone` — and `INDEX.md` lists those
same nine, no phantoms, no omissions.

### Bonus: `TOOLKIT.md` is also exactly accurate

`comm` of on-disk skill dirs against TOOLKIT headings: **37 vs 37, zero
difference in both directions.** At 4,748 words it indexes 100,217 words of
`SKILL.md` plus 63,895 words of reference — a **~21:1 compression ratio** —
and it is the single most-read file in the fleet (**220** Read-tool
invocations, 4× the next). This is the harness's best-executed idea.

---

## 6. Top 10 cuts by leverage

Ordered by (words removed × confidence), not by word count alone.

| # | Cut | Words | Class | Confidence |
|---|---|---:|---|---|
| 1 | **Stop counting `gdoc/node_modules` as harness content.** Not a deletion — a measurement fix. Every `find`-based audit of the skill tree must exclude it (as the brief's own 165,662 shows). | 101,781 apparent | DEAD WEIGHT (inert) | **High** |
| 2 | Prune docs/changelogs from `gdoc/node_modules` (§2 command). Reclaims ~100 MB; regenerable by `npm install`. | 101,781 real | DEAD WEIGHT | Medium |
| 3 | Delete `autonoveld/.claude/skills/heartbeat/` — self-labelled `RETIRED`, superseded by `/pulse`. Keep 3 lines of its "where did it go" map in `autonoveld/refs/pulse.md`. | 1,103 | **STALE** | **High** |
| 4 | Retire toybox `graduate` — 0 cross-umbrella loads and its stated purpose (hoisting AAIF → `~/aaif`) is **complete**; `~/aaif` exists as a top-level repo. A finished one-shot migration runbook. | 3,680 | STALE | **High** |
| 5 | Delete the 3 `.pytest_cache/README.md` files under `scrub-secrets`/`recall`/`dream` — test-runner litter inside the skill tree. | 120 | DEAD WEIGHT | **High** |
| 6 | Reconcile toybox `pico-serve` (0 loads) against `picod/ha-serve` — two tailnet-deploy skills, one of which has a real consumer. Merge into `picod`. | 1,305 | REDUNDANT | Medium |
| 7 | **Graduate** `zig-zone` (4 loads, vs14d) and `daily-digest` (3 loads, linearb) to the global set. The criterion is met; not graduating them is the actual debt. *This is an addition, not a cut* — but it's the highest-leverage action here. | +17,364 | — | **High** |
| 8 | Decide `databases` (0 loads, mtime 07-08) — either wire it into a real consumer or drop it. | 9,268 | DEAD WEIGHT | Medium |
| 9 | Review `autonoveld/feedback` (297 w, mtime **2026-04-25** — 3 months stale, oldest in fleet) against current autonoveld reality. | 297 | likely STALE | Medium |
| 10 | Add `reference/` splits to the 4 largest ref-less SKILL.md files: `desk` (9,772), `pulse` (6,158), `housekeeping` (3,310), `orchestrator` (3,138). Same *expand-progressive-disclosure* move as #7. | ~22,000 restructured | CTX-SCARCITY inverse | Medium |

Cuts 3+4+5+9 are the only unambiguous deletions: **~5,200 words**, all
high-confidence. That is the honest size of the "stale cruft" problem in
this corpus — small.

---

## 7. What I would NOT touch, and why

Zig's constraint — *"DO NOT clear things just to clear them"* — binds hard
here, because **the two biggest numbers in this audit are both healthy.**

**1. The 63,895-word legitimate `reference/` corpus — expand it, don't cut
it.** All 63 files are cited from their SKILL.md; 53 have been read at least
once in six months. This is textbook progressive disclosure: a small
always-loaded surface (`TOOLKIT.md`, 4,748 w) over a large on-demand body.
The words cost nothing until loaded. `beads/reference/handoff-templates.md`
(21 reads) and `daemon/reference/pwa-cockpit-push.md` (10 reads) are the
proof the pattern pays.

**2. `impeccable`'s 8 never-read operation playbooks.** These look like the
most cuttable thing in the report and are the trap. `/impeccable` loads
`reference/operations/$operation.md` **dynamically** (SKILL.md:41), and 6 of
14 ops *have* been read — so the wiring is proven. The other 8 are
unexercised inventory with zero standing cost. Cutting them removes
capability, saves no context, and is exactly "clearing to clear."

**3. `explore/ab/evals/` (173,695 w) and `linearb/lb-demo-flow-builder/references/` (129,779 w).**
Together 66% of all project-skill words, and both are the *right* shape:
1,809 w and 4,076 w of SKILL.md sitting over large committed corpora. `ab`'s
eval cases are a **process artifact** — per MEMORY's "preserve process
artifacts," the research record is as load-bearing as the result. Deleting
committed eval corpora destroys the A/B baseline.

**4. `gdoc/node_modules` itself.** It is a documented, deliberate,
self-contained dependency install with a prior incident (`dotfiles-1ag`)
behind the decision. Already gitignored with an explanatory comment; never
in history; invisible to Grep. **The correct fix was already applied before
this audit.** Deleting it breaks `/gdoc`.

**5. Five apparently-redundant voice skills.** `zig-voice`, `linearb-brand`,
`vs14-voice`, `learn-voice`, `aaif-brand-guidelines` — five bylines, five
skills, correctly separate. Merging them would violate `/zig-voice`'s own
scope rule.

**6. The `investd` → `andrewzigler3` `zettelkasten` symlink.** Verified
identical; it is one skill, shared correctly. Nothing to deduplicate.

**7. `aaif/housekeeping` (333 w).** Reads as a global-skill duplicate; is
actually an aaif-path-specific index-drift lint that explicitly says it
supplements the global ritual. LOCAL-FACT.

### The meta-finding

I went looking for bloat in three places and found it in **one**
(`node_modules`, already handled) plus **~5,200 words** of genuine stale
matter. The tracking mechanism the brief suspected had died is **firing
today**. Both indexes (`INDEX.md` 9/9, `TOOLKIT.md` 37/37) are **exactly
accurate** — a rare state for hand-maintained indexes and worth naming as a
success of `/housekeeping`.

The real debt in this corpus is not bloat. It is **two toybox skills that
have met the documented graduation criterion and haven't graduated**
(`zig-zone`, `daily-digest`). The harness is measuring correctly and not
acting on the measurement — a smaller problem than bloat, but the one that
actually needs a decision.
