#!/bin/bash
# PreCompact OBSERVE-MODE backstop (pulse wave 4 — dotfiles-mhn §3d,
# dotfiles-lb6). The spec's backstop blocks an AUTO compaction once
# ("offboard first") — but PreCompact blockability has never been
# observed on a real auto-compact on this build, and the spec requires
# empirical verification before an enforcing hook ships. So this logs
# what an enforcing guard WOULD have done and always allows.
#
# Flip to enforce only after /tmp/claude-compact-observe.log shows a
# real trigger=auto entry AND docs/behavior confirm blocking works
# there (manual compacts must never be blocked — Andrew asked for
# them). The Stop-hook guard (stop-context-guard.sh) fires at 85%,
# well before auto-compaction, so this backstop is defense-in-depth,
# not the primary mechanism.

INPUT=$(cat 2>/dev/null || echo '{}')

TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
LOG="${COMPACT_OBSERVE_LOG:-/tmp/claude-compact-observe.log}"

WOULD="allow"
if [ "$TRIGGER" = "auto" ]; then
  OFFBOARDED="no"
  if [ -n "$CWD" ] && [ -f "$CWD/.claude/last-offboard-session" ] \
     && grep -q "$SESSION_ID" "$CWD/.claude/last-offboard-session" 2>/dev/null; then
    OFFBOARDED="yes"
  fi
  [ "$OFFBOARDED" = "no" ] && WOULD="block(offboard-first)"
fi

echo "$(date -u +%FT%TZ) trigger=$TRIGGER session=$SESSION_ID cwd=$CWD would=$WOULD" >> "$LOG" 2>/dev/null

exit 0
