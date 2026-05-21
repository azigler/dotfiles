# Image narrative — Google Doc Tab 2 template

The canonical source of truth for the deck's image plan. Lives at
`deck/image-narrative.md` and is mirrored to Tab 2 of the talk's
Google Doc (Tab 1 is the talk script). The user iterates on this tab;
the orchestrator restages Gamma per-slide notes from this document; no
Gamma fires until the user approves a complete pass.

`deck/visual-arc.md` and `deck/slide-plan.md` are downstream of this.

---

## Section 1 — Base aesthetic and rules

### 1.1 Hard rules (NON-NEGOTIABLE)

Whatever's wrong on the first generation pass that you don't want to
keep re-fixing — codify here once. The image agent reads these
verbatim. Examples:

- NO PEOPLE OF ANY KIND. {{No children, no adults, no figures, no
  silhouettes, no hands, no body parts. The {{X}} is empty — windows
  show a warm cream-marigold glow rather than figures.}}
- NO WRITING / WORDS / LETTERS / TEXT inside any image. Zero readable
  characters. NO EXCEPTIONS — no chalkboard text, no labels, no signs,
  no readable rules, no diagrams with text, no annotated screenshots,
  no notebook content visible. (Annotated screenshots stay as a
  separate Gamma layer over a clean image.)
- NO TRADEMARKED CHARACTERS / DESIGNS. {{No specific show character
  likenesses, no wordmark, no trademarked silhouettes.}} The {{X}} is
  a GENERIC abstract {{description}}, NOT the show's specific design.
- 16:9 frames throughout.

### 1.2 The canonical recurring object

{{The X}} is the recurring through-line. It appears in {{N}} of {{N}}
slides and **must look IDENTICAL every time it appears**. Same
proportions, same coloration, same simplicity. **Defined ONCE here;
referenced as "the canonical X" in every per-slide entry.**

The canonical {{X}}: {{Two to four sentences describing the object
— proportions, coloration, line weight, what's allowed, what's
forbidden. NO ROOFTOP DETAILS, NO LOGO, NO WORDMARK, etc.}} The {{X}}
reads as a {{child's-drawing simplification / iconic flat shape /
specific style descriptor}}, not a photographic rendering. **Same
proportions, same coloration, same simplicity in EVERY appearance.**

### 1.3 The aesthetic register

{{Verbatim from gamma/style-c.json's imageOptions.style field — palette,
treatment, era, mood. Carry this register into every frame.}}

Examples (replace with talk-specific):

- 1990s educational-cartoon aesthetic at PEAK hand-painted-cel quality
- VIBRANT vintage palette — saturated mustard yellow, vivid teal,
  fire-engine red, kelly green, royal purple, with cream highlights
- RICH and PUNCHY, not washed-out, not modern rainbow
- Hand-painted-cel look: bold black ink outlines, flat shaded fills,
  painterly highlights, slight paper-grain texture
- Strong tonal contrast

### 1.4 The detail discipline

**Less is more.** Each frame is iconic, simple, child's-drawing-clear.
Empty space is a virtue. **ONE primary subject per frame.**

AVOID: secondary props, background clutter, detail flourishes,
ornamental textures, stuff-stuffing, multiple competing focal points.

**If a frame can be reduced from four elements to two, reduce it.**
Misalignment opportunity scales with element count.

---

## Section 2 — The arc shape

{{One paragraph — three to five sentences — describing the audience's
visual journey end-to-end. References the canonical recurring object
as the through-line. Drawn from `deck/visual-arc.md` so this doc is
self-contained when the user reads it on their phone.}}

---

## Section 3 — Per-slide depictions

Every entry references "the canonical {{X}}" rather than re-describing
it. Each is **under 80 words**, distilled, iconic. The image agent
reads only this entry plus Sections 1.1-1.4 — no other context.

Format per entry:

