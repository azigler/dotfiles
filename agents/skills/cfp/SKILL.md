---
description: Conference proposal & paper-submission orchestrator. Bootstraps a new submission project at ~/cfp/<slug>/ with full discipline (beads, CLAUDE.md, refs/, research/), runs the interview-research-draft-critic-submit loop, and shepherds the post-acceptance pipeline. Includes a peer-reviewed-paper sub-arc (reference/scientific-paper-arc.md) for academic venues that adds revision specs, artifact bundles, and arXiv preprints. Hands off to /talk on acceptance. Delivers up-to-and-including "you have an accepted, archived, registered submission" — not the talk itself.
when_to_use: User wants to write a CFP, draft a conference proposal, submit a paper to a workshop / conference / journal, fill out a Sessionize form, or revise an accepted paper for camera-ready. Also fire when the user asks to "set up a new submission project," names a CFP deadline, or has an angle they want to fit to a conference. ALSO use as the post-acceptance shepherd — reviewer responses, camera-ready, artifact bundles, arXiv, registration. Stop at the talk-deck boundary; that's /talk's scope.
argument-hint: "[slug]"
---

# /cfp — Conference proposal & paper-submission orchestrator

## What this skill does

`/cfp` is the canonical orchestrator for the **first half** of a conference deliverable: get the proposal or paper from "I should submit something" through "it's accepted, archived, registered, and the talk-builder agent can pick up cold." The talk itself — deck, speaker notes, dry runs, day-of — is the **second half** and lives in `/talk` (a sibling skill).

This is a **fully-supported, opinionated process**. Every CFP — whether a 30-minute Sessionize form or a multi-month peer-reviewed paper — gets the same disciplined treatment: bootstrap with beads + CLAUDE.md + refs/ + research/, interview to lock decisions, capture refs verbatim, explore angles before drafting, critic-loop the draft, submit, and shepherd through post-acceptance. The skill doesn't take shortcuts. The discipline is what produces consistent, ship-able CFPs across very different venues.

What varies per CFP is the **deliverable shape** (proposal.md vs paper/) and whether the **scientific-paper sub-arc** fires (the camera-ready / revision spec / open-science artifact / arXiv pipeline that academic venues require). The sub-arc lives in `reference/scientific-paper-arc.md` and triggers automatically when the venue is peer-reviewed.

Concretely, `/cfp` covers:

| Phase | What | Skill output |
|---|---|---|
| **Bootstrap** | Create `~/cfp/<slug>/` with CLAUDE.md, beads, refs/, research/ | A scaffolded project ready for content |
| **Interview** | Lock conference, format, hard limits, voice, audience | Locked-decisions block in CLAUDE.md |
| **Capture refs** | Verbatim source material (CFP form, prior art, neighbor CFPs) | `refs/` populated, `refs/INDEX.md` if >10 files |
| **Angle exploration** | 3–5 framings; user picks; pivot to chosen one | `research/angle-options.md` + locked angle |
| **Draft** | Proposal (markdown) OR paper (LaTeX, beads-driven) | `proposal.md` OR `paper/main.pdf` |
| **Critic loop** | Read-only review passes (naive / cold reader / voice) | Iterated draft, char counts within limits |
| **Submit** | Char-count verification, owner submits via portal | Submission confirmation captured |
| **Post-acceptance (universal)** | Capture acceptance email, tag submitted commit, light revisions, registration, logistics | Acceptance archived, conference confirmed, paper preserved |
| **Post-acceptance (paper sub-arc)** | Revision spec → camera-ready → artifact bundle → arXiv (peer-reviewed venues only) | DOIs minted, preprint live, integrity check passed |
| **Handoff** | Ensure CFP folder is mineable; create `talk-<slug>/` neighbor; cross-link | `~/cfp/talk-<slug>/` initialized for `/talk` to pick up |

## Examples in the wild

The flagship case study is `~/cfp/mise/` — *Mise en Place for Agentic Coding*, accepted at VibeX 2026 (EASE 2026, Glasgow). It's the only one in this user's history that exercised the full peer-reviewed-paper sub-arc end-to-end: revision spec, camera-ready cycle, SIGSOFT artifact bundle on Zenodo, arXiv preprint with cs.SE endorsement, ORCID rendering bug, the lot. Read its `CLAUDE.md` and `.beads/issues.jsonl` for the canonical reference on the heavier sub-arc.

