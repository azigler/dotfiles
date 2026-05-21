#!/usr/bin/env bash
# gamma-render.sh — Submit a Gamma generation, poll until complete, save the
# full response, and print gammaUrl / exportUrl / credit usage.
#
# Usage:
#   gamma-render.sh <payload.json>
#
# The payload is the Gamma POST /generations request body. See the SKILL.md
# 3-style framework for canonical examples (Style A / B / C).
#
# Output:
#   ~/.cache/gamma/<basename-of-payload>-<timestamp>.json
#
# Auth (in priority order):
#   1. $GAMMA_API_KEY env var
#   2. ~/.config/gamma/api-key file
#   3. $GAMMA_ENV_FILE — path to an .env.local carrying a GAMMA_API_KEY= line
#
# Exit codes:
#   0  OK — generation completed
#   1  Missing or invalid args
#   2  Missing API key
#   3  Generation failed (API returned status: "failed")
#   4  Polling timed out (>5 minutes)

set -euo pipefail

usage() {
    cat >&2 <<'USAGE_EOF'
gamma-render.sh — Submit a Gamma generation and save the result.

Usage:
  gamma-render.sh <payload.json>

The payload is the Gamma POST /generations request body. See the SKILL.md
3-style framework for canonical Style A / B / C examples.

Output:
  ~/.cache/gamma/<name>-<timestamp>.json   (full response JSON)

Auth lookup priority:
  1. $GAMMA_API_KEY env var
  2. ~/.config/gamma/api-key file
  3. $GAMMA_ENV_FILE — an .env.local carrying GAMMA_API_KEY=

Exit codes:
  0  OK
  1  Missing or invalid args
  2  Missing API key
  3  Generation failed
  4  Polling timed out (>5 min)

Examples:
  gamma-render.sh ./style-c.json
  gamma-render.sh ~/projects/my-deck/payload.json
USAGE_EOF
    exit 1
}

# Args
[ "$#" -lt 1 ] && usage
PAYLOAD="$1"

if [ ! -f "$PAYLOAD" ]; then
    echo "ERROR: payload file not found: $PAYLOAD" >&2
    exit 1
fi

# Validate JSON early so we don't waste a credit-deducting submit on a typo
if ! python3 -c "import json,sys; json.load(open('$PAYLOAD'))" >/dev/null 2>&1; then
    echo "ERROR: payload is not valid JSON: $PAYLOAD" >&2
    exit 1
fi

# Auth lookup
FALLBACK_ENV_FILE="${GAMMA_ENV_FILE:-}"

if [ -z "${GAMMA_API_KEY:-}" ]; then
    if [ -f "${HOME}/.config/gamma/api-key" ]; then
        GAMMA_API_KEY=$(< "${HOME}/.config/gamma/api-key")
    elif [ -f "$FALLBACK_ENV_FILE" ]; then
        # Extract GAMMA_API_KEY=... line; strip quotes if present
        GAMMA_API_KEY=$(grep -E '^GAMMA_API_KEY=' "$FALLBACK_ENV_FILE" 2>/dev/null \
            | head -1 \
            | sed -E 's/^GAMMA_API_KEY=//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
    fi
fi

if [ -z "${GAMMA_API_KEY:-}" ]; then
    cat >&2 <<'KEY_ERR_EOF'
ERROR: GAMMA_API_KEY not found in any of:
  1. $GAMMA_API_KEY env var
  2. ~/.config/gamma/api-key
  3. $GAMMA_ENV_FILE (an .env.local carrying GAMMA_API_KEY=)

Fix one:
  export GAMMA_API_KEY='sk-gamma-...'
  # OR
  mkdir -p ~/.config/gamma && echo 'sk-gamma-...' > ~/.config/gamma/api-key && chmod 600 ~/.config/gamma/api-key
  # OR point GAMMA_ENV_FILE at an .env.local that has the key
KEY_ERR_EOF
    exit 2
fi

# Output path
NAME=$(basename "$PAYLOAD" .json)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="${HOME}/.cache/gamma"
RESULT="${OUTPUT_DIR}/${NAME}-${TIMESTAMP}.json"
mkdir -p "$OUTPUT_DIR"

# Submit
echo ">>> Submitting Gamma generation from $PAYLOAD" >&2
SUBMIT_TMP=$(mktemp /tmp/gamma-submit.XXXXXX.json)
trap 'rm -f "$SUBMIT_TMP"' EXIT

curl -fsSL "https://public-api.gamma.app/v1.0/generations" \
    -H "X-API-Key: $GAMMA_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD" \
    -o "$SUBMIT_TMP"

GENERATION_ID=$(python3 -c "import json,sys; print(json.load(open('$SUBMIT_TMP'))['generationId'])")
WARNINGS=$(python3 -c "import json,sys; print(json.load(open('$SUBMIT_TMP')).get('warnings') or '')")

echo ">>> Generation ID: $GENERATION_ID" >&2
if [ -n "$WARNINGS" ]; then
    echo ">>> Warnings: $WARNINGS" >&2
fi

# Poll
echo ">>> Polling for completion (5-sec interval, 5-min timeout)…" >&2
START=$(date +%s)
POLL_TMP=$(mktemp /tmp/gamma-poll.XXXXXX.json)
trap 'rm -f "$SUBMIT_TMP" "$POLL_TMP"' EXIT

while true; do
    curl -fsSL "https://public-api.gamma.app/v1.0/generations/$GENERATION_ID" \
        -H "X-API-Key: $GAMMA_API_KEY" \
        -o "$POLL_TMP"
    STATUS=$(python3 -c "import json,sys; print(json.load(open('$POLL_TMP'))['status'])")
    case "$STATUS" in
        completed)
            echo "" >&2
            echo ">>> Status: completed" >&2
            break
            ;;
        failed)
            echo "" >&2
            python3 -m json.tool < "$POLL_TMP" >&2
            echo "!!! Generation failed" >&2
            cp "$POLL_TMP" "$RESULT"
            echo ">>> Saved failure response to: $RESULT" >&2
            exit 3
            ;;
        pending)
            ELAPSED=$(( $(date +%s) - START ))
            if [ "$ELAPSED" -gt 300 ]; then
                echo "" >&2
                echo "!!! Polling timed out after ${ELAPSED}s" >&2
                cp "$POLL_TMP" "$RESULT"
                echo ">>> Saved last poll response to: $RESULT" >&2
                exit 4
            fi
            printf "." >&2
            sleep 5
            ;;
        *)
            echo "" >&2
            echo "!!! Unknown status: $STATUS" >&2
            python3 -m json.tool < "$POLL_TMP" >&2
            exit 3
            ;;
    esac
done

# Save full response
cp "$POLL_TMP" "$RESULT"
echo ">>> Saved response to: $RESULT" >&2
echo "" >&2

# Print URLs and credits
GAMMA_URL=$(python3 -c "import json,sys; print(json.load(open('$RESULT')).get('gammaUrl') or '')")
EXPORT_URL=$(python3 -c "import json,sys; print(json.load(open('$RESULT')).get('exportUrl') or '')")
CREDITS=$(python3 -c "import json,sys; c=json.load(open('$RESULT')).get('credits') or {}; print(f\"deducted={c.get('deducted')} remaining={c.get('remaining')}\")")

echo ">>> gammaUrl:  $GAMMA_URL" >&2
echo ">>> exportUrl: $EXPORT_URL" >&2
echo ">>> credits:   $CREDITS" >&2
