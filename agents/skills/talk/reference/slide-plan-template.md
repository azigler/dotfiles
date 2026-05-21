# Slide plan — template

Per-slide architecture. Lives at `deck/slide-plan.md`. The slide plan
is the spine; the talk script's H3 headings mirror it; the image
narrative's per-slide depictions are downstream.

---

## Header

```
# Per-slide plan — {{TALK_TITLE}} deck ({{N}} slides, compressed)

Every slide gets: **#** / **Beat** / **Display duration** / **Role** /
**Speaker line(s)** / **Visual concept** / **Text on slide** / **Image source**.

Default text on slide is EMPTY. Bold-phrase slides are the exception,
not the rule.

**Compression note (this version).** This deck was compressed from
{{N_OLD}} slides to {{N_NEW}} slides per {{REASON}}. Total runtime
{{HELD / DRIFTED}} at ~{{N}} min. Per-beat before/after, decisions, and
concerns live in `deck/compression-report.md`.

Image-source values:
- `existing-render` — already rendered at `gamma/images/`
- `brief-NN` — referenced existing brief in `gamma/image-briefs.json`
- `new-brief` — needs new brief staged in a follow-on subagent pass
- `mermaid` — Mermaid diagram render (not nano-banana)
- `paper-figure` — designed in Gamma / external tool, not nano-banana
- `typography-only` — text IS the visual; no image needed
- `screenshot` — annotated source screenshot
```

---

## Per-slide block

Repeat for each slide. Use H3 for slide titles so the script's H3
headings can mirror exactly.

```
### Slide N — Short title

- **Beat:** {{0-5}}
- **Display:** ~{{N}} sec
- **Role:** {{anchor / artifact / bold callout / typography}}
- **Speaker line:** *"{{What the human says while this slide is up.}}"*
- **Visual concept:** [Arc position: {{one-line arc note}}.] {{One paragraph of visual specification — composition, palette, foreground/background subjects, what the canonical recurring object is doing in this frame, what continuity hook ties it to the next slide.}} *Continuity hook: {{what carries forward}}.* See `deck/visual-arc.md`.
- **Text on slide:** {{none | "exact verbatim text"}}
- **Image source:** {{one of the seven values above}}
```

Notes:

- **Visual concept is one paragraph, not a bullet list.** It needs to
  read as a brief the image agent can act on cold.
- **Arc position note in square brackets** at the start. Without it,
  the image agent loses the through-line.
- **Continuity hook in italic** at the end. Identifies what carries
  forward to the next slide.
- **Speaker line in italic quotes.** Mirrors the script's verbatim
  prose exactly.
- **Bold-phrase slides have a "Text on slide" entry** with the verbatim
  text. Image-only slides have `none`.

---

## Beat dividers

Use H2 for beat boundaries. Format:

```
---

## Beat N — {{Beat title}} (slides A–B) — {{N}} min

{{Optional one-paragraph beat-level notes — what the beat opens with,
what it lands, what gets dropped if over budget.}}
```

---

## Compression report format (`deck/compression-report.md`)

Lives separately from `slide-plan.md`. The audit trail for the
compression discipline.

### Section 1 — Executive summary

- **Cut**: {{N_OLD}} slides → {{N_NEW}} slides (Δ{{%}} cut)
- **Runtime**: {{HELD / DRIFTED}} at ~{{N}} min
- **New per-slide pacing**: ~{{N}} sec (was ~{{N_OLD}} sec)
- **What's preserved**: every non-negotiable load-bearing slide (list
  them explicitly — bold-phrase spine slides, lesson punctuations,
  takeaway card, closer)
- **What got cut**: top 3 patterns (e.g., redundant bold-text,
  multi-slide stat reveals collapsed to one card, multi-slide
  anecdotes collapsed to one sustained image)
- **Welcome simplification**: deck size now within Gamma cap → single
  generation vs. split-and-merge

### Section 2 — Per-beat before/after table

| Beat | Old | **New** | Δ | Rationale |
|---|---|---|---|---|
| 0 — {{Title}} | N | **N** | -N | {{One-paragraph why}} |
| 1 — {{Title}} | N | **N** | -N | {{One-paragraph why}} |
| 2 — {{Title}} | N | **N** | -N | {{One-paragraph why}} |
| ... | | | | |
| **Total** | **N** | **N** | **-N** | Average per-slide display: ~N sec |

### Section 3 — What's preserved (and why)

#### Non-negotiable bold-phrase slides

| Slide | Phrase | Why load-bearing |
|---|---|---|
| {{N}} | **{{phrase}}** | {{Why this slide can't be cut}} |

#### Lesson recognition-punctuation slides (each lesson appears EXACTLY ONCE in flow)

| Slide | Lesson | Why load-bearing |
|---|---|---|
| {{N}} | **{{lesson name}}** | {{Why this slide can't be cut}} |

(Per anti-listicle test: each lesson appears exactly twice — once as
recognition punctuation in flow, once on the takeaway card. Both
appearances preserved. Five separate slides {{not}} bunched together.)

### Section 4 — What got cut (and why)

For each cut slide or block, one paragraph:
- **Cut slide(s)**: {{N or N-M range}}
- **Old role**: {{what it did}}
- **Reason for cut**: {{redundant bold-text / multi-slide expansion of
  one beat / etc.}}
- **What absorbs the cut content**: {{the surviving slide(s) the spoken
  line now lands against}}

### Section 5 — Judgment calls

The non-obvious decisions. Each one a paragraph documenting:
- **What was cut / kept**
- **The argument for cutting it**
- **The argument for keeping it**
- **Why we landed where we did**

### Section 6 — Concerns

What the compression introduced that we should watch for in dry runs:
- **Per-slide display now N sec** — if the speaker rushes, slides flip
  too fast for the audience to absorb. Dry runs should verify the
  speaker holds long enough.
- **Bold-phrase frequency** — N bold-phrase slides across N total. If
  it reads as too many bold callouts in a row, dry run will surface
  it.
- **Specific risky transitions** — list the seams that may feel abrupt
  given the cuts, so dry runs can validate them.
