#!/bin/bash
# test-molt-thresholds.sh — THE BINDING TEST (dotfiles-9060).
#
# The two-tier molt threshold is deliberate: it06's stop-context-guard fires at
# 75% (the BACKSTOP), 69qr R5 paces the marshal at 50% (PROACTIVE). Two numbers,
# two files, one intent — and until this file existed, nothing tied them
# together. Move one and the other silently means something else: a marshal
# molting twice as often as intended, or never molting proactively at all.
# Neither shows up in any suite, any lint, or any ledger.
#
# So this suite fails if EITHER number moves without the other. It reads the
# LIBRARY, then reads BOTH CONSUMERS off disk, then drives one of them for real
# — because a constant that everyone imports and nobody obeys is the same
# defect with an extra file.
#
# Usage: bash agents/lib/test-molt-thresholds.sh   (exit 0 = pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)                 # agents/lib
LIB="$HERE/molt-thresholds.sh"
GUARD="$HERE/../hooks/stop-context-guard.sh"
DRAIN="$HERE/../scheduler/marshal-drain.sh"

PASS=0; FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s -- %s\n' "$1" "${2:-}"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/molt-bind.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- MB1 the library itself ------------------------------------------------
[ -r "$LIB" ] || { echo "molt-thresholds.sh is missing — the binding has no subject"; exit 1; }
# shellcheck source=molt-thresholds.sh
. "$LIB"

eq "MB1 the ratified BACKSTOP (it06, stop-context-guard)"  "$MOLT_BACKSTOP_PCT" "75"
eq "MB1 the headroom an offboard+molt needs"               "$MOLT_HEADROOM_PCT" "25"
eq "MB1 the ratified PACING (69qr R5, the marshal)"        "$MOLT_PACING_PCT"   "50"

if molt_thresholds_sane; then ok "MB1 the derived pair is sane"; else bad "MB1 the derived pair is sane" "refused"; fi

# --- MB2 the pacing is DERIVED, not a second literal -----------------------
# If someone re-hardcodes the 50, this is the case that notices: overriding the
# backstop must move the pacing with it.
OUT=$(MOLT_BACKSTOP_PCT=80 bash -c '. "$1"; echo "$MOLT_PACING_PCT"' _ "$LIB")
eq "MB2 raising the backstop raises the pacing (derived, not literal)" "$OUT" "55"
OUT=$(MOLT_BACKSTOP_PCT=40 MOLT_HEADROOM_PCT=45 bash -c '. "$1"; molt_thresholds_sane && echo sane || echo refused' _ "$LIB")
eq "MB2 a headroom bigger than the backstop is REFUSED, not negative" "$OUT" "refused"

# --- MB3 consumer 1: the guard sources it ---------------------------------
if grep -q 'molt-thresholds.sh' "$GUARD"; then
  ok "MB3 stop-context-guard.sh sources the shared constant"
else
  bad "MB3 stop-context-guard.sh sources the shared constant" \
      "the backstop is back to being this file's private literal"
fi
GUARD_LITERAL=$(grep -oE 'MOLT_BACKSTOP_PCT:-[0-9]+' "$GUARD" | grep -oE '[0-9]+$' | head -n1)
eq "MB3 the guard's literal fallback equals the shared backstop" "$GUARD_LITERAL" "$MOLT_BACKSTOP_PCT"

# --- MB4 consumer 1, FOR REAL: the guard fires at the shared number --------
# Reading the file proves the constant is spelled right; running it proves the
# constant is obeyed. Both, because either alone has been wrong before.
STATE="$T/pct"; PROJ="$T/proj"
mkdir -p "$STATE" "$PROJ"
SID="molt-bind-session"
PAYLOAD=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ")

