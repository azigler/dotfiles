#!/bin/bash
# SessionEnd: persist bead state, then drop the .offboard-pending marker
# if this session ended WITHOUT /offboard having run.
#
# The marker is the retroactive-offboard safety net: the next session's
# /onboard Step 0 finds it and runs /offboard for the prior session.
# /offboard removes it (Step 5). "Did /offboard run this session?" is
# detected by HEAD having committed the session handoff note — /offboard
# always writes and commits it.
#
# pre-compact.sh deliberately does NOT drop the marker: compaction keeps
# the same session alive, so that session's own post-compaction /onboard
# would misread its own marker as a prior session's.

if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null
fi

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  case "$ROOT" in
    ""|*/.claude/worktrees/*) ;;  # outside git, or inside a worktree — skip
    *)
      if git -C "$ROOT" diff-tree --no-commit-id --name-only -r --root HEAD 2>/dev/null \
           | grep -qE 'session-handoff\.md$'; then
        : # /offboard ran this session — HEAD committed the handoff note
      else
        touch "$ROOT/.offboard-pending"
      fi
      ;;
  esac
fi

exit 0
