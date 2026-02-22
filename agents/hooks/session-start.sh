#!/bin/bash
# SessionStart: inject project context so the agent starts oriented.

echo "=== Session Context ==="

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  echo "Branch: ${BRANCH:-detached}"
  DIRTY=$(git status --short 2>/dev/null | head -10)
  if [ -n "$DIRTY" ]; then
    echo "Dirty files:"
    echo "$DIRTY"
  fi
fi

if command -v br &>/dev/null; then
  # In a worktree, symlink .beads/ to the main worktree's copy (single source of truth)
  if [ -f ".git" ] && [ -d ".beads" ] && [ ! -L ".beads" ]; then
    MAIN_WT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    if [ -n "$MAIN_WT" ] && [ -d "$MAIN_WT/.beads" ]; then
      rm -rf .beads
      ln -s "$MAIN_WT/.beads" .beads
      echo "Symlinked .beads/ → $MAIN_WT/.beads/"
    fi
  fi

  # Ensure .gitattributes has merge=union for JSONL (needed for worktree merges)
  if [ -d ".beads" ] && ! grep -q 'merge=union' .gitattributes 2>/dev/null; then
    echo '.beads/*.jsonl merge=union' >> .gitattributes
    git add .gitattributes && git commit -q -m ":wrench: config: add gitattributes for JSONL merge" 2>/dev/null
  fi

  br sync --import-only 2>/dev/null
  BEADS=$(br list 2>/dev/null)
  if [ -n "$BEADS" ]; then
    echo ""
    echo "Open beads:"
    echo "$BEADS"
  fi
fi

exit 0
