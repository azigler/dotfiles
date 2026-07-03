---
description: /randomize -- mandatory protocol for diverse generation. Forces real entropy (seed -> modulo -> choice) into every discretionary creative decision so generation doesn't collapse to the modal default. NEVER narrate "committed choices" without running the seed-and-map arithmetic and recording the provenance block -- the provenance block is what makes it a real randomize. Without it, you prior-collapsed and only pretended to randomize.
when_to_use: Creative generation (copy, image prompts, design choices) where the model would collapse to the modal answer. NOT for single-correct-answer tasks (facts, code, math).
---

# /randomize -- forced real-entropy diversity for creative generation

Mandatory protocol for creative generation where the LLM would otherwise
collapse to its modal response. It forces real randomness (seed -> modulo
-> choice) into every discretionary decision, with a mandatory provenance
block recording the arithmetic.

> Renamed from the `ssot` skill (String Seed of Thought) on 2026-07-03 --
> "randomize" is the accurate name, and it frees "SSOT" for "single source
> of truth."

**Source:** Misaki & Akiba (2025), *String Seed of Thought: Prompting LLMs
for Distribution-Faithful and Diverse Generation*, arxiv 2510.21150.

**If you cannot point to a hex seed and the arithmetic that derived your
choices from it, you did not randomize.** Listing axes and narrating
"committed choices" while actually reaching for the obvious option is a
*ceremonial randomize* -- the exact failure mode §7.3 of the paper calls out
and that this skill exists to prevent.

## The failure mode this catches

You pick an opener because it "feels right for this piece." You reach for a
metaphor because "it's the natural fit." You keep a structure because "it
worked last time." That is prior collapse, not choice. The randomize
protocol makes the choice derive from randomness that has no relationship to
the prior.

Red flags you're doing a ceremonial randomize:

- You describe the seed as "hash of source material + user feedback phrase"
  without running an actual hash.
- Your "committed choice" is also the first option your gut reached for.
- There is no verifiable arithmetic a reviewer can re-run.
- The provenance is a narrative paragraph, not a numbered block.

If any of those apply, stop. Restart the protocol from Step 1.

## The mandatory protocol

### Step 1 -- Generate a real seed (in a shell)

```bash
openssl rand -hex 8
# => e.g., edc165f706616610
```

No approximations. No "hash of the topic" hand-waving. Run the command.
Paste the output into the provenance block. If you are offline, use
`head -c 8 /dev/urandom | xxd -p` or any other real entropy source. If you
don't have a shell, you can't randomize.

### Step 2 -- Enumerate the axes, 0-indexed, write them down

For every axis that will drive the output, write a numbered list of 6-10
candidates. Candidates must be *executable choices* (a reader could tell
two candidates apart from the output alone) -- not vibes.

Standard axes for long-form copy (use as-is or adapt to the piece):

1. **Opening archetype** (~8 candidates): scene-setter / specific-noticing /
   overheard-line / confessional-admission / contradiction /
   direct-address-question / stat-flip / physical-detail /
   in-media-res-quote.
2. **Central metaphor domain** (~6-8): strike the LLM's top-1 prior first,
   then list alternatives (kitchen / sports / music / medicine /
   cartography / poker / theater / construction / detective-work).
3. **Structural shape** (~7): chronological / braided /
   top-down-thesis / bottom-up-discovery / argument-with-objection /
   three-vignettes-one-through-line / Q-and-A / diary-entries.
4. **Rhythm template** (~6): long-paragraph-reflective /
   short-paragraph-punchy / dialogue-heavy / list-light-prose-heavy /
   rhythm-cascade / monologue.
5. **POV distance** (~5): arms-length-observer / co-conspirator-whisper /
   insider-gossip / reflective-reconstruction / fresh-eyes-reporter.
6. **Climax shape** (~6): named-thesis-in-bold / five-point-lesson-list /
   three-short-beats / single-sentence-reframe / overheard-quote-callback /
   return-to-opener.

Add piece-specific axes as needed (title archetype, subtitle angle,
section-level action framings). Each gets its own enumeration.

### Step 3 -- Map the seed to indices (show the arithmetic)

Take a distinct 4-character hex slice per axis (bytes 0-3 for axis 1,
bytes 4-7 for axis 2, etc.). Convert to int. Apply modulo N.

```bash
SEED="edc165f706616610"

# Axis 1: opener archetype, 8 candidates
AXIS1_HEX="${SEED:0:4}"
AXIS1_IDX=$((16#$AXIS1_HEX % 8))

# Axis 2: metaphor domain, 6 candidates
AXIS2_HEX="${SEED:4:4}"
AXIS2_IDX=$((16#$AXIS2_HEX % 6))

# Axis 3: structural shape, 7 candidates
AXIS3_HEX="${SEED:8:4}"
AXIS3_IDX=$((16#$AXIS3_HEX % 7))

# Axis 4: rhythm, 6 candidates
AXIS4_HEX="${SEED:12:4}"
AXIS4_IDX=$((16#$AXIS4_HEX % 6))

echo "axes: $AXIS1_IDX $AXIS2_IDX $AXIS3_IDX $AXIS4_IDX"
```

Use non-overlapping slices so axes are independent. If you need more axes
than the seed supports (4 axes per 16 hex chars), regenerate longer:
`openssl rand -hex 16` gives you 8 axes of headroom.

### Step 4 -- Write the provenance block BEFORE the prose

Paste the computed indices and resolved candidates at the top of the draft
file, in the bead comment, in the doc comment, or in the commit trailer --
somewhere versionable. Format:

