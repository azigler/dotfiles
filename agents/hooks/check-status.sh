#!/bin/bash
# Stop: informational checklist before session ends.

set +e

echo ""
echo "=== Session End Checklist ==="
echo ""

CHANGES=$(git status --porcelain 2>/dev/null)
if [ -n "$CHANGES" ]; then
  echo "Uncommitted changes:"
  echo "$CHANGES" | head -10
  COUNT=$(echo "$CHANGES" | wc -l | tr -d ' ')
  [ "$COUNT" -gt 10 ] && echo "... ($COUNT total files)"
  echo ""
fi

UNPUSHED=$(git log @{u}.. --oneline 2>/dev/null)
if [ -n "$UNPUSHED" ]; then
  echo "Unpushed commits:"
  echo "$UNPUSHED"
  echo ""
fi

if command -v br &>/dev/null; then
  IN_PROGRESS=$(br list --status=in_progress 2>/dev/null | head -5)
  if [ -n "$IN_PROGRESS" ]; then
    echo "In-progress beads (close or pause):"
    echo "$IN_PROGRESS"
    echo ""
  fi
fi

echo "=== End Checklist ==="
exit 0