```
### Slide N — {{Short title}}

Arc position: {{one-line arc note — where in the journey is this}}
Depiction: {{Up to 80 words. Specific composition, foreground subject,
background ground, what the canonical X is doing in this frame, what
NOT to include. References "the canonical X" verbatim. ONE primary
subject. Stops short of micro-management.}}
```

Examples:

```
### Slide 1 — Title hero

Arc position: dawn, the schoolyard, ready to board.
Depiction: simple schoolhouse exterior at cool dawn. The canonical bus
parked at the curb, doors open, facing the schoolhouse. Sky in cool
teal with a marigold sunrise behind the rooftop. Generous empty
upper-third for the title overlay. ONE bus, ONE schoolhouse, ONE sky.
Nothing else in the frame.
```

```
### Slide 7 — Examples > Rules — EXISTING RENDER, survives without re-render

Arc position: the wall has peeled; contrast between rule-grid and
methodology-cluster.
Depiction: existing render `gamma/images/03-examples-over-rules.png` —
small dim corduroy-grid block on the left vs. glowing beaded clay
cluster on the right. Composition reads as the contrast the spine line
names. No re-render.
```

```
### Slide 10 — your AI agents are first-graders right now

Arc position: typography frame, fully inside the device.
Depiction: deep cobalt background with a few simple marigold
circuit-trace lines. ONE color field plus a few traces. Typography is
the slide.
```

Keep entries lean. The image agent doesn't need to know the speaker
line; it needs to know what the frame LOOKS like and what NOT to put in
it.

Mark per-entry:
- **Existing renders** that survive without re-render — `EXISTING RENDER, survives without re-render`
- **Typography-only frames** — "Typography is the slide" + the
  background ground that carries the world
- **Slides that are paper-figure / Mermaid / screenshot** — note the
  layer model: the image is the BACKGROUND; the text/diagram is a
  separate Gamma overlay

---

## Section 4 — How we iterate

The image narrative is the **source of truth for image generation**.
Iteration loop:

1. **User reviews** the per-slide depiction list (Section 3) on Tab 2
   of the Google Doc.
2. **User leaves comments** on specific entries — "make this simpler,"
   "drop the second prop," "the canonical X is wrong here," etc.
3. **Orchestrator updates** the per-slide entry on Tab 2 to match the
   user's comment.
4. **Orchestrator re-stages** the Gamma payload (`gamma/style-c.json`
   inputText + per-slide image-style brief) per the updated entries.
5. **Orchestrator fires** Gamma per the smoke→batch→full sequence,
   confirming credit cost with the user before each fire.
6. **Repeat** from step 1 until the user approves a full pass.

**No Gamma fire until a complete pass is approved.** Iterating on the
narrative is free; iterating on Gamma renders costs credits per fire.

When the user approves: tag the version in the doc tab name (e.g.,
"Image Narrative v3 — APPROVED 2026-05-08"), commit
`deck/image-narrative.md` with a `Bead: <id>` trailer, and proceed to
Step 9 of the `/talk` pipeline.

---

## Notes on Tab 1 / Tab 2 mechanics

Per `/gdoc`:
- The shim's `gdoc.sh write <docId> <tabId>` is **broken** for per-tab
  writes — it inserts HTML as literal text. Use the no-tabId form for
  single-tab docs; for multi-tab docs that need targeted writes, use
  bun inline.
- Tab listing: `./scripts/gdoc.sh tabs <docId>`.
- Tab reads: `./scripts/gdoc.sh read <docId> <tabId>`.
- See `/gdoc` for the full per-tab write pattern.

Mirror policy:
- `deck/image-narrative.md` (the repo file) is the canonical source of
  truth.
- Tab 2 of the Google Doc is the user-facing collaboration surface.
- After every meaningful update, the orchestrator pushes the repo file
  → Tab 2 (so the user always reads the latest).
- After every user comment, the orchestrator copies the comment thread
  context into the bead's `--notes` field for posterity.
