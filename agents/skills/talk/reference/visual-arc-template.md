# Visual narrative arc — template

Lives at `deck/visual-arc.md`. The flip-book / comic-book story shape
across the WHOLE deck, designed BEFORE the image narrative or any
generation.

This is the highest-leverage step in the talk pipeline. Skipping it
produces a deck that's N unrelated cartoons. Doing it produces a deck
the audience experiences as one continuous story, even if they never
consciously narrate the through-line.

---

## Section structure

```
# Visual narrative arc — {{N}}-slide deck

## Thesis (one sentence)

**{{One sentence describing the audience's visual journey across the
deck, end-to-end.}}**

## The arc shape

{{One paragraph — three to five sentences — that describes beat-by-beat
what changes across the deck. Camera position. Subject scale. Light.
Palette. Where the canonical recurring object is at each moment. The
shape of the journey.}}

## Continuity techniques

Three techniques are woven through the arc — each appears in ≥10
slides and threads the frames together below the audience's conscious
attention.

- **{{Technique 1 name}} progression.** {{What it is, where it's
  dominant, what frames carry it. Each technique should appear in ≥10
  frames; if it doesn't, it isn't a continuity technique — it's a
  one-off.}}
- **{{Technique 2 name}} progression.** {{Same shape.}}
- **{{Technique 3 name}} progression.** {{Same shape.}}

A fourth, lighter technique — **palette pacing** — shifts the dominant
hue per movement, drawn directly from the final-approved Style C
aesthetic register.

**Aesthetic register (verbatim from `gamma/style-c.json`).**
*{{Verbatim copy of the imageOptions.style field — palette, treatment,
era, mood. Carry this register into every frame brief.}}*

**Hard rules (NON-NEGOTIABLE on every frame).** {{NO PEOPLE / NO TEXT /
NO TRADEMARKED LIKENESSES / 16:9 — whatever the talk's hard rules are.
Codify here once so the image narrative + per-slide briefs all
reference the same rules.}}

## The canonical recurring object

The single most-important continuity tool. **Defined ONCE here,
referenced everywhere.** Without this, the image agent re-designs the
recurring object per slide and the deck reads as N different cartoons
stitched together.

The canonical {{X}}: {{Two to four sentences describing the recurring
object — proportions, coloration, simplicity, what's allowed and what
isn't. The image narrative's Section 1.2 references this directly.}}

The canonical X appears in {{N}} of {{TOTAL}} slides — visible (full or
partial) or implied via {{shadow / wheel-tracks / headlight glow /
windshield-POV}}. The slides without the canonical X are typography
frames where the WORLD-AS-GROUND carries the continuity.

## Subject-matter variety palette

| Subject category | Where it appears | Frequency |
|---|---|---|
| {{Category 1}} | slides {{N, N, ...}} | {{N}} |
| {{Category 2}} | slides {{N, N, ...}} | {{N}} |
| {{Category 3}} | slides {{N, N, ...}} | {{N}} |
| ... | | |
| Typography-only frames | slides {{N, N, ...}} | {{N}} — text IS the subject; ground texture echoes the surrounding world |

**Variety summary**: **{{N}} distinct subject categories** across {{N}}
slides. Most-frequent categories are {{X}} ({{N}} — {{why}}), {{Y}}
({{N}}), {{Z}} ({{N}}). **No single category > 5 slides** (the variety
budget). Typography-only slides reuse the surrounding world as their
*ground texture* rather than introducing new motifs.

**Canonical-X presence audit**: canonical X visible (full or partial)
or strongly implied in **{{N}} of {{TOTAL}}** slides — {{above / at /
below}} the ≥{{floor}} target.

## Per-beat visual chapters

### Beat 0 — {{Title}} (slides A–B) — "{{Visual chapter title}}"

- **Visual chapter title**: {{One-line title for the beat's visual
  arc}}
- **Camera position**: {{Wide / close / aerial / interior — what the
  camera does across this beat}}
- **Light**: {{Cool dawn / warming morning / saturated interior /
  golden hour / twilight — time-of-day moves like a real journey
  day}}
- **Palette dominant**: {{Which 2-3 hues dominate}}
- **Canonical-X presence**: {{full / partial / implied}} in every Beat
  N slide
- **Mood**: {{One line — what the audience feels visually}}

### Beat 1 — {{Title}} (slides A–B) — "{{Visual chapter title}}"

{{Same shape, beat-specific.}}

### Beat 2 — {{Title}} (slides A–B) — "{{Visual chapter title}}"

{{Same shape, beat-specific.}}

### ... and so on through every beat ...

## Per-slide visual frames

One line per slide tying it to the arc. The image narrative's per-slide
section is downstream of this — the arc says "what role this frame
plays in the journey"; the image narrative says "what specifically the
image looks like."

| Slide | Beat | Arc role | One-line frame |
|---|---|---|---|
| 1 | 0 | Anchor | {{One-line frame description}} |
| 2 | 0 | Pivot | {{One-line frame description}} |
| ... | | | |
| N | 5 | Closer | {{One-line frame description}} |
```

---

## The discipline behind the technique

**Every continuity technique earns its presence.** A technique that
appears in 3 slides is a one-off, not a continuity tool. ≥10 slides is
the floor.

**Variety ≤ 5 per category.** Without this, the deck collapses into
"many slides of the same thing." If you find yourself writing the same
visual type for 6 slides in a row, you're either over-running a beat
or you missed a category-shift opportunity.

**The canonical recurring object is non-negotiable.** It must be
described ONCE, with proportions and coloration locked, and referenced
everywhere downstream. Anywhere the deck has more than one canonical
recurring object (e.g., "the bus AND the chalkboard"), one is the
spine and the other is a Beat-bound motif.

**Aesthetic register is verbatim.** Whatever the final-approved Style C
`imageOptions.style` field says, copy it into the visual arc verbatim.
The brief and the API call agreeing on register is what produces
visual consistency.

**Hard rules in CAPS.** NO PEOPLE / NO TEXT IN IMAGE / NO TRADEMARKED
LIKENESSES / 16:9. Whatever's wrong on the first generation pass that
you don't want to keep re-fixing — codify it here once.
