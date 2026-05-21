# {{CONFERENCE}} {{YEAR}} — {{TITLE}}

> {{ONE_LINE_TALK_DESCRIPTION}}

## Goal

Build the actual conference talk (deck + speaker notes + handouts +
day-of artifacts) for the **accepted** {{CONFERENCE}} session. The CFP
work is done — this project is execution.

| Field | Value |
|---|---|
| Conference | [{{CONFERENCE}}]({{URL}}) |
| Public talk page | {{URL}} |
| Track | {{TRACK_NAME}} |
| Track host | {{NAME}} ({{CONTACT_FOR_DAY_OF}}) |
| Title (locked) | *{{TITLE}}* |
| Speaker | {{NAME}}, {{SOLO_OR_PAIRED}} |
| Format | {{IN_PERSON_KEYNOTE / IN_PERSON_WORKSHOP / VIRTUAL / HYBRID}} |
| Length | **{{N–N}} min** ideal (per organizer email; supersedes any earlier estimate) |
| **Talk date** | **{{DATE}}** |
| Venue | {{VENUE}}, {{ROOM_OR_BALLROOM}} |
| Stage tech | {{ASPECT_RATIO}} slides, present from own laptop via {{HDMI_OR_USB-C}}, **bring {{ADAPTER_TYPE}}** |
| Q&A | {{ON_STAGE / OFFSTAGE_IN_OFFICE_HOURS / NONE}} |
| Recording | Goes up on {{CONFERENCE}} {{YOUTUBE_OR_OTHER_CHANNEL}} ({{N_SUBSCRIBERS}}) |
| Final deliverable | **{{PDF_OR_PPTX}} export uploaded to {{ORGANIZER_FORM}}** alongside the live deck |
| Audience | {{AUDIENCE_PROFILE}} |
| Asana planning hub | [{{ASANA_TASK_TITLE}}]({{ASANA_URL}}) (gid `{{GID}}`) |
| Asana parent | [{{PARENT_TASK_TITLE}}]({{PARENT_URL}}) (gid `{{PARENT_GID}}`) |

The Asana planning task is the canonical outside-the-repo hub. Post
progress comments, update its description with running links, and drop
Gamma artifact URLs there as the deck takes shape. See `/asana` for
fleet-proxied write mechanics — comments are plaintext (`text` field),
never `html_text`.

## What the talk teaches

**The thesis line.** *{{ONE_SENTENCE_THESIS}}*

**The audience promise.** {{WHAT_DOES_AN_ATTENDEE_LEAVE_WITH}}

**The connecting principle.** {{ONE_LINE_CONNECTING_PRINCIPLE}}

{{N_LESSONS_OR_BEATS_TABLE_HERE_IF_APPLICABLE}}

## Track-specific framing

{{Why this audience, what their language is, what tropes to lean
into, what tropes to avoid. Anything the public talk page +
screening call + prep email together imply about how this talk
must speak.}}

## The trajectory framing (committed on the screening call)

{{Verbatim or near-verbatim from the screening-call transcript —
what the host heard you say you'd build. This locks the talk's
shape. If no screening call: skip this section.}}

## Hidden narrative scaffolding

