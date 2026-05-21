# Dry-run checklist

What to clock, what to flag, what to fix between dry runs. The agent
helps; the agent does NOT replace coaching.

Recommend: ≥1 dry run ≥1 week before delivery; ≥2 dry runs total. Each
dry-run bead is typed `task`, references the talk-script + slide-plan
beads, and carries the runtime data + flagged moments + fixes-applied.

---

## Before the dry run

- [ ] **Latest deck rendered** — the most recent Gamma URL is the one
      being practiced against
- [ ] **Latest script committed** — `deck/talk-script.md` matches what
      the speaker will read
- [ ] **Timer ready** — phone, watch, or stopwatch app
- [ ] **Quiet room** — no interruptions for the full runtime + 10
      minutes for notes
- [ ] **Recording (optional but recommended)** — voice memo on the
      speaker's phone for self-review

---

## During the dry run

The agent's job is **clocking and flagging**, not coaching. The
speaker runs the talk; the agent (or a peer) takes structured notes.

### What to clock

- **Per-beat timing**: start each beat, note the wall-clock; difference
  is the beat's spoken time
- **Total runtime**: from "I used to be a teacher" (first spoken word)
  to "Thank you" (applause anchor)
- **Per-slide hold time** for the load-bearing slides — bold-phrase
  spine slides especially. If the speaker rushes a bold phrase, that's
  a coaching moment.
- **Pause discipline** — does the speaker hold the silences the script
  marks with `*(Beat.)*`?

### What to flag

- **Lines that landed flat** — read OK on paper but rushed off the
  tongue. Mark the slide # for revision.
- **Transitions that dropped energy** — beat-to-beat seams where the
  audience would feel the rhythm break. Mark the slide # before/after.
- **Filler words** — "um" / "so" / "like" / "you know" — count them
  per beat as a delivery proxy (not for editing the script; for the
  speaker's awareness).
- **Stumbles + recovery** — where the speaker hesitates and what they
  pivot to. Often the script's wording is at fault.
- **Pacing drift** — if Beat 2 went 90 seconds over budget, where did
  that time come from? Specific slides, specific lines.

### What to NOT flag

- Vocal delivery (projection, modulation, gesture) — the agent doesn't
  have ears; the speaker has a coach or peers for that
- Charisma / stage presence — same
- Whether the speaker "looks confident" — same
- Whether the audience would laugh / nod / sit up — same

---

## After the dry run

### Build the runtime table

```
| Beat | Target | Actual | Δ | Notes |
|---|---|---|---|---|
| 0 — Hook | 1.5 min | 1.4 min | -0:06 | OK |
| 1 — Setup | 4.0 min | 4.7 min | +0:42 | Slide 5 + 6 ran long; tighten |
| 2 — Centerpiece | 14.5 min | 16.0 min | +1:30 | Per-slide hold too long on artifact slides |
| 3 — Application | 7.0 min | 6.8 min | -0:12 | OK |
| 4 — Takeaway | 2.0 min | 1.9 min | -0:06 | OK |
| 5 — Closer | 2.0 min | 2.1 min | +0:06 | OK |
| **Total** | **31.0** | **32.9** | **+1:54** | over budget; cut from Beat 2 |
```

### Build the flag list

For each flagged moment:

- **Slide #** — the slide where it happened
- **Symptom** — landed flat / energy dropped / speaker stumbled / over
  time
- **Likely cause** — script wording / pacing / transition seam / slide
  composition
- **Proposed fix** — script tightening / slide cut / slide swap / no
  change

### Update artifacts

- `deck/talk-script.md` — apply the script-side fixes
- `deck/slide-plan.md` — note any slide changes
- `gamma/style-c.json` — re-stage if a slide's image brief changed
- Bead trail: update the dry-run bead with the runtime table + flag
  list + fixes-applied

### Decide on a re-fire

- **If the runtime drift is ≤30 sec**: tighten via script edits
  (reading-faster won't make 30 seconds disappear; cut content)
- **If the runtime drift is 30 sec - 2 min**: cut ONE slide from the
  longest beat, or compress two adjacent slides into one
- **If the runtime drift is >2 min**: the spec is wrong. Re-rev the
  spec's Beat-by-beat timing budget; don't try to deliver a 33-minute
  talk in a 30-minute slot.

### Schedule the next dry run

- ≥48 hours after the first dry run (let the changes settle in the
  speaker's memory)
- ≥1 week before delivery (the second dry run should be the last
  major-revision opportunity)
- Same conditions: quiet room, timer, recording optional

---

## Dry-run-to-delivery cadence

| When | What | Goal |
|---|---|---|
| 2 weeks before | First dry run | Find the structural issues — runtime drift, beat-seam problems |
| 1 week before | Second dry run | Confirm fixes from the first dry run; runtime within budget |
| 3-5 days before | Third dry run (if needed) | Final pacing pass; speaker's familiarity locks in |
| Day before | Deck final + uploaded | PDF exported, organizer Google Form upload done |
| Day of | Day-of checklist (`reference/day-of-checklist.md`) | Laptop + adapter + clicker + organizer contact ready |

---

## Anti-patterns

- ❌ **Coaching the speaker.** The agent's notes are *structural*, not
  performative. "Slow down on slide 7" is a coaching note; "slide 7
  ran 8 seconds short" is a structural note.
- ❌ **Treating dry runs as optional.** They aren't. The first dry run
  ALWAYS surfaces something; the second confirms the fix. Skipping
  them means discovering the problem during delivery.
- ❌ **Practicing alone without a clock.** Without a clock, the
  speaker doesn't know if they're on time. With a clock, the clock is
  the data; the speaker is the experiment.
- ❌ **Over-revising between dry runs.** Major rev should land in the
  first dry run; the second dry run is for confirmation, not new
  rewrites. Last-week rewrites destabilize the speaker's familiarity.
- ❌ **Re-running Gamma full-deck between dry runs.** The deck is
  largely locked by the time dry runs start. Edit the script, not the
  deck — unless a flagged moment is genuinely a slide problem (not a
  script problem).
