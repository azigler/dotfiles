#!/bin/bash
# PreToolUse (Bash): block `git merge worktree-agent-*` if the worktree
# branch's last commit looks broken (no Bead: trailer, no actual content).
# Catches cases where the orchestrator merges a subagent before its
# /handoff cleared.
# Exit 2 = block and feed error to agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null); [ -z "$SKEL" ] && SKEL="$COMMAND"

# Only intercept git merge of worktree-agent-* branches
echo "$SKEL" | grep -qE 'git merge[[:space:]]+worktree-agent-' || exit 0

# Extract the worktree branch name
BRANCH=$(echo "$SKEL" | grep -oE 'worktree-agent-[a-zA-Z0-9_-]+' | head -1)
[ -z "$BRANCH" ] && exit 0

# Verify the branch exists locally
if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
  exit 0  # let git's own error fire
fi

# Check 1: the branch has commits beyond main
COMMIT_COUNT=$(git log "main..$BRANCH" --oneline 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "Blocked: $BRANCH has no commits beyond main. Nothing to merge." >&2
  exit 2
fi

# Check 2: every commit on the branch has a Bead: trailer
MISSING_BEAD=$(git log "main..$BRANCH" --pretty=format:'%H %s' 2>/dev/null | while read -r hash subject; do
  if ! git show -s --format=%B "$hash" 2>/dev/null | grep -q '^Bead:'; then
    echo "$hash  $subject"
  fi
done)

if [ -n "$MISSING_BEAD" ]; then
  echo "Blocked: $BRANCH has commits without a Bead: trailer:" >&2
  echo "$MISSING_BEAD" >&2
  echo "" >&2
  echo "Subagents must include 'Bead: <id>' in commit trailers (see /commit, /handoff)." >&2
  echo "Fix the trailer (e.g., git rebase + reword) before merging." >&2
  exit 2
fi

exit 0