```
randomize provenance -- <piece>, <version>, <date>
  seed: edc165f706616610  [openssl rand -hex 8]
  axis 1 (opener archetype, n=8): int(edc1,16)=60865, 60865 % 8 = 1 -> specific-noticing
  axis 2 (metaphor domain, n=6): int(65f7,16)=26103, 26103 % 6 = 3 -> medicine
  axis 3 (structural shape, n=7): int(0661,16)=1633, 1633 % 7 = 2 -> top-down-thesis
  axis 4 (rhythm, n=6): int(6610,16)=26128, 26128 % 6 = 4 -> rhythm-cascade
```

If the block isn't written before the prose, you haven't randomized. If the
arithmetic doesn't match the stated choices, you committed randomize fraud
-- discard the draft and restart.

### Step 5 -- Write against the forced choices

Now layer voice skills (/zig-voice, /linearb-brand, /apex, etc.) on top of
the scaffolding the arithmetic chose. Voice rules apply within the frame.
They do not override the frame.

**Overrides count against you.** If a forced choice is manifestly wrong
(e.g., user stipulated POV=co-conspirator but axis landed on
omniscient-narrator), override once, explicitly, in the provenance block:

```
  axis 5 override: user stipulation (co-conspirator whisper) supersedes
    idx 2 (arms-length observer)
```

More than one override per draft = you are vibing. Regenerate the seed or
prune the axis list to better-matched candidates.

### Step 6 -- On revision, regenerate (or explicitly lock)

Every revision pass gets its own seed. The provenance stacks
chronologically:

```
randomize provenance history
  v1: seed=a1b2c3d4...  (opener=scene-setter, metaphor=cartography, ...)
  v2: seed=e5f67890...  (opener=overheard-line, metaphor=medicine, ...)
  v3: LOCK prior choices, re-roll only axis 4 (rhythm) + axis 6 (climax)
      seed=1a2b3c4d... (rhythm=monologue, climax=return-to-opener)
```

Section-level edits can re-roll just that section's axes. Whole-article
rewrites get a fresh seed and full arithmetic. Lock only when the user has
stipulated a choice or a prior pick tested well in review.

## Provenance block is load-bearing

- **No provenance block -> you didn't randomize.** Regardless of what the
  author claims. Reviewers reject "randomize-generated" content without the
  block.
- **Provenance is verifiable.** A reviewer can re-run `echo $((16#edc1 % 8))`
  and confirm it equals 1. If it doesn't match the stated choice, the author
  committed randomize fraud. Regenerate.
- **Stale provenance is a bug.** If the block says axis 2 = cartography but
  the draft's central metaphor is clearly teaching, the block is lying or
  the draft drifted mid-write. Either way, restart.

## When NOT to randomize

- Single-correct-answer tasks (facts, code, math, structured data
  extraction). Paper §7 explicitly warns the technique distracts on these.
- When the user has stipulated an exact opener, title, metaphor, or
  structure. Don't randomize over user choices -- that's not randomizing,
  that's ignoring the brief.
- Signature voice-markers that are load-bearing by design (e.g., Zig's
  frog emoji stamp on LinkedIn). These are prior by intent.

## Minimum viable randomize (for quick revisions)

When the full six-axis protocol is overkill (one paragraph rewrite, a
subject line, a title pass), use the compressed form. **Arithmetic is still
mandatory:**

```bash
# Quick two-axis pass
SEED=$(openssl rand -hex 4)
# List 4 obvious candidates the LLM would reach for
# Append 2-3 non-obvious ones
# Compute idx = int(seed[0:4], 16) % (total count)
IDX=$((16#$SEED % 6))
echo "picked: $IDX"
```

Still requires a provenance line. The line can be short. But the arithmetic
has to actually run.

## Paper's §7 failure modes (worth re-reading)

1. **Reasoning dependency.** Small models (<8B params) fail to execute
   seed-to-choice mapping at all. Don't expect this to work on weak models.
2. **Positional bias propagation.** If a model only attends to the first
   few chars of a long random string, bias leaks. Use short uniform hex
   seeds and distinct non-overlapping slices per axis.
3. **Lazy strategy adoption.** The one this skill is designed to prevent.
   Model uses the seed ceremonially without letting it drive. Counter with
   the mandatory provenance block and reviewer verification.

## Worked example (verifiable)

From the TDX recap revision, v7 -> v8 handoff:

```
randomize provenance -- TDX recap, v8, 2026-04-21
  seed: edc165f706616610  [openssl rand -hex 8]
  axis 1 (Jayesh action framing, n=8):
    int(edc1,16)=60865, 60865 % 8 = 1
    -> "Phoenix span diff on agent output vs. human final"
  axis 2 (Alex action framing, n=7):
    int(65f7,16)=26103, 26103 % 7 = 5
    -> "voice-compliance regex turning eye-audit rules into CI checks"
  axis 3 (Comstock action framing, n=6):
    int(0661,16)=1633, 1633 % 6 = 1
    -> "clone factory + flip config flags (auth+otel+tasks from min 1)"
  axis 4 (APEX density, n=4):
    int(6610,16)=26128, 26128 % 4 = 0
    -> "single paragraph, pillar names parenthetical, no metric drilldown"

  overrides: none
  locked from v7: title + subtitle (user stipulation)
```

Anyone reading can verify:
`python3 -c 'print(int("edc1", 16) % 8)'` -> `1`. If the stated choice
matches the arithmetic, it is a real randomize. If not, it's ceremony.
