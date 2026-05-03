#!/usr/bin/env bash
# openrouter-image.sh — Generate an image via OpenRouter and save to disk.
#
# Default model is Google's Gemini 3.1 Flash Image Preview (nano-banana 2).
# Costs roughly $0.004 per 1K image; cost scales with image_size.
#
# Usage:
#   openrouter-image.sh <prompt> <output-path> [options]
#
# Options:
#   --aspect <ratio>     Aspect ratio (1:1, 16:9, 9:16, etc.). Default: 1:1
#   --size <size>        Image size (0.5K, 1K, 2K, 4K). Default: 1K
#   --ref <path>         Reference image for image-to-image. Optional.
#   --model <slug>       Override model. Default: google/gemini-3.1-flash-image-preview
#
# Auth (in priority order):
#   1. $OPENROUTER_API_KEY env var
#   2. ~/.config/openrouter/api-key file
#
# Exits non-zero on:
#   - Missing args (1)
#   - Missing API key (2)
#   - Empty image in response (3)
#   - HTTP / curl error (passthrough from curl)

set -euo pipefail

usage() {
    cat >&2 <<'USAGE_EOF'
openrouter-image.sh — Generate an image via OpenRouter and save to disk.

Default model: Google's Gemini 3.1 Flash Image Preview (nano-banana 2).
Costs roughly $0.004 per 1K image; cost scales with image_size.

Usage:
  openrouter-image.sh <prompt> <output-path> [options]

Options:
  --aspect <ratio>     Aspect ratio (1:1, 16:9, 9:16, etc.). Default: 1:1
  --size <size>        Image size (0.5K, 1K, 2K, 4K). Default: 1K
  --ref <path>         Reference image for image-to-image. Optional.
  --model <slug>       Override model. Default: google/gemini-3.1-flash-image-preview

Auth (in priority order):
  1. \$OPENROUTER_API_KEY env var
  2. ~/.config/openrouter/api-key file

Examples:
  openrouter-image.sh "rolling autumn hills, soft coral palette" ./out.png
  openrouter-image.sh "..." ./out.png --aspect 16:9 --size 2K
  openrouter-image.sh "..." ./out.png --ref ./reference.png
USAGE_EOF
    exit 1
}

# Args
[ "$#" -lt 2 ] && usage
PROMPT="$1"
OUTPUT="$2"
shift 2

# Defaults
ASPECT="1:1"
SIZE="1K"
REF=""
MODEL="google/gemini-3.1-flash-image-preview"

# Parse flags
while [ $# -gt 0 ]; do
    case "$1" in
        --aspect) ASPECT="$2"; shift 2 ;;
        --size)   SIZE="$2";   shift 2 ;;
        --ref)    REF="$2";    shift 2 ;;
        --model)  MODEL="$2";  shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown flag: $1" >&2; usage ;;
    esac
done

# Auth lookup
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    if [ -f "${HOME}/.config/openrouter/api-key" ]; then
        OPENROUTER_API_KEY=$(< "${HOME}/.config/openrouter/api-key")
    else
        echo "ERROR: OPENROUTER_API_KEY not set and no key file at ~/.config/openrouter/api-key" >&2
        echo "       export OPENROUTER_API_KEY='sk-or-v1-...' or write the key to that file." >&2
        exit 2
    fi
fi

# Build request body via jq (handles JSON escaping correctly)
if [ -n "$REF" ]; then
    if [ ! -f "$REF" ]; then
        echo "ERROR: reference image not found: $REF" >&2
        exit 1
    fi
    REF_B64=$(base64 -w0 "$REF")
    BODY=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --arg ref "data:image/png;base64,$REF_B64" \
        --arg aspect "$ASPECT" \
        --arg size "$SIZE" \
        '{
            model: $model,
            messages: [{
                role: "user",
                content: [
                    {type: "text", text: $prompt},
                    {type: "image_url", image_url: {url: $ref}}
                ]
            }],
            modalities: ["image", "text"],
            image_config: {aspect_ratio: $aspect, image_size: $size}
        }')
else
    BODY=$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$PROMPT" \
        --arg aspect "$ASPECT" \
        --arg size "$SIZE" \
        '{
            model: $model,
            messages: [{role: "user", content: $prompt}],
            modalities: ["image", "text"],
            image_config: {aspect_ratio: $aspect, image_size: $size}
        }')
fi

echo ">>> Generating via $MODEL ($ASPECT, $SIZE) -> $OUTPUT" >&2

# Call API
RESPONSE=$(curl -fsSL "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/azigler" \
    -H "X-OpenRouter-Title: openrouter-skill" \
    -d "$BODY")

# Extract image
IMAGE_URL=$(echo "$RESPONSE" | jq -r '.choices[0].message.images[0].image_url.url // empty')

if [ -z "$IMAGE_URL" ]; then
    echo "ERROR: no image in response. Response was:" >&2
    echo "$RESPONSE" | jq . >&2
    exit 3
fi

# Decode base64 data URL -> file
mkdir -p "$(dirname "$OUTPUT")"
echo "$IMAGE_URL" | sed 's|^data:image/[^;]*;base64,||' | base64 -d > "$OUTPUT"

echo ">>> Saved $OUTPUT ($(file -b "$OUTPUT"))" >&2

# Print usage info if available (token counts → cost tracking)
USAGE=$(echo "$RESPONSE" | jq -c '.usage // empty')
if [ -n "$USAGE" ]; then
    echo ">>> Usage: $USAGE" >&2
fi
