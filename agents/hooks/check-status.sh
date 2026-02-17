#!/bin/bash
# Session end status check — informational only (Stop hook)
# Provides a checklist of items to review before ending session

set +e

echo ""
echo "=== Session End Checklist ==="
echo ""

# Uncommitted changes
CHANGES=$(git status --porcelain 2>/dev/null)
if [ -n "$CHANGES" ]; then
  echo "Uncommitted changes:"
  echo "$CHANGES" | head -10
  COUNT=$(echo "$CHANGES" | wc -l | tr -d ' ')
  if [ "$COUNT" -gt 10 ]; then
    echo "... ($COUNT total files)"
  fi
  echo ""
fi

# Unpushed commits
UNPUSHED=$(git log @{u}.. --oneline 2>/dev/null)
if [ -n "$UNPUSHED" ]; then
  echo "Unpushed commits:"
  echo "$UNPUSHED"
  echo ""
fi

# Check beads status
if command -v br &> /dev/null; then
  IN_PROGRESS=$(br list --status=in_progress 2>/dev/null | head -5)
  if [ -n "$IN_PROGRESS" ]; then
    echo "In-progress beads (remember to close or pause):"
    echo "$IN_PROGRESS"
    echo ""
  fi

  # Sync beads before ending
  br sync --flush-only 2>/dev/null || true
fi

echo "=== End Checklist ==="
exit 0
