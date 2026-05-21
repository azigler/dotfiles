# 3-style framework — deeper dive

The same outline, three control levels. This framework was pioneered
in the AI Council 2026 talk project; it generalizes to any
Gamma-based deck workflow.

## The framework at a glance

| Style | `textMode` | `cardSplit` | What you control | Gamma owns |
|---|---|---|---|---|
| **A — Overarching theme** | `generate` | `auto` | Outline + style brief | Slide breaks, copy, images, layout |
| **B — Slide-by-slide theme** | `generate` (or `condense`) | `inputTextBreaks` | Per-slide brief + slide breaks | Copy in your voice, images, layout |
| **C — Deterministic** | `preserve` | `inputTextBreaks` | Exact slide text + breaks | Image selection, layout |

The variable across the three is **how much text Gamma writes for
you**. A: all of it. B: most of it, guided. C: none of it.

## When to pick each

### Style A — when you don't know the deck yet

You have a thesis and 5-7 bullets. You don't have slide-by-slide
copy. You want fast feedback on aesthetic + voice + slide count.

**Costs**: same as B and C (~4-5 credits per slide); credits are not
the differentiator.

**Risk**: Gamma's copy may not match your voice. The deck might over-
or under-shoot the slide count you wanted.

**Antidote**: read the result, decide if voice is salvageable. If
yes, iterate on `textOptions.tone` + `additionalInstructions`. If no,
move to Style B (you write per-slide briefs in your voice; Gamma
writes copy guided by them).

### Style B — when you have structure but not copy

You know what each slide is about — you've written a 1-2 sentence
brief per slide — but you haven't drafted the actual on-slide text.
You want Gamma to write copy in your voice, but you want to control
which slides exist and what's on each.

**Best balance** of quality + control for most decks.

**Risk**: Gamma may over-write — adding ledes, bullet expansions,
takeaway lists you didn't ask for. Mitigate with
`textOptions.amount: "brief"` and an explicit
`additionalInstructions` directive: *"Do not add ledes, bullets, or
takeaway lists. The speaker carries the narrative."*

### Style C — when copy is locked

You have the exact text for every slide. Some slides are
typography-only ("Examples > Rules"); some are image-only (empty
text); some are bullet lists. You want Gamma to do layout + image
selection — nothing else.

**Most predictable output**. Ship-grade.

**Risk**: layout still autonomous (see
[layout-workarounds.md](layout-workarounds.md)). You control the
text but not where the image lands.

**Antidote**: pair Style C with workaround #2 (inline raw image
URLs) when layout matters. Pre-generate images via `/openrouter`,
host at HTTPS, drop URLs in `inputText` adjacent to the slide they
belong to.

## How the knobs interact

| Combination | Behavior |
|---|---|
| `textMode: "generate"` + `cardSplit: "auto"` | Style A — Gamma decides everything |
| `textMode: "generate"` + `cardSplit: "inputTextBreaks"` | Style B — you control breaks; Gamma writes copy |
| `textMode: "condense"` + `cardSplit: "inputTextBreaks"` | Style B variant — you wrote dense briefs; Gamma compresses to slide-shape |
| `textMode: "preserve"` + `cardSplit: "inputTextBreaks"` | Style C — full text control |
| `textMode: "preserve"` + `cardSplit: "auto"` | Anti-pattern — Gamma can't break content it can't rewrite. It will likely produce one giant slide or refuse cleanly. Use `inputTextBreaks` when preserving. |

### Ignored fields by mode

`textMode: "preserve"` voids `textOptions.tone` / `audience` /
`amount`. Set `additionalInstructions` for stylistic / image guidance
instead — that field is honored across all modes.

`cardSplit: "inputTextBreaks"` voids `numCards` (Gamma derives the
count from `\n---\n` segments). Don't try to force a count when
you've supplied breaks.

The submit-response `warnings` field lists every ignored override.
Read it.

## Migration patterns

**Start at A, end at C.** Common workflow:

1. **Round 1 — Style A** to validate aesthetic and slide count.
   You're tuning `imageOptions.style`, `textOptions.tone`,
   `themeId`. The copy is throwaway.
2. **Round 2 — Style B** once aesthetic is locked. You write
   per-slide briefs; Gamma writes copy in the voice you chose. You
   review per-slide copy, edit briefs, re-render.
3. **Round 3 — Style C** for the final pass. You take Gamma's
   round-2 copy, edit it to ship-quality, paste into a Style C
   payload, and lock the deck.

**Stay at A for low-stakes decks.** Internal-only readouts, draft
proposals, brainstorm visuals — the time savings outweigh the
quality risk.

**Skip to C for repeat templates.** If you ship the same deck shape
weekly (status report, sprint review), write Style C once with
templated text and edit per-week values. Round-trip cost: one
generation per cycle, no draft iterations.

## Common pitfalls

- **Style A with `additionalInstructions` that contradicts
  `textOptions.tone`**. Gamma usually honors the more specific
  signal (the in-prompt instruction); pick one source of truth.
- **Style B with overlong briefs** — if your brief is itself paragraph
  copy, Gamma may pass it through nearly verbatim, or condense it
  oddly. Use `textMode: "condense"` to make compression explicit.
- **Style C with paragraph bodies treated as titles** — Gamma renders
  the first non-empty line of each segment as the slide title in
  most themes. If you want body-only with no title, prefix the
  segment with an empty line + a short headline, or design the
  theme to suppress title rendering.
- **Mixing styles within one payload** — there's no per-slide
  `textMode`. The whole payload picks one. If half your deck is
  locked copy and half is briefed, render two payloads and merge in
  the Gamma editor.

## See also

- [layout-workarounds.md](layout-workarounds.md) — when text control
  isn't enough, layout direction.
- [example-deterministic.json](example-deterministic.json) —
  canonical Style C payload.
- [SKILL.md](../SKILL.md) — top-level skill body.
