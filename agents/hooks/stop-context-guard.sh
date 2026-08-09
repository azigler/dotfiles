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
# - pct >= threshold (default 75, CONTEXT_GUARD_PCT to override):
#   exit 2 — the agent keeps working WITH the stderr instruction, i.e.
#   the session offboards itself AND THEN CYCLES ITSELF (the MOLT,
#   dotfiles-it06). 85 -> 75 because the old number left no room: an
#   /offboard is real work (handoff note + commit + push) and firing at
#   85% meant doing it in the last 15% of the window, with auto-compaction
#   able to land mid-wrap. 75 buys the headroom to offboard properly and
#   then molt deliberately.
# - The instruction is now SELF-SERVICE. It used to end "surface to
#   Andrew that this session should be /compact'ed or /clear'ed" — which
#   blocks autonomy by design: a marshal running all night has no Andrew
#   in the room, so the seat stalled at the ceiling until morning. It now
#   names agents/scheduler/seat-molt.sh, which does the cycle mechanically.
#   This guard is the BACKSTOP, not the mechanism: a long-loop seat molts
#   PROACTIVELY at work-item boundaries and should never reach this line.
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
#
# ⚠️ THE FRESHNESS WINDOW NEEDS A REAL MTIME (dotfiles-5vz2). It used to read
#   AGE=$(( $(date +%s) - $(stat -c %Y "$F" 2>/dev/null || echo 0) ))
# and `stat -c` is GNU-only: on macOS every call failed, the suppression hid
# the usage error, and `|| echo 0` made the offboard file ~56 years old. The
# guard therefore NEVER released a freshly-offboarded session on a Mac — it
# fired at the end of a turn that had just finished wrapping up. Now the mtime
# comes from lib/portable.sh, which returns non-zero instead of a wrong number,
# and an unreadable mtime FAILS CLOSED: no release, plus a line on stderr, so
# the degradation cannot be silent a second time.

INPUT=$(cat 2>/dev/null || echo '{}')

_CG_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
_CG_LIB="$_CG_DIR/lib/portable.sh"
[ -r "$_CG_LIB" ] && . "$_CG_LIB"

# The instruction below is an EXAMPLE, and in a prompt-driven harness an example
# is EXECUTABLE (this repo's rule 2): the agent copies it verbatim. So the path
# is resolved from this hook's own location and only printed as an absolute path
# when it actually exists — never a guessed repo-relative string that resolves
# against whatever cwd the session happens to be in.
_CG_MOLT="$_CG_DIR/../scheduler/seat-molt.sh"
if [ -x "$_CG_MOLT" ]; then
  _CG_MOLT="$(cd "$(dirname "$_CG_MOLT")" && pwd)/seat-molt.sh"
else
  _CG_MOLT="agents/scheduler/seat-molt.sh (not found — check the agents tier)"
fi

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

THRESHOLD="${CONTEXT_GUARD_PCT:-75}"
[ "$PCT" -ge "$THRESHOLD" ] || exit 0

# Fire once per session.
MARKER="$STATE_DIR/$SESSION_ID.fired"
[ -f "$MARKER" ] && exit 0

# A RECENT offboard already wrapped this session — nothing to protect.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
OFFBOARD_FILE="$CWD/.claude/last-offboard-session"
if [ -n "$CWD" ] && [ -f "$OFFBOARD_FILE" ] \
   && grep -q "$SESSION_ID" "$OFFBOARD_FILE" 2>/dev/null; then
  if OFFBOARD_MTIME=$(_p_mtime "$OFFBOARD_FILE"); then
    AGE=$(( $(date +%s) - OFFBOARD_MTIME ))
    [ "$AGE" -lt "${CONTEXT_GUARD_OFFBOARD_FRESH_SECS:-1800}" ] && exit 0
  else
    # FAIL CLOSED + ANNOUNCE. Without an mtime there is no freshness answer,
    # and the release is the permissive branch — so we do not take it, and we
    # say why rather than letting a broken mtime read look like a stale file.
    echo "stop-context-guard: could not read the mtime of $OFFBOARD_FILE — treating the offboard as NOT fresh (see lib/portable.sh)." >&2
  fi
fi

touch "$MARKER" 2>/dev/null

echo "Context at ${PCT}% of the window — nearing auto-compaction. Cycle this session YOURSELF, in two steps, before taking new work; do not start anything new first, and do not wait for Andrew. (1) Run /offboard NOW — handoff note + commit + push. (2) Then run: $_CG_MOLT --self --mode auto --in-flight <yes|no>   — pass yes if background tasks or an unfinishable arc are in flight (it /compacts, which preserves task handles) and no otherwise (it /clears + /onboards, which is cheaper and cleaner). It detaches and fires once you end this turn; it REFUSES unless step 1 really happened." >&2
exit 2
