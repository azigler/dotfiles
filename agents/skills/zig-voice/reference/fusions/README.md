# Aesthetic fusions — methodology + case studies

This folder is for **one-off aesthetic blends**: cases where Andrew's
visual register needs to fuse with another brand's, an event's,
a partner organization's, or a co-branded campaign's identity.

Files here are NOT canonical zig references. They live one level deeper
than `reference/*.{webp,png}` precisely so the standard non-recursive
glob in `/openrouter` won't pull them as style anchors for new
generations. If a fusion image accidentally ends up referenced as a
canonical zig anchor, the look starts drifting toward the partner
brand on every future generation — exactly what we don't want.

## When to fuse vs. when to stay canonical

Fuse when:
- A specific event card, conference promo, partner co-branded asset,
  or one-time campaign needs to honor BOTH visual languages.
- The partner brand has a strong identifiable aesthetic that would
  feel hostile if you ignored it (e.g., a conference's pixel-grid
  navy, a publication's editorial photography palette).
- The deliverable is short-lived (single post, single card, single
  asset). Long-lived material should pick one register and commit.

Stay canonical when:
- The post is on Andrew's personal feed talking about his own work,
  even if it mentions a partner. The partner gets named in the body;
  the visual stays zig-coded.
- The partner brand is generic / unremarkable / doesn't have a
  distinctive register to fuse with.

## How to fuse — the protocol

The literal-paste failure mode is the trap that catches every first
attempt. The model sees two source aesthetics in the API call and
produces a collage instead of a synthesis. Avoid it deliberately.

### Step 1 — Study both aesthetics in writing

Before generating anything, write a paragraph for each side covering:
- **Palette** — actual colors, not "warm" / "cool"
- **Surface** — material register (clay, glass, photo, flat vector,
  pixel-art, etc.)
- **Composition** — typical framing, negative space, focal pattern
- **Lighting** — soft / hard, directional, ambient
- **Mood** — emotional register the aesthetic carries

The act of writing forces explicit observation. You'll catch
something each side does that you wouldn't have noticed by eye.

### Step 2 — Identify shared elements + complementary contrasts

What do both aesthetics already agree on? (Both might be saturated,
or both might prefer flat backgrounds, or both might lean
geometric.) Those become the easy load-bearing parts of the fusion.

What's contrasting? (Warm vs. cool, organic vs. digital, soft vs.
crisp.) Those are the friction points. The fused register has to
*resolve* them, not split the difference.

### Step 3 — Write the fused register in plain language

Don't visualize it yet. Write the fused aesthetic as a paragraph
the model can understand from text alone. Cover:
- Surface ("clay-soft silhouettes with visibly voxel-tiled
  substructure")
- Palette (specify dominant + accent + ratios; "cobalt navy +
  marigold + accent mint, mint never dominant")
- Composition ("conference-card negative space, no logos")
- Lighting ("studio softness with crisper digital edges")
- Mood ("warm-clay-pop body with cool-digital edges")

This text becomes the **system instruction** for the generation. If
you can't articulate the fusion in words, you don't have one yet.

### Step 4 — Generate using zig refs ONLY in the API call

Critical: do **NOT** include the partner aesthetic's reference images
in the OpenRouter `image_url` parts. Including them invites the model
to literal-paste branded layouts, footers, and logos into the output.
Use the partner aesthetic's *description* in your text prompt and
zig refs alone in the image inputs.

If a generation comes back as a literal collage anyway, regenerate
with stronger no-go language: *"do NOT reproduce any source's literal
subjects, logos, branded typography, footer text, or layouts."*

### Step 5 — Save the fused output here, not in canonical references

Add the final image to a per-fusion subfolder
(`fusions/<aesthetic-slug>/`) with a descriptive name. Include a
README in that subfolder describing the partner aesthetic, the fused
register you wrote, and what worked / what failed. Optionally include
the source partner reference images for the next person's context.

**Do not copy fusion outputs back into the canonical `reference/`
top-level folder.** Those are for zig-coded work only.

## Worked examples

- [`ai-council-2026/`](ai-council-2026/) — fusion of the zig clay-pop
  register with AI Council 2026's pixel-grid mint-navy conference
  identity, for Andrew's promo posts around his "5 Lessons from the
  Classroom for Evaluating Agents" talk. Includes the failure-mode
  history (v1 was a literal collage) and the successful v2 generations.

When you do another fusion, add a new subfolder here with the same
shape: README + final images + (optionally) source partner refs.
