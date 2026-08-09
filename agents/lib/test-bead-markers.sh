#!/bin/bash
# Test for bead-markers.sh — the fleet/outward marker grammar (dotfiles-dh89).
#
# Hermetic: the pure-grammar tests never call the real `br`. The ID-based API
# tests (marker_get/marker_set/marker_is_fleet) stub _bm_br_show_description
# and _bm_br_update_description — the file's ONLY two I/O seams — with
# in-memory fakes, so no real bead is ever read or written by this suite.
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on
# the last line.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/bead-markers.sh"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }

# --- T1: marker_key_for — known + unknown -----------------------------
[ "$(marker_key_for fleet)" = "Fleet" ] && ok || bad "T1a: marker_key_for fleet"
[ "$(marker_key_for fleet-model)" = "Fleet-Model" ] && ok || bad "T1b: marker_key_for fleet-model"
[ "$(marker_key_for outward)" = "Outward" ] && ok || bad "T1c: marker_key_for outward"
marker_key_for bogus >/dev/null 2>&1
[ $? -eq 1 ] && ok || bad "T1d: marker_key_for bogus must return 1"

# --- T2: marker_extract — 'fleet: yes' matches, value is 'yes' --------
OUT=$(marker_extract fleet "Fleet: yes")
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "yes" ] && ok || bad "T2: 'Fleet: yes' -> got rc=$RC out='$OUT'"

# --- T3: marker_extract — 'fleetish: yes' must NOT match 'fleet' ------
marker_extract fleet "fleetish: yes" >/dev/null 2>&1
[ $? -eq 1 ] && ok || bad "T3: 'fleetish: yes' must not match marker 'fleet'"

# --- T4: marker_extract — 'Fleet-Model: opus' must NOT match 'fleet' --
# (the colon-anchor property: Fleet: never matches a Fleet-Model: line)
marker_extract fleet "Fleet-Model: opus" >/dev/null 2>&1
[ $? -eq 1 ] && ok || bad "T4: 'Fleet-Model: opus' must not match marker 'fleet'"

# --- T5: marker_extract — well-formed value that isn't 'yes' is still
#         FOUND (raw extraction is honest; only the boolean layer judges) --
OUT=$(marker_extract fleet "fleet: yesterday")
RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "yesterday" ] && ok || bad "T5: 'fleet: yesterday' -> got rc=$RC out='$OUT'"

# --- T6: marker_extract — case-insensitive key, lowercase input -------
OUT=$(marker_extract fleet "fleet: yes")
[ "$OUT" = "yes" ] && ok || bad "T6: lowercase 'fleet: yes' -> got '$OUT'"

# --- T7: marker_extract — last matching line wins ----------------------
TEXT=$'## Context\nFleet: yes\nsome prose\nFleet: no'
OUT=$(marker_extract fleet "$TEXT")
[ "$OUT" = "no" ] && ok || bad "T7: last-line-wins -> got '$OUT'"

# --- T8: marker_extract — unrecognized marker returns 2 ---------------
marker_extract bogus "bogus: yes" >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "T8: unrecognized marker must return 2"

# --- T9: marker_bool_from_value — exact-match grammar ------------------
for v in yes Yes YES yEs; do
  marker_bool_from_value "$v"
  [ $? -eq 0 ] || bad "T9: '$v' should be truthy"
done
ok
for v in yesterday no "" yess "yes "; do
  marker_bool_from_value "$v"
  [ $? -eq 1 ] || bad "T9: '$v' should NOT be truthy"
done
ok

# --- T10: marker_strip — removes only the matching marker's lines -----
TEXT=$'## Context\nFleet: yes\nOutward: yes\nsome prose'
STRIPPED=$(marker_strip fleet "$TEXT")
if printf '%s' "$STRIPPED" | grep -qi '^Fleet:'; then
  bad "T10: marker_strip did not remove the Fleet: line"
else
  ok
fi
printf '%s' "$STRIPPED" | grep -qi '^Outward: yes$' && ok || bad "T10b: marker_strip must not touch Outward:"

# --- T11: marker_get / marker_set round trip via STUBBED I/O -----------
# In-memory fake bead store — no real `br` call anywhere in this block.
declare -A FAKE_DESC
FAKE_DESC[bead-1]="## Context
some prose"

_bm_br_show_description() { printf '%s' "${FAKE_DESC[$1]:-}"; }
_bm_br_update_description() { FAKE_DESC[$1]=$2; }

marker_set bead-1 fleet yes >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "T11a: marker_set fleet yes -> rc=$RC"
VAL=$(marker_get bead-1 fleet)
[ "$VAL" = "yes" ] && ok || bad "T11b: marker_get after set -> got '$VAL'"

marker_is_fleet bead-1
[ $? -eq 0 ] && ok || bad "T11c: marker_is_fleet must be true after 'fleet: yes'"

# --- T12: marker_set re-set does not duplicate the line ----------------
marker_set bead-1 fleet-model opus >/dev/null 2>&1
marker_set bead-1 fleet-model sonnet >/dev/null 2>&1
COUNT=$(printf '%s\n' "${FAKE_DESC[bead-1]}" | grep -ci '^Fleet-Model:')
[ "$COUNT" -eq 1 ] && ok || bad "T12: expected exactly 1 Fleet-Model: line, got $COUNT"
VAL=$(marker_get bead-1 fleet-model)
[ "$VAL" = "sonnet" ] && ok || bad "T12b: re-set must win -> got '$VAL'"

# --- T13: marker_is_fleet is false for a malformed / absent marker -----
FAKE_DESC[bead-2]="Fleet: yesterday"
marker_is_fleet bead-2
[ $? -eq 1 ] && ok || bad "T13a: 'Fleet: yesterday' must not be fleet-eligible"
FAKE_DESC[bead-3]="## Context
nothing fleet-related here"
marker_is_fleet bead-3
[ $? -eq 1 ] && ok || bad "T13b: absent marker must not be fleet-eligible"

# --- T14: marker_set rejects a value that fails the token grammar ------
BEFORE="${FAKE_DESC[bead-1]}"
marker_set bead-1 fleet "yes please" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 2 ] && ok || bad "T14a: space-containing value must be rejected (rc=$RC)"
[ "${FAKE_DESC[bead-1]}" = "$BEFORE" ] && ok || bad "T14b: rejected marker_set must not have written"

# --- T15: marker_set rejects an unrecognized marker name ---------------
marker_set bead-1 bogus yes >/dev/null 2>&1
[ $? -eq 2 ] && ok || bad "T15: unrecognized marker name must be rejected"

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