{{If the deck has a structural metaphor (Magic School Bus episode
shape, hero's journey, something else), describe it briefly here.
Origin scaffolding lives in `refs/talk-beats.md` if it's borrowed
from another project. Surface-level cues stay implicit; structural
load lives in the visual arc, not in the talk's external copy.}}

## Slide / handout doctrine

- **Each slide is a cheat sheet.** Photo-able, standalone, makes
  sense without the spoken track.
- **Slides must stand on their own** — they get permanently
  published alongside the recording.
- **Closer hands off** to {{OFFICE_HOURS_ROOM / Q&A / NEXT_TRACK}}
  with a resource URL / QR pointing to a public artifact (the
  `talk-{{slug}}-resources` repo on `github.com/{{owner}}`).

## Source material to mine

| Source | Why it matters |
|---|---|
| `refs/{{conf}}-page.md` | Verbatim public talk metadata |
| `refs/final-prep-email.md` | Locked logistics: runtime, slide format, A/V, final-deliverable mechanism, venue |
| `refs/screening-call-{{host}}.md` | Trajectory framing committed to the host |
| `refs/talk-beats.md` | Narrative scaffolding (origin: `{{ORIGIN_PATH}}`) |
| `refs/{{aesthetic}}/` | Curated reference image set (image-to-image inputs for nano-banana fusion) |
| `../{{slug}}/` | UPSTREAM CFP repo (proposal, abstract, reviewer comments, prior bios) |
| `../{{closest-talk-neighbor}}/` | Closest talk-shape neighbor (visual arc patterns, slide doctrine) |
| `../{{methodology-paper}}/` | Backing peer-reviewed methodology paper (cite for any quantitative claim) |
| `../{{methodology-paper}}/.beads/issues.jsonl` | Backing data on prep / hackathon stats |

## Image aesthetic — {{REGISTER_NAME}}

The deck's visual register is {{2-3 sentences on the aesthetic — palette,
treatment, era, mood}}.

Generation pipeline:

1. Curate a reference set in `refs/{{aesthetic}}/` (stills, source art,
   close-ups). Convention: YYYY-MM-DD-slug.png + README catalog.
2. Read `~/.claude/skills/openrouter/SKILL.md` and any fusion methodology
   doc relevant to this aesthetic before fusing.
3. **Critical fusion rule** (from `/openrouter`): in the nano-banana API
   call, include the {{primary-aesthetic}} references as actual image-to-image
   inputs; convey {{secondary-aesthetic}} via **text instructions only**
   (so we don't collage). Generated images live in `gamma/images/`.
4. Each generated image gets a short caption + the prompt + the
   reference-set hash, so we can reproduce it later.
5. Image generation is `/openrouter` cost-aware — **never fire
   autonomously**, always confirm cost first.

## Gamma rendering

Default style is **Style C — Deterministic** (`textMode: preserve`,
`cardSplit: inputTextBreaks`) once the slide plan is locked. See
`/gamma`'s 3-style framework and layout workarounds.

Payload bodies live at `gamma/style-c.json` (and `gamma/style-a.json` /
`style-b.json` for the early aesthetic-validation phase).

**Theme:** `{{THEME_ID}}` (the workspace default).

## Deliverables

| Artifact | Where | Status |
|---|---|---|
| Talk spec (typed `spec` bead) | `.beads/issues.jsonl` | TBD |
| Beat-by-beat outline with timing | spec bead Section 4 | TBD |
| Slide plan | `deck/slide-plan.md` | TBD |
| Compression report | `deck/compression-report.md` | TBD |
| Visual arc | `deck/visual-arc.md` | TBD |
| Image narrative | `deck/image-narrative.md` (mirrored to Google Doc Tab 2) | TBD |
| Talk script | `deck/talk-script.md` (mirrored to Google Doc Tab 1) | TBD |
| Slide deck | Gamma URL (pasted into Asana hub) | TBD |
| PDF export | `gamma/exports/<conf>-final.pdf` | TBD |
| Resource pack repo | `github.com/{{owner}}/talk-{{slug}}-resources` | TBD |
| Day-of checklist | typed `note` bead, persistent | TBD |

## Toolchain

- **Beads (`br`) is on.** Every meaningful chunk of work is a typed
  bead. Prefix is `talk-{{slug}}`.
- **Gamma generation API** — see `/gamma`. Cost-aware always.
- **`/openrouter`** for nano-banana image generation when the inline-URL
  layout workaround is needed. Cost-aware.
- **`/gdoc`** for the two-tab Google Doc (script + image narrative).
- **`/asana`** posts progress to the planning hub. Plaintext comments
  via the `text` field — never `html_text` for comments.
- **`/zig-voice`** is the writing voice for any speaker copy that ships
  externally (script, Asana write-ups, social-promo copy).
- **`/onboard` / `/offboard`** bracket every session.

### Credentials we have

- `GAMMA_API_KEY` and `GAMMA_DEFAULT_THEME_ID` per `/gamma`
- `OPENROUTER_API_KEY` per `/openrouter`
- `FLEET_API_TOKEN` for the Asana fleet proxy per `/asana`

## Conventions

- **Voice.** {{`/zig-voice` for Andrew | other voice anchor}}. Em-dash
  density cap: 1 per 200 words.
- **Time budget.** {{N-N}} min target. Beat-level timings in the spec
  bead's Section 4. Total ≤ runtime minus a buffer (~10%).
- **{{HIDDEN_SCAFFOLD}} dose.** Structural scaffold + recurring visual
  motifs only. Do NOT make the metaphor structurally load-bearing in
  copy that ships outside the deck.
- **Numbers must be source-verified.** When citing stats, pull from the
  paper / repo / authoritative source, not blog posts or Substacks.
- **Each slide is a cheat sheet.** Photo-able, standalone, makes sense
  without the spoken track.

## Pipeline

1. **Bootstrap** — beads init, CLAUDE.md, refs imported ☐
2. **Discover constraints** — talk page, screening call, prep email,
   Asana hub, recording venue ☐
3. **Lock the talk spec** — typed `spec` bead, Sections 1-7 ☐
4. **`/check` loop** — multiple iterations expected ☐
5. **Slide plan** — exploded → compressed (~40 slides @ ~47 sec/slide) ☐
6. **Visual arc** — flip-book story, continuity techniques, canonical
   recurring object ☐
7. **Image narrative** — Google Doc Tab 2, iterated WITH user BEFORE
   generation ☐
8. **Talk script** — Google Doc Tab 1, ~140-150 wpm, H1/H2/H3 ☐
9. **Aesthetic iteration** — 3-slide smoke → 10-slide batch → full deck ☐
10. **Resource pack repo** — `github.com/{{owner}}/talk-{{slug}}-resources` ☐
11. **Dry runs** — clock, flag, audit voice (≥1 dry run ≥1 week before; ≥2 total) ☐
12. **PDF export + organizer Google Form upload** ☐
13. **Day-of artifacts** — laptop backup, adapter, slide advancer,
    organizer mobile contact ☐

## Logistics

- **Travel:** {{COVERED / SELF / EMPLOYER}}
- **Lodging:** {{ARRANGEMENT}}
- **Equipment:** {{LAPTOP / ADAPTER / CLICKER / WHATEVER}}
- **On-site arrival:** {{N}} min before talk per prep email
- **Track-host text on arrival:** {{NUMBER}}

## See also

- `/cfp` — UPSTREAM sibling skill (proposal phase)
- `/talk` — this skill (deck-and-script phase)
- `/zig-voice` — DOWNSTREAM (post-talk content extraction)
- `/gamma` — rendering pipeline
- `/gdoc` — two-tab Google Doc mechanics
- `/asana` — planning-hub writes
- `/beads` — task tracking
- `../{{slug}}/` — UPSTREAM CFP repo
- `../{{closest-talk-neighbor}}/` — closest talk-shape neighbor
- `../{{methodology-paper}}/` — backing methodology paper
