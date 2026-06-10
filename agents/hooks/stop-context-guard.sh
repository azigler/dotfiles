#!/bin/bash
# Stop-hook context guard (pulse wave 4 — dotfiles-mhn §3d, dotfiles-lb6).
#
# When a session's context nears the auto-compaction zone, the agent
# should offboard DELIBERATELY (handoff + commit + push) instead of
# letting compaction surprise it mid-arc. Hooks don't receive the
# context-window % — only the statusline does — so statusline.sh
# persists the official used_percentage per session to
# /tmp/claude-context-pct/<session_id> and this hook reads it on Stop.
#
# Behavior:
# - pct >= threshold (default 85, CONTEXT_GUARD_PCT to override):
#   exit 2 — the agent keeps working WITH the stderr instruction, i.e.
#   the session offboards itself.
# - Fires ONCE per session (.fired marker) — never a nag loop.
# - Released by a RECENT offboard: if <cwd>/.claude/last-offboard-session
#   matches this session and was written within the last 30 min, the
#   work is already wrapped — stay quiet. The freshness window matters:
#   a session that offboarded yesterday and kept working is NOT wrapped,
#   and a stale match must not silence the warning (found live testing
#   against this very case, 2026-06-10).
# - stop_hook_active=true means we're already in a continuation forced
#   by a Stop hook — never re-block (loop protection per docs).
# - No pct file (statusline hasn't rendered / non-TUI) -> do nothing.
#
# Verified on 2.1.170 (2026-06-10): statusline payload carries
# session_id + context_window.used_percentage; see dotfiles-lb6 notes.
#
# Always exits 0 on the no-op paths; exit 2 is the single deliberate
# "keep going, offboard now" signal.

INPUT=$(cat 2>/dev/null || echo '{}')

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

# Already inside a stop-hook-forced continuation — never re-block.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-/tmp/claude-context-pct}"
PCT_FILE="$STATE_DIR/$SESSION_ID"
[ -f "$PCT_FILE" ] || exit 0

PCT=$(tr -dc '0-9' < "$PCT_FILE")
[ -n "$PCT" ] || exit 0

THRESHOLD="${CONTEXT_GUARD_PCT:-85}"
[ "$PCT" -ge "$THRESHOLD" ] || exit 0

# Fire once per session.
MARKER="$STATE_DIR/$SESSION_ID.fired"
[ -f "$MARKER" ] && exit 0

# A RECENT offboard already wrapped this session — nothing to protect.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
OFFBOARD_FILE="$CWD/.claude/last-offboard-session"
if [ -n "$CWD" ] && [ -f "$OFFBOARD_FILE" ] \
   && grep -q "$SESSION_ID" "$OFFBOARD_FILE" 2>/dev/null; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$OFFBOARD_FILE" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt "${CONTEXT_GUARD_OFFBOARD_FRESH_SECS:-1800}" ] && exit 0
fi

touch "$MARKER" 2>/dev/null

echo "Context at ${PCT}% of the window — nearing auto-compaction. Run /offboard NOW (handoff note + commit + push), then surface to Andrew that this session should be /compact'ed or /clear'ed deliberately before taking new work. Do not start anything new first." >&2
exit 2
