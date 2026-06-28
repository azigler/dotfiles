#!/bin/bash
# PostToolUse (Bash): nudge against speculative image/deck fan-out.
#
# /gamma and /openrouter are cost-aware — one generation per call,
# confirm cost first, never fan out variants on speculation. This hook
# counts successful gamma-render.sh / openrouter-image.sh invocations in
# a rolling window and prints a reminder on the 2nd+.
#
# WARN only — it never blocks (exit 0 always). The call already ran, and
# "did the user ask for this one?" is unobservable to a hook; only the
# speculative-loop pattern is.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null); [ -z "$SKEL" ] && SKEL="$COMMAND"

# Only react to a generation-helper invocation.
echo "$SKEL" | grep -qE 'gamma-render\.sh|openrouter-image\.sh' || exit 0

# Only count successful runs.
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0')
[ "$EXIT_CODE" -ne 0 ] && exit 0

SESSION=$(echo "$INPUT" | jq -r '.session_id // "nosession"')
STATE="/tmp/claude-gen-fanout-${SESSION}"
WINDOW=600   # seconds
NOW=$(date +%s)

# Keep only timestamps within the window, then append this one.
RECENT=""
if [ -f "$STATE" ]; then
  while IFS= read -r ts; do
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    if [ $((NOW - ts)) -lt "$WINDOW" ]; then
      RECENT+="$ts"$'\n'
    fi
  done < "$STATE"
fi
RECENT+="$NOW"$'\n'
printf '%s' "$RECENT" > "$STATE"

COUNT=$(printf '%s' "$RECENT" | grep -c .)

if [ "$COUNT" -ge 2 ]; then
  echo "" >&2
  echo "Hint: $COUNT image/deck generations in the last $((WINDOW / 60)) min." >&2
  echo "/gamma and /openrouter are cost-aware — one generation per call;" >&2
  echo "confirm cost before fanning out variants. (Reminder, not a block.)" >&2
fi

exit 0