Other neighbors are routine CFPs that exercised the universal flow without the paper sub-arc:

- `~/cfp/o11y/` — sessionize-style proposal
- `~/cfp/github-universe-2026/` — Sandbox session with hard char limits + critic-pass discipline
- `~/cfp/talk-ai-council/` — POST-acceptance talk build (out of `/cfp` scope; lives in `/talk`)

The discipline is the same across all of them: beads, CLAUDE.md, refs/, research/, critic agents. What changes is the venue's specifics (page limits vs. char limits; markdown vs. LaTeX; whether peer review and SIGSOFT compliance enter the picture).

## When NOT to use this

- **You're building the deck for an already-accepted talk.** Use `/talk` in `~/cfp/talk-<slug>/` instead. (If the `~/cfp/<slug>/` repo exists from a prior `/cfp` run, mine it from the talk repo's `## Source material to mine` table.)
- **It's an RFC, internal proposal, blog draft, or grant.** Wrong shape — these don't have CFP forms, char limits, reviewer cycles. Use `/spec` for RFCs, plain Write/Edit for blogs.
- **The submission is too small to scaffold.** A one-paragraph lightning-talk submission doesn't need a project tree. Just type it.

## Pipeline at a glance

```
   Step 0: shape detection (new vs existing)
       │
       ▼
   Step 1: bootstrap ── ~/cfp/<slug>/, CLAUDE.md, .beads/, refs/, research/
       │
       ▼
   Step 2: interview ── lock conference / format / hard limits / voice
       │
       ▼
   Step 3: capture refs ── CFP form, prior art, neighbor CFPs verbatim
       │
       ▼
   Step 4: angle exploration ── 3–5 framings → user picks → lock title/angle
       │
       ▼
   Step 5: draft ── proposal.md (markdown) OR paper/ (LaTeX + beads pipeline)
       │
       ▼
   Step 6: critic loop ── read-only review agents (naive / cold / voice)
       │
       ▼
   Step 7: submit ── owner uploads, /cfp records the receipt
       │
       ├── REJECTED → close beads, archive, neighbor for future CFPs
       │
       └── ACCEPTED ──▼
                  Step 8: post-acceptance ── reviews / revisions / camera-ready /
                                              artifact bundle / arXiv / registration
                       │
                       ▼
                  Step 9: handoff to /talk ── create ~/cfp/talk-<slug>/, cross-link
```

## Step 0 — Shape detection

When `/cfp` fires:

```bash
# Are we already inside a CFP project?
if [ -f CLAUDE.md ] && grep -q "^# .*CFP\|^# .*Paper\|^# .*Proposal" CLAUDE.md 2>/dev/null; then
  echo "EXISTING CFP project — resume."
elif [ -n "$slug" ] && [ ! -d "$HOME/cfp/$slug" ]; then
  echo "NEW project — Step 1 bootstrap."
elif [ -d "$HOME/cfp/$slug" ]; then
  echo "RESUME existing $HOME/cfp/$slug."
else
  echo "Ask the user for a slug."
fi
```

If new: proceed to Step 1.
If existing: jump to whichever step the project is parked at (read CLAUDE.md `## Pipeline` checkboxes).

## Step 1 — Bootstrap (new project only)

This is opinionated and identical for every CFP. Don't ask "do you want beads?" — beads is on. Don't ask "do you want refs/ and research/?" — they're standard. The discipline is what makes CFPs consistent.

```bash
SLUG="<from-arg-or-ask>"
mkdir -p ~/cfp/$SLUG && cd ~/cfp/$SLUG
git init
br init                                # creates .beads/
mkdir refs research                    # standard layout

# .gitignore — beads history shouldn't track
cat > .gitignore <<'EOF'
.beads/.br_history/
EOF

# CLAUDE.md from template (see reference/claude-md-template.md)
cp ~/.claude/skills/cfp/reference/claude-md-template.md CLAUDE.md
# Then edit placeholders: {{CONFERENCE}}, {{TITLE}}, {{DEADLINE}}, etc.

# Initial commit
git add CLAUDE.md .gitignore .beads/
git commit -m ":seedling: bootstrap: new CFP project for {{CONFERENCE}}"
```

**Don't auto-fill the placeholders.** The interview (Step 2) drives that. Bootstrap leaves the template in place so the interview's answers land where they belong.

