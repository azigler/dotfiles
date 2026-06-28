#!/bin/bash
# PostToolUse (Bash): after `br close` or `git merge worktree-*` succeeds,
# nudge to /triage if br ready is unmanageable.
# Informational only (never blocks).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null); [ -z "$SKEL" ] && SKEL="$COMMAND"

# Only fire on close / merge actions that change orchestrator state
case "$SKEL" in
  br\ close*|*"&& br close"*|*"; br close"*) ;;
  *git\ merge\ worktree-agent-*) ;;
  *) exit 0 ;;
esac

# Only fire if the action succeeded (PostToolUse runs after tool ran;
# if exit code in tool_response.exit_code is set and non-zero, skip)
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0')
[ "$EXIT_CODE" -ne 0 ] && exit 0

command -v br &>/dev/null || exit 0

READY_COUNT=$(br ready 2>/dev/null | grep -cE '^[○●]' || echo 0)

# Threshold: 30 ready beads = backlog needs attention
if [ "$READY_COUNT" -gt 30 ]; then
  echo "" >&2
  echo "Hint: 'br ready' has $READY_COUNT items — consider running /triage to clean up stale / orphaned beads." >&2
fi

# Concrete next-pick nudge via bv (graph-aware). Skip if bv isn't installed
# or no beads here. Stays at "hint" volume — single line to stderr.
if command -v bv &>/dev/null && [ -d ".beads" ]; then
  NEXT=$(bv --robot-next 2>/dev/null | jq -r 'select(.id) | "Next pick: \(.id) — \(.title)  (claim: \(.claim_command))"' 2>/dev/null)
  if [ -n "$NEXT" ]; then
    echo "" >&2
    echo "$NEXT" >&2
  fi
fi

exit 0
