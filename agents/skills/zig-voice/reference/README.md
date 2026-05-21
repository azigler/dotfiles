# Zig-coded visual style references

Canonical visual aesthetic for images generated to accompany Andrew
Zigler's social posts (LinkedIn primarily). When `/openrouter` is asked
to generate a new image *in Andrew's style*, pull every file in this
folder as image-to-image style references on the API call. The point
is cohesion across Andrew's feed over time — the more posts share a
recognizable pop-art-3D-clay register, the more his images become a
brand asset rather than one-off art.

## The aesthetic in words

- **Palette** — saturated cobalt blue, marigold yellow, vivid orange,
  with accents of red, white, turquoise. Two-color split backgrounds
  are common (cobalt over marigold; orange over blue).
- **Render** — 3D clay / matte / textured. Knit, corduroy, ribbing,
  and beaded surfaces show up frequently; smooth glossy finishes accent
  the rougher textures.
- **Lighting** — bright studio lighting from above-left, soft drop
  shadows, slightly dewy highlights on spheres.
- **Composition** — centered subjects on flat saturated backgrounds.
  Shapes carry the meaning; even when figures appear, they read as
  designed objects rather than illustrations of people.
- **Mood** — retrofuturist 60s-70s pop-art, slightly surreal,
  design-forward, confident, occasionally playful.
- **No-go list** — generic AI-illustration aesthetic, photorealism,
  text overlays, infographic-style decoration, stock-art tropes
  (lightbulbs, gears, jigsaw pieces, handshakes).

## Files in this folder

### `style-NN-*.webp` — original style anchors (sourced from AZ)

These four are the seeds Andrew picked as the canonical mood board.
They predate any agent generations and define the register:

- `style-01-beaded-hand.webp` — beaded blue hand with eye motif and
  flower-pots flanking a yellow sun disc
- `style-02-portrait-spheres.webp` — portrait on orange background
  with a cluster of yellow / blue / orange spheres around the head
- `style-03-striped-goggles.webp` — striped figure with orange
  goggles against blue sky
- `style-04-knit-yellow-goggles.webp` — knit-textured figure with
  yellow goggles on a blue / orange split background

### `YYYY-MM-DD-*.png` — generations that landed in production

Image generations made for Andrew's posts that captured the aesthetic
well enough to fold back into the reference set. Adding them here is
the mechanism by which the look stays cohesive across his feed:
each new generation pulls all prior files as references, so the style
self-reinforces.

Current generations:

- `2026-05-05-beads-orbs-dependency-graph.png` — abstract beads as
  clusters of textured orbs connected by knit threads, cobalt /
  marigold split. Made for the Beads primer post.
- `2026-05-05-beads-classroom.png` — empty pop-art classroom (book-
  shelf, pinboard, four cobalt desks, globe, marigold floor). Made
  for the Beads primer "skill = classroom" post.

## How to add new generations

When a generation lands well — Andrew approves the aesthetic, the
post ships, the style holds — copy the final PNG into this folder
with the convention:

```
YYYY-MM-DD-<short-slug>.png
```

That's it. The next image generation that pulls this folder will
include it as a style reference automatically.

When to NOT add a generation here:

- One-off fusions with another brand's aesthetic (e.g., conference
  visual identities, partner-event co-branding) — those should not
  pollute the canonical zig-coded register.
- Failed generations or rejected drafts — only post-publish artifacts
  belong here.
- Generations made to deliberately break the style (test cases,
  experiments). Keep those in `/tmp` or a project-specific spot.

## How `/openrouter` should use this folder

When generating an image in Andrew's style, include every file in
this folder as an `image_url` part in the OpenRouter chat-completions
request alongside the text prompt. nano-banana 2 (Gemini 3.1 Flash
Image) handles up to a dozen reference images comfortably; the more
diverse the prior set, the more the generation captures the
aesthetic without copying any single source.

**The glob is non-recursive on purpose**: `glob.glob(f"{REF_DIR}/*.{{webp,png}}")`
matches only the top level. Subfolders like `fusions/` are excluded
deliberately — they hold one-off blends with partner brands and
should not bleed into canonical zig generations.

See [`/openrouter`](../../openrouter/SKILL.md) → "Image generation"
for the canonical multi-reference image-to-image call shape.

## `fusions/` — one-off aesthetic blends

When Andrew's visual register needs to fuse with another brand's
identity (conference promos, partner co-branded campaigns, event
cards), the artifacts go in [`fusions/<aesthetic-slug>/`](fusions/) —
not at the top level. Each fusion subfolder holds the partner
aesthetic study, the fused register written in plain language, and
the final generated images.

See [`fusions/README.md`](fusions/README.md) for the methodology
(study both / identify shared + complementary / write the fused
register / generate with zig refs only / save here, not in canonical
references) and [`fusions/ai-council-2026/`](fusions/ai-council-2026/)
for the worked example, including the v1 literal-collage failure
mode and the v2 fix.
