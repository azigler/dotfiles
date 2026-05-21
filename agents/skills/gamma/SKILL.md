---
description: Generate Gamma presentations / documents / webpages / social-format decks via the Gamma generations API. Cost-aware (every call deducts credits). Supports the 3-style framework (overarching / slide-by-slide / deterministic) for varying control levels. Document layout (image-left vs background, etc.) is autonomous in Gamma — note the layout limitation + 3 workarounds in the body. Output URLs (gammaUrl + exportUrl) suitable for sharing or PDF export.
when_to_use: User says "render the deck", "generate a Gamma", "build slides via Gamma", "iterate on the deck", "export the PDF" or otherwise explicitly invokes Gamma generation. NEVER fire autonomously, in loops, or as a "let me try a few" speculation.
allowed-tools: Bash(curl *) Bash(jq *) Bash(python3 *) Bash(/home/ubuntu/.claude/skills/gamma/*)
---

# /gamma — Gamma generations

[Gamma](https://gamma.app) turns prose / markdown outlines into polished
presentations, documents, webpages, or social-format decks. The
[generations API](https://developers.gamma.app/) accepts an outline +
style brief and returns a `gammaUrl` (web view) plus optional
`exportUrl` (signed S3 PDF / PPTX / PNG with ~7-day TTL).

This skill is the wrapper. It supports a **3-style framework** that's
proven across real projects: same outline, three control levels —
let Gamma drive (Style A), guide it slide-by-slide (Style B), or write
the exact text and let Gamma only do layout + image selection (Style C).

## CRITICAL: cost awareness

**Every call deducts Gamma credits.** Credits are workspace-scoped,
not USD; conversion to dollars varies by plan. Before calling:

1. **Confirm the user explicitly asked.** This skill never fires
   from autonomous loops, background polling, or speculative
   "let me try a few variants" workflows.
2. **State the estimated credits** in your acknowledgment, citing
   the [Cost reality](#cost-reality) table — e.g., *"This will spend
   ~40-50 credits on a 10-slide batch — OK?"*
3. **Smoke-test before full deck.** For unknown territory, fire a
   3-slide smoke (~15 credits) before committing to a 30-slide
   deck (~150 credits).
4. **Save outputs immediately.** The script saves the full response
   JSON to `~/.cache/gamma/` so iteration is cheap (you can
   re-export an existing generation without spending again).
5. **One generation per call by default.** Don't fan out A/B/C
   variants in parallel without explicit ask + cost confirmation.
6. **Print credit deduction from the response.** The script does
   this on stderr; don't suppress it.

If you find yourself thinking "I'll just render three styles and pick
the best," **stop and ask the user first**.

## Prerequisites

Set the API key as an env var (preferred) or as a file:

```bash
# Option A — env var
export GAMMA_API_KEY="sk-gamma-..."

# Option B — config file (works for non-interactive shells)
mkdir -p ~/.config/gamma
echo "sk-gamma-..." > ~/.config/gamma/api-key
chmod 600 ~/.config/gamma/api-key

```

The helper script checks in priority order:

1. `$GAMMA_API_KEY` env var
2. `~/.config/gamma/api-key` file

Get a key at [gamma.app workspace settings](https://gamma.app/) →
API Keys (Pro / Teams / Ultra plans only). Format is `sk-gamma-...`.

## Base URL & auth

```
https://public-api.gamma.app/v1.0
X-API-Key: $GAMMA_API_KEY
```

**Note**: NOT `Authorization: Bearer ...`. Gamma uses a custom
`X-API-Key` header.

Endpoint inventory:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/generations` | Submit a new generation (returns `generationId`) |
| `GET` | `/generations/{id}` | Poll status; read `gammaUrl` / `exportUrl` / `credits` |
| `POST` | `/generations/from-template` | Generate from an existing single-page template |
| `GET` | `/themes` | List workspace + standard themes |
| `GET` | `/folders` | List workspace folders |

## Generate a presentation

### Use the helper script

The cleanest path is the wrapper at
`~/.claude/skills/gamma/gamma-render.sh`:

```bash
~/.claude/skills/gamma/gamma-render.sh ./payload.json
```

The script handles auth lookup, submission, polling (5-sec interval,
5-min timeout), and result persistence to
`~/.cache/gamma/<name>-<timestamp>.json`. It prints `gammaUrl`,
`exportUrl`, and `credits` on stderr.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | OK — generation completed |
| 1 | Missing or invalid args |
| 2 | Missing API key |
| 3 | Generation failed (API returned `status: "failed"`) |
| 4 | Polling timed out (>5 min) |

### Raw curl (when the helper is wrong tool)

```bash
# Submit
curl -fsSL "https://public-api.gamma.app/v1.0/generations" \
  -H "X-API-Key: $GAMMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @./payload.json
# -> {"generationId": "abc123...", "warnings": null}

# Poll
curl -fsSL "https://public-api.gamma.app/v1.0/generations/abc123" \
  -H "X-API-Key: $GAMMA_API_KEY"
# -> {"status": "completed", "gammaUrl": "...", "exportUrl": "...", "credits": {"deducted": 27, "remaining": 8473}}
```

## The 3-style framework

The same outline can be rendered at three control levels via Gamma's
API knobs. This framework was pioneered in the AI Council 2026 talk
project; it's reusable across any Gamma-based deck workflow.

| Style | `textMode` | `cardSplit` | What you control | When to reach for it |
|---|---|---|---|---|
| **A — Overarching theme** | `generate` | `auto` | Outline + style brief; Gamma fills everything | Fast feedback on aesthetic + voice; copy isn't locked |
| **B — Slide-by-slide theme** | `generate` (or `condense`) | `inputTextBreaks` | Per-slide brief, Gamma writes copy in your voice | Best balance of quality + control |
| **C — Deterministic** | `preserve` | `inputTextBreaks` | Exact text per slide; Gamma only does layout + image selection | Final pass, when copy is locked |

### Style A — Overarching theme (let Gamma drive)

```jsonc
{
  "inputText": "Quarterly Update Q2 2026\nThesis: shipped velocity is up 40%\n- Onboarding redesign cut TTV by 11 days\n- New billing flow lifted conversion 8%\n- Support load down 22% from in-product hints",
  "textMode": "generate",
  "format": "presentation",
  "numCards": 12,
  "cardSplit": "auto",
  "additionalInstructions": "Confident exec tone; data-forward; one chart-style slide per number",
  "themeId": "<your-theme-id>",
  "exportAs": "pdf",
  "textOptions": {
    "amount": "medium",
    "tone": "confident exec, data-forward",
    "audience": "leadership team and board observers"
  },
  "imageOptions": { "source": "aiGenerated", "style": "muted blue editorial" },
  "cardOptions": { "dimensions": "16x9" }
}
```

### Style B — Slide-by-slide theme (guided structure)

```jsonc
{
  "inputText": "Title slide: Quarterly Update Q2 2026\n---\nOpening: shipped velocity is up 40%\n---\nWin #1: onboarding redesign — TTV down 11 days\n---\nWin #2: billing flow — conversion up 8%\n---\nWin #3: in-product hints — support load down 22%\n---\nWhat's next: Q3 roadmap preview",
  "textMode": "generate",
  "format": "presentation",
  "cardSplit": "inputTextBreaks",
  "additionalInstructions": "Confident exec tone; one bold metric per slide; speaker carries the narrative",
  "themeId": "<your-theme-id>",
  "exportAs": "pdf",
  "textOptions": { "amount": "brief", "tone": "...", "audience": "..." },
  "imageOptions": { "source": "aiGenerated", "style": "..." },
  "cardOptions": { "dimensions": "16x9" }
}
```

### Style C — Deterministic (full control)

```jsonc
{
  "inputText": "Quarterly Update Q2 2026\nQ2 — Ship velocity up 40%\n---\nWe shipped 40% more this quarter than Q1.\n---\nOnboarding redesign\nTTV: 11 days faster\n---\nBilling flow\nConversion: +8%\n---\nIn-product hints\nSupport load: -22%\n---\nQ3 — see appendix",
  "textMode": "preserve",
  "format": "presentation",
  "cardSplit": "inputTextBreaks",
  "additionalInstructions": "Layout only; image selection only. Don't rewrite the text.",
  "themeId": "<your-theme-id>",
  "exportAs": "pdf",
  "imageOptions": { "source": "aiGenerated", "style": "..." },
  "cardOptions": { "dimensions": "16x9" }
}
```

See [reference/3-styles.md](reference/3-styles.md) for the deeper
dive — when to pick each, how knobs interact, migration patterns
("start with A for fast feedback, move to C once content is locked").

A canonical Style C payload lives at
[reference/example-deterministic.json](reference/example-deterministic.json).

## Layout limitation + workarounds

**Gamma's API does not support per-slide layout control.** Image
placement (left, right, top, full-bleed background) is autonomous.
Gamma's own docs:

> *"Accent images are automatically placed by Gamma — they cannot be
> directly controlled via the API."*

This is the single biggest gap when you need pixel-precise visual
direction. Three workarounds, each with trade-offs:

| # | Workaround | Determinism | Cost / effort | When to use |
|---|---|---|---|---|
| 1 | Natural-language directive in `additionalInstructions` | Probabilistic | Free | Every project; first attempt |
| 2 | Inline raw image URLs in `inputText` | Deterministic | Image-host pipeline + extra credits | When workaround #1 isn't honored consistently |
| 3 | Manual click-background in the Gamma editor | Deterministic | Per-slide manual step | One-off polishing of a small deck |

**Workaround #1** — example directive:

> *"For empty-text slides, the image MUST be the slide's full-bleed
> background; image fills the 16:9 frame edge-to-edge with no
> side-placement, no text-zone padding."*

Gamma sometimes honors this; sometimes it doesn't. Probabilistic
because the directive is interpreted by the same LLM that does
generation.

**Workaround #2** — inline raw URLs work; markdown `![alt](url)` and
HTML `<img>` are stripped by Gamma's preprocessor. Pre-generate via
nano-banana (`/openrouter`), host at public HTTPS, drop the bare URL
in `inputText`. Adds an upload step but is fully deterministic.

**Workaround #3** — open the gammaUrl, click an image, "Set as
background." Per-slide manual click. Survives re-exports.

See [reference/layout-workarounds.md](reference/layout-workarounds.md)
for full examples and the interaction with `imageOptions.source`
modes (`aiGenerated`, `placeholder`, `noImages` each behave
differently).

## Hard caps & gotchas

Tested empirically against the live API:

| Field | Cap | Behavior over cap |
|---|---|---|
| `imageOptions.style` | 500 chars | Soft warning + clipping. Going much over may cause silent truncation. Keep ≤500. |
| `additionalInstructions` | 5,000 chars | **HARD** — `400 Bad Request` confirmed. |
| `textOptions.tone` | 500 chars | Soft warning. |
| `textOptions.audience` | 500 chars | Soft warning. |
| `numCards` | 60 (Pro/Teams), 75 (Ultra) | `400 Bad Request` over cap. |
| `folderIds` | 10 | `400 Bad Request` over cap. |

### Ignored-field warnings

Gamma silently overrides + warns when fields conflict:

| When you set | Field that gets ignored | Why |
|---|---|---|
| `cardSplit: "inputTextBreaks"` | `numCards` | Count is derived from `\n---\n` segments |
| `textMode: "preserve"` | `textOptions.tone`, `audience`, `amount` | Those control "generate" mode only |
| `textMode: "preserve"` | Body rewriting | Gamma keeps text verbatim |

Read the `warnings` field in the submit response — it lists every
override.

### Empty trailing segment

A stray `\n---\n` at the END of `inputText` produces a final empty
card. Trim trailing breaks unless you want a deliberate blank slide.

## Cost reality

Gamma bills in **credits**, not USD. Conversion varies by plan.
Don't pre-compute USD; print the credit deduction from the response.

Real costs observed (workspace: Gamma Ultra-tier, May 2026):

| Generation | Credits | Per-slide |
|---|---|---|
| 3-slide smoke @ 2K | ~15 | ~5 credits/slide |
| 10-slide batch @ 2K | ~40-50 | ~4-5 credits/slide |
| 27-slide deck @ 2K | ~110-130 | ~4 credits/slide |
| 40-slide deck @ 2K | ~160-200 | ~4-5 credits/slide |

**Image output tokens are billed at a higher rate than text
completion** — that's why published per-token pricing extrapolates
poorly. Trust the `credits.deducted` field in the response, not the
text-pricing model.

**Re-exporting from the Gamma UI is free** — open the deck and export
to another format without re-generating. The **API has no re-export
endpoint**: `exportUrl` delivers one format per generation, so a new
format via the API means a fresh generation (and fresh credits).

## Cap split logic

For decks above the per-generation cap:

| Plan | Cap | Split strategy |
|---|---|---|
| Pro / Teams | 60 cards | Split at hard narrative boundary (act break, chapter break, "and now…" hinge) |
| Ultra | 75 cards | Same — split at the boundary, NOT mid-content |

Pattern: render `payload-part-1.json` (slides 1-N), then
`payload-part-2.json` (slides N+1 to end). After generation, manually
join in the Gamma editor (or post-process the PDFs). Don't try to
auto-merge generations — Gamma doesn't support that via API.

When splitting, mirror the `themeId`, `imageOptions.style`,
`additionalInstructions` style register, and tone across both
payloads so the seam is invisible.

## Polling pattern

After `POST /generations`, poll `GET /generations/{id}` until
`status` is `"completed"` or `"failed"`.

- **Interval**: 5 seconds (the helper script default)
- **Total timeout**: 5 minutes hard cap
- **Pending duration**: 30 sec - 5 min depending on slide count + image complexity. Image-heavy decks at 2K take longer.

The driver should:

1. Save the final response JSON (full body, not just URLs) to a
   results dir for replay / debugging.
2. Print `gammaUrl`, `exportUrl`, and `credits.deducted` /
   `credits.remaining` to stderr.
3. On `failed`, print the error body and exit non-zero so caller
   notices.

## stylePreset

`imageOptions.stylePreset` selects a tuned image-generation pipeline:

```ts
imageOptions.stylePreset?:
  | "photorealistic"
  | "illustration"
  | "abstract"
  | "3D"
  | "lineArt"
  | "custom";
```

When set to a named preset (anything other than `"custom"`), the
`style` free-text field is **ignored** — the preset wins.

Projects with a clear stylistic intent should prefer `stylePreset` —
e.g. `"3D"` or `"illustration"` — over free-text `style`. The preset
routes to a tuned image-gen pipeline; free-text is interpreted more
loosely.

If you set both, `style` is a tiebreaker only when
`stylePreset: "custom"`.

## imageOptions.source enum

Full list with one-line semantics:

| Value | Behavior |
|---|---|
| `aiGenerated` | Gamma generates fresh images per slide. Highest credits, most flexibility. |
| `pictographic` | Pictogram / icon style; flat illustration |
| `pexels` | Stock photos from Pexels |
| `giphy` | Animated GIFs from Giphy |
| `webAllImages` | Web search; any usage rights |
| `webFreeToUse` | Web search; free-to-use license filter |
| `webFreeToUseCommercially` | Web search; commercial-use license filter |
| `themeAccent` | Use the theme's accent images only (no per-slide image gen) |
| `placeholder` | Empty image slot — useful with workaround #2 (inline URLs) or #3 (manual fill) |
| `noImages` | Text-only slides; layout collapses without image area |

Pair `noImages` with deterministic Style C when the deck is purely
typographic. Pair `placeholder` with workaround #2 when you want
Gamma's layout but your own images.

## Themes & folders

```bash
# List workspace themes
curl -fsSL "https://public-api.gamma.app/v1.0/themes?limit=50" \
  -H "X-API-Key: $GAMMA_API_KEY" | jq '.data[] | {id, name, type}'

# List workspace folders
curl -fsSL "https://public-api.gamma.app/v1.0/folders?limit=50" \
  -H "X-API-Key: $GAMMA_API_KEY" | jq '.data[] | {id, name}'
```

Both endpoints are paginated; pass `?after=<nextCursor>` to walk past
50 results. `themes` returns custom (workspace) + standard themes;
custom ones are workspace-tuned and usually what you want.

Each workspace has a default theme. Pass an explicit `themeId` (an `id`
from the `/themes` listing above) for deterministic output; omit it to
fall back to the workspace default.

## Common workflows

### Smoke test → batch expansion

```bash
# 1. 3-slide smoke (~15 credits) to validate aesthetic
~/.claude/skills/gamma/gamma-render.sh ./smoke.json
# Review gammaUrl. Style holds? Aesthetic right?

# 2. Full deck (~150 credits)
~/.claude/skills/gamma/gamma-render.sh ./full.json
```

Don't skip the smoke. A bad aesthetic on a 3-slide test costs 15
credits to discover; a bad aesthetic on a 30-slide deck costs 150.

### A/B/C comparison (only on explicit ask)

```bash
~/.claude/skills/gamma/gamma-render.sh ./style-a.json
~/.claude/skills/gamma/gamma-render.sh ./style-b.json
~/.claude/skills/gamma/gamma-render.sh ./style-c.json
```

Three generations × ~50 credits = ~150 credits for a 10-slide
comparison. **Confirm with the user first.**

### Re-rendering an existing generation

The Gamma **UI** exports an existing deck to other formats for free,
and edits made in the UI are preserved. The **API has no re-export
endpoint** — don't script it. Pattern:

1. Initial render generates the deck (one `exportAs` format).
2. User edits + exports further formats in the Gamma UI.
3. Re-generate via the API only when the *content* must change.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Missing or wrong API key | Verify `$GAMMA_API_KEY` or `~/.config/gamma/api-key`; confirm header is `X-API-Key:` not `Authorization: Bearer` |
| `400 Bad Request` on `additionalInstructions` | Over 5,000 chars | Trim. This is a HARD cap. |
| `400 Bad Request` on `numCards` | Over plan cap (60 or 75) | [Cap split](#cap-split-logic) |
| `400 Bad Request` on `folderIds` | Over 10 entries | Reduce list |
| `429 Too Many Requests` | Rate limit (burst / hourly / daily) | Back off; check `X-RateLimit-*` response headers |
| Empty final card | Trailing `\n---\n` in `inputText` | Trim trailing break |
| `numCards` ignored | `cardSplit: "inputTextBreaks"` | Expected — count derives from segments. Check `warnings` in submit response. |
| `tone`/`audience` ignored | `textMode: "preserve"` | Expected — those are "generate"-mode only. |
| `style` ignored | `stylePreset` is set to a named preset | Expected — preset wins. Use `stylePreset: "custom"` to fall back to `style`. |
| `style` clipped silently | Over 500 chars | Trim to 500. Soft cap. |
| Layout doesn't honor full-bleed directive | `additionalInstructions` is probabilistic | [Layout workarounds](#layout-limitation--workarounds) — try #2 (inline URLs) or #3 (manual). |
| Polling never completes | Image-heavy deck + 2K size | Bump `--timeout` if your wrapper supports it; otherwise wait. 5 min is the helper default. |
| Helper script: `GAMMA_API_KEY not set` | Env var missing in non-interactive shell | Put key in `~/.config/gamma/api-key` (works without shell init). |

## Guardrails

- **Never fire without explicit user invocation.** No autonomous
  loops, no background polling, no speculative renders.
- **Save outputs immediately.** The helper script writes to
  `~/.cache/gamma/<name>-<timestamp>.json`; that's the source of
  truth for replay.
- **One generation per call by default.** Don't fan out variants
  without explicit ask + cost confirmation.
- **Cost is in CREDITS, not USD.** Print the `credits.deducted`
  field on every call. Don't claim a USD figure unless the user has
  set their plan's conversion rate.
- **Smoke before batch.** 3-slide validation before full-deck
  generation, every time the aesthetic / framing is unproven.
- **Don't store API keys in repos.** Use the env var or
  `~/.config/gamma/api-key`. Both are off-repo.
- **Ask before retrying.** If a generation comes back unsatisfactory,
  show the result to the user and ask before re-generating.

## See also

- [/openrouter](../openrouter/SKILL.md) — image generation via
  nano-banana 2 (Gemini 3.1 Flash Image). Pair with workaround #2
  (inline URLs) for deterministic per-slide imagery.
- [/asana](../asana/SKILL.md) — drop generated `gammaUrl` /
  `exportUrl` into Asana planning hubs (fleet-proxied writes).
- [/gdoc](../gdoc/SKILL.md) — companion for non-Gamma docs (Google
  Docs mechanics, LinearB styling contract).
- [reference/3-styles.md](reference/3-styles.md) — deeper dive on
  the 3-style framework.
- [reference/layout-workarounds.md](reference/layout-workarounds.md)
  — full examples for each layout workaround.
- [reference/example-deterministic.json](reference/example-deterministic.json)
  — canonical Style C payload as a starting point.