fire_at() { # fire_at <pct> [env assignments...] -> prints the exit code
  local pct=$1; shift
  rm -f "$STATE/$SID.fired"
  printf '%s' "$pct" > "$STATE/$SID"
  printf '%s' "$PAYLOAD" | env "$@" CONTEXT_GUARD_STATE_DIR="$STATE" bash "$GUARD" >/dev/null 2>&1
  printf '%s' "$?"
}

eq "MB4 one below the backstop is a no-op"  "$(fire_at $(( MOLT_BACKSTOP_PCT - 1 )) FOO=bar)" "0"
eq "MB4 AT the backstop the guard fires"    "$(fire_at "$MOLT_BACKSTOP_PCT" FOO=bar)"         "2"
# and at the PACING number it must stay quiet — the marshal molts there by
# choice; if the backstop ever slid down to the pacing number, the two tiers
# would have collapsed into one and this is where that shows up.
eq "MB4 at the PACING threshold the backstop stays quiet" "$(fire_at "$MOLT_PACING_PCT" FOO=bar)" "0"
# the sourcing is LIVE, not decorative: moving the shared constant moves the
# guard's behaviour.
eq "MB4 overriding the shared backstop moves the guard's firing point" \
   "$(fire_at 60 MOLT_BACKSTOP_PCT=60)" "2"

# --- MB5 consumer 2: the drain publishes the derived pacing ---------------
if grep -q 'molt-thresholds.sh' "$DRAIN"; then
  ok "MB5 marshal-drain.sh sources the shared constant"
else
  bad "MB5 marshal-drain.sh sources the shared constant" "the pacing is a private literal again"
fi

# End to end: a real `plan` run (hermetic — an opt-in repo with no bead db, so
# the queue is empty and nothing is dispatched) must publish the SAME pacing
# number the library derives.
mkdir -p "$T/repo/.beads" "$T/state"
cat > "$T/conf" <<CONF
repos=nothing:$T/repo
home_repo=nothing
tz_offset_hours=-7
week_reset_dow=3
week_reset_hour=0
tap=personal
budget_floor_tokens=1000
safety_margin_pct=20
default_model=sonnet
CONF
PLAN=$(MARSHAL_CONF="$T/conf" HARNESS_STATE_DIR="$T/state" \
       MARSHAL_FREEZE_SCRIPT="$T/no-such-freeze" MARSHAL_BV_BIN="$T/no-such-bv" \
       MARSHAL_POST_LIB="$T/no-such-post" MARSHAL_NOW="2026-08-09T06:00:00Z" \
       bash "$DRAIN" plan --budget 1000 2>/dev/null | sed '$d')
PLAN_PACING=$(printf '%s' "$PLAN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["molt_pacing_pct"])' 2>&1)
PLAN_BACKSTOP=$(printf '%s' "$PLAN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["molt_backstop_pct"])' 2>&1)
eq "MB5 the plan publishes the DERIVED pacing, not its own number" "$PLAN_PACING"   "$MOLT_PACING_PCT"
eq "MB5 the plan publishes the backstop it was derived from"       "$PLAN_BACKSTOP" "$MOLT_BACKSTOP_PCT"

# --- MB6 the pair keeps its relationship ---------------------------------
# The whole point of the two tiers: the proactive number must sit far enough
# below the backstop that a seat which paces itself never reaches it. If a
# future edit narrows that gap, the tiers have collapsed and the marshal is
# molting mid-arc, which is what it06's header argues against.
if [ "$MOLT_PACING_PCT" -lt "$MOLT_BACKSTOP_PCT" ]; then
  ok "MB6 pacing sits below the backstop"
else
  bad "MB6 pacing sits below the backstop" "$MOLT_PACING_PCT >= $MOLT_BACKSTOP_PCT"
fi
GAP=$(( MOLT_BACKSTOP_PCT - MOLT_PACING_PCT ))
if [ "$GAP" -ge 20 ]; then
  ok "MB6 the gap leaves room for a real /offboard (>=20 points)"
else
  bad "MB6 the gap leaves room for a real /offboard (>=20 points)" "gap=$GAP"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
