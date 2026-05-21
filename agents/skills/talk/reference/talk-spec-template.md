# Talk spec — template (Sections 1-7)

Mirror of `/spec`'s 7-section shape, talk-specific contents. The spec
lives in a typed `spec` bead's `--description` field; iterations
supersede prior revisions but **do not close prior beads** — the
trail is the value.

---

## Section 1 — Overview

What this talk is, who it's for, what they leave with. ≤200 words.

- **Title** (locked): *{{TITLE}}*
- **Conference / track / date** (locked): {{CONFERENCE}} / {{TRACK}} / {{DATE}}
- **Speaker** (locked): {{NAME}}, {{SOLO_OR_PAIRED}}
- **Runtime target** (locked): {{N-N}} min ideal per organizer
- **Audience profile**: {{WHO_IS_IN_THE_ROOM}}
- **One-sentence thesis**: *{{THESIS_SENTENCE}}*
- **Audience promise**: {{WHAT_THEY_LEAVE_WITH}}

---

## Section 2 — Baseline

The unchangeable contract with the host and the audience. Anything
below this baseline breaks the contract.

### 2.1 The abstract (verbatim)

{{Abstract from the public talk page, character-for-character.}}

### 2.2 Screening-call commitments

{{What you committed to verbally — the framing, the structural choices,
the format. Verbatim from the screening-call transcript when present.
Each commitment is a bullet; cite the transcript line.}}

### 2.3 Organizer-locked logistics

| Field | Value | Source |
|---|---|---|
| Runtime | {{N-N}} min | prep email |
| Slide format | {{ASPECT_RATIO}} | prep email |
| A/V | {{HDMI / USB-C / OTHER}} | prep email |
| Q&A format | {{ON_STAGE / OFFSTAGE / NONE}} | prep email |
| Final-deliverable upload | {{GOOGLE_FORM / EMAIL / PORTAL}} | prep email |
| Recording | {{YOUTUBE_CHANNEL_OR_OTHER}} | prep email |

---

## Section 3 — Changes from baseline

Post-acceptance evolution. The talk has moved since the abstract was
written; document what changed and why.

Examples (one bullet each):
- {{Trajectory framing emerged on the screening call (e.g., "5 lessons
  as a methodology trajectory" — referenced by the host)}}
- {{Audience-shape adjustment — the public page said "engineers and
  builders" but the track is Analytics & Data Science → frame as DS
  first}}
- {{Runtime change — Katie said 20-30 on the screening call; the prep
  email said 35-40 → go with the prep email}}
- {{Structural choice — Magic School Bus episode shape as hidden
  scaffolding}}
- {{Hard cut — single-case-study framing replaced by lessons-learned
  trajectory}}

---

## Section 4 — Beat-by-beat outline with timing budget

Per-beat duration / role / narrative function. Total ≤ runtime minus a
buffer.

| Beat # | Title | Duration | Role | One-line summary |
|---|---|---|---|---|
| 0 | Hook | ~1.5 min | Anchor | {{What this beat does}} |
| 1 | {{Title}} | ~4.0 min | Setup | {{What this beat does}} |
| 2 | {{Title}} | ~14.5 min | Centerpiece | {{What this beat does}} |
| 3 | {{Title}} | ~7.0 min | Application | {{What this beat does}} |
| 4 | {{Title}} | ~2.0 min | Takeaway | {{What this beat does}} |
| 5 | {{Title}} | ~2.0 min | Closer | {{What this beat does}} |
| **Total** | | **~31 min** | | (within {{N-N}} min budget with buffer) |

For each beat, include:
- **What the beat opens with** (the moment-zero of the beat)
- **What the beat lands** (the punchline / lesson / recognition)
- **What slide-types appear** (anchors, artifacts, bold callouts,
  typography frames)
- **What gets dropped if we go over time** (the cut-list, in priority
  order)

---

## Section 5 — Test cases (≥10)

Each test case is a falsifiable statement: when applied to the talk,
either passes or fails. Talk-specific. Examples (adapt to your talk):

1. **Photographable slides** — every slide is legible from row 12 of a
   ballroom and self-explanatory enough to photograph.
2. **Voice anti-patterns** — `/zig-voice` audit shows zero "delve" /
   "leverage" / "plot twist" / "here's the thing"; em-dash density ≤1
   per 200 words.
3. **Recognition-not-listicle** — when the title implies a list
   ("5 Lessons"), each lesson appears once as recognition punctuation
   in flow + once on the takeaway card. Not 5 numbered slides in a
   row.
4. **Numbers source-verified** — every cited stat traces to the paper /
   repo / authoritative source. No Substack-style approximations.
5. **Standalone-without-audio** — slides published with the YouTube
   video make sense without narration.
6. **Closer hands off** — the last beat invites Office Hours / resource
   pack / next track, not on-stage Q&A unless the format includes it.
7. **Runtime within budget** — spoken at ~140-150 wpm, total ≤ runtime
   minus 10% buffer.
8. **Compression-discipline holds** — final slide count is ≤ target
   (commonly 30-45 for 30-40 min); compression-report.md documents what
   was cut and why.
9. **Visual arc through-line** — the canonical recurring object is
   visible (or implied) in ≥75% of frames.
10. **Variety palette in budget** — no single subject category > 5
    slides (per the visual-arc-template's variety rule).
11. **Two-tab discipline** — script and image narrative live in
    different tabs of the same Google Doc; neither tab carries content
    that belongs in the other.
12. **Asana hub current** — most recent Gamma fire's URL is in a
    plaintext comment on the Asana planning task.

Add or replace tests as the talk's specifics demand. Aim for tests that
are cheap to run (`grep`, `wc`, manual visual scan) and rerun against
each spec revision.

---

## Section 6 — Open Questions

Unresolved before drafting. `/check` walks these and produces a typed
`decision` bead with an OQ-by-OQ verdict + Implementation Readiness
summary.

Examples:
- {{Should the {{example}} beat use the {{recent}} hackathon or the
  {{older}} hackathon as the load-bearing case study?}}
- {{Where does the {{methodology-paper}} reference land — Beat 1 setup
  or Beat 2 announcement?}}
- {{How does the closer's QR resolve when the resource-pack repo is
  still being filled out at delivery time?}}

Each OQ has:
- **Context** — why this is open
- **Options** considered
- **Constraint** that decides it (when known)

---

## Section 7 — Future considerations

Post-talk content extraction routes. **Mark explicitly out of scope for
`/talk`.** That's `/zig-voice`'s pickup, fired AFTER delivery against
the YouTube recording + the talk repo.

Examples:
- LinkedIn recap post (one-week post-delivery cadence)
- Blog draft for Dev Interrupted (deeper dive)
- Podcast clip (host-facing assets for Dev Interrupted episode)
- Talk neighbor — the next talk in the same lineage

Flag each as a `/zig-voice`-future bead OR a `/cfp`-future bead, not as
work that this `/talk` project owns.

---

## Spec evolution notes

- **Each rewrite supersedes the prior** — but don't close superseded
  spec beads. The trail is the value.
- **`br update <id> --notes` captures what changed** between revisions.
  The notes field is the live log of why-this-revision-exists.
- **Cite the spec bead's ID in critical commits** (`Bead: <id>` trailer
  per `/commit`).
- **The spec is the contract.** When the slide plan / image narrative /
  script disagrees with the spec, the spec wins. If the spec is wrong,
  rev the spec; don't drift the downstream artifacts.
