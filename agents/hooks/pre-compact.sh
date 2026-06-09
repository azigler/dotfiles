#!/bin/bash
# PreCompact: re-inject state so the agent doesn't lose orientation.

echo "=== State Before Compaction ==="

# Tell the post-compaction agent to onboard before any action.
echo "IMPORTANT: Run /onboard before doing anything. It re-reads CLAUDE.md, MEMORY.md, the prior session's handoff note (refs/session-handoff.md), and the skills TOOLKIT digest in the main session — preventing blind post-compaction execution."

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Branch: $(git branch --show-current 2>/dev/null)"
  DIRTY=$(git status --short 2>/dev/null | head -10)
  if [ -n "$DIRTY" ]; then
    echo "Dirty files:"
    echo "$DIRTY"
  fi
fi

if command -v br &>/dev/null; then
  BEADS=$(br list 2>/dev/null)
  if [ -n "$BEADS" ]; then
    echo ""
    echo "Open beads:"
    echo "$BEADS"
  fi
  br sync --flush-only 2>/dev/null
fi

exit 0
