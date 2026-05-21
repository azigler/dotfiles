#!/usr/bin/env bash
# openrouter-image.sh — Generate an image via OpenRouter and save to disk.
#
# Default model is Google's Gemini 3.1 Flash Image Preview (nano-banana 2).
# Costs roughly $0.05-0.07 per 1K image; cost scales with image_size.
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
Costs roughly $0.05-0.07 per 1K image; cost scales with image_size.

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
REFS=()
MODEL="google/gemini-3.1-flash-image-preview"

# Parse flags
while [ $# -gt 0 ]; do
    case "$1" in
        --aspect) ASPECT="$2"; shift 2 ;;
        --size)   SIZE="$2";   shift 2 ;;
        --ref)    REFS+=("$2"); shift 2 ;;
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

# Build request body via Python (handles multi-ref cleanly; avoids ARG_MAX
# on large base64 reference images and complex jq escaping with N images).
BODY_TMP=$(mktemp /tmp/openrouter-body.XXXXXX.json)
RESP_TMP=$(mktemp /tmp/openrouter-resp.XXXXXX.json)
trap 'rm -f "$BODY_TMP" "$RESP_TMP"' EXIT

# Validate ref files
for ref in "${REFS[@]}"; do
    if [ ! -f "$ref" ]; then
        echo "ERROR: reference image not found: $ref" >&2
        exit 1
    fi
done

REFS_JOINED=$(printf "%s\n" "${REFS[@]}")

PROMPT="$PROMPT" MODEL="$MODEL" ASPECT="$ASPECT" SIZE="$SIZE" \
  REFS_LIST="$REFS_JOINED" \
  python3 - <<'PYEOF' > "$BODY_TMP"
import os, sys, json, base64

prompt = os.environ["PROMPT"]
model = os.environ["MODEL"]
aspect = os.environ["ASPECT"]
size = os.environ["SIZE"]
refs_raw = os.environ.get("REFS_LIST", "").strip()
refs = [r for r in refs_raw.split("\n") if r]

content = [{"type": "text", "text": prompt}]
for ref in refs:
    with open(ref, "rb") as f:
        b64 = base64.b64encode(f.read()).decode("ascii")
    content.append({
        "type": "image_url",
        "image_url": {"url": f"data:image/png;base64,{b64}"},
    })

# When no refs, content can stay as plain string for simpler payloads
if len(content) == 1:
    payload_content = prompt
else:
    payload_content = content

body = {
    "model": model,
    "messages": [{"role": "user", "content": payload_content}],
    "modalities": ["image", "text"],
    "image_config": {"aspect_ratio": aspect, "image_size": size},
}
json.dump(body, sys.stdout)
PYEOF

echo ">>> Generating via $MODEL ($ASPECT, $SIZE) -> $OUTPUT" >&2

# Call API — read body from file, write response to file (avoids ARG_MAX
# both directions when reference images are large).
curl -fsSL "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/azigler" \
    -H "X-Title: openrouter-skill" \
    -d "@$BODY_TMP" \
    -o "$RESP_TMP"
RESPONSE=$(cat "$RESP_TMP")

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
