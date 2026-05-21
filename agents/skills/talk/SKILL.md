---
description: Talk-prep orchestrator. Picks up from /cfp at acceptance and shepherds the talk all the way to ready-to-deliver. Bootstraps a working `~/cfp/talk-<slug>/` (or rehydrates from /cfp's handoff), runs spec → critic → slide-plan → visual-arc → image-narrative → script → smoke-to-batch aesthetic-iteration → dry-runs → final-deliverables. Beads-driven from bootstrap. Two-tab Google Doc collaboration (script + image narrative). Stops at the boundary where the talk goes live (delivery is the human's job; post-talk content extraction is /zig-voice's job).
when_to_use: User has an accepted talk and needs to build the deck + script. /cfp finished and handed off, OR the user starts mid-stream with an existing accepted talk that wasn't /cfp'd. Also fire when tuning a talk based on dry-run feedback, finalizing the slide deck for upload to the organizer's Google Form, or building day-of artifacts. Stop at delivery.
argument-hint: "[slug]"
---

# /talk — Conference talk preparation orchestrator

## What this skill does

`/talk` is the canonical orchestrator for the **second half** of a conference deliverable: take an accepted talk from "we have a slot" all the way through "the deck is uploaded, the script is rehearsed, the day-of artifacts are locked, the human walks on stage prepared." Delivery itself — standing up, speaking, the Q&A in the Office Hours room, the post-talk content extraction — is **not** in scope. That's the human's job (delivery) and `/zig-voice`'s job (post-talk content).

This skill is the natural continuation of [`/cfp`](../cfp/SKILL.md). `/cfp` ends at *"accepted, archived, registered submission, with the CFP repo mineable for the next phase."* `/talk` picks up there. The two skills share a structural shape — beads-driven bootstrap, opinionated `~/cfp/<slug>/` tree, refs/ verbatim, critic-loop discipline — but the deliverables are different. `/cfp`'s deliverable is a proposal or paper; `/talk`'s deliverable is a deck + script + image narrative + dry-run-validated runtime + day-of checklist.

What varies per talk is the **rendering pipeline** (Gamma is the default; some venues prefer Keynote / Google Slides / PPTX) and whether the **visual-narrative arc** is structurally load-bearing (most full-runtime talks; rarely lightning talks). The arc work lives in a separate visual-arc + image-narrative pair of artifacts so the deck's story-shape is an explicit design step, not an emergent property of slide-by-slide drafting.

Concretely, `/talk` covers:

| Phase | What | Skill output |
|---|---|---|
| **Bootstrap (or rehydrate)** | Create `~/cfp/talk-<slug>/` with CLAUDE.md, beads, refs/, deck/, gamma/. Rehydrate from `/cfp`'s handoff if it exists. | A scaffolded project ready for content |
| **Discover constraints** | Capture the talk page + screening call + organizer prep email + Asana hub gid + YouTube channel verbatim into `refs/` | Locked-logistics block in CLAUDE.md |
| **Lock the talk spec** | Typed `spec` bead — overview / baseline / changes-from-CFP / beat-by-beat outline / test cases / OQs / future | A versioned spec the talk is built against |
| **Critic loop** | `/check` walks OQs; multiple iterations expected | Spec rev-2, rev-3 etc. |
| **Build the slide plan** | Per-slide architecture (#/beat/duration/role/speaker-line/visual/text/image-source). Compress aggressively before render. | `deck/slide-plan.md` + `deck/compression-report.md` |
| **Design the visual arc** | Flip-book / comic-book story across the WHOLE deck. Continuity techniques + variety palette + canonical recurring object. | `deck/visual-arc.md` |
| **Write the image narrative** | Google Doc Tab 2: 4 sections + 40 per-slide depictions. Iterated WITH the user before any generation. | `deck/image-narrative.md` mirrored to Google Doc Tab 2 |
| **Write the script** | Google Doc Tab 1: delivery-ready prose at ~140-150 wpm. H1/H2/H3 hierarchy. | `deck/talk-script.md` mirrored to Google Doc Tab 1 |
| **Aesthetic iteration loop** | 3-slide smoke → 10-slide batch → full deck. Cost-aware Gamma + nano-banana fires. | `gamma/style-c.json` + a series of `gammaUrl`s posted to Asana |
| **Resource pack repo** | Public GitHub repo at `<owner>/<slug>-resources` for the closer's QR target | `github.com/<owner>/<slug>-resources` live |
| **Dry runs** | Light orchestration: clock, flag, audit voice. Agent is NOT a speech coach. | Runtime data + flagged moments |
| **Final deliverables** | PDF export, organizer Google Form upload, final Asana milestone, day-of checklist note bead | Talk-ready state, tagged |
| **Handoff to delivery** | `/talk` ends here. Human walks on stage. `/zig-voice` picks up post-talk. | `~/cfp/talk-<slug>/` in talk-ready state |

## Examples in the wild

The flagship case study is **`~/cfp/talk-ai-council/`** — *5 Lessons from the Classroom for Evaluating Agents*, AI Council 2026 (Analytics & Data Science track), May 13, 2026 at the SF Marriott Marquis. It's the project that exercised the full pipeline end-to-end:

- Multi-iteration spec (3 spec revisions, multiple `/check` walks)
- Compression discipline: 75 slides → 40 slides at ~47 sec/slide, with a `deck/compression-report.md` documenting what was cut and why
- Visual arc redesigns: literal Magic-School-Bus-episode flip-book with the canonical bus visible (or implied) in 39 of 40 frames
- Palette iteration through the smoke→batch→full sequence
- Two-tab Google Doc collaboration (script tab + image-narrative tab), with the image narrative iterated BEFORE any image generation fired
- Manual click-background workflow for full-bleed slides (Gamma's API doesn't support per-slide layout — see [`/gamma`](../gamma/SKILL.md)'s `layout-workarounds.md`)
- 9+ beads tracking spec iterations, slide plan, visual arc, script, image narrative, render batches

Read the project's `CLAUDE.md`, `deck/`, `gamma/`, and `.beads/issues.jsonl` for the canonical reference. Future talk neighbors will land alongside (`~/cfp/talk-<other-slug>/`); the discipline is the same across all of them.

## When NOT to use this

- **You're delivering the talk itself.** That's the human's job. `/talk` stops at "talk-ready," not "talk-delivered."
- **You're extracting post-talk content** (LinkedIn recap, blog draft, podcast clip). Wrong skill — that's [`/zig-voice`](../zig-voice/SKILL.md). The talk repo is the source material to mine; the recap is its own deliverable.
- **You're submitting / drafting the proposal.** Wrong half. That's [`/cfp`](../cfp/SKILL.md). Don't fire `/talk` until acceptance is confirmed and the talk slot is real.
- **It's a 5-minute lightning talk.** Too small to scaffold. The scaffold (spec → arc → narrative → script → render) carries overhead that pays off across a 30+ minute talk; for 5-minute slots, just write a half-page script and a few slides.

## Pipeline at a glance

```
   Step 0: shape detection (rehydrate from /cfp vs fresh-start)
       │
       ▼
   Step 1: bootstrap ── ~/cfp/talk-<slug>/, CLAUDE.md, .beads/, refs/, deck/, gamma/
       │
       ▼
   Step 2: discover constraints ── talk page, screening call, prep email, Asana hub, YouTube channel
       │
       ▼
   Step 3: lock the spec ── typed `spec` bead, sections 1-7
       │
       ▼
   Step 4: /spec → /check loop ── multiple iterations expected
       │
       ▼
   Step 5: slide plan ── exploded → compressed (~40 slides @ ~47 sec/slide)
       │
       ▼
   Step 6: visual arc ── flip-book story, continuity techniques, canonical recurring object
       │
       ▼
   Step 7: image narrative ── Google Doc Tab 2, iterated with user BEFORE generation
       │
       ▼
   Step 8: talk script ── Google Doc Tab 1, ~140-150 wpm, H1/H2/H3 hierarchy
       │
       ▼
   Step 9: aesthetic iteration ── 3-slide smoke → 10-slide batch → full deck
       │
       ▼
   Step 10: resource pack repo ── github.com/<owner>/<slug>-resources for closer QR
       │
       ▼
   Step 11: dry runs ── clock, flag, audit voice (agent is NOT a speech coach)
       │
       ▼
   Step 12: final deliverables ── PDF export, organizer upload, day-of checklist
       │
       ▼
   Step 13: handoff to delivery ── out of scope; /zig-voice picks up post-talk
```

## Step 0 — Shape detection

When `/talk` fires:

```bash
# Are we already inside a talk project?
if [ -f CLAUDE.md ] && grep -q "talk-" CLAUDE.md 2>/dev/null; then
  echo "EXISTING talk project — resume."
elif [ -d "$HOME/cfp/talk-$SLUG" ]; then
  echo "RESUME existing $HOME/cfp/talk-$SLUG."
elif [ -d "$HOME/cfp/$SLUG" ]; then
  echo "REHYDRATE from /cfp's handoff at $HOME/cfp/$SLUG."
else
  echo "FRESH-START — accepted talk that wasn't /cfp'd. Bootstrap fresh."
fi
```

Three onboard paths:

1. **Rehydrate from `/cfp`** — `~/cfp/<slug>/` exists from a prior `/cfp` run. The CFP repo is the source-material-to-mine; the new `~/cfp/talk-<slug>/` is the talk-build repo. See `reference/handoff-from-cfp.md` for the full handoff.
2. **Resume an existing talk-<slug>/** — read `CLAUDE.md`'s `## Pipeline` checkboxes; run `br ready` to see what's next; honor the tag history.
3. **Fresh-start** — accepted talk that wasn't `/cfp`'d. Bootstrap manually (no upstream CFP repo to mine; the talk page + screening call + prep email become the verbatim source material).

If resuming, **`br ready` is what you walk first.** Tags + CLAUDE.md `## Pipeline` checkboxes corroborate state.

## Step 1 — Bootstrap (or rehydrate)

This is opinionated and identical for every talk. Don't ask "do you want beads?" — beads is on. Don't ask "do you want refs/ and deck/ and gamma/?" — they're standard. The discipline is what makes talks consistent.

```bash
SLUG="<from-arg-or-ask>"
mkdir -p ~/cfp/talk-$SLUG && cd ~/cfp/talk-$SLUG
git init
br init                                # creates .beads/ — UNCONDITIONAL, NOT optional
mkdir refs deck gamma                  # standard layout

# .gitignore — beads history shouldn't track
cat > .gitignore <<'EOF'
.beads/.br_history/
.env.local
EOF

# CLAUDE.md from template (see reference/claude-md-template.md)
cp ~/.claude/skills/talk/reference/claude-md-template.md CLAUDE.md
# Then edit placeholders: {{CONFERENCE}}, {{TITLE}}, {{TALK_DATE}}, {{RUNTIME}}, etc.

# If rehydrating from /cfp: cross-link the upstream CFP repo
# CLAUDE.md ## Source material to mine table points at ../<slug>/ paths
# CFP repo's ## See also adds ../talk-<slug>/

# Initial commit
git add CLAUDE.md .gitignore .beads/
git commit -m ":seedling: bootstrap: new talk project for {{CONFERENCE}}"
```

`br init` runs **unconditionally**. It is load-bearing. The skill is beads-driven from this commit forward. There is no "lite" mode that skips beads.

**Don't auto-fill the placeholders.** Step 2 (discover constraints) drives that. Bootstrap leaves the template in place so the verbatim source material lands where it belongs.

## Step 2 — Discover delivery constraints

The talk's logistics are not negotiable — they're set by the conference. `refs/` carries verbatim source material the agent loads to do its work; `research/`-style analysis is folded into beads and decision notes.

Capture, at minimum:

| Source | Why it matters | Where it lands |
|---|---|---|
| **Public talk page** (URL on the conference site) | Verbatim metadata: title, abstract, track, dates, format, speaker bio | `refs/<conf>-page.md` |
| **Screening call transcript** (when present) | The host's read on you + commitments you made on the call. **This is gold** — what you committed to verbally is what the host expects. | `refs/screening-call-<host>.md` |
| **Organizer prep email** (final-prep, speaker logistics) | Locked logistics: runtime, slide format, A/V, Q&A format, final-deliverable upload mechanism | `refs/final-prep-email.md` |
| **Asana planning task** (the milestone-sync hub) | gid + URL — confirm with the user; plant in CLAUDE.md | CLAUDE.md `Asana planning hub` row |
| **Conference YouTube channel** (or other recording venue) | So we know what the recording context is — slides get permanently published alongside the video | CLAUDE.md `Recording` row |
| **Venue + stage tech** (from prep email) | HDMI vs. USB-C, slide format, advance clicker, mic type | CLAUDE.md `Stage tech` row |

The screening-call transcript especially: when you have one, **read it like a contract**. The host's tone, the framing you committed to, the format choices the host signaled — all of that locks the talk's shape in ways the public page doesn't reveal. The talk-ai-council case study shows this: the trajectory framing ("you get the trajectory of figuring out the context engineering") was committed verbally on a screening call and became the spine of the talk.

Update CLAUDE.md's locked-decisions table as you go. The interview is **completeness check**, not a script — extract everything the user gave you in their first message, fill remaining slots with `TBD`, then circle back only on what's missing.

## Step 3 — Lock the talk spec

Create a typed `spec` bead. The talk is built against this spec; iterations supersede prior versions. Use [`/spec`](../spec/SKILL.md)'s mechanics — bead `--description` carries the full spec, sections 1-7.

```bash
br create -t spec -p 2 "talk: <slug> beat-by-beat spec"
br update <id> --description "$(cat reference/talk-spec-template.md)"
br update <id> --claim
```

Talk-spec sections (mirrors `/spec`'s 7-section shape, talk-specific contents):

1. **Overview** — what this talk is, who it's for, what they leave with
2. **Baseline** — the abstract verbatim, the screening-call commitments, the organizer-locked logistics. Anything below this baseline breaks the contract with host or audience.
3. **Changes from baseline** — post-acceptance evolution. Trajectory framing, audience-shape adjustment, runtime change (Katie said 20-30 on the call; the prep email said 35-40 — go with the prep email), structural choices (Magic School Bus scaffold, etc.)
4. **Beat-by-beat outline with timing budget** — per-beat duration, role, narrative function. Total ≤ runtime minus a buffer.
5. **Test cases** (≥10) — talk-specific. Examples:
   - Photographable slides (a back-row attendee can take a phone shot of any frame and have the cheat sheet)
   - Voice anti-patterns (no `/zig-voice` violations in the script)
   - Recognition-not-listicle (lessons appear in flow, not as a numbered list — except where the takeaway card explicitly is a list)
   - Hackathon-numbers-paper-verified (numbers cited match a peer-reviewed source, not a Substack)
   - Standalone-without-audio (slides published with the YouTube video must make sense without narration)
   - Closer-hands-off (the last beat invites Office Hours / resource pack / etc., not on-stage Q&A unless the format includes it)
6. **Open Questions** — unresolved before drafting. `/check` walks these.
7. **Future considerations** — post-talk content extraction routes (LinkedIn recap, blog post, podcast clip). **Mark explicitly out of scope for `/talk`.** That's `/zig-voice`'s pickup.

See `reference/talk-spec-template.md` for the full section-by-section template.

## Step 4 — /spec → /check loop (multiple iterations expected)

The first spec is rarely the final spec. Normalize that.

- **v1 too abstract** — the spec reads like the abstract; reviewers can't see beat-level shape
- **v2 still has gaps** — beats are sketched but the test cases reveal load-bearing decisions still TBD
- **v3 lands** — beats fit the runtime, test cases pass against the draft, OQs are decided

Cite the talk-ai-council case as the worked example: 3 spec iterations + multiple `/check` walks before drafting started in earnest. **Iteration discipline** — each spec rewrite supersedes the prior; mark prior beads as superseded but **don't close them** (the trail is the value). Use `br update <id> --notes` to capture what changed and why between revisions.

`/check` produces a **decision bead** per pass — typed `decision`, parented to the spec. The decision bead carries the OQ-by-OQ verdicts and an Implementation Readiness summary.

## Step 5 — Build the slide plan

Start exploded. Compress aggressively before any rendering fires.

Pattern from the flagship: **75 slides → 40 slides at ~47 sec/slide.** That's Bret Victor / Garr Reynolds territory — each slide carries more weight, the speaker holds longer per visual, the audience absorbs each beat as a cheat sheet rather than parsing a stop-motion sequence.

Slide doctrine:

- **Visual-driven, not text-driven.** Most slides are image-only. Default text on slide is EMPTY.
- **Each slide is a photographable cheat sheet.** Back-row attendees should want to photograph individual slides.
- **Makes sense without audio.** Slides get permanently published with the YouTube video; replays will see them without narration.
- **Text only for very simple/bold callouts.** A bold-phrase slide is the exception (lesson punctuations, spine lines, the takeaway card), not the rule.
- **"If a frame can be reduced from four elements to two, reduce it."** Misalignment opportunity scales with element count.

Per-slide spec format (one block per slide):

- **#** / **Beat** / **Display duration** / **Role** (anchor / artifact / bold callout / typography)
- **Speaker line(s)** — what the human says while the slide is up
- **Visual concept** — one paragraph; specific composition; arc-position note
- **Text on slide** — verbatim if any, else `none`
- **Image source** — `existing-render` / `brief-NN` / `new-brief` / `mermaid` / `paper-figure` / `typography-only` / `screenshot`

Once the exploded plan exists, **compress to a target slide count** (commonly 30-45 for a 30-40 minute talk) and write a `deck/compression-report.md` documenting what was cut and why. The report is the audit trail for the compression discipline.

See `reference/slide-plan-template.md` for the per-slide spec format and `reference/slide-plan-template.md`'s "Compression report format" section.

## Step 6 — Design the visual narrative arc

The deck tells a story across the WHOLE deck — a flip-book, a comic-book story shape — designed BEFORE any image generation. This is the highest-leverage step in the whole pipeline; it's also the easiest to skip and regret.

`deck/visual-arc.md` carries:

- **Thesis** (one sentence) — the through-line the audience experiences across all 40 frames
- **Arc shape** (one paragraph) — beat-by-beat what changes across the deck (camera position, subject scale, light progression, palette pacing)
- **Continuity techniques** — pick 2-3 from: camera position progression, recurring objects, light progression, palette pacing, scale shift. Each technique should appear in ≥10 frames to count.
- **Variety palette** — a table of 10-15 distinct subject categories with appearance counts. **No single category > 5 slides.** Without this constraint, the deck collapses into "many slides of the same thing."
- **Per-beat visual chapters** — what the camera is doing in each beat
- **Per-slide frames** — one line per slide tying it to the arc

The talk-ai-council flagship: *the audience boards a yellow vintage school bus and literally takes the field trip the talk describes — the bus pulls away from a quiet schoolhouse at dawn, drives into a road choked with rules, shrinks down and dives inside the system, navigates the methodology's worlds and the working machine, rises back out into an aerial view of the route just travelled, and parks at the same schoolhouse at twilight with the door open to the next room.* The bus is the canonical recurring object — visible (or implied) in 39 of 40 frames. **17 distinct subject categories** across the 40 slides, with the most-frequent category at 5 (anatomical cross-section) — within the budget.

See `reference/visual-arc-template.md` for the full template and the canonical-recurring-object discipline.

## Step 7 — Write the image narrative (Google Doc Tab 2)

Collaborative iteration with the user **BEFORE** generation fires. Per [`/gdoc`](../gdoc/SKILL.md), use the doc's tab system — the talk-script and the image-narrative live in the SAME doc, on different tabs, so the user has one place to read both in sync.

Image Narrative tab structure (4 sections + N per-slide entries):

- **Section 1.1: Hard rules** (NON-NEGOTIABLE) — no people, no text in images, no trademarked likenesses, frame format (16:9 / 4:3 / etc.). Whatever's wrong on the first generation pass that you don't want to keep re-fixing — codify here once.
- **Section 1.2: The canonical recurring object/character** — defined ONCE here, referenced everywhere. Without this, the image agent re-designs the canonical object per slide and the deck reads as 40 different cartoons stitched together.
- **Section 1.3: Aesthetic register** — palette + treatment. Verbatim from your final-approved Style C `imageOptions.style` field, so the brief and the API call agree.
- **Section 1.4: Detail discipline** — less is more. ONE primary subject per frame. AVOID secondary props, background clutter, detail flourishes.
- **Section 2: Arc shape** — one-paragraph reference to `deck/visual-arc.md`'s thesis (so this doc is self-contained for the user reading on their phone)
- **Section 3: Per-slide depictions** — N entries (one per slide), each ≤80 words, distilled, iconic. References "the canonical bus" / "the canonical recurring object" rather than re-describing it.
- **Section 4: How we iterate** — user comments → orchestrator updates the tab → re-stage gamma → fire. Closes the iteration loop.

The flagship's image narrative went through several v3-class iterations BEFORE any nano-banana / Gamma generation fired for the full deck. Saved enormous credit spend; produced a deck whose visual language is consistent across 40 frames.

See `reference/image-narrative-template.md` for the full Tab 2 structure.

## Step 8 — Write the talk script (Google Doc Tab 1)

Delivery-ready prose, in the speaker's voice. Same Google Doc as the image narrative, on Tab 1.

Word-count math:
- ~140-150 wpm comfortable speaking pace
- 30-min talk = ~4,200-4,500 words
- 35-40 min talk = ~5,000-5,500 words
- Budget for ~10% buffer (laughs, beats, applause anchor) — write to 90% of the spoken minutes

Heading hierarchy:

- **H1**: Title + delivery metadata (date, runtime target, venue, audience)
- **H2**: Per beat
- **H3**: Per slide (mirroring the slide-plan spec)
- **Bold inline**: lessons / spine lines at recognition-punctuation moments
- **Italic**: stage directions ("(Beat.)" / "(Andrew walks to position.)")
- **Plain prose**: the actual spoken text

Apply [`/zig-voice`](../zig-voice/SKILL.md)'s anti-patterns to every pass: no "delve" / "leverage" / "plot twist" / "here's the thing." Em-dash density capped at 1 per 200 words. Listicle structure is a smell when the title implies a list — recognition-in-flow beats numbered enumeration.

See `reference/talk-script-template.md` for the heading hierarchy + voice rules.

## Step 9 — Aesthetic iteration loop (smoke → batch → full)

Cost-aware, via [`/gamma`](../gamma/SKILL.md) and [`/openrouter`](../openrouter/SKILL.md). The pattern that works across talks:

| Fire | Slide count | Credits (Gamma Pro/Teams, ~5 credits/slide) | What it validates |
|---|---|---|---|
| **Smoke** | 3 | ~15 | Aesthetic alignment in isolation — palette, register, the canonical object's render |
| **Batch** | 10 | ~40-50 | Arc + composition + palette across diverse slide types (typography frames, full-bleed images, artifact slides) |
| **Full** | 30-45 | ~150-300 | Final pass — only after smoke + batch land |

**Iterate the brief between fires.** The image narrative is the source of truth; update it per the user's notes, re-stage the gamma payload, fire again. The user clicks "Set as background" manually for full-bleed slides (Gamma's API doesn't support per-slide layout; see [`/gamma`](../gamma/SKILL.md)'s `reference/layout-workarounds.md`).

After each fire, **post the gammaUrl to the Asana planning hub** as a plaintext comment via [`/asana`](../asana/SKILL.md). The Asana hub is the milestone-sync hub between the agent's work and the human's review surface. See `/asana` for the comment mechanics.

Never fire Gamma autonomously, in loops, or as "let me try a few" speculation. Always confirm credit cost first. See `/gamma`'s "CRITICAL: cost awareness" section.

## Step 10 — Resource pack repo

Created EARLY (right after Step 6 — the visual arc is locked) so the closer's QR code has a real destination by the time the closer slide gets designed.

```bash
gh repo create <owner>/<slug>-resources --public --description "Resources for <talk title> at <conf>"
mkdir -p $SLUG-resources/{handouts,reading,links}
cd $SLUG-resources

cat > README.md <<EOF
# <talk title> — Resources

Slides, handouts, and reading list for <talk title> at <conference>, <date>.

Slides go up alongside the YouTube recording; this repo is the deeper-dive.

## What's here

- handouts/ — printable cheat sheets, rubrics, templates
- reading/ — long-form references for the methodology
- links/ — URLs to the paper, the podcast, related talks

## Office Hours

Andrew is in the <conf> Office Hours room after the talk. Come find me.
EOF

cat > LICENSE <<EOF
<MIT or CC-BY-4.0 — pick the right one for handouts>
EOF

git add . && git commit -m ":seedling: bootstrap resource pack repo"
git push -u origin main
```

Track the repo bootstrap as a typed `task` bead with `--external-ref` pointing to the GitHub repo URL.

## Step 11 — Dry runs

Light orchestration only. The agent helps the human; the agent does NOT replace coaching.

What the agent helps with:
- **Clock the talk.** Spoken at ~140-150 wpm, total runtime within the buffer? Slide-by-slide timing matches the budget?
- **Flag landing-flat moments.** Lines that read OK on paper but rush off the tongue; transitions where the energy drops.
- **Audit timing drift.** If beat 2 went over by 90 seconds in dry run 1, where's that buffer coming from?
- **Voice anti-pattern check.** Last `/zig-voice` pass on anything that got tightened during dry runs.

What the agent does NOT do:
- Tell the human how to gesture, breathe, project, modulate
- Critique vocal delivery from audio (we don't have ears)
- Replace a real practice rehearsal with peers

Recommend ≥1 dry run ≥1 week before delivery; ≥2 dry runs total. Each dry-run bead (`-t task`) carries the runtime data + the flagged moments + the fixes-applied list.

See `reference/dry-run-checklist.md` for the per-dry-run checklist.

## Step 12 — Final deliverables

| Deliverable | Where it goes | Mechanism |
|---|---|---|
| **PDF export** of the deck | Locally + repo `gamma/exports/` | `/gamma`'s `exportAs: "pdf"` plus a re-export endpoint hit (free) |
| **Organizer Google Form upload** | Conference's pre-event Google Form | Manual upload by the human (most conferences require PDF, not Gamma URL) |
| **Final Asana milestone comment** | Asana planning hub | `/asana` plaintext comment with the gammaUrl + PDF link |
| **Day-of checklist note bead** | The talk repo | Typed `note` bead, never closed (persistent reference) |

Tag the final state:

```bash
git tag -a <conf>-deck-final -m "Final deck state for <conf> on <date>"
git push origin <conf>-deck-final
```

See `reference/day-of-checklist.md` for the day-of checklist content.

## Step 13 — Handoff to delivery (out of scope)

`/talk` ends here. The human walks on stage; that's not the agent's work.

The talk repo is now mineable historical state for two downstream consumers:

1. **`/zig-voice`** picks up post-talk content extraction — the YouTube video, audience photos, recap LinkedIn posts, blog draft, podcast clips. The talk repo's `deck/talk-script.md` + `deck/slide-plan.md` + the YouTube URL together are the source material.
2. **The next talk neighbor** — `~/cfp/talk-<other-slug>/` — that may want to mine this talk's visual arc, slide doctrine, dry-run checklist, etc.

Drop a closing typed `note` bead: *"Handoff: talk delivered at <conf> on <date>. Next-stage skills: /zig-voice for content extraction; this repo is mineable for future talks."*

## CLAUDE.md template

See `reference/claude-md-template.md` — paste at bootstrap, fill placeholders during Step 2 (discover constraints).

## Reference material

| File | Purpose |
|---|---|
| `reference/claude-md-template.md` | The CLAUDE.md skeleton with placeholders for conference / runtime / locked decisions / source material to mine |
| `reference/talk-spec-template.md` | The talk spec section structure (Sections 1-7), talk-specific |
| `reference/slide-plan-template.md` | Per-slide spec format + the compression-report.md format |
| `reference/visual-arc-template.md` | The flip-book design pattern: thesis / arc shape / continuity techniques / variety palette / per-beat chapters / canonical-recurring-object discipline |
| `reference/image-narrative-template.md` | The Google Doc Tab 2 structure: 4 sections + N per-slide depictions |
| `reference/talk-script-template.md` | The Google Doc Tab 1 structure: heading hierarchy + voice rules |
| `reference/dry-run-checklist.md` | What to clock, what to flag, what to fix between dry runs |
| `reference/day-of-checklist.md` | Laptop with PDF backup, HDMI adapter, slide advancer, organizer mobile contact, room-arrival timing, final A/V check |
| `reference/handoff-from-cfp.md` | How `/talk` picks up from `/cfp`'s handoff: what `~/cfp/<slug>/` should provide; what the talk repo's `## Source material to mine` table looks like |

## Beads-as-structural

Beads is **load-bearing** in `/talk` — same as in `/cfp`. The pipeline is bead-tracked from bootstrap onward.

| Phase | Bead type | Pattern |
|---|---|---|
| Talk spec | `-t spec` | One canonical spec bead, evolved through iterations |
| Critic decisions | `-t decision` | Each `/check` pass produces a decision bead under the spec |
| Slide plan | `-t plan` | One plan bead capturing per-slide architecture |
| Visual arc | `-t plan` | Separate plan bead for the flip-book + canonical-object definition |
| Image narrative | `-t plan` | Plan bead pointing at the Google Doc tab |
| Talk script | `-t plan` | Plan bead pointing at the Google Doc tab |
| Each Gamma render batch | `-t task` | One bead per fire, `--external-ref` to the gammaUrl |
| Each image-gen run | `-t task` | One bead per nano-banana batch (cost-aware tracking) |
| Resource pack repo bootstrap | `-t task` | One bead, `--external-ref` to the GitHub repo |
| Each dry run | `-t task` | One bead per dry run with runtime + flagged moments |
| Day-of checklist | `-t note` | Persistent reference bead — never closed |

**Bead-trailer commits throughout.** Every commit gets `Bead: <id>` per [`/commit`](../commit/SKILL.md). Worktree subagents claim and reference; the orchestrator owns lifecycle (create / claim / close).

**`br ready` at Step 0.** When resuming an existing `talk-<slug>/`, `br ready` is what you walk first. Tags + CLAUDE.md `## Pipeline` checkboxes corroborate state.

The flagship case study has 9+ beads tracking spec iterations, slide plan, visual arc redesigns, script, image narrative, render batches — read its `.beads/issues.jsonl` cold to see the worked example.

## Anti-patterns

- ❌ **Drafting slides without an arc.** The visual arc (Step 6) is upstream of the slide plan AND of any image generation. Drafting slides slide-by-slide without an arc produces a deck that's 40 unrelated cartoons.
- ❌ **Generating images before the image narrative is reviewed.** Saves real money. Even one full-deck Gamma fire is ~150-300 credits; the image narrative is free to iterate on.
- ❌ **One doc for everything.** The script and the image narrative live in the SAME Google Doc on DIFFERENT TABS. Per `/gdoc`. Combining them turns the doc into a wall of mixed-purpose prose.
- ❌ **Letting the canonical recurring object drift.** Without a "Section 1.2 — the canonical X" entry in the image narrative, the image agent re-designs the recurring object per slide and the deck reads as 40 different cartoons stitched together.
- ❌ **Listicle structure when the title implies a list.** "5 Lessons" doesn't mean 5 numbered slides — recognition-in-flow beats numbered enumeration. The five lessons appear once each as recognition punctuation in the talk's spine, plus once together on a takeaway card. That's it.
- ❌ **Extrapolating cost from per-image rates.** Gamma bills in credits; image-output tokens are billed at a higher rate than text-completion tokens. Trust the `credits.deducted` field in the response, not the published per-token pricing.
- ❌ **No buffer between target runtime and the organizer's window.** If the prep email says "35-40 min ideal," target 31-32 min spoken. Buffer covers laughs, beats, applause anchor, and the inevitable "the host's intro ran 90 seconds long."
- ❌ **Skipping the screening-call transcript.** When you have one, read it like a contract. What you committed to verbally is what the host expects. The flagship's trajectory framing came from the screening call, not the public abstract.
- ❌ **Firing Gamma in loops or as autonomous speculation.** Cost-aware always — confirm credit spend with the user before each fire. See `/gamma`'s "CRITICAL: cost awareness."
- ❌ **Writing the script before the slide plan exists.** The slide plan is the spine; the script's H3 headings mirror the slides. Without that scaffold, the script drifts and re-scaffolds against itself mid-rev.
- ❌ **Working on talk content without bead-tracking it.** Beads carry handoff context. A "let me just sketch the deck plan in a markdown file" detour breaks the trail; the next agent (or future-you) won't know what state the work is in.
- ❌ **Treating the Asana planning hub as optional.** It's the human's review surface. Drop gammaUrls there as plaintext comments after every fire (see `/asana` for `text` field mechanics — comments are plaintext-only).

## Skills this composes with

| Skill | When to fire |
|---|---|
| `/cfp` | UPSTREAM. `/cfp` ends at acceptance + handoff; `/talk` picks up. Cross-link `~/cfp/<slug>/` from `~/cfp/talk-<slug>/`. |
| `/onboard` / `/offboard` | Bracket every working session, even short ones |
| `/spec` / `/check` | The talk's spec lives in a `spec` bead; `/check` walks its OQs in decision beads |
| `/dispatch` | Before every worktree subagent dispatch (slide plan, visual arc, image narrative drafts) |
| `/handoff` | Every subagent's pre-final-commit verification |
| `/beads` | Constantly. `/talk` is beads-driven from bootstrap onward |
| `/commit` | Every meaningful checkpoint with `Bead: <id>` trailer |
| `/zig-voice` | Every external-facing copy pass (script, Asana write-ups, social-promotion copy). DOWNSTREAM after delivery for content extraction. |
| `/gdoc` | Two-tab Google Doc collaboration: script tab + image-narrative tab. Use `gdoc.sh` shim for reads; per-tab writes use bun inline (the shim's `write` with a `tabId` is broken). |
| `/gamma` | Every Gamma render — payload shape, cost awareness, layout-workaround references. The default rendering pipeline. |
| `/openrouter` | Image generation via nano-banana 2 for any inline-URL pattern (Gamma layout workaround #2). Cost-aware. |
| `/asana` | Routing progress to the planning hub via fleet-proxied plaintext comments. The hub is the human's review surface. |
| `/explore` | Read-only research compile when the talk needs prior-art mining (other talks at the venue, related papers) |
| `/triage` | Mid-project bead-state hygiene |

## See also

- [`/cfp`](../cfp/SKILL.md) — the upstream sibling. Ends at acceptance + handoff; `/talk` picks up.
- [`/gamma`](../gamma/SKILL.md) — downstream rendering pipeline. The 3-style framework + layout workarounds.
- [`/zig-voice`](../zig-voice/SKILL.md) — voice anti-patterns + post-talk content extraction (out of `/talk`'s scope).
- `~/cfp/talk-ai-council/` — the flagship case study. AI Council 2026, May 13. Read its `CLAUDE.md`, `deck/`, `gamma/`, `.beads/issues.jsonl`.
- Future neighbors will land alongside (`~/cfp/talk-<slug>/`).

## The /talk discipline in one paragraph

Bootstrap with beads on, refs verbatim, two-tab Google Doc shape, before you draft a slide. Lock the talk spec; iterate it through `/check`. Build the slide plan exploded, then compress aggressively at ~47 sec/slide before any rendering. Design the visual arc — the flip-book story across the WHOLE deck — and the canonical recurring object BEFORE the image narrative; iterate the image narrative WITH the user BEFORE any generation fires. Write the script after the slide plan exists, in the speaker's voice, at ~140-150 wpm with a real buffer. Smoke 3 slides, then batch 10, then full deck — never autonomous, always cost-aware. Stand up the resource pack repo early so the closer's QR has a real destination. Dry-run twice; clock and flag, never coach. Export the PDF, upload to the organizer's Google Form, comment the gammaUrl into the Asana hub, and stop. Delivery is the human's job; post-talk content extraction is `/zig-voice`'s. The talk repo is mineable historical state for the next talk neighbor — that's the whole skill.
