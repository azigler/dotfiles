#!/bin/bash
# PreToolUse (Bash): block `br close` if the bead lints fail.
# Mechanically enforces the description-mandatory rule.
# Exit 2 = block the close and feed errors to agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept br close commands
case "$COMMAND" in
  br\ close*|*"&& br close"*|*"; br close"*) ;;
  *) exit 0 ;;
esac

# br must be installed
command -v br &>/dev/null || exit 0

# Extract bead IDs from `br close <id> [<id> ...] [&&|;|other-cmd]`
# Stop at the first &&, ;, |, or pipe so we only get the actual close args.
CLOSE_ARGS=$(echo "$COMMAND" | grep -oE 'br close [^&;|]+' | sed 's/^br close //')
BEAD_IDS=$(echo "$CLOSE_ARGS" | tr ' ' '\n' | grep -E '^[a-z0-9]+-[a-z0-9]+$')

[ -z "$BEAD_IDS" ] && exit 0

# If the command chains `cd <path>` before `br close`, follow that cd
# so `br lint` runs against the same beads store the user's command
# will target. Without this, closing a bead in project A from a session
# whose cwd is in project B walks up to B's .beads/ and reports
# 'Issue not found' even when the bead is correctly populated.
# See bd-8euh.
TARGET_CWD=$(echo "$COMMAND" | grep -oE '(^|[;&] *)cd +[^&;|]+' | head -1 | sed -E 's/^.*cd +//' | tr -d ' ')
TARGET_CWD="${TARGET_CWD/#\~/$HOME}"
if [ -n "$TARGET_CWD" ] && [ -d "$TARGET_CWD" ]; then
  cd "$TARGET_CWD" || true
fi

set +e
FAILED=0
for ID in $BEAD_IDS; do
  OUTPUT=$(br lint "$ID" 2>&1)
  if [ $? -ne 0 ] && [ -n "$OUTPUT" ]; then
    echo "Blocked: bead $ID has incomplete template sections." >&2
    echo "$OUTPUT" >&2
    echo "" >&2
    echo "Fix the bead via 'br update $ID --description ...' (or --acceptance-criteria, --design)" >&2
    echo "before closing. See /beads SKILL." >&2
    FAILED=1
  fi
done

[ $FAILED -ne 0 ] && exit 2
exit 0
