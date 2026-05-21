# Layout workarounds — deeper dive

## The limitation

Gamma's API does not expose per-slide layout control. Image
placement (left, right, top, full-bleed background) is autonomous,
chosen by Gamma's layout engine based on content + theme + image
shape.

Per Gamma's docs:

> *"Accent images are automatically placed by Gamma — they cannot be
> directly controlled via the API."*

There is no `layout: "imageBackground"` field. There is no
per-card override hook. The only knobs you have are:

- `cardOptions.dimensions` (slide aspect ratio — global, not
  per-slide)
- `imageOptions.source` (which images, not where)
- `imageOptions.style` (aesthetic, not placement)
- `additionalInstructions` (free text — see workaround #1)

## Workaround #1 — natural-language directive

**Determinism**: probabilistic. Sometimes works; sometimes ignored.

**Cost / effort**: free.

**When to use**: every project, first attempt. Costs nothing to try.

Add a layout directive to `additionalInstructions`. Example:

```text
LAYOUT: For empty-text slides, the image MUST be the slide's
full-bleed background; image fills the 16:9 frame edge-to-edge with
no side-placement, no text-zone padding. For typography-only slides
with one bold phrase, treat text AS the visual subject — typography
composition over a thematically-toned background, not text overlaid
on a content image.
```

Gamma's docs even include layout-style examples in the
`additionalInstructions` they recommend, e.g.:

> *"Group the last 10 images into a gallery."*

**Why probabilistic**: Gamma interprets this with the same LLM that
does generation. Sometimes the instruction is a strong-enough signal
to override the autonomous layout engine; sometimes it's drowned out
by other parts of the prompt or the theme's default behavior.

**Interaction with `imageOptions.source`**:

| Source | Workaround #1 effect |
|---|---|
| `aiGenerated` | Best-case — Gamma generates an image-shape compatible with the directive (e.g., wide aspect for full-bleed). Most likely to honor the directive. |
| `pictographic` / `pexels` / `giphy` | Mixed — found images may not match the requested aspect; Gamma falls back to its default placement. |
| `themeAccent` | Directive likely ignored — accent images are theme-driven, layout is too. |
| `placeholder` | Directive partially honored — slot reserves space; manual fill (workaround #3) handles placement. |
| `noImages` | N/A — directive about images is moot. |

## Workaround #2 — inline raw image URLs

**Determinism**: deterministic. The image you specify lands on the
slide you specified.

**Cost / effort**: image-host pipeline + extra credits for
pre-generation (e.g., nano-banana via `/openrouter`).

**When to use**: when workaround #1 isn't honored and visual fidelity
matters.

Gamma supports raw HTTPS image URLs **inline in `inputText`**.
Markdown `![alt](url)` and HTML `<img>` are stripped by Gamma's
preprocessor; **bare URLs ARE accepted**.

Pattern:

1. Pre-generate images via `/openrouter` (nano-banana 2 / Gemini
   3.1 Flash Image).
2. Upload to a public HTTPS host (S3 with public-read, GitHub Pages,
   any static hosting).
3. Drop the URL in `inputText` adjacent to the slide content.
4. Set `imageOptions.source: "placeholder"` so Gamma reserves an
   image slot per slide and inserts the URL you provided.

Example payload fragment:

```jsonc
{
  "inputText": "Title slide\n---\nhttps://cdn.example.com/decks/slide-2.png\n---\nWin #1: onboarding\nTTV: 11 days faster\nhttps://cdn.example.com/decks/slide-3.png\n---\nWin #2: billing flow\nhttps://cdn.example.com/decks/slide-4.png",
  "textMode": "preserve",
  "cardSplit": "inputTextBreaks",
  "imageOptions": { "source": "placeholder" }
}
```

**Interaction with `imageOptions.source`**:

| Source | Workaround #2 effect |
|---|---|
| `placeholder` | **Best fit** — Gamma reserves a slot per slide, inline URL fills it. Layout engine still picks placement (left vs right vs background) BUT it has only one image to work with. |
| `noImages` | Inline URLs ignored — no image slot to fill. |
| `aiGenerated` / `pexels` / `giphy` | Partially works — Gamma may use the inline URL OR generate/fetch its own. Unpredictable. Stick with `placeholder`. |
| `themeAccent` | Inline URLs likely ignored — theme accents take precedence. |

**Caveat**: workaround #2 still doesn't directly control PLACEMENT
(left vs right vs full-bleed). It controls which IMAGE appears.
Combine with workaround #1 (natural-language directive) for the best
chance at both.

## Workaround #3 — manual click-background

**Determinism**: deterministic.

**Cost / effort**: per-slide manual step in the Gamma editor.

**When to use**: one-off polish on a small deck. Not viable for
templated / repeated workflows.

Pattern:

1. Render the deck via API.
2. Open the `gammaUrl` in a browser.
3. Per slide: click the image → menu → **Set as background**.
4. The image fills the slide; text overlays on top.
5. Re-export to PDF — manual change persists.

**Interaction with `imageOptions.source`**:

| Source | Workaround #3 effect |
|---|---|
| `aiGenerated` | Works — generated image becomes the background. |
| `placeholder` | Works — but the placeholder image is generic; pair with workaround #2 to get the right image, then manually set as background. |
| `noImages` | Won't work — no image to set as background. Use `placeholder` instead. |
| `themeAccent` | Works on slides where the theme generated an accent image. |

## Combining workarounds

The strongest setup is **#1 + #2 + #3**:

1. **#1**: write a layout directive in `additionalInstructions`
   ("full-bleed background for empty-text slides").
2. **#2**: pre-generate images, host them, inline URLs in
   `inputText` with `imageOptions.source: "placeholder"`.
3. **#3**: open the result, click any image that didn't auto-honor
   the directive, "Set as background."

Steps 1 and 2 minimize the manual work in step 3. Step 3 is the
deterministic safety net.

## What you can't do

There is no API knob for:

- Per-slide `imagePosition: "left" | "right" | "background"`
- Per-slide `layout: "title-only" | "image-left" | "image-bg"`
- Per-slide image *crop* / focal point
- Per-slide image *opacity* / overlay tint
- Forcing a specific theme template variant per slide

If your aesthetic depends on consistent per-slide layout discipline
(matching the same layout across every slide), the best path is:

1. **Pick a theme that defaults to your target layout.** Custom
   workspace themes can be tuned to favor full-bleed image-background
   layouts — work with the theme designer.
2. **Render via API.**
3. **Polish manually.**

For high-volume layout-precise workflows, the API isn't the right
tool — Gamma's UI editor is. The API excels at first-draft
generation; layout polish is a UI step.

## See also

- [3-styles.md](3-styles.md) — text-control framework.
- [SKILL.md](../SKILL.md) — top-level skill body.
- [/openrouter](../../openrouter/SKILL.md) — image generation for
  workaround #2.
