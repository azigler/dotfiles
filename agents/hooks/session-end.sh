#!/bin/bash
# SessionEnd: persist bead state, then drop the .offboard-pending marker
# if this session ended WITHOUT /offboard having run.
#
# The marker is the retroactive-offboard safety net: the next session's
# /onboard Step 0 finds it and runs /offboard for the prior session.
# /offboard removes it (Step 5). "Did /offboard run this session?" is
# detected primarily by .claude/last-offboard-session matching this
# session's id (/offboard writes that file in Step 5; both it and the
# marker are in the global gitignore). Fallback: HEAD committed the
# session handoff note. The HEAD heuristic alone was fragile — any
# commit AFTER /offboard in the same session (a bead close, a quick
# fix) made HEAD no longer the handoff commit, dropping the marker
# spuriously (fixed 2026-06-09).
#
# pre-compact.sh deliberately does NOT drop the marker: compaction keeps
# the same session alive, so that session's own post-compaction /onboard
# would misread its own marker as a prior session's.

STDIN=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$STDIN" | jq -r '.session_id // empty' 2>/dev/null)

if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null
fi

# Servitor / dispatched sessions opt OUT of the offboard safety net. They have
# no handoff contract (ephemeral workers), and in a SHARED git umbrella like
# ~/explore — where local-coding-models/, fledgling/, etc. all resolve to the
# explore git root — a servitor ending here would otherwise drop a root-scoped
# .offboard-pending that the explore PULSE orchestrator then trips over as a
# false positive. The dispatcher (dispatch-cc.sh) sets this for every servitor.
if [ -n "${CLAUDE_NO_OFFBOARD_MARKER:-}" ]; then
  exit 0
fi

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  case "$ROOT" in
    ""|*/.claude/worktrees/*) ;;  # outside git, or inside a worktree — skip
    *)
      OFFBOARDED=false
      if [ -n "$SESSION_ID" ] && [ -f "$ROOT/.claude/last-offboard-session" ] \
         && [ "$(cat "$ROOT/.claude/last-offboard-session" 2>/dev/null)" = "$SESSION_ID" ]; then
        OFFBOARDED=true   # /offboard ran this session (primary signal)
      elif git -C "$ROOT" diff-tree --no-commit-id --name-only -r --root HEAD 2>/dev/null \
           | grep -qE 'session-handoff\.md$'; then
        OFFBOARDED=true   # fallback: HEAD is the handoff commit
      fi
      # Stamp the marker with the ending session's id (not a bare touch), so a
      # stale one is traceable to its source session for debugging.
      $OFFBOARDED || printf '%s\n' "${SESSION_ID:-unknown}" > "$ROOT/.offboard-pending"
      ;;
  esac
fi

exit 0
