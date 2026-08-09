#!/usr/bin/env bash
# mutate-hall-tap.sh — do the TAP COLUMN's guards actually BITE?
# (dotfiles-oq4n; modelled on agents/scheduler/mutate-tunnel-ownership.sh, which
# is the house pattern for this and whose two clauses are restated below.)
#
# A green suite is not evidence that a guard bites — only a mutant that dies is
# (dotfiles-8aj5/jm1c). This file breaks ONE rule of agents/bin/hall's tap cell
# at a time and requires test-hall.sh to go red **on the case that names that
# rule**, not merely somewhere.
#
# TWO CLAUSES, both paid for in the dotfiles-ogkz arc and both mechanical here:
#
#   1. ASSERT THE MUTATION APPLIED. An over-escaped sed pattern that matches
#      NOTHING leaves the suite red for its own reasons and is indistinguishable
#      from a kill by exit code alone (dotfiles-47nf). Every mutant below is
#      checked for a real change to the file before its suite result is allowed
#      to mean anything; a no-op patch is a HARNESS ERROR, not a kill.
#   2. A KILLED MUTANT MUST FAIL THE CASE IT NAMES. Red-somewhere says nothing
#      about the guard under test and is usually evidence the mutant broke the
#      script globally (dotfiles-77s4). Each mutant declares the test-case tag
#      it expects in the FAILED list, and a mutant that goes red without it is
#      reported as SURVIVED-ish (WRONG-CASE), not as a kill.
#
# Usage: bash agents/bin/mutate-hall-tap.sh
# Exit:  0 every mutant died on its own case · 1 otherwise.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HALL="$HERE/hall"
SUITE="$HERE/test-hall.sh"
WORK=$(mktemp -d)
RESCUE="${TMPDIR:-/tmp}/hall.pristine.$$"
trap 'rm -rf "$WORK"' EXIT

# ⚠️ THIS HARNESS EDITS agents/bin/hall IN PLACE and puts it back. That is the
# only way to mutate the real file the suite runs, and it means a WRITE FROM
# ANYWHERE ELSE during the ~6 minutes this takes is silently reverted by the
# restore. Paid for while writing this file: two comment edits made to hall
# during a background run vanished, with no error and no diff to explain it —
# the harness "succeeded" and took the other writer's work, which is exactly
# the shape AGENTS.md's stash rule is about.
#
# So every write checks that the file on disk is still what this harness last
# put there, and REFUSES rather than clobbering. The refusal leaves the tree in
# whatever state the other writer wanted; recovering the mutation is trivial,
# recovering their edit is not.
DIED=0; SURVIVED=0; WRONG=0; HARNESS=0

ORIG="$WORK/hall.orig"
cp "$HALL" "$ORIG"
EXPECT=$(sha256sum < "$HALL")     # what this harness believes is on disk

restore() {
  if [ "$(sha256sum < "$HALL")" != "$EXPECT" ]; then
    cp "$ORIG" "$RESCUE"
    echo "REFUSING to write $HALL: it changed underneath this harness." >&2
    echo "  Another writer edited it mid-run; overwriting would take their work." >&2
    echo "  The pristine copy is at $RESCUE — reconcile by hand, then delete it." >&2
    HARNESS=1
    return 1
  fi
  cp "$ORIG" "$HALL"
  EXPECT=$(sha256sum < "$HALL")
}
trap 'restore || true; rm -rf "$WORK"' EXIT

# mutate <name> <expected failing case tag> <python patch: OLD then NEW>
mutate() {
  local name=$1 tag=$2 old=$3 new=$4 out rc
  restore || return
  python3 - "$HALL" "$old" "$new" <<'PY' || { echo "HARNESS-ERROR $name: patch did not apply"; HARNESS=1; return; }
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
old, new = sys.argv[2], sys.argv[3]
n = t.count(old)
if n != 1:
    print(f"  patch anchor matched {n} times, wanted exactly 1", file=sys.stderr)
    sys.exit(1)
p.write_text(t.replace(old, new))
PY
  # Clause 1: the file must actually differ now.
  if cmp -s "$ORIG" "$HALL"; then
    echo "HARNESS-ERROR $name: the file is unchanged after a 'successful' patch"
    HARNESS=1; return
  fi
  EXPECT=$(sha256sum < "$HALL")     # the mutant is now what we expect on disk
  out=$(bash "$SUITE" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "SURVIVED  $name — the suite stayed GREEN with this rule broken"
    SURVIVED=$((SURVIVED + 1)); return
  fi
  # Clause 2: red is not enough; it must be red on the case this mutant names.
  if printf '%s\n' "$out" | grep -q -- "- $tag"; then
    echo "died     $name (killed by: $tag)"
    DIED=$((DIED + 1))
  else
    echo "WRONG-CASE $name — red, but NOT on $tag. Failures were:"
    printf '%s\n' "$out" | sed -n '/^  - /p' | head -8
    WRONG=$((WRONG + 1))
  fi
}

# --- M1: the byte-vs-cell arithmetic ---------------------------------------
# hall_fieldw stops carrying the arrow's excess bytes, so a PADDED arrow cell
# is 2 bytes short of its column and the charter after it drifts left.
mutate "M1 hall_fieldw ignores the arrow's bytes" "TAPCOLMATH" \
  'printf '"'"'%s'"'"' "$(( n + ${#s} - chars ))"' \
  'printf '"'"'%s'"'"' "$n"'

# --- M2: the epoch-3 map ---------------------------------------------------
# The epoch-2 alias lookup (pool.<p>.groups) is dropped, so `personal` and
# `work` fall through to the roster value — the original defect.
mutate "M2 epoch-2 aliases no longer resolve" "TAPEPOCH" \
  '    for t in ${groups//,/ }; do
      [ "$t" = "$want" ] && { printf '"'"'%s\t%s'"'"' "${groups%%,*}" "$pool"; return 0; }
    done' \
  '    :'

# --- M3: an override that AGREES is not news -------------------------------
# The equality guard goes, so a seat whose seat_home names its OWN pool renders
# `primary→primary`.
mutate "M3 the override renders even when it agrees" "TAPAGREE" \
  'if [ -n "$home" ] && [ "$home" != "$pool" ]; then' \
  'if [ -n "$home" ]; then'

# --- M4: the squeeze keeps the OVERRIDE ------------------------------------
# hall_trunc_tap degrades to a plain right-truncation, so at the medium floor
# the cell reads `primary→seco.` and the override is what is lost.
mutate "M4 the tap cell truncates from the right" "BPMEDIUM60" \
  '    *"$TAP_ARROW"*)
      left=${s%%"$TAP_ARROW"*}; right=${s#*"$TAP_ARROW"}' \
  '    *"$TAP_ARROW"XX*)
      left=${s%%"$TAP_ARROW"*}; right=${s#*"$TAP_ARROW"}'

# --- M5: no conf, no change ------------------------------------------------
# The graceful fallback becomes a dash, which is the meaning reserved for an
# UNREGISTERED window.
mutate "M5 a missing conf renders a dash" "TAPNOCONF" \
  '  [ -n "$e" ] || { printf '"'"'%s'"'"' "$t"; return 0; }' \
  '  [ -n "$e" ] || { printf '"'"'%s'"'"' "-"; return 0; }'

restore || true
echo "----"
echo "mutants: $DIED died · $SURVIVED survived · $WRONG wrong-case · harness-errors: $HARNESS"
[ "$SURVIVED" -eq 0 ] && [ "$WRONG" -eq 0 ] && [ "$HARNESS" -eq 0 ] && exit 0
exit 1
