# AI Council 2026 × zig-voice fusion

One-off aesthetic blend made on 2026-05-06 for Andrew's promo posts
around his AI Council 2026 talk ("5 Lessons from the Classroom for
Evaluating Agents," Analytics & Data Science track, May 12-14, SF
Marriott Marquis). The fusion lives here, not in the canonical zig
reference set, because it carries AI Council brand DNA that should
not bleed into future zig-only generations.

## The two source aesthetics

### zig-voice (canonical)

- **Palette** — saturated cobalt + marigold + orange, two-color
  split backgrounds
- **Surface** — 3D clay / matte / textured (knit, corduroy, beaded)
- **Composition** — centered subjects on flat backgrounds, slightly
  surreal pop-art density
- **Lighting** — warm studio softness from above-left, soft drop
  shadows
- **Mood** — retrofuturist 60s-70s pop-art, design-forward, warm

### AI Council 2026 (partner)

See [`source-ac-screenshot-1-speaker-card.png`](source-ac-screenshot-1-speaker-card.png)
and [`source-ac-screenshot-2-general-template.png`](source-ac-screenshot-2-general-template.png).

- **Palette** — light mint-seafoam green + deep navy/cobalt blue,
  occasional white
- **Surface** — flat / pixel-grid / pixel-cursor motif, no rendered
  3D, no texture
- **Composition** — clean tech-conference card layouts, generous
  negative space, structural restraint, branded bottom band with
  date + venue footer
- **Lighting** — flat, no rendered light
- **Mood** — cool digital, structural, conference-rigorous

## Shared / complementary

**Shared**:
- Both use cobalt/navy prominently (huge anchor)
- Both reject photorealism in favor of stylization
- Both have a designed, intentional feel

**Complementary contrasts** (where the fusion has to do work):
- Warm clay (zig) vs. cool digital (AC)
- Rendered 3D (zig) vs. flat 2D (AC)
- Texture-rich surfaces (zig) vs. pixel-grid-clean (AC)
- Marigold/orange dominance (zig) vs. mint-seafoam accent (AC)

## The fused register

Resolved as a NEW shared style, written before any generation:

- **Surface**: 3D clay-soft silhouettes whose surface is *visibly
  voxel-tiled*, as if each form is built from small cubic clay
  pixels. Soft rounded edges meet a subtly visible cubic
  substructure. (Synthesis of zig clay + AC pixel-grid.)
- **Palette**: warm cobalt navy + marigold orange + accent
  mint-seafoam green. Mint appears as rim-light highlights on
  cobalt forms or as soft grid washes — never as the dominant
  color. (Adds AC mint to the zig palette.)
- **Composition**: generous negative space, structural restraint,
  conference-card composure. Centered subjects on flat saturated
  split backgrounds. NO crowding, NO logos, NO branded text, NO
  event footers. (Borrows AC restraint into zig framing.)
- **Lighting**: studio-soft warmth with a crisper digital edge —
  sharper highlight rims than pure clay, softer than pure pixel-art.
- **Mood**: warm-clay-pop materials rendered with cool-digital
  crispness. Retrofuturist + tech-aesthetic without being either.

## What failed first (v1)

The first pass put zig-rendered classroom imagery (chair, bookshelf,
globe, pinboard) on top of literal AC branded bottom bands ("AI
Council" pixel-cursor logo, "SAN FRANCISCO • MARRIOTT MARQUIS • MAY
12-14, 2026" footer text), in three separate variations. That's a
collage, not a fusion. The mistake: including the AC reference
screenshots in the OpenRouter `image_url` parts alongside the zig
refs — the model interpreted "use both as references" as "paste
their layouts together."

The v1 outputs are not preserved here. They were superseded by v2.

## What worked (v2)

For the v2 generations:

1. **Dropped the AC screenshots from the API call entirely.** Used
   only the zig canonical refs as `image_url` inputs. AC's aesthetic
   came in via the text prompt instead.
2. **Wrote the fused register in plain language** as the system
   instruction (the paragraph above), explicitly forbidding logos,
   branded text, and event footers.
3. **Concepted each composition abstractly** — arrival / arena /
   aftermath — instead of "AI Council classroom card."

The 3 v2 outputs are in this folder:

- [`fusion-01-teaser-archway.png`](fusion-01-teaser-archway.png) —
  cobalt voxel-tile archway with marigold + mint spheres approaching
  from the left. The archway *is* AC-grid-textured AND AZ-clay-shaped
  at the same time. For the "AI Council is next week" teaser post.
- [`fusion-02-dayof-arena.png`](fusion-02-dayof-arena.png) — mint
  pixel-grid floor extending to a cobalt horizon, single warm clay
  sphere centered under a soft column of light. Conference-card-
  restrained negative space, AZ surface texture, AC grid foundation.
  For the "today is the day" post.
- [`fusion-03-after-trail.png`](fusion-03-after-trail.png) —
  marigold sphere at rest on a cobalt floor with a mint-green
  pixel-grid trail behind it. The mint grid as a *trail* (the wake
  of the talk having moved through) was the strongest single fusion
  idea — AC grid showing up as residue rather than literal collage.
  For the post-talk recap.

## If you re-fuse with AI Council later

Pull this README first. Skip the v1 mistake. The text prompt below
is the working version (paste verbatim or adapt as the system
instruction):

> We are generating in a FUSED AESTHETIC that blends two source
> registers into a new shared style. DO NOT reproduce any source's
> literal subjects, logos, branded typography, footer text, or
> layouts. Generate a NEW image in the fused style described below.
>
> The fused register:
> - SURFACE: 3D clay-soft silhouettes whose surface is visibly
>   voxel-tiled, as if each form is built from small cubic clay
>   pixels — clay material seen through a pixel-grid lens. Soft
>   rounded edges meet a subtly visible cubic substructure.
> - PALETTE: warm cobalt navy + marigold orange + accent mint-seafoam
>   green. The mint appears as rim-light highlights on cobalt forms
>   or as soft grid washes — never as the dominant color.
> - COMPOSITION: generous negative space, structural restraint,
>   conference-card composure. Centered subjects on flat saturated
>   split backgrounds. NO crowding, NO logos, NO branded text, NO
>   event footers.
> - LIGHTING: studio-soft warmth with a crisper digital edge —
>   sharper highlight rims than pure clay, softer than pure pixel-art.
> - MOOD: warm-clay-pop materials rendered with cool-digital
>   crispness. Retrofuturist + tech-aesthetic without being either.
>
> Use the reference images ONLY as anchors for the warm clay-pop
> register half (palette, texture, lighting). Don't use them as
> anchors for subject matter. Generate a new abstract image in the
> FUSED register described above.
