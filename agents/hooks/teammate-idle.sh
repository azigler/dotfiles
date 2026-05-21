#!/bin/bash
# TeammateIdle: block if unpushed commits; warn on uncommitted changes.
# Exit 2 to keep the teammate working.

set +e

PROBLEMS=""

CHANGES=$(git status --porcelain 2>/dev/null)
if [ -n "$CHANGES" ]; then
  COUNT=$(echo "$CHANGES" | awk 'END {print NR}')
  echo "Warning: ${COUNT} uncommitted/untracked file(s) in working tree." >&2
  echo "If you authored these, commit before going idle." >&2
fi

# In worktrees, branches typically have no upstream — skip the unpushed check
# since the orchestrator handles merging and pushing
GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
case "$GIT_TOPLEVEL" in
  */.claude/worktrees/*) ;;  # worktree — skip
  *)
    UNPUSHED=$(git log @{u}.. --oneline 2>/dev/null)
    if [ -n "$UNPUSHED" ]; then
      COUNT=$(echo "$UNPUSHED" | awk 'END {print NR}')
      PROBLEMS="${PROBLEMS}You have ${COUNT} unpushed commit(s). Push before going idle.
"
    fi
    ;;
esac

if [ -n "$PROBLEMS" ]; then
  printf 'Not ready to go idle:\n\n%s' "$PROBLEMS" >&2
  exit 2
fi

exit 0
