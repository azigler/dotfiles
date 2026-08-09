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

# `grep -c` PRINTS "0" and EXITS 1 when nothing matches. The old
# `... | grep -cE '...' || echo 0` therefore appended a SECOND "0" on the
# no-match path, making READY_COUNT the two-line string "0\n0" — and the
# `-gt` test below then failed with `[: integer expression expected` on
# stderr for EVERY `br close` / worktree merge in a repo with no ready
# beads. Assign first (grep -c always prints a count), then normalize.
READY_COUNT=$(br ready 2>/dev/null | grep -cE '^[○●]')
READY_COUNT=${READY_COUNT:-0}
# Belt-and-braces: never feed a non-integer to `[ -gt ]`. A hint hook must
# not be able to spray shell errors into the agent's transcript.
case "$READY_COUNT" in
  ''|*[!0-9]*) READY_COUNT=0 ;;
esac

# Threshold: 30 ready beads = backlog needs attention
if [ "$READY_COUNT" -gt 30 ]; then
  echo "" >&2
  echo "Hint: 'br ready' has $READY_COUNT items — consider running /triage to clean up stale / orphaned beads." >&2
fi

# Concrete next-pick nudge: adopt `br close --suggest-next` at the call
# site instead of a separate `bv --robot-next` shell-out (dotfiles-n10e).
# `--suggest-next` only returns data for the CLOSE invocation it's passed
# to (`br help close`: "After closing, return newly unblocked issues
# (single ID only)") — a PostToolUse hook runs AFTER that command already
# finished, so it cannot retroactively fetch the answer; it can only nudge
# the orchestrator to pass the flag on the *next* close and read the
# answer straight off that command's own stdout. Only applies to the
# `br close` trigger (a worktree merge never ran `br close`, so there is
# nothing to suggest passing the flag to). Gated on `br blocked` actually
# having entries — same "only speak if there's something to say" behavior
# the old bv shell-out had (it stayed silent when bv had no suggestion);
# without this gate the hint would fire on EVERY close, which is noise.
if echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+close([[:space:]]|$)' \
   && ! echo "$SKEL" | grep -q -- '--suggest-next'; then
  if br blocked 2>/dev/null | grep -qE '^\['; then
    echo "" >&2
    echo "Hint: pass --suggest-next to 'br close' to see newly-unblocked issues in its own output (e.g. 'br close <id> --suggest-next') — replaces the old bv --robot-next lookup." >&2
  fi
fi

exit 0
