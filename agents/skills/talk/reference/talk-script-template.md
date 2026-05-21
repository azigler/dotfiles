# Talk script — Google Doc Tab 1 template

The delivery-ready prose, in the speaker's voice. Lives at
`deck/talk-script.md` and is mirrored to Tab 1 of the talk's Google
Doc (Tab 2 is the image narrative). The user reads, edits, and
practices off this tab.

---

## Word-count math

- ~140-150 wpm comfortable speaking pace
- 30-min talk = ~4,200-4,500 words
- 35-40 min talk = ~5,000-5,500 words
- **Budget for ~10% buffer** (laughs, beats, applause anchor) — write
  to 90% of the spoken minutes

Verify at draft-end: `wc -w deck/talk-script.md`. Compare to budget.

---

## Heading hierarchy

| Level | Use for |
|---|---|
| **H1** | Title + delivery metadata (date, runtime target, venue, audience) — appears ONCE at the top |
| **H2** | Per beat — mirrors the slide plan's beat dividers |
| **H3** | Per slide — mirrors the slide plan's per-slide spec |
| **Bold inline** | Lessons / spine lines at recognition-punctuation moments |
| **Italic** | Stage directions ("(Beat.)" / "(Andrew walks to position.)") |
| **Plain prose** | The actual spoken text |

The H3 hierarchy mirrors the slide plan exactly. If the slide plan has
"Slide 7 — Examples > Rules", the script has "### Slide 7 — Examples >
Rules" with the spoken paragraph(s) underneath. This makes the script
greppable by slide number and keeps the deck-and-script in sync.

---

## Document shape

```
# {{TALK_TITLE}} — Talk Script

*Target runtime: ~{{N}} min spoken at {{N}} wpm. {{CONFERENCE}} {{YEAR}},
{{TRACK}}. {{DATE}} at the {{VENUE}}, {{ROOM}}. {{ASPECT_RATIO}} slides.
{{Q&A_FORMAT}}.*

## Beat 0 — {{Title}} (~{{N}} min)

### Slide 1 — {{Slide title}}

*(Stage direction in italic — what the speaker is doing while the
slide is up.)*

### Slide 2 — {{Slide title}}

The first paragraph of spoken prose. One thought per sentence,
delivery-ready. No buzzwords, no marketing register. The speaker reads
this verbatim or near-verbatim.

*(Beat.)*

A second paragraph if the slide carries a longer spoken line.

### Slide 3 — {{Slide title}}

**The bold-phrase spine line.**

*(Beat. Hold the line. Slide changes.)*

The follow-on context after the bold phrase lands.

## Beat 1 — {{Title}} (~{{N}} min)

### Slide 4 — {{Slide title}}

...

### Slide 5 — {{Slide title}}

...
```

---

## Voice rules

Apply [`/zig-voice`](../../zig-voice/SKILL.md) (or whatever voice
anchor the talk's CLAUDE.md declares) on every pass. Common
anti-patterns:

- ❌ "delve" — auto-fail
- ❌ "leverage" (as a verb) — auto-fail
- ❌ "plot twist" / "here's the thing" / "so here's the thing" —
  auto-fail
- ❌ "let me tell you" / "let's talk about" — flag for tightening
- ❌ Em-dash density > 1 per 200 words — count and reduce
- ❌ Adverb stacking (very / really / actually) — reduce
- ❌ Marketing-deck register ("transformative," "next-generation,"
  "best-in-class") — replace with concrete language
- ❌ Listicle structure when the title implies a list — recognition-in-flow
  beats numbered enumeration

Read the script aloud at every revision. If a sentence stumbles in the
mouth, rewrite for spoken cadence.

---

## Stage directions

Use italic in parentheses. Examples:

- *(Andrew walks to position. Lights low. The title slide is on. Beat.
  He looks up at the room before he speaks.)*
- *(Beat.)*
- *(Slide changes.)*
- *(Pause. Hold the silence.)*
- *(Aside, lower energy.)*

Stage directions are for the speaker, not the audience. They don't get
spoken. They're delivery cues that anchor pacing and breath.

---

## Bold-phrase rendering

When a bold-phrase slide hits, the script shows the phrase **on its
own line**, surrounded by stage directions:

```
### Slide N — {{Bold phrase title}}

*(The setup line that lands the bold phrase.)*

**The bold phrase.**

*(Beat. Hold the line.)*

The follow-on context.
```

The speaker holds the bold phrase. The slide is the bold phrase. The
audience absorbs both.

---

## Numbers + citations

When the script cites stats, include the source inline as plain text
(no footnote markup — the script is for delivery, not publication):

> *"Five hours, around a hundred teams, and the brief was: parse 97,000
> synthetic enterprise documents. **Top 20.**"*

The cited number traces back to the spec's test case ("Numbers
source-verified") and to a source in `refs/` (the paper, the repo,
the dev log). If you can't trace it, don't cite it.

---

## Closer mechanics

The closer hands off to whatever the format is — Office Hours room,
Q&A in-place, next track, etc. Per the talk's CLAUDE.md `Q&A` field.

Pattern:

```
### Slide N — Closer

The wrap-up sentence — one or two lines that land the talk's thesis
in the speaker's voice.

The QR / URL / next-step line — concrete, actionable, single sentence.

*(Office Hours invitation, next door — or whatever the format is.)*

**Thank you.**

*(Applause anchor. Hold for a beat. Exit.)*
```

The "Thank you" is the applause anchor. It tells the audience the talk
is over.

---

## Mirror policy (script + image narrative on different tabs)

Per `/gdoc`:
- **Tab 1**: this document — the talk script
- **Tab 2**: the image narrative

The user reads both in sync. The orchestrator does NOT combine them
into one tab — the script is delivery-shaped prose; the image
narrative is image-agent-shaped per-slide depictions. They share a
container (one Google Doc) but stay separate documents inside it.

When the user comments on Tab 1, the comment is about delivery
(pacing, voice, runtime). When the user comments on Tab 2, the comment
is about images (composition, palette, the canonical recurring object).

---

## Verification before final state

Before tagging the script as final:

- [ ] Word count within the runtime budget (10% buffer)
- [ ] `/zig-voice` audit clean (no anti-patterns)
- [ ] Em-dash density ≤ 1 per 200 words (`grep -o "—" deck/talk-script.md | wc -l` ÷ word count × 200)
- [ ] H3 headings match the slide plan exactly (script + slide plan in sync)
- [ ] All bold-phrase slides show the phrase on its own line, in bold
- [ ] Numbers cited trace to a verifiable source in `refs/` or an
      external paper/repo
- [ ] Closer ends with "Thank you" as the applause anchor
- [ ] Stage directions in italic, one delivery cue per moment
