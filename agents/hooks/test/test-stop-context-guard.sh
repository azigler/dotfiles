#!/bin/bash
# Test for stop-context-guard.sh + statusline pct persistence +
# pre-compact-observe.sh (pulse wave 4, dotfiles-lb6).
#
# Hook test convention: executable bash, non-zero exit = failure,
# PASS/FAIL summary on the last line.

set -u

HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
. "$HOOKS/lib/portable.sh"
GUARD="$HOOKS/stop-context-guard.sh"
OBSERVE="$HOOKS/pre-compact-observe.sh"
STATUSLINE="$(cd "$HOOKS/../.." && pwd)/claude/statusline.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

STATE=$(mktemp -d)
PROJ=$(mktemp -d)
trap 'rm -rf "$STATE" "$PROJ"' EXIT

SID="test-session-1234"

guard() {
  printf '%s' "$1" | CONTEXT_GUARD_STATE_DIR="$STATE" CONTEXT_GUARD_PCT="${2:-75}" "$GUARD" 2>/tmp/guard-stderr-$$
}
# The DEFAULT threshold, with no CONTEXT_GUARD_PCT in the environment. Separate
# helper on purpose: guard() pins the threshold, so it can never observe the
# default drifting — and the default is the number every real session gets.
guard_default() {
  printf '%s' "$1" | CONTEXT_GUARD_STATE_DIR="$STATE" "$GUARD" 2>/tmp/guard-stderr-$$
}

PAYLOAD_BASE=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ")

# 1. No pct file yet → quiet exit 0
guard "$PAYLOAD_BASE"
[ $? -eq 0 ] && ok || bad "no pct file is a no-op"

# 2. Below threshold → exit 0
echo "40" > "$STATE/$SID"
guard "$PAYLOAD_BASE"
[ $? -eq 0 ] && ok || bad "below threshold is a no-op"

# 3. At threshold → exit 2 with the two-step self-service instruction
echo "80" > "$STATE/$SID"
guard "$PAYLOAD_BASE"
RC=$?
[ $RC -eq 2 ] && ok || bad "at threshold exits 2 (got $RC)"
grep -q "/offboard" /tmp/guard-stderr-$$ && ok || bad "stderr carries the offboard instruction"

# 3b. THE MOLT (dotfiles-it06). The instruction must name the mechanical cycle,
#     not "surface to Andrew" — a marshal running all night has no Andrew in the
#     room, and a guard that can only escalate is a guard that stalls the seat.
grep -q -- "seat-molt.sh --self --mode auto --in-flight" /tmp/guard-stderr-$$ && ok \
  || bad "the instruction names seat-molt.sh --self --mode auto --in-flight"
if grep -q "surface to Andrew" /tmp/guard-stderr-$$; then
  bad "the old 'surface to Andrew' escalation is gone"
else ok; fi

# 3c. AND THE PATH IT NAMES MUST EXIST AND BE EXECUTABLE. A documented example is
#     executable in a prompt-driven harness (this repo's rule 2): the agent runs
#     this line verbatim, so a stale path here is a defect that replicates itself
#     into every session that hits the ceiling.
MOLT_PATH=$(grep -o '[^ ]*seat-molt\.sh' /tmp/guard-stderr-$$ | head -1)
[ -n "$MOLT_PATH" ] && [ -x "$MOLT_PATH" ] && ok \
  || bad "the seat-molt.sh path in the message is executable (got '${MOLT_PATH:-<none>}')"
rm -f "$STATE/$SID.fired"

# 3d. THE DEFAULT THRESHOLD IS 75, pinned from both sides (85 -> 75, it06). The
#     old default left an /offboard — real work: note + commit + push — to be done
#     in the last 15% of the window, with auto-compaction able to land mid-wrap.
echo "75" > "$STATE/$SID"
guard_default "$PAYLOAD_BASE"
[ $? -eq 2 ] && ok || bad "the DEFAULT threshold fires at 75%"
rm -f "$STATE/$SID.fired"
echo "74" > "$STATE/$SID"
guard_default "$PAYLOAD_BASE"
[ $? -eq 0 ] && ok || bad "the DEFAULT threshold does NOT fire at 74% (it is 75, not lower)"
rm -f "$STATE/$SID.fired"
echo "80" > "$STATE/$SID"
guard "$PAYLOAD_BASE"   # re-arm the fired marker for case 4

# 4. Second fire same session → marker suppresses (no nag loop)
guard "$PAYLOAD_BASE"
[ $? -eq 0 ] && ok || bad "marker suppresses second fire"

# 5. stop_hook_active=true → never blocks even over threshold
rm -f "$STATE/$SID.fired"
ACTIVE=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","stop_hook_active":true}' "$SID" "$PROJ")
guard "$ACTIVE"
[ $? -eq 0 ] && ok || bad "stop_hook_active suppresses block"

