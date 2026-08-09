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
# ── THE TURN-END STAMP (dotfiles-ygf8) ──────────────────────────────────────
# This hook runs on EVERY Stop, so it is the one place that can cheaply record
# "a turn just ended" for something OUTSIDE the pane to read. seat-molt.sh's
# --self path used to infer idle-ness from pane-TEXT stability, and a
# background builder's token counter/spinner redraws every second — so a
# pane with real work in flight can STRUCTURALLY never read as stable, which
# is exactly the case that most needs molting (FINDING 3, live 2026-08-09: the
# first --self run sat blind until killed). The fix moves the signal out of
# the pane: this hook `touch`es $HARNESS_STATE_DIR/turn-end/<session_id>
# UNCONDITIONALLY, before any early exit below — mkdir -p + touch, the
# timestamp IS the content, nothing is ever read back here — and seat-molt.sh
# waits for that file's mtime to read NEWER than its own invocation instead of
# reading pixels. Unconditional-at-entry is deliberate: a stamp gated behind
# "there is a pct file" or "not already fired" would go dark for exactly the
# sessions (freshly cleared, or below the guard's own thresholds) that a
# waiting molt cares about most.
#
# ── RE-ARM (hysteresis) ─────────────────────────────────────────────────────
# The .fired marker below used to be permanent for the life of a session_id.
# A session that fires the 75% backstop, then compacts (same session_id,
# fresh context), climbs past 75% again with the backstop already dead — found
# live 2026-08-09, Zig at 78% with no guard firing. Two paths clear it, and
# both are load-bearing for a DIFFERENT reason, not redundantly:
#   (a) HERE, on every Stop: if pct drops below (threshold-20), the marker is
#       removed. This is the general case — ANY context drop re-arms the
#       guard, compaction included, and it needs no cooperation from whatever
#       caused the drop. The -20 gap is hysteresis: without it, a session
#       oscillating right at the threshold (busy work compresses old turns,
#       new turns grow it back) would fire on every single climb — a nag loop
#       the "fire once" marker exists specifically to prevent.
#   (b) pre-compact.sh ALSO clears it explicitly, unconditionally, on every
#       PreCompact. This is the belt: (a) depends on the NEXT Stop actually
#       reporting a pct file with a value below the re-arm floor, and the
#       statusline may not have rendered yet post-compaction (no pct file at
#       all -> exit 0 at the PCT_FILE check, never reaching the re-arm line).
#       Clearing at the compaction boundary itself has no such dependency.
# ── THE 50% NUDGE ────────────────────────────────────────────────────────────
# The 75% backstop is deliberately a LAST resort — the doctrine is to molt
# PROACTIVELY at a work-item boundary well before the ceiling. Nothing
# mechanical said so until now: a session had no signal between "fine" and
# "backstop firing in the agent's face." At pct >= CONTEXT_GUARD_NUDGE_PCT
# (default 50) and below the backstop THRESHOLD (the two never fire in the
# same turn — the backstop is strictly more urgent and wins), this hook prints
# a one-line advisory. It has to use exit 2 like the backstop: a Stop hook's
# stderr on exit 0 is invisible to the agent (only exit 2 is surfaced), but
# the nudge is "non-blocking" in the sense that matters — it names no
# mandatory next action within THIS turn, just a boundary to aim for — and it
# is rate-limited HARD (a separate .nudged marker, once per
# CONTEXT_GUARD_NUDGE_RATE_SECS, default 4h) so it nudges rather than nags.
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

# TURN-END STAMP (dotfiles-ygf8). Unconditional, before every early exit
# below — cheap (mkdir -p + touch, no read-back here), and it is the whole
# point that it goes down even on the paths that stop here for other reasons
# (stop_hook_active, no pct file yet). seat-molt.sh --self reads this file's
# mtime instead of inferring idle-ness from the pane.
_CG_TURN_END_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}/turn-end"
mkdir -p "$_CG_TURN_END_DIR" 2>/dev/null
touch "$_CG_TURN_END_DIR/$SESSION_ID" 2>/dev/null

# Already inside a stop-hook-forced continuation — never re-block.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-/tmp/claude-context-pct}"
PCT_FILE="$STATE_DIR/$SESSION_ID"
[ -f "$PCT_FILE" ] || exit 0

PCT=$(tr -dc '0-9' < "$PCT_FILE")
[ -n "$PCT" ] || exit 0

THRESHOLD="${CONTEXT_GUARD_PCT:-75}"
MARKER="$STATE_DIR/$SESSION_ID.fired"

# RE-ARM (path a — see the header comment for why path b, in pre-compact.sh,
# is ALSO needed and not redundant). Any drop below threshold-20 clears the
# marker so a later climb fires the backstop again.
REARM_FLOOR=$(( THRESHOLD - 20 ))
if [ "$PCT" -lt "$REARM_FLOOR" ]; then
  rm -f "$MARKER" 2>/dev/null
fi

# THE 50% NUDGE — see the header comment. Only in the gap between the nudge
# floor and the backstop threshold: at/above THRESHOLD the backstop below is
# strictly more urgent and the two must never fire in the same turn.
NUDGE_PCT="${CONTEXT_GUARD_NUDGE_PCT:-50}"
if [ "$PCT" -ge "$NUDGE_PCT" ] && [ "$PCT" -lt "$THRESHOLD" ]; then
  NUDGE_MARKER="$STATE_DIR/$SESSION_ID.nudged"
  NUDGE_RATE_SECS="${CONTEXT_GUARD_NUDGE_RATE_SECS:-14400}"
  NUDGE_DUE=1
  if [ -f "$NUDGE_MARKER" ]; then
    if command -v _p_mtime >/dev/null 2>&1 && NUDGE_MTIME=$(_p_mtime "$NUDGE_MARKER" 2>/dev/null); then
      NUDGE_AGE=$(( $(date +%s) - NUDGE_MTIME ))
      [ "$NUDGE_AGE" -lt "$NUDGE_RATE_SECS" ] && NUDGE_DUE=0
    fi
    # An unreadable mtime (missing lib/portable.sh, or the stat call itself
    # fails) is NOT a freshness question the way the offboard/backstop ones
    # are — the nudge is advisory, not a release gate — so it degrades to
    # "due again" rather than failing closed.
  fi
  if [ "$NUDGE_DUE" -eq 1 ]; then
    touch "$NUDGE_MARKER" 2>/dev/null
    echo "context past ${NUDGE_PCT}% — molt at your next boundary: /offboard then seat-molt --self" >&2
    exit 2
  fi
fi

[ "$PCT" -ge "$THRESHOLD" ] || exit 0

# Fire once per session.
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
