---
description: The EXECUTOR loop of the research lab — dive ONE lead, bounded, surface and log it. Multi-source research-and-compile: given a list of URLs and an Asana task, fetches everything in parallel and synthesizes a structured plaintext report into the task description. Two output shapes — **archival** (creates a `~/explore/<topic>/` folder under the explore umbrella for the compendium) or **publishing** (creates a subtask with a Zig-voice LinkedIn-ready post + randomize-driven image attachment). Bridges /zig-voice + /randomize + /openrouter + the Asana fleet proxy in one canonical flow. Distinct from /grok (in-repo code reading) — /dive is for external-topic research; distinct from /desk, which ALLOCATES rather than executes.
when_to_use: User says "dive [topic / list of URLs]", "explore [topic]", "research these and put it on Asana", "look into [N URLs] and tell me what to learn", "do the same treatment for [task]"; or the `dive` pulse row fires. Anytime the user hands over multiple sources and an Asana destination.
argument-hint: "<asana-task-gid> <url> [<url> ...]"
allowed-tools: Bash(curl *) Bash(jq *) Bash(python3 *) Bash(openssl rand *) Bash(file *) Bash(/home/ubuntu/dotfiles/agents/skills/openrouter/*) WebFetch
---

# /dive — Multi-source research + Asana compile + optional post deliverable

**`/dive` is the lab's EXECUTOR.** `/desk` allocates — it decides what is
worth funding; `/dive` executes — it digs into ONE lead. The verb is
transitive and **bounded**: you dive a lead, you *surface*, and you log
what you found. That boundedness is the time-box discipline, encoded in the
name rather than argued for in prose. A dive that never surfaces is the
failure mode; see `.claude/practices.md` "Time-box the exploration anyway."

(Renamed from `/explore` on 2026-07-26 — bead `explore-mqvu`. The umbrella
repo is still `~/explore`, and an entry in it is still an *exploration*;
only the LOOP took the new name. "Lab" names the institution, never a loop.)

Codifies the pattern so future sessions don't drift, especially around the
Asana plaintext discipline, the image generation that has to stay specific
(not abstract), and the cross-skill bridges to /zig-voice + /randomize +
/openrouter.

## CRITICAL: voice scope per output

This skill produces TWO kinds of artifacts. They get different voices.
Conflating them is the most common failure mode and a real one — caught
on 2026-05-07 after multiple Asana descriptions drifted into zig voice
("u" / "ur" / "w/" / "btw") that read as sloppy on work artifacts that
other humans and agents need to read.

**Asana task descriptions, research reports, comments on non-post tasks,
chat replies to the user, and any other work artifact** → CLEAN
PROFESSIONAL PROSE. "You" not "u." No deliberate stylization. Direct,
concise, neutral. These get read by hiring managers, coworkers, future
agents, and people who expect a professional register.

**The LinkedIn post deliverable in Step 6c (post comment on a subtask
named `LinkedIn post: ...`)** → FULL ZIG VOICE. This is the only place
zig voice applies. The post is content the user will publish under his
name; everything else is supporting infrastructure.

Apply the test before writing any text: "Will the user publish this
verbatim under his name?" If yes → zig voice. If no → clean prose.

See `/zig-voice` SKILL.md "SCOPE" section for the broader rule.

## Three modes

| Mode | When | Output |
|---|---|---|
| **Report-only** | User wants compiled findings, no follow-on artifact, no archive | Asana task description updated w/ structured plaintext report |
| **Archival (umbrella-folder)** | User says "explore X and put it in a folder", or the Asana task is on the personal "Vibes" board pointing at a specific topic worth archiving (e.g. Zero Native, Tolaria) | Asana task description updated **AND** a `~/explore/<topic>/` folder created with CLAUDE.md + FINDINGS.md + refs/ |
| **Report + post deliverable** | User says "do the same treatment", "make a post about it", or "put a post on a subtask" | Report on parent task + a subtask w/ LinkedIn-ready Zig-voice post (as comment) + randomize-driven specific-subject image (as attachment) |

Default to **report-only** unless the user explicitly asks for an archive or a post. The three modes can compose (an archival run can also produce a post if the topic warrants), but most invocations are one of them.

## Effort — search at `high`, brainstorm HOTTER

- **Run the research at `high`** — the session default, and the vendor
  default on Opus 5. **Do NOT escalate the search/fetch fan-out.** Opus 5
  returns `400 … effort 'xhigh' is not supported when thinking is disabled`
  and Claude Code disables thinking on the **WebSearch** path, so a
  searching step raised to `xhigh`/`max` loses search entirely — and loses
  it *silently*, answering from in-weights knowledge instead. For the skill
  whose whole job is searching, escalating the search step is the one move
  that breaks it. (See AGENTS.md "Effort".)
- **Add a divergent `max`-effort ideation pass.** Beyond cataloguing "what
  is this," every archival exploration gets a fresh, **max**-effort
  brainstorm — *"what's the novel opportunity here — an ENTIRELY NEW idea
  this sparks (tied to nothing yet); a non-obvious interlink to another
  exploration or an open-ended bead that forms a deeper context; a thing
  worth building; an application to an arc Andrew works on now; OR simply
  why this is genuinely interesting on its own terms? Lead with CURIOSITY —
  don't force a tie-back to a real project here."* — as a Workflow
  `agent(…, {effort:'max'})`, ideally a fresh unpolluted agent so it isn't
  anchored to the convergent writeup (or to the example projects already
  sitting in `~/explore`). **`max` is safe here precisely because this pass
  reasons over the corpus you already gathered — it doesn't search.** Hand
  it the material, not a search task. Fold its best ideas into FINDINGS under a "Novel
  opportunities" heading. This is where the exhaustive upfront brainstorm
  Andrew wants actually lives — don't skip it for researchable topics.
  **Where that upside can land (including nowhere but a genuinely new idea)
  is governed by the next section — read it before prompting the ideation
  agent.** (For re-examining ALREADY-finished explorations, use `/elevate`.)

## Where the opportunity can land — lead with curiosity, not a tie-back

The `Novel opportunities` pass's FIRST job is to be **curious**, not to find a
home for the finding on this machine. **Over-anchoring to the real example
projects here is how novelty gets missed** (Zig, 2026-07-13): if every
opportunity has to cash out as "a move for LinearB / the harness / a live `~/`
arc," the ideation collapses to the modal tie-back and the genuinely new idea
never gets said. So the ideation agent ranges across **all** of the following
with **no default ranking** — explicitly do not privilege the active-arc one.
It mirrors the same steer in `/desk` and `/elevate` ("Where the upside can land");
keep all three in sync.

- **An entirely NEW idea.** Net-new — a thing worth building or exploring that
  this finding *sparked*, tied to nothing already here. Novelty is a
  first-class output, not a consolation prize. Say it even when it connects to
  nothing on the machine.
- **An interlink that forms a deeper context.** Connect the finding to *another
  exploration* (the Step 3.5 siblings / `Related explorations`) **and to
  open-ended beads** — proposed-but-not-done ideas in `br` (`explore:` /
  `desk:` / legacy `elevate:` / `human:` threads). Two half-ideas that meet become one bigger
  opportunity; a finding that hands an open bead its missing piece is worth more
  than either alone. Interlinking the compendium into deeper contexts is the
  whole reason it lives in one place — hunt these **actively**, not just the
  nearest sibling.
- **An application to Andrew's active work — when it's real.** Some findings
  genuinely land on what he works on now (derive it by recency each run — git
  activity + mtimes across `~/`, `~/explore`, `~/linearb`, `~/explore/aaif`; the
  usual hot arcs are LinearB / `~/explore/aaif` / the harness / recently-touched
  `~/explore`). When one does, name the concrete move. But this is **one** valid
  landing, not the preferred one.
- **Interesting for its own sake.** Cool, beautiful, clarifying, or just worth
  understanding. A `Novel opportunities` section may legitimately be "no build;
  the value is comprehension" plus a genuinely-curious thread. Comprehension is
  the deliverable (see `~/explore/CLAUDE.md`); the harvest is a bonus, not a tax.

**Three guards stay hard:**

- **Don't manufacture a tie-back.** A forced connection to LinearB / the harness
  / a `~/` project is worse than an honest "this sparks a new idea with no home
  yet" or "this is here because it's interesting."
- **"NO adopt" is not "NO build" — hold the two questions apart.** "Don't adopt
  *this artifact*" (a 2-commit repo, a WASM lib, a commercial engine, a runtime
  mismatch) must NOT silently become "there's nothing to build here." Ask the
  second question *separately*: is there a transferable **method, pattern, or
  primitive** worth building — one that dodges the artifact's runtime wall? A wall
  for the tool (weights, WASM, a paywall) is rarely a wall for the pattern (a
  prompt convention, a skill-loader, an on-device primitive, a Generator/Verifier
  loop). The tell: a verdict that jumps from "runtime mismatch / immature repo"
  straight to "no build" without ever weighing the method on its own. (Caught
  2026-07-13 by the curiosity re-exam: reflexive "NO harness build" buried ~3
  buildable experiments — colibrì's skill-loader, kapa's judge primitive,
  ternlight's embedder — each conflating a real runtime wall with a
  substrate-independent pattern.)
- **The build PROJECTS are tabled — the CONCEPTS are not.** The **Hermes /
  MUD-golem / local-coding-models / Hermes-local BUILD PROJECTS** are tabled
  (2026-06-29): don't frame an opportunity as advancing or reviving *them*. But
  that tabling is about those named projects + local models — **not the concepts
  they happened to touch.** An **agent-sim / simulation / agent-toy / agent-pet**
  idea, a memory idea, a loops idea is **active** even though the golem also did
  it — route it to a general harness move or a net-new build, never into the
  tabled bucket. (The tell you've over-tabled: writing "tabled *agent-sim* arc"
  or calling a sim/pet build "not a live destination." Zig flagged exactly this
  on `subterrans`, 2026-07-13.) The golem/MUD stays a *source* to reason from;
  frontier-model versions (subscription, no local model) dodge the tabling
  entirely.

The net: **always** interlink into the compendium (siblings **+ open-ended
beads** → deeper contexts), **freely** propose entirely new ideas and
interesting-for-its-own-sake threads, and land on active work **only when it's
real** — never forced, never at the tabled build projects.

## Archival mode — the commonplace book (umbrella-folder pattern)

`~/explore/` is Zig's **commonplace book — a modern zettelkasten**. The unit is
**intrigue**: he dumps a link or resource that pulls at him in order to bring it
into his world, learn it, **see what resonates, and innovate on it**. The
deliverable is comprehension + a networked web of interests, not a verdict.
Tool-evaluation ("should I adopt X") is *one shape an entry can take* — never the
spine; treating it as the spine is what flattens a hobby/idea/craft entry into
"what's the harness move" (the qertaasi failure). Lead with what the thing IS and
why it's interesting on its own terms.

When the task is to bring an intriguing topic into this compendium (recent examples: `~/explore/zero/`, `~/explore/tolaria/`), the canonical output shape is:

```
~/explore/<topic>/
├── CLAUDE.md          # orientation: what this is, why, how to navigate
├── FINDINGS.md        # the writeup — the deliverable for future-you
└── refs/              # primary source captures (one .md per source)
    ├── <source-1>.md
    ├── <source-2>.md
    └── ...
```

**Workflow within archival mode — the tick ORCHESTRATES; a fresh, blank-context subagent GENERATES.** This is cognitive isolation, and it's just the `/dispatch` + `/orchestrator` pattern pointed here: the running session never generates the take from its own corpus-marinated context — it *steers* a new, clean session that does. Every session decides how it steers the next.

1. Run Steps 1-3 (verify Asana, fetch URLs) and write each source's capture to `refs/<source-slug>.md` (one per primary source). **Capture the real source text VERBATIM by default** under fair use — the captures are the durable evidence base *and* what `bin/verify-quotes.py` greps every FINDINGS quote against, so a paraphrased capture silently defeats quote-verification (the archive's durability claim fails the day the live page moves). Flag any file that does NOT stand in for its whole source with a first-line header `capture: extract` plus the capture-date + source URL — that marker tells `verify-quotes.py` to downgrade its no-hits to warnings instead of false-failing. **Three honest reasons take that same marker**, and naming which one applies is the point of the file: (1) the source was **too large to mirror**, so you archived a partial slice; (2) the source **could not be retrieved at all** — a block, a paywall, a 403, a dead link — so what you archive is the attempt, its outcome, and what the writeup therefore does not rest on (worked example: `token-relay-economy/refs/socradar-dark-token-economy-NOT-CAPTURED.md`); (3) the source is retrievable but **not redistributable**. **Optionally, name which one machine-readably** — a parenthetical immediately after the marker, drawn from a **closed vocabulary of exactly three tokens**: `capture: extract (oversized)` / `(unretrievable)` / `(non-redistributable)`, with any explanation of your own after a comma or a spaced dash (`capture: extract (unretrievable - Cloudflare interstitial, 2026-07-27)`). That is what lets `check-captures-declared` print a breakdown, so a later sweep can count truncations separately from absences instead of opening every file (`explore-a1j1`). **This is OPTIONAL and omitting it is not an error**: bare `capture: extract` stays correct forever and is the right form when you don't want to commit to a category, and because the vocabulary is closed, any other parenthetical (`capture: extract (HTML-stripped)`) reads as ordinary prose exactly as it does today. Note this trades away Step 4b-i: an entry holding any `capture: extract` file **cannot** also declare `refs/.captures-complete` (that combination is a hard config error), so reach for the marker only when the archive really is incomplete for one of those three reasons — never as a way to skip a mirror you could have made. **A FOURTH token, `derived`, says something different in kind** — not "this mirror is incomplete" but **"this file is not a capture of a source at all."** It is for synthesized secondary material: a research agent's fan-out summary, a multi-outlet WebSearch digest, anything whose text you wrote rather than fetched. Such a file wears `capture: extract` today only because nothing else stops a mirror-check treating it as a mirror, which makes an entry padded with agent-synthesized research read identically to one holding honest partial mirrors. So write `capture: extract (derived - research agent synthesis, 2026-07-26)` (same anchored parenthetical, same optional prose after a separator, same closed vocabulary — five real files carry it, `explore-b2j8`), and `check-captures-declared` reports it on its **own** line, `NOT SOURCE CAPTURES: n derived.`, never summed with the three reasons. It changes no verdict and no exit code either; `/desk` §5's `### EVIDENCE LAYER` is what reads it corpus-wide. These captures are the raw material.
2. **Generative pass — dispatch a fresh, blank-context subagent** (`/dispatch`). Hand it: the topic + the `refs/` captures + a **specifically-tuned prompt** — *"what IS this, why is it interesting, what resonates, what would you innovate on — **on its own terms**; lead with curiosity."* Run it at **`max`** for the divergent ideation. **Do NOT give it the compendium prose** — marinating a fresh take in ~100 prior FINDINGS' house-style is exactly what over-rotates it to the modal harness tie-back (the qertaasi failure). Its return **is** the FINDINGS body + the `Novel opportunities`.
3. **Connective pass — orchestrator, AFTER the take exists, via CLEAN essences only.** *Now* consult the compendium for links: read `CHILDREN.md` / `INDEX.md` **essences** (the clean connection map), **not** the verbose FINDINGS bodies. Add the `Related explorations` links + any genuine cross-interlinks. This is the zettelkasten step — it connects the take without re-styling it.
4. **Assemble `FINDINGS.md`** = the subagent's take (body + `Novel opportunities`) + the connective `Related explorations` + the frontmatter. Write the `what:` yourself here (orchestrator step — this is where the gitflow tick's bloat slipped through): a **tight 1–2 sentence hook** — what it is + why it's interesting — **never** an abstract, **never** a forced harness tie-back (see `.exploration-meta/README.md` "The `what:` discipline"). A harness/active-arc note in the *body* is conditional the same way: include only when genuine; otherwise "no harness tie-back — interesting on its own terms," never manufactured.

   ⚠️ **4a. `what:` and `index_bullet` are PUBLISHED COPY, not a summary — hedges must survive the compression.** These two fields are the one part of an exploration that *travels*: `gen-index.py` propagates them **verbatim** into `CHILDREN.md` and `INDEX.md`, where **no surrounding hedge follows**, and Step 3.5 tells the *next* exploration's connective pass to read those **essences** rather than the bodies — so an overclaim here seeds the next entry's framing. They are the most-read and least-reviewed copy in the compendium, and they take the **same evidence rules as the body**.

   The failure is structural, not careless: a blank-context subagent writes the body under heavy evidence discipline, then **you** write the metadata afterwards, compressing under length pressure — and compression is exactly where a hedge dies. **A claim too long to carry its hedge must be NARROWED, not un-hedged** ("the entire UI *chrome*" — not "built **entirely** out of plugins"; "two places… and a third unresolved" — not "three places"). Caught by the scrutiny gate on two consecutive ticks, 2026-07-27 (`explore-3ftu`) — the first of those entries reproduced its *own* headline finding in its own metadata.

   **4b. Run the two local checks, and fix what they find BEFORE the scrutiny gate and the commit.**

   ```bash
   python3 bin/check-frontmatter.py <topic>   # advisory — absolutes the body qualifies (4a)
   python3 bin/verify-quotes.py <topic>       # FAIL = a quoted span matching no refs/ capture AND no cited bead
   ```

   These are cheap and local, and that is the point: they let the mandatory `/scrutinize` pass spend its effort on interpretation and premise instead of re-fetching sources to string-match quotes.

   **4b-i. Settle what you claim about your captures — this is what makes the check mean anything, and it is GATED.** `verify-quotes` is **advisory by default**: a quote matching no capture is a WARN (`unverified`), not a FAIL. An entry opts INTO hard-FAIL semantics by dropping a `refs/.captures-complete` marker file (same idiom as `refs/.handoff-per-window`). **A `/dive` archival entry SHOULD declare it**, because you just captured every source verbatim in Step 1 — that is precisely the claim the marker makes. Add it once `verify-quotes` is clean, and from then on a FAIL in your entry is a real defect rather than a shrug.

   If a source genuinely could not be mirrored, you mark that capture `capture: extract` instead (Step 1) and do **not** declare — that is equally settled, and the two are mutually exclusive. What is NOT acceptable is asserting neither, because `verify-quotes` structurally cannot fail an entry that claims nothing, however thin its archive. Check with:

   ```bash
   python3 bin/check-captures-declared.py <topic>   # 0 = settled · 1 = asserts nothing · 2 = contradictory
   ```

   This is in the `dive` **done-proof** (`refs/pulse.md`), so a tick cannot log `done` without settling it. The ~86 unsettled historical entries are deliberately untouched — the backlog is measured, not fixed (`explore-gi0p`).

   Why the default is advisory (`explore-w4zd`, measured 2026-07-27): across the 117 entries with a `refs/`, **95% of the old FAILs were the author's own words** — coined thesis lines, Vibes-card and bead titles, quotes from internal docs, paraphrase-with-emphasis — not fabricated source quotations. Nothing syntactic separates those from a real quote, and quote length does not either (median 9 words passing vs 7 failing). So a no-match means *unverifiable*, not *wrong*, unless you have asserted your captures are complete. **Do not "fix" a WARN backlog by adding the marker to old entries or by backfilling `capture: extract` — both are the bypass.** `--strict` audits the whole backlog in one flag (3,365 spans corpus-wide today); that number is a measurement, not a target.

   **Reading their output honestly — both are noisier than their exit codes suggest:**
   - `verify-quotes` resolves a quote against `refs/` first, then against the **bodies of beads the entry cites** (printed as `matched bead:<id>`), so interlinking with a bead quotation is not a failure. It degrades to WARN, never a false FAIL, if `br` is unavailable; `--no-beads` restores refs-only matching. Its WARN tier still carries a known apostrophe-splitting false positive (`explore-yqtm`). It cannot declare completeness and hold `capture: extract` files at once — that combination is a hard config error.
   - `check-frontmatter` is **advisory only and must never gate**, but it now has **two tiers with very different precision — do not adjudicate them at the same weight**:
     - the **FAIL/WARN** tier (frontmatter absolute vs. body hedge) is the noisy one: measured precision about **1 real catch in 11 flags**. Adjudicate in five seconds from the body span it prints and move on.
     - the **ADVISORY** tier (`what:` and `index_bullet` disagreeing *with each other* about the same claim) is measured at roughly **1 in 2 — 6 true of 11 flags, firing on 11 of 135 entries** (`explore-3r9p`, 2026-07-27). **Read every one of these.** It has a much better prior because it compares two short fields covering the same ground, rather than scanning a whole body. Its residual false positives are one shape — a hedge attaching to a different noun phrase inside a well-matched pair — so check *which* claim the hedge modifies before dismissing it.
     Both tiers stay silent on the large majority of entries; that silence is the checker's main virtue, not a sign it is asleep.

   **4c. Run the mandatory `/scrutinize` pass** — a fresh, read-only adversarial reviewer on the corpus / method / interpretation (the explore CLAUDE.md scrutiny gate). **Three clauses are STANDING in that dispatch — include them every time, not when you happen to think of it:**
   - **"Verify the frontmatter is as careful as the body."** Give the reviewer the `what:` / `index_bullet` fields explicitly and tell it these propagate verbatim into `CHILDREN.md` / `INDEX.md` with no hedge following, so a hedge present in the body but stripped from the metadata is a **real finding**, not a nitpick. Both 2026-07-27 catches happened *only* because the dispatch said this; it was ad-hoc both times.
   - **"Check every characterisation of another exploration."** The `Related explorations` section makes claims about sibling entries the reviewer can open and check. A mischaracterised sibling corrupts the crawl graph, and it is invisible to `verify-quotes.py` (which only greps this topic's `refs/`).
   - **"Re-derive every number yourself."** Counts, dates, intervals and sizes are where a confident writeup is most often quietly wrong, and they are the cheapest thing for a reviewer to check independently.

   Expect **FIX-FIRST**, not SHIP, on a substantial entry — that is the gate working. Re-verify each load-bearing finding against the captures yourself before adopting it (a reviewer can also be wrong), then fix.

   **4d. Append the verdict** as a durable block at the END of `FINDINGS.md`: `## Scrutiny — <date>: Verdict: <SHIP | FIX-FIRST → addressed → SHIP | REJECT>` + a short rationale naming what changed. For a `dive` tick this block IS the machine-checkable **done-proof** the commit gate greps for (`grep -q '## Scrutiny' <topic>/FINDINGS.md`, see `refs/pulse.md` → "Done-proof") — a `done` committed without it is BLOCKED by `pre-commit-checks.sh`. This is the `explore-len0` fix: the mandated adversarial pass now leaves a trace future-you can check, instead of vanishing into the transcript. (The same verdict string closes the bead — `pre-bead-close.sh` accepts this exact form, including the `FIX-FIRST → addressed → SHIP` chain; fixed 2026-07-27, `explore-x8mj`.)
5. Write `CLAUDE.md` as the orientation file pointing future-agents at the structure.
6. Run Step 5 (POST to Asana) — mirror the FINDINGS.md content, **end with the back-pointer** `Archived: ~/explore/<topic>/ (FINDINGS.md)` so review can jump from the card to the brain.
7. Commit the folder: `git add <topic> && git commit -m ":seedling: explore: <topic> — <one-line theme>"`.
8. If `Novel opportunities` surfaced a "build/explore X" worth queueing, **append a row to the Pending table of `~/explore/refs/vibes-candidates.md`** (`date | proposed card title | one-line why | source | bead`) — don't let it evaporate, and don't leave it only in a handoff. **Never create the Asana Vibes card yourself: promotion is human-gated** (that file's header is the contract). `/desk` §5 reads Pending back to Zig weekly and puts the stale rows to him for a go/no-go, so a row parked here is queued, not lost; a "no" lands in the same file's **Dropped** table.

### Folder vs submodule — when each is right

Default: **folder**. The umbrella's CLAUDE.md documents this explicitly. Folders match the `linters/` and `shell-home-assistant/` precedent.

Submodule only when the exploration **earns** its own repo. Bar:

- **Independent activity**: the topic generates ongoing commits, not just one writeup
- **Public visibility**: external audience or contributors
- **Distinct lifecycle**: own release cadence, own issue tracker

Existing submodule examples that met the bar: `autonovel`, `smalltalk`, `fragments`, `simon-willison`, `duckdb`, `afcl`. Each has its own GitHub repo + ongoing work.

Existing folder examples: `linters`, `shell-home-assistant`, `zero`, `tolaria`. Investigation/comparison artifacts, no ongoing repo activity, fine as folders.

**Submodules are the default for `~/coding-jams/`** (each jam is an atomic submitted unit). They're the exception for `~/explore/`. Don't reach for a submodule under `~/explore/` unless the criteria above are clearly met — the cost of submodule infrastructure (separate git history, distribute discipline, CI hookup) outweighs the benefit for one-off investigations.

See `~/explore/CHILDREN.md` for the roster (the flat children table) and `~/explore/CLAUDE.md` for the naming convention (local folder drops `explore-` prefix even if remote repo keeps it).

## Inputs

1. **Asana task GID** — required. The destination for the report (description) and any subtasks.
2. **URLs** — at least 2, usually 3-6, sometimes 1 if it's a deep single source.
3. **Research question** (optional) — a specific lens. If absent, the implicit lens is "what's genuinely interesting or worth understanding here, on its own terms" — a harness/research/content or social-post angle is welcome when it's real, never forced (see "Where the opportunity can land").

## Step 1: Verify the Asana target

```bash
FLEET_URL=http://localhost:7100
FLEET_TOKEN="$FLEET_API_TOKEN"   # exported from your env — never hardcode

curl -s -H "Authorization: Bearer $FLEET_TOKEN" \
  "$FLEET_URL/api/asana/tasks/<gid>" \
  | jq '{name: .data.name, current_notes: .data.notes, assignee_section: .data.assignee_section.name}'
```

Confirms the task exists and shows what's already in `notes` (the
description) so you don't accidentally overwrite something the user
populated themselves. The `assignee_section` tells you where on the
user's personal board this lives — handy context.

See [reference/asana-fleet-cheatsheet.md](reference/asana-fleet-cheatsheet.md) for the full endpoint set, the gotchas (PUT-vs-POST-update,
strict-XML, `<br/>` self-closing), and the route handlers in lb-agent-fleet.

## Step 2: Fetch all URLs in parallel via WebFetch

Always parallelize. Each WebFetch should request structured detail —
architecture, license, benchmarks, quotes, target deployment, novel claims
vs marketing. The richer the per-source extraction, the easier the
synthesis.

If a fetch fails (403, 401, 404, partial body):

- **Try a related URL** — the canonical model card on Hugging Face, the
  GitHub repo, the company's About page.
- **Note the failure honestly** in the final report. Never paper over.
- **Ask the user** if u've exhausted alternates. They may paste back the
  contents (this session: Neuron 403'd, user pasted the article body).
- **Search adjacent sources** for the same substance.

### A failed fetch is a fact about the TOOL, not about the source

That list above is *recovery*. This is the **interpretation** rule, and it
is the one the loop keeps breaking. `/dive` already teaches the right
discipline for **absent** evidence — "no third-party benchmark was located"
is a statement about the search, not about the world. The same discipline
applies to **mangled** evidence, and it is far less intuitive: a 403, a
garbled table, or a truncated quote *feels* like data about the source. It
isn't.

- **A non-200, a parse oddity, or a truncation is a TOOL EVENT.** Record it
  as one ("WebFetch returned 403 on X"). Never restate it as a property of
  the source ("gated", "misconfigured", "malformed", "they only published a
  name and one sentence").
- **Re-verify by a second path before ANY claim that rests on a bad fetch.**
  It costs seconds: `curl -sS -I <url>` for reachability + size + type,
  `curl -sS <url>` and read the **raw markup** for structure, a different URL
  form (canonical vs mirror, `/p/<slug>` vs the SPA page) for content.
- **Structural claims require raw markup, never rendered text.** If you are
  about to say a table is malformed, a field is missing, or a layout is
  broken, parse the HTML — count the `<td>`s, read the `<colgroup>`, check
  for an explicit N/A convention. Rendered-text capture is lossy in exactly
  the way that *invents* structural defects.
- **Enumerate the source's own index before declaring a gap.** Fetching 1 of
  7 posts listed on the site's own index and then writing about what is
  "unknown" is a coverage failure wearing the costume of a finding.

**Why this is a rule and not a nicety:** skepticism has a false-positive
rate and nobody reports it. In the 2026-07-25 odyssey-ml tick the scrutiny
gate overturned two of the writeup's loudest findings, both this error — a
403 on a 28 MB PDF that `curl -I` showed as a public HTTP 200 the whole
time, and a "dropped cell" theory about a table whose raw markup is clean,
on the strength of which a credibility point was **retracted from the
vendor**. That is not noise; it is an unfair reading manufactured out of a
tool limitation. (`explore-g6v8`; inverse flavor of `explore-cdby`, "the
number is not the thing".)

## Step 3: Search for what u're missing

A good /dive run does NOT stop at the user's URL list. After fetching,
pause and ask:

- What other models / projects / standards are *adjacent* to the named
  set? (e.g., when the user named four April-2026 open models, Qwen3 +
  Phi-4 + OLMo + Granite belonged in the picture.)
- What infrastructure layer makes the named pattern possible? (e.g., for
  on-device LLMs: Ollama, llama.cpp, MLX, MLC, llamafile.)
- What are concrete consumer-facing examples already shipping the
  pattern? (e.g., Apple Intelligence, Copilot+ PCs.)
- What's the LANEAGE — what came before, what's coming next?

Cite these as a separate "u missed these" section in the report. Add
working URLs.

## Step 3.5: Consult the compendium — what do I ALREADY know that connects?

**This is the connective-tissue step. Do not skip it** — skipping it is
the single biggest historical failure of the explore loop (audit
2026-06-28, `~/explore` bead `explore-doj`: across 40 FINDINGS only 3
inter-exploration cross-refs existed, because nothing forced a new
exploration to consult its 56 siblings). Step 3 looks OUTWARD for missing
external sources; Step 3.5 looks INWARD at the brain you've already built.

Before synthesizing:

1. **Read the map.** `~/explore/INDEX.md` is the theme-clustered
   concept-map (regenerated by /housekeeping). Find the cluster(s) this
   topic belongs to and note the siblings already there.
2. **Grep the brain** for the topic's key terms across prior findings:
   ```bash
   grep -rIl -iE "<term1>|<term2>" ~/explore --include=FINDINGS.md \
     --include=CLAUDE.md 2>/dev/null | grep -v "/.beads/"
   ```
3. **Read the 2-4 most adjacent prior FINDINGS** enough to know how this
   new topic AGREES, EXTENDS, CONTRADICTS, or REMIXES with them.
4. The synthesis (Step 4) then **must** carry a `Related explorations`
   section that links those siblings with relative links AND says, in one
   line each, what the *connection* is — not just "see also." This is what
   grows a connected brain instead of a pile of folders.

## Step 4: Synthesize into the structured report

Use the canonical section headers in [reference/report-template.md](reference/report-template.md). The shape is:

```
== TL;DR ==
== What each is ==        (per-source detail)
== Pattern across them == (cross-cuts)
== Yes/no answer ==        (if user asked a specific question)
== Models/projects you missed ==
== Related explorations ==  (REQUIRED in archival mode — the Step 3.5 siblings + the connection)
== What you should learn ==
== Novel opportunities ==   (REQUIRED in archival mode — the max-effort ideation output, see Effort §)
== Possible social-post angles ==
== Sources ==
```

Don't pad. Cite what u actually found. Leave gaps as gaps. Quote
specific numbers + named individuals where they sharpen the report.

`Related explorations` and `Novel opportunities` are **required headings in
archival mode** (report-only mode may omit them). They're the two sections
that make the double loop actually compound — the first connects the brain,
the second harvests the opportunity. Historically both were skipped (0/40
FINDINGS had `Novel opportunities`); they are now first-class, not optional.

## Step 5: POST to the Asana update endpoint (NOT PUT)

```bash
# Build the JSON payload via Python — handles multi-line escaping
python3 <<'PY'
import json
notes = """<the report content>"""
with open("/tmp/explore-update.json", "w") as f:
    json.dump({"notes": notes}, f)
PY

# POST to /update — the bare /tasks/<gid> path returns 405 (see bd-wji0)
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<gid>/update" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/explore-update.json
```

**Plaintext only.** Use `notes` (not `html_notes`). The user copy-pastes
content out and HTML wrappers + `<br/>` tags become noise. Real `\n`
newlines are how plaintext line breaks travel through JSON.

The fleet auto-prepends `[claude-code via Marketing Fleet]\n` once. Don't
prepend it yourself.

**Archival back-pointer (P5).** When the run is archival, end the Asana
report body with a final line: `Archived: ~/explore/<topic>/ (FINDINGS.md)`.
The card holds the report; the folder holds the durable brain — the
back-pointer lets a review pass jump from one to the other instead of the
two drifting apart.

## Step 6 (deliverable mode only): the post-as-deliverable pipeline

When the user asks for a post deliverable, run this 4-step pipeline.
Full mechanics in [reference/social-post-flow.md](reference/social-post-flow.md).

### 6a. Create a subtask

```bash
curl -sS -X POST "$FLEET_URL/api/asana/tasks" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/subtask.json
```

Subtask name should be specific: `LinkedIn post: <topic> — <one-line angle>`.
The `parent` field carries the GID of the task u just compiled the report
into.

### 6b. Draft the post in Zig voice

Read [/zig-voice](../zig-voice/SKILL.md) before drafting. The relevant
genre is usually **builder devlog** (~200-300 words) or **interview
field notes** (~250-350 words). Hard rules to honor:

- Specific moment opener, NOT a thesis or topic
- Casual register: u, ur, w/, btw, pls, da
- Plain text only — no markdown bold/italic, plain URLs, line breaks
- Em-dash budget ~1 per 200 words in flow prose
- Selective ALL CAPS on 2-3 words
- Crystallizing flip line at least once
- Identity stamps where they fit (🐸 ✨)
- Avoid magic adverbs: quietly, deeply, fundamentally
- Avoid scaffolding: "Here's the thing", "Let's break this down", "Plot twist"
- Avoid apology-register openers
- Trust the reader — peer frame, not pedagogical

When the post is part of a series (this session: Mycroft post → Open
Models post building on it), the SECOND post should reference the first
in its opener so the narrative thread is visible.

### 6c. Generate the image via /openrouter w/ randomize-driven prompt

**The image must depict a SPECIFIC SUBJECT, never an abstract concept.**
Past sessions have drifted toward abstract/simple imagery (neural
networks, text bubbles, glowing brains) which is exactly the AI-slop
imagery the user rejects. Force specificity through the randomize roll.

Always run the canonical randomize axes in [reference/social-post-flow.md](reference/social-post-flow.md). Generate a real seed via
`openssl rand -hex 12`, do the modulo arithmetic, and write the
provenance block before composing the prompt. NEVER skip this — the
provenance block IS what makes it a real randomize.

The "Surprise me" baseline: u (the agent) and the user should not
predict what subject the randomize roll will produce. The roll forces the
subject to be specific AND surprising. If the rolled subject feels too
on-the-nose, regenerate the seed (max once).

Cost calibration: nano-banana 2 (Gemini 3.1 Flash Image Preview) actual
cost is ~$0.05-0.07 per 1K image, NOT $0.004 as the older /openrouter
docs suggest. Always state the real cost in ur acknowledgment to the
user, and don't generate variants without explicit confirmation.

### 6d. Attach + comment

Upload the image as an attachment, then post the LinkedIn-ready text as
a plaintext comment.

```bash
# Attach
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/attachments" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -F "file=@/tmp/img.png;type=image/png"

# Post plaintext comment
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/comment" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/comment.json    # {"text": "<the post>"}
```

Use `text` (plaintext), not `html_text`. Same reasoning as the description
update — the user copy-pastes to LinkedIn.

## Step 7: Brief the user

Short summary in chat:

- Where the report landed (Asana URL)
- Headline findings — the 3-5 most punchy bullets
- For deliverable mode: the subtask URL, post angle, image style, total cost
- Any fetches that failed and what u worked around
- Any models/sources u proactively added beyond the user's list

Keep it tight. The user asked for the report; the report is the output.
The chat summary is the index.

## Anti-patterns

- ❌ **HTML in Asana fields.** Plaintext only. `notes` not `html_notes`,
  `text` not `html_text`. The user copy-pastes content — HTML is noise.
- ❌ **PUT to `/api/asana/tasks/<gid>`.** Returns 405. Use POST to the
  `/update` sub-route. (Diagnosed in `bd-wji0` in lb-agent-factory.)
- ❌ **Bare `<br>` if u ever do use HTML.** Asana strict-XML rejects it.
  Use `<br/>` self-closing. (Same gotcha caught this session.)
- ❌ **Stopping at the user's URL list.** Always proactively search for
  adjacent missing sources / models / projects.
- ❌ **Padding the report.** Cite what u found. Leave gaps as gaps.
  "Couldn't fetch X, here's what I tried" beats "Likely contains X."
- ❌ **Abstract image subjects.** Skip "neural network with text bubbles",
  "glowing brain", "futuristic city of data". Force a specific subject
  via the randomize roll — a 1990s newsroom desk, a craftsman's pegboard,
  a brass apothecary jar w/ a hand-lettered label.
- ❌ **Skipping the randomize provenance block.** No block = no randomize.
  The arithmetic is what defeats prior collapse.
- ❌ **Generic emojis on bullets.** Use thematic emojis (📓 for journalism,
  🌳 for Gemma, 🪶 for Bonsai, 🤖 for agentic, 🧠 for reasoning, ⚓ for
  Water Town). Not generic ✨🚀💡.
- ❌ **Quoting vendor-supplied stats without naming the source as
  vendor-supplied.** Be honest about where numbers come from.
- ❌ **Assuming the user wants a post.** Default mode is report-only.
  Ask if u're not sure.

## Cross-skill bridges (read these before drafting)

- [/grok](../grok/SKILL.md) — **sibling skill, different scope**.
  `/grok` is for understanding code INSIDE a repo before editing it
  (read-only walk, optional `-t study` bead summarizing findings).
  `/dive` is for compiling a report on a topic OUTSIDE the repo
  (URLs, papers, products, projects). They can compose — a `/grok`
  walk's output can land inside a `/dive` folder when the topic
  spans both code and external context — but most invocations are
  one or the other.
- [/zig-voice](../zig-voice/SKILL.md) — voice rules + format-specific
  guidance for whatever genre the post is (builder devlog / interview
  field notes / narrative-story / whimsical thesis).
- [/randomize](../randomize/SKILL.md) — mandatory protocol for the image
  prompt. Real seed, real arithmetic, real provenance block. Skip and
  u've prior-collapsed.
- [/openrouter](../openrouter/SKILL.md) — image generation via
  nano-banana 2. Cost-aware. Save outputs. Note: stated $0.004/image
  cost is stale; current ~$0.05-0.07/image. Confirm w/ user before
  generating multiple.
- [/asana](../asana/SKILL.md) — the underlying fleet proxy mechanics.
  /dive overrides /asana's PUT recommendation w/ POST-/update for
  task description updates (per bd-wji0).
- [/beads](../beads/SKILL.md) — file follow-up bugs / improvements as
  beads in the appropriate repo if u catch them mid-/dive.

## See also

- [reference/asana-fleet-cheatsheet.md](reference/asana-fleet-cheatsheet.md) — fleet endpoints, route paths, the PUT-vs-POST gotcha, plaintext discipline, multipart attachments.
- [reference/report-template.md](reference/report-template.md) — canonical section structure for the Asana description.
- [reference/social-post-flow.md](reference/social-post-flow.md) — the deliverable pipeline w/ randomize image axes baked in.
