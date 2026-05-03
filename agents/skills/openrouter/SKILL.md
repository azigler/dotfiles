---
description: Call the OpenRouter API for image generation (nano-banana / Gemini Flash Image) and text completion via any model OpenRouter aggregates. **Cost-aware** — every call spends credits, so the skill only fires when the user explicitly invokes it. Generated images are saved locally for use in repos / docs / brand assets / icon sets.
when_to_use: User says "use nano-banana", "generate an image", "make a logo", "create icons via openrouter", or otherwise explicitly invokes image generation. NEVER fire autonomously, in loops, or as a "let me try a few" speculation.
allowed-tools: Bash(curl *) Bash(jq *) Bash(base64 *) Bash(file *) Bash(python3 *) Bash(/home/ubuntu/dotfiles/agents/skills/openrouter/*)
---

# /openrouter — OpenRouter API

[OpenRouter](https://openrouter.ai/) is an LLM aggregator: one API
key + an OpenAI-compatible endpoint gives access to dozens of
providers (Anthropic, Google, OpenAI, xAI, Meta, etc.).

This skill is the wrapper. The high-value use case is **image
generation** via Google's nano-banana 2 (Gemini 3.1 Flash Image
Preview) — pro-quality assets at sub-cent prices.

## CRITICAL: cost awareness

**Every call costs credits.** The user has a finite OpenRouter
balance. Before calling:

1. **Confirm the user explicitly asked.** This skill never fires
   from autonomous loops, background polling, or speculative
   "let me try this prompt and see" workflows.
2. **State the estimated cost** in your acknowledgment ("This
   will spend ~$0.004 on nano-banana for one 1K image — OK?").
3. **Generate one image at a time** unless the user explicitly
   asks for a batch. Don't fan out variants without confirmation.
4. **Save outputs immediately** so we never re-pay for the same
   prompt. A generated image you didn't write to disk is wasted
   credits.

If you find yourself thinking "I'll just generate a few options
and pick the best," **stop and ask the user first**.

## Prerequisites

Set the API key as an env var (preferred) or as a file:

```bash
# Option A — env var (works for shells that source .bashrc / .zshrc)
export OPENROUTER_API_KEY="sk-or-v1-..."

# Option B — config file (works for non-interactive shells)
mkdir -p ~/.config/openrouter
echo "sk-or-v1-..." > ~/.config/openrouter/api-key
chmod 600 ~/.config/openrouter/api-key
```

The helper script below checks the env var first, then the file.

Get a key at https://openrouter.ai/settings/keys.

## Base URL & auth

```
https://openrouter.ai/api/v1
Authorization: Bearer $OPENROUTER_API_KEY
```

OpenAI-compatible. Optional headers for OpenRouter-leaderboard
attribution:

- `HTTP-Referer: <your site url>`
- `X-OpenRouter-Title: <your project name>`

## Image generation

### Model: nano-banana 2

Google's **Gemini 3.1 Flash Image Preview** — current state of the
art image generation + editing.

- **Model ID**: `google/gemini-3.1-flash-image-preview`
- **Pricing**: $0.50/M input tokens, $3.00/M output tokens
- **Per-image cost**: roughly $0.004 (about half a cent) for a
  standard 1K image; varies with output size

### Use the helper script

The cleanest path is the wrapper at
`~/.claude/skills/openrouter/openrouter-image.sh`:

```bash
~/.claude/skills/openrouter/openrouter-image.sh \
  "Frutiger Aero meets Silicon Dreams: rolling autumnal hill at golden hour, dewy moss texture, soft coral and sage palette" \
  ./brand/logo-v1.png

# With aspect / size overrides:
~/.claude/skills/openrouter/openrouter-image.sh \
  "..." ./out.png --aspect 16:9 --size 2K

# With a reference image (image-to-image):
~/.claude/skills/openrouter/openrouter-image.sh \
  "..." ./out.png --ref ./reference.png
```

The script handles auth lookup, request shape, response parsing,
base64 decode, and file write. It prints token usage on stderr so
you can track cost.

### Raw curl (when the helper is wrong tool)

```bash
curl -fsSL "https://openrouter.ai/api/v1/chat/completions" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemini-3.1-flash-image-preview",
    "messages": [
      {"role": "user", "content": "Generate a beautiful sunset over rolling hills at golden hour"}
    ],
    "modalities": ["image", "text"],
    "image_config": {
      "aspect_ratio": "1:1",
      "image_size": "1K"
    }
  }' \
  > /tmp/openrouter-response.json
```

Image data is at `.choices[0].message.images[0].image_url.url`
as a `data:image/png;base64,...` URL. Decode + write:

```bash
jq -r '.choices[0].message.images[0].image_url.url' /tmp/openrouter-response.json \
  | sed 's|^data:image/[^;]*;base64,||' \
  | base64 -d \
  > ./out.png

file ./out.png   # confirm valid PNG
```

### Image-to-image (with a reference)

```bash
REF_B64=$(base64 -w0 ./reference.png)

cat > /tmp/req.json <<JSON
{
  "model": "google/gemini-3.1-flash-image-preview",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "Re-render this image in the style of soft coral autumn pastels"},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,$REF_B64"}}
      ]
    }
  ],
  "modalities": ["image", "text"],
  "image_config": {"aspect_ratio": "1:1", "image_size": "1K"}
}
JSON

curl -fsSL "https://openrouter.ai/api/v1/chat/completions" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/req.json \
  > /tmp/openrouter-response.json
```

## Image config reference

**Standard aspect ratios** (all image-output models):
`1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `2:3`, `3:2`, `4:5`, `5:4`,
`21:9`

**Extended ratios** (Gemini 3.1 Flash only):
`1:4`, `4:1`, `1:8`, `8:1`

**Image sizes**:
- `0.5K`, `1K`, `2K`, `4K` — Gemini 3.1 Flash supports all four
- Other models typically start at `1K`

Higher sizes use more output tokens, so cost scales with size.

## Other use cases on OpenRouter

### Text completion via any model

Drop `modalities` and `image_config`; use the standard chat
shape. Browse the model catalog at https://openrouter.ai/models.

```bash
curl -fsSL "https://openrouter.ai/api/v1/chat/completions" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-opus-4.7",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

This is rare in practice — Claude Code already gives you direct
Claude access without OpenRouter overhead. Reach for OpenRouter
text-gen only when you need a model Claude Code can't invoke
directly (xAI Grok, niche fine-tunes, deprecated models for
research, etc.).

### Other image-output models

- `google/gemini-3.1-flash-image-preview` — nano-banana 2,
  current best-in-class
- `google/gemini-2.5-flash-image` — older nano-banana, slightly
  cheaper, slightly lower quality
- Various community fine-tunes — see
  https://openrouter.ai/models?output_modalities=image

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | Missing or wrong API key | Verify `$OPENROUTER_API_KEY` or `~/.config/openrouter/api-key` |
| `402 Payment Required` | Out of credits | Top up at https://openrouter.ai/settings/credits |
| `429 Too Many Requests` | Per-account rate limit | Back off; wait a minute |
| `400` with `Invalid model` | Wrong slug | Check exact slug at https://openrouter.ai/models |
| Empty `images` array in response | Model returned text only | Add `"modalities": ["image", "text"]` |
| Decoded file isn't a valid PNG | Wrong content-type prefix on the data URL | The `sed` strip should handle `data:image/png;base64,` and `data:image/jpeg;base64,` — check the actual prefix |
| Helper script: `OPENROUTER_API_KEY not set` | Env var missing in non-interactive shell | Put the key in `~/.config/openrouter/api-key` (works without shell init) |

## Guardrails

- **Never fire without explicit user invocation.** No autonomous
  loops, no background polling, no speculative "let me just try
  this prompt."
- **Save outputs immediately.** A generated image you didn't save
  is wasted credits.
- **One image per call by default.** Don't loop to generate 50
  variants without explicit ask + cost confirmation.
- **Ask before retrying.** If a generation comes back unsatisfactory,
  show the result to the user and ask before re-generating.
- **Don't store API keys in repos.** Use the env var or
  `~/.config/openrouter/api-key`. Both are off-repo.
- **Track cost.** The helper script prints `usage` on stderr — log
  these or sum them across a session if cost is a concern.

## See also

- [/impeccable](../impeccable/SKILL.md) — design library; pairs
  with image gen for brand work (run `/impeccable colorize` or
  `/impeccable typeset` to refine palettes / type before feeding
  prompts to nano-banana)
- [/ssot](../ssot/SKILL.md) — force diversity in creative gen;
  apply axes-and-arithmetic to brand prompts BEFORE feeding to
  nano-banana so we don't collapse to AI-default aesthetics
- [/zig-voice](../zig-voice/SKILL.md) — written voice for any
  text fields in generated assets (taglines, alt text, etc.)
- [/commit](../commit/SKILL.md) — landing generated assets in
  the repo with proper attribution