**For peer-reviewed paper venues**, also create the paper directory now so the LaTeX template is in place before drafting:

```bash
mkdir -p paper/sections paper/figures
# Drop in the venue's class file + bibstyle + a starter main.tex.
# (Varies by venue: acmart for ACM ICPS, IEEEtran for IEEE, llncs for Springer.
# Pull from a prior submission if you have one. See reference/scientific-paper-arc.md
# for the LaTeX project layout pattern.)
```

The deliverable shape (proposal.md vs paper/) is decided here based on the venue. This is not a tier — it's a deliverable type.

## Step 2 — Conference interview

Ask the user the following, in order. Each answer goes into the locked-decisions table in CLAUDE.md. Don't move on until each is filled (or explicitly marked `TBD`):

1. **Conference name + URL** + co-located parent if applicable
2. **Hard deadline** (date + timezone)
3. **Track / format** (talk / poster / demo / paper / sandbox / lightning)
4. **Hard limits** — title char limit, abstract char limit, full-paper page limit. *Get these verbatim from the CFP form; don't guess.*
5. **Audience profile** — who reviews, who attends, what level (200 / 300 / 400)
6. **Voice / tone preferences** — typically `/zig-voice` for Andrew; for other authors, ask explicitly
7. **Author angles + credibility stack** — what receipts back the proposal? (papers, awards, products, prior talks)
8. **Co-speaker** — solo or paired? Solo is the default
9. **Theme** — does the conference have a stated theme to thread through?
10. **Asana planning hub** — does the user have a planning task on Asana for this submission? (Most LinearB-fleet workflows do — a "Plan submission" or "Prepare and submit talk" task on the user's personal board, often with a parent task for the conference itself.) Capture the task gid + URL + parent gid into CLAUDE.md's locked-decisions table. The hub is **the canonical outside-the-repo milestone surface**. See "Asana planning hub" below.

**Also determine: is this a peer-reviewed paper venue?** If yes, the scientific-paper sub-arc (Step 8.5 + `reference/scientific-paper-arc.md`) becomes part of the project's pipeline from day one. Note this in CLAUDE.md `## Locked decisions` — it shapes the deliverable, the bootstrap, and the post-acceptance work.

When the user answers laconically ("AI Council, May 13, solo, 5-page sessionize, angle is Y"), don't drag them through nine questions one at a time — extract everything they gave you, fill remaining slots with `TBD`, then circle back only on what's missing. The interview is a **completeness check**, not a script. Just ensure every slot is either filled or explicitly marked TBD before drafting begins.

### Asana planning hub (canonical, not optional)

When the project has an Asana planning hub (item #10 above), `/cfp` is **beads-driven internally + Asana-driven externally**. Beads carry the per-step handoff packets between agents; Asana comments carry the per-milestone status updates the user (and other humans on their team) can read at a glance.

The contract for posting:

- **One comment per meaningful milestone.** Bootstrap, angle locked, refs captured, proposal drafted, critic pass, submission, acceptance, revision, camera-ready, registration, /talk handoff. Don't batch; don't skip.
- **Comments are plaintext.** Use the `text` field on `/api/asana/tasks/<gid>/comment`. HTML is technically supported by the Asana API via `html_text` but renders unevenly in the Asana UI and fails to copy-paste cleanly. The talk-ai-council orchestrator agent learned this the hard way (reposted multiple HTML comments as plaintext); `/talk`'s Step 9 codifies the same lesson. Use bare URLs, `\n\n` for paragraph breaks, `-` or `*` for bullets, no Markdown bold/italic (Asana strips them in plaintext).
- **Each comment includes**: the milestone, bead IDs that landed, repo paths the user can grep, links to artifacts, what's next.
- **Agent name** — set the `X-Agent-Name` header to a stable per-project name like `talk-<slug>-orchestrator` or `cfp-<slug>-orchestrator`. The fleet auto-prepends `[<agent> via Marketing Fleet]`; don't add it yourself.
- **Catching up retroactively.** If the project ran for hours before the hub was wired, post one consolidated catch-up comment summarizing prior milestones, then post per-milestone going forward. Better than nothing.

This mirrors `/talk`'s discipline (Steps 2, 9, 12 + anti-pattern). For invited-talk projects where `/cfp` and `/talk` co-locate in the same `~/cfp/talk-<slug>/` tree, the hub-posting expectation starts at `/cfp` day one, not at `/talk` pickup.

## Step 3 — Capture verbatim refs

`refs/` carries source-of-truth material that the agent loads to do its work. The discipline is **verbatim, not summarized** — the agent should always be able to grep the original.

Capture, at minimum:

- **The CFP form** — convert .docx / .pdf to markdown if needed. Both forms (binary + .md) live in refs/.
- **Prior art** — papers / talks the proposal will cite or build on. Author's own prior CFPs (`../o11y/`, `../mise/`, etc.) get pointed to via path; only fetch if external.
- **Neighbor CFPs** — link via path in CLAUDE.md `## See also`. Don't copy.
- **Conference theme / track docs** — track descriptions, judging criteria, prior selected sessions
- **Author bio source material** — bios used in past submissions, current LinkedIn copy, credibility statements

If `refs/` exceeds 10 files, generate `refs/INDEX.md` (see template at `reference/refs-index-template.md`). Update on every refs/ change.

For multi-source web research, fire `/explore` — it fetches in parallel, compiles a structured plaintext report, and (optionally) routes to Asana. Useful for "research these 12 URLs" briefs.

## Step 4 — Angle exploration

Don't draft from cold. Produce `research/angle-options.md` with **3–5 framings** the proposal could take.

When the user walks in with the angle already decided ("the talk is about X, that's locked"), the angle-options file still gets written — but as a one-line capture of the locked angle plus 1-2 alternatives the author rejected and why. The point isn't to relitigate; the point is that future-you, mid-draft, can see *why* this framing won. That decision history is the value. Each framing has:

- **Hook line** (one sentence)
- **Audience promise** (what the attendee leaves with)
- **Differentiator** (why this author, why now)
- **Pacing sketch** (for talks: minute-level beats; for papers: section outline)
- **Risk** (what makes this angle weak; reviewer likely objection)

The user reviews, often picks one outright, sometimes asks for an angle they didn't see. Lock the chosen angle in CLAUDE.md `## Locked decisions`. Cite the angle by name (e.g., "Angle D — atomic-task discipline") so future agents can find it.

This step prevents the "draft, dislike, redraft, dislike, redraft" thrash. The angle is a contract.

## Step 5 — Draft

Branch on submission shape:

### Shape A — Short-form proposal (typical CFP)

Single deliverable: `proposal.md`. Every form field gets its own markdown section, copy-paste ready, ending with a running char count comment:

```markdown
## Title
*Plan, Loop, Ship: An Agentic Task Management Bootcamp*
<!-- 54 / 75 -->

## Abstract
[abstract text]
<!-- 583 / 600 -->

## Session details
[longer copy]
<!-- 2,394 / 2,500 -->
```

Verify with `wc -m` (subtract 1 for trailing newline). Char counts that exceed limits are a build break — fix before claiming the draft is done.

### Shape B — Paper submission (academic workshop / conference / journal)

Multi-deliverable. Lives in `paper/`:

- `paper/main.tex` — root LaTeX
- `paper/sections/*.tex` — one file per section
- `paper/references.bib` — bibliography (BibTeX)
- `paper/main.pdf` — built artifact, committed to track changes
- `paper/<class-files>` — ship class files (e.g., `acmart.cls`, `*.bst`) so builds are reproducible

For papers, **use the full `/spec` → `/check` → `/test` → `/impl` pipeline** — beads-typed `spec`, `decision`, `task`, `feature`. Each section is a feature bead. Major changes are spec'd before drafting. The paper itself is the implementation; the spec bead carries the plan.

Tools that help:

- `latexmk -pdf` for builds (bake into project Bash discipline)
- `pdfinfo paper/main.pdf | grep Pages` for page-count gates
- `pdftotext paper/main.pdf -` to grep rendered output for placeholders, missing references, or "[TBD]" leakage
- `pypdf` (`pip install --break-system-packages --user pypdf`) for PDF link audits — verify hyperlinks resolve to expected URIs (the ORCID-icon-not-rendered bug from the mise project would have been caught earlier with this)
- TikZ for figures (consistent with most paper templates; avoids external image deps)

### Shape C — Hybrid (proposal + supplementary materials)

Some CFPs (Universe, KubeCon, etc.) want a short proposal + supplementary deck / video / starter repo. Treat the short proposal as Shape A; treat each supplementary as its own deferred bead (`-t task --defer "post-acceptance"`).

## Step 6 — Critic loop

Every meaningful draft of `proposal.md` or each major paper section goes through **read-only critic agents**. Three flavors, applied as needed:

1. **Naive student** — "I have no context for this. Does it stand on its own?"
2. **Cold reviewer** — "I'm a CFP reviewer reading 200 of these. What grabs me, what makes me skip?"
3. **Voice / writing pass** — "Does this sound like the author? Are there `/zig-voice` anti-patterns leaking in?"

**Critic agents are read-only.** Use `subagent_type: "general-purpose"` or `"Explore"` — NOT worktree subagents. Critics review and report; they don't edit. Workflow:

```
1. Orchestrator: write/refine draft
2. Orchestrator: dispatch critic with full draft text + critic role
3. Critic: returns severity-ranked findings + suggested fixes
4. Orchestrator: applies the ones that hold up
5. Repeat until findings drop below severity threshold
```

The critic loop is what separates a good draft from a great submission. Don't skip it.

## Step 7 — Submit

The owner submits — `/cfp` doesn't (no programmatic CFP portal access). The skill's job at submission time:

1. **Final char-count audit** — every long field within limits
2. **Final critic pass** — voice + claim accuracy + receipt verification
3. **Spell-check the form fields** — manually or via a local tool
4. **Receipt capture** — once submitted, have the owner forward the confirmation email or paste the submission ID into a typed `note` bead so the project has an authoritative "submitted on YYYY-MM-DD as #N" record
5. **Tag the submitted commit** — `git tag <conf>-submitted` and push. Preserves the as-submitted state for audit / diff against post-acceptance revisions.

Then enter waiting state. Update CLAUDE.md `## Pipeline` to mark Step 7 done.

## Step 8 — Post-acceptance (universal flow)

Every accepted CFP gets the same treatment here, regardless of venue. The peer-reviewed-paper sub-arc (Step 8.5 below) layers on top when the venue requires it.

### 8.1 — Capture acceptance verbatim

Write the acceptance email into a typed `note` bead OR into `refs/acceptance-email.md`. Verbatim source-of-truth — never paraphrase the organizers' language. If the email comes with reviewer comments, attach those too.

### 8.2 — Tag the submitted state

```bash
git tag -a <conf>-submitted -m "As-submitted state for <conf>"
git push origin <conf>-submitted
```

This preserves the exact submission snapshot for diff/audit. The `<conf>-camera-ready` tag (if applicable) lands later, after revisions.

### 8.3 — Read the conference's post-acceptance email carefully

Even non-paper venues send a sequence of organizer emails after acceptance: registration deadlines, slide upload windows, social-promotion forms, headshot uploads, virtual-vs-in-person policies, visa letters, AV requirements. **Each piece of this becomes a typed `note` bead with the deadline in the bead title.** The acceptance email is just the first; expect 3–5 more over the months between acceptance and the conference.

### 8.4 — Conference registration (hard deadline, watch for it)

Registration usually has its own deadline distinct from any camera-ready / artifact deadline. Watch for:

- In-person vs. virtual policies (some venues require in-person attendance for proceedings inclusion — get any virtual exception confirmed in writing)
- Visa letter requests for non-domestic authors
- Registration tier matching (early-bird, regular, student, virtual)

**Missing the registration deadline pulls the paper from proceedings, full stop.** If chairs haven't responded to a clarification by ~6 hours before the deadline, register at the appropriate tier and reconcile after — the cost of a wrong-tier registration is much smaller than the cost of being pulled from proceedings.

### 8.5 — Scientific paper sub-arc *(only when the venue is peer-reviewed)*

When the venue is peer-reviewed (academic workshop / conference / journal with reviewer comments + camera-ready cycles + accepted-with-revisions outcomes), the sub-arc adds:

- **Reviewer comment table** → revision spec (`/spec`)
- **Worktree dispatch** for the revision feature beads
- **Open-science artifact bundle** if SIGSOFT / IEEE / similar policy applies
- **arXiv preprint** with cs.SE (or equivalent) endorsement flow
- **Camera-ready integrity check + e-rights** at the publisher
- **DOI population** (Zenodo for the artifact, ACM/publisher for the paper)

The full mechanics — revision-spec shape, artifact-bundle layout, Zenodo via GitHub integration, arXiv tarball build, content-filter pitfalls when anonymizing PII, the ORCID iD rendering bug, the [TBD]-placeholder sweep — live at **[`reference/scientific-paper-arc.md`](reference/scientific-paper-arc.md)**. Read that doc end-to-end the first time you fire this sub-arc; the mise project (`~/cfp/mise/`) is the worked example.

The sub-arc is bead-driven like everything else in `/cfp`. The revision spec is a typed `spec` bead (one per CFP); each revision is a typed `feature` bead under it; critic agents review every diff before merge. The discipline doesn't change for academic venues — only the steps that follow it.

### 8.6 — Final state by end of post-acceptance

The project at this point should have:

**Universal:**
- Tag `<conf>-submitted` (as-submitted)
- Acceptance email captured verbatim
- All organizer-email derived deadlines tracked as typed `note` beads
- Conference registration confirmed; receipt saved
- `proposal.md` (or `paper/main.pdf`) preserved at the accepted version

**Peer-reviewed paper additions:**
- Tag `<conf>-camera-ready` (final post-revision state)
- `paper/main.pdf` final-final, with real copyright + real DOIs, no `[TBD]` strings
- `artifact/` published to Zenodo (or equivalent), DOI live
- arXiv ID public (or marked as deferred — the endorsement loop can run async)
- All beads closed except the `note`-typed human-checklist for ongoing follow-ups

When all that's true, the project is ready for Step 9 — handoff to `/talk`.

## Step 9 — Handoff to /talk

Acceptance triggers the talk-build phase, which is `/talk`'s scope. /cfp's last act:

1. **Verify the CFP repo is mineable.** Read CLAUDE.md cold — does it tell a future agent everything they need to extract talk material? Common things to verify:
   - Locked decisions table is complete
   - `refs/` has the CFP form, prior bios, conference theme docs
   - `research/angle-options.md` exists (the talk benefits from knowing why a given angle won)
   - `proposal.md` (or paper) has the accepted version preserved
   - `.beads/issues.jsonl` is current
2. **Create the talk neighbor folder.** `~/cfp/talk-<slug>/`. Bootstrap it with a CLAUDE.md template that includes a `## Source material to mine` table pointing back at `../<slug>/`. Don't copy refs — point at the CFP repo via path.
3. **Cross-link.** In the CFP repo's `## See also`, add `../talk-<slug>/`. In the talk repo's `## See also`, add `../<slug>/`.
4. **Note the handoff.** Append to the CFP repo's bead trail: a `note` bead saying "Handoff to /talk on <date>; talk repo at ~/cfp/talk-<slug>/". /talk's onboard will see it.

After this, /cfp is done. /talk takes over for deck building, dry runs, day-of.

## CLAUDE.md template

See `reference/claude-md-template.md` — paste at bootstrap, fill placeholders during the Step 2 interview.

## Reference material

| File | Purpose |
|---|---|
| `reference/claude-md-template.md` | The CLAUDE.md skeleton, with placeholders for conference / format / locked decisions / hard limits / source material |
| `reference/refs-index-template.md` | The `refs/INDEX.md` shape for projects with >10 ref files |
| `reference/scientific-paper-arc.md` | **Full how-to for the peer-reviewed-paper sub-arc** — revision spec, worktree dispatch, artifact bundle, arXiv preprint, ORCID rendering bug fix, content-filter pitfalls. Read this end-to-end the first time you fire the sub-arc. |
| `reference/zenodo-json-template.json` | Zenodo metadata for the GitHub-Zenodo integration on artifact bundles |
| `reference/arxiv-tarball-build.md` | Step-by-step for building the arXiv source tarball (LaTeX, .bbl, class files) |
| `reference/handoff-checklist.md` | The end-of-/cfp checklist that ensures /talk can pick up cold |

The bulk of the venue-specific procedural detail lives in `reference/scientific-paper-arc.md` rather than inline in this SKILL.md — that doc is loaded only when the sub-arc fires, keeping the main skill focused on the universal process.

## Anti-patterns

### Skill-shape

- ❌ **Drafting from cold.** Always do Step 4 (angle options) first. Saves 2–3 redraft cycles.
- ❌ **Worktree subagents for critics.** Critics are read-only review. Use `general-purpose` or `Explore` agent types. Worktree is for code-writing work.
- ❌ **Fudging char counts.** Every long field ends with `<!-- N / LIMIT -->`. Verify with `wc -m`. CFP portals enforce limits server-side; submitting at 605/600 means the final 5 chars get truncated and you don't notice until reviewers see "...incom" instead of "...incomplete preparation."
- ❌ **Skipping verbatim refs.** Summarizing the CFP form into "what they're asking for" loses the exact phrasing reviewers will check against. Always grep-able.
- ❌ **Treating /cfp as a one-shot.** It's a multi-week to multi-month workflow. Beads make this work; trust the persistence.
- ❌ **Treating the Asana planning hub as optional.** When a hub exists, it's the user's milestone surface — post one comment per meaningful milestone (bootstrap, angle, proposal draft, critic pass, submission). Mirrors `/talk`'s discipline; for co-located `/cfp` + `/talk` projects (invited talks), hub posting starts at `/cfp` day one. See "Asana planning hub" in Step 2.

### Post-acceptance specific

- ❌ **Trying to address Reviewer 1's empirical critique by inventing data.** Don't fake comparisons that aren't real. Reframe and scope-as-future-work; reviewers see through fabrication.
- ❌ **Forgetting the Open Science artifact for SIGSOFT venues.** Reviewer 2 will flag it. Build the bundle as part of the revision pass, not as an afterthought.
- ❌ **Missing the conference registration deadline because you waited for chair confirmations.** If the deadline is at risk, register at the appropriate tier and reconcile with the chairs after — missing registration pulls the paper from proceedings, full stop.
- ❌ **Letting `[TBD]` placeholders leak into the camera-ready PDF.** `pdftotext paper/main.pdf - | grep -i TBD` is your final-final gate. Run it after every rebuild.
- ❌ **Inline-reciting PII in subagent summaries.** Anthropic's content filter blocks the output. Tell agents up front: report counts, not content.

### Voice

- ❌ **Letting /zig-voice anti-patterns leak in.** "Plot twist," "Here's the thing," "delve," "leverage" — auto-fail. Apply `/zig-voice` to every draft pass, not just final.
- ❌ **Identity-first author bios.** Per the github-universe-2026 lesson: "former teacher" was rejected as biographical lead in favor of pedagogy as methodological technique. Bios are recipe-ordered: most-recent + most-substantial first.

## Skills this composes with

| Skill | When to fire |
|---|---|
| `/onboard` / `/offboard` | Bracket every working session, even short ones |
| `/spec` / `/check` / `/test` / `/impl` | Paper-shape submissions; revision cycles after acceptance |
| `/dispatch` | Before every worktree subagent dispatch (revision agents, drafting agents) |
| `/handoff` | Every subagent's pre-final-commit verification |
| `/zig-voice` | Every external-facing copy pass (and most internal) |
| `/linearb-brand` | When the proposal references LinearB / APEX / brand context |
| `/explore` | Multi-source research compile (3+ URLs) — research phase |
| `/asana` | Routing progress to the planning hub via fleet-proxied comments. **Canonical, not optional** — one comment per meaningful milestone, from bootstrap onward. See Step 2 "Asana planning hub" + the matching anti-pattern. |
| `/openrouter` | Visual deliverables — talk preview images, paper figures (cost-aware) |
| `/beads` | Constantly. /cfp is beads-driven from bootstrap onward |
| `/commit` | Every meaningful checkpoint |
| `/triage` | Mid-project bead-state hygiene |

## See also

- `~/cfp/mise/` — flagship case study (paper submission, full pipeline)
- `~/cfp/github-universe-2026/` — short-form CFP with hard char limits + critic discipline
- `~/cfp/o11y/` — minimal sessionize-style submission
- `~/cfp/talk-ai-council/` — the next-stage `/talk` skill's working folder; reference for how a talk picks up from a CFP project
- `/talk` (forthcoming) — sibling skill that takes over post-acceptance for deck building

## The CFP discipline in one paragraph

Lock the conference and its hard limits before you write a sentence. Capture refs verbatim. Explore 3–5 angles before drafting. Critic-loop every draft. Verify char counts. Track everything in beads. Tag the submission. Treat acceptance as the *start* of a new pipeline, not the end of one — the post-acceptance work (revisions, camera-ready, artifact, arXiv, registration) is half the job. When the talk-build agent shows up, the CFP repo should read like a cold-pickup-friendly handoff packet. That's the whole skill.