# 6. Offboard release: FRESH last-offboard-session match → exit 0, no marker
rm -f "$STATE/$SID.fired"
mkdir -p "$PROJ/.claude"
echo "$SID" > "$PROJ/.claude/last-offboard-session"
guard "$PAYLOAD_BASE"
[ $? -eq 0 ] && ok || bad "freshly offboarded session is released"
[ ! -f "$STATE/$SID.fired" ] && ok || bad "offboard release leaves no marker"

# 6b. STALE offboard match (hours old) does NOT release — the session
#     kept working past its offboard; the warning must still fire.
#     NOT `touch -d '2 hours ago'`: that is GNU-only, and on BSD it dies with
#     "out of range or illegal time specification" — which leaves the fixture
#     at NOW and turns this case into a silent duplicate of case 6. Same defect
#     class as the hook bug it is testing (dotfiles-5vz2).
_p_touch_at "$(( $(date +%s) - 7200 ))" "$PROJ/.claude/last-offboard-session"
guard "$PAYLOAD_BASE"
[ $? -eq 2 ] && ok || bad "stale offboard does not silence the guard"
rm -f "$STATE/$SID.fired" "$PROJ/.claude/last-offboard-session"

# 6c. FAIL CLOSED (dotfiles-5vz2). If the mtime cannot be read at all, the
#     release — the permissive branch — must not be taken, and the hook must
#     SAY so. Proven against a copy of the guard with no lib/ beside it, which
#     is the only way to make _p_mtime genuinely unavailable.
rm -f "$STATE/$SID.fired"
echo "$SID" > "$PROJ/.claude/last-offboard-session"   # FRESH: case 6 would release
NOLIB="$STATE/nolib"
mkdir -p "$NOLIB"
cp "$GUARD" "$NOLIB/stop-context-guard.sh"
NL_ERR=$(printf '%s' "$PAYLOAD_BASE" | CONTEXT_GUARD_STATE_DIR="$STATE" \
  CONTEXT_GUARD_PCT=75 bash "$NOLIB/stop-context-guard.sh" 2>&1 >/dev/null)
NL_RC=$?
[ "$NL_RC" -eq 2 ] && ok || bad "unreadable mtime must NOT grant the release (got $NL_RC)"
echo "$NL_ERR" | grep -q "could not read the mtime" && ok \
  || bad "the fail-closed mtime path announces itself"
rm -f "$STATE/$SID.fired" "$PROJ/.claude/last-offboard-session"

# 7. Threshold env override: 90 → 80% no longer fires
rm -f "$STATE/$SID.fired"
guard "$PAYLOAD_BASE" 90
[ $? -eq 0 ] && ok || bad "CONTEXT_GUARD_PCT override respected"

# 8. statusline persists the official pct per session
SL_INPUT=$(printf '{"session_id":"%s","model":{"display_name":"Test"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0,"total_duration_ms":0},"context_window":{"used_percentage":42.7}}' "$SID" "$PROJ")
printf '%s' "$SL_INPUT" | CONTEXT_GUARD_STATE_DIR="$STATE" "$STATUSLINE" >/dev/null 2>&1
[ "$(cat "$STATE/$SID" 2>/dev/null)" = "42" ] && ok || bad "statusline persists integer pct (got '$(cat "$STATE/$SID" 2>/dev/null)')"

# 9. pre-compact-observe: manual trigger → would=allow, exit 0
OLOG="$STATE/observe.log"
printf '{"hook_event_name":"PreCompact","trigger":"manual","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" \
  | COMPACT_OBSERVE_LOG="$OLOG" "$OBSERVE"
[ $? -eq 0 ] && ok || bad "observe always exits 0 (manual)"
grep -q "trigger=manual.*would=allow" "$OLOG" && ok || bad "manual compact logged as allow"

# 10. pre-compact-observe: auto + not offboarded → would=block, still exit 0
printf '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" \
  | COMPACT_OBSERVE_LOG="$OLOG" "$OBSERVE"
[ $? -eq 0 ] && ok || bad "observe always exits 0 (auto)"
grep -q "trigger=auto.*would=block(offboard-first)" "$OLOG" && ok || bad "auto compact logged as would-block"

# 11. pre-compact-observe: auto + offboarded → would=allow
echo "$SID" > "$PROJ/.claude/last-offboard-session"
printf '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" \
  | COMPACT_OBSERVE_LOG="$OLOG" "$OBSERVE"
tail -1 "$OLOG" | grep -q "would=allow" && ok || bad "auto compact after offboard logged as allow"

rm -f /tmp/guard-stderr-$$

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
