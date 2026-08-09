#!/bin/bash
# Mutation harness for marshal-drain.sh's silent decisions (dotfiles-69qr).
#
#   bash agents/scheduler/mutate-marshal-drain.sh [-v]
#
# WHY THIS EXISTS. Every property this script owns fails SILENTLY, at 01:07,
# with nobody watching, and each failure LOOKS like a working night:
#
#   • THE RESERVE. Drop the `- zig_daytime_reserve` term and the budget is
#     simply bigger. Nothing errors; the drain lands more beads; Zig's Tuesday
#     hits the weekly cap at noon and the ledger says every night went fine.
#   • THE TAP FILTER. Loosen the epoch-1 classification and the WORK tap's
#     spend counts as Zig's personal spend — a number that is wrong in both
#     directions at once (spent inflated, reserve inflated) and never absent.
#   • THE MARKER. Disarm the `Fleet: yes` check and the drain claims the whole
#     ready pool: specs, half-written investigations, beads with taste calls in
#     them. Scrutiny catches DEFECTIVE code; it does not catch code that
#     confidently implements the wrong goal (69qr's R1c rationale — the exact
#     failure mode opt-in exists to prevent).
#   • THE TYPE LIST. Admit a `Fleet: yes` decision bead and the marshal starts
#     AUTHORING. R10's whole point is that the marker does not outrank the type.
#   • THE FREEZE. Ignore it and the drain dispatches into a cutover window.
#   • THE DEGRADE. Return anything but the floor when the budget cannot be
#     computed and "I could not measure" becomes "spend freely".
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites; only
# a mutant that dies is. test-marshal-drain.sh is green by construction — it was
# written alongside the script. This file is the evidence its cases are
# load-bearing, and tools/githooks/pre-commit is its consumer.
#
# Modelled on mutate-demesne-sync.sh / mutate-tunnel-ownership.sh, INCLUDING
# their two hard-won properties:
#   1. ASSERT THE MUTATION APPLIED. Target present exactly once, replacement
#      absent before / present after, bytes changed, `bash -n` still clean.
#      A failure here is a HARNESS ERROR, never a killed mutant — an
#      over-escaped pattern that matches nothing produces a red suite too, and
#      by exit code alone the two are indistinguishable (dotfiles-47nf).
#   2. A KILLED MUTANT MUST DIE ON THE CASES IT NAMES (dotfiles-77s4).
#
# ONE DELIBERATE DIVERGENCE from mutate-demesne-sync.sh: `mutate` reads the
# CURRENT working copy rather than the pristine one, so a mutant may CHAIN two
# edits (M3 needs both halves of the type policy moved, or the bead is refused
# by the other half and the mutant proves nothing). The exactly-once assertion
# still runs against the file being edited, so nothing is weakened.
#
# Fixed strings, never regexes. SAFE TO RUN ANY TIME: the suite is hermetic
# under $TMPDIR and the mutant copy lives outside any real tree.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
LIB_DIR="$(cd "$SRC_DIR/../lib" && pwd)"        # agents/lib
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-marshal-drain.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

CHK="marshal-drain.sh"
SUITE="test-marshal-drain.sh"
CONF="marshal.conf"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/lib" "$WORK/pristine"
for f in "$CHK" "$SUITE" "$CONF"; do
  [ -f "$SRC_DIR/$f" ] || { echo "HARNESS ERROR: $SRC_DIR/$f does not exist" >&2; exit 2; }
  cp -a "$SRC_DIR/$f" "$WORK/pristine/$f"
done
# The libraries the subject imports by relative path. They are copied, never
# mutated: this harness is about the drain's own decisions.
for f in bead-markers.sh molt-thresholds.sh; do
  [ -f "$LIB_DIR/$f" ] || { echo "HARNESS ERROR: $LIB_DIR/$f does not exist" >&2; exit 2; }
  cp -a "$LIB_DIR/$f" "$WORK/lib/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$CHK"   "$WORK/scheduler/$CHK"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
  cp -a "$WORK/pristine/$CONF"  "$WORK/scheduler/$CONF"
}

run_suite() {
  SUITE_OUT=$(MD_SCRIPT="$WORK/scheduler/$CHK" bash "$WORK/scheduler/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to>
mutate() {
  local file=$1 from=$2 to=$3
  local path="$WORK/scheduler/$file"

  python3 - "$path" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1:4]
before = open(path).read()
n = before.count(frm)
if n != 1:
    sys.stderr.write(f"  target text occurs {n}x (want exactly 1) in {path}\n")
    sys.stderr.write("  the line this mutant aims at has MOVED or CHANGED; "
                     "re-derive the mutant from the current source.\n")
    sys.exit(1)
if to in before:
    sys.stderr.write("  replacement text is ALREADY present — this mutation "
                     "would be a no-op.\n")
    sys.exit(1)
after = before.replace(frm, to)
open(path, "w").write(after)
if after.count(to) != 1:
    sys.stderr.write("  replacement is not present exactly once after the write\n")
    sys.exit(1)
PY
  # shellcheck disable=SC2181  # the heredoc'd python is the command; $? is it
  [ $? -eq 0 ] || { harness_error "$file: mutation did not apply"; return 1; }

  if cmp -s "$WORK/pristine/$file" "$path"; then
    harness_error "$file: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$file: the mutant is not valid bash — it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

# check <mutant-name> <must-FAIL case ids> [<must-PASS case ids>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  ($SUITE is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | awk '{ print $2 }' | tr '\n' ' ')
  for c in $want_fail; do
    case " $got " in *" $c "*) ;; *) missing="$missing $c" ;; esac
  done
  for c in $want_pass; do
    case " $got " in *" $c "*) wrongly="$wrongly $c" ;; esac
  done

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name"
    echo "           the suite went red but NOT on the case(s) this mutant names:$missing"
    echo "           actually failing: ${got:-<none>}"
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name"
    echo "           case(s) that had to keep PASSING went red:$wrongly"
    echo "           actually failing: ${got:-<none>}"
    FAILED=1
  else
    echo "killed    $name"
    echo "          failing cases: $got"
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/          | /'
  return 0
}

echo "=== baseline: the unmutated copy must be GREEN ============================"
fresh_copy
if run_suite; then
  echo "  ok      $SUITE: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
else
  echo "  BROKEN  $SUITE is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — THE RESERVE IS NOT SUBTRACTED. The single most attractive simplification
# in the whole file ("share is already the nightly number") and the one that
# spends Zig's own week: the drain takes the full nightly share and his daytime
# interactive work has nothing left. Nothing errors, and the ledger's
# spent-vs-budget column stays inside budget every single night.
fresh_copy
# (the replacement multiplies the term out rather than deleting it: a
# deletion would be a SUBSTRING of the original and the no-op guard would
# rightly refuse it.)
mutate "$CHK" 'raw = share - reserve' 'raw = share - reserve * 0'
check "M1 budget-ignores-reserve (the night eats Zig's day)" \
      "T3.5 T3b.3 T3b.4 T3b.5" "T3.1 T3.3 T3.4 T3b.1 T3b.2 T15.1"

# M2 — THE MARKER CHECK IS DISARMED. R1c's opt-in becomes opt-out: the drain
# claims the whole ready pool, which is dominated by specs, investigations and
# beads with taste calls in them. The failure is SILENT by construction —
# scrutiny gates defective code, not plausible code built to the wrong goal.
fresh_copy
mutate "$CHK" '  (cd "$repo" && marker_is_fleet "$id") && marked=0' '  marked=0'
check "M2 marker-check-disarmed (opt-in becomes opt-out)" \
      "T1.1 T1.2 T1b" "T2.1 T14.1 T3.5 T15.1"

# M3 — A DECISION BEAD BECOMES DRAINABLE. Two chained edits, because either
# half alone leaves the bead refused by the other and the mutant would prove
# nothing: the refusal list loses `decision` AND the eligible list gains it.
# This is R10 inverted — the marshal starts authoring, at 3am, unattended.
fresh_copy
mutate "$CHK" 'FLEET_REFUSED_TYPES="decision spec epic"' 'FLEET_REFUSED_TYPES="spec epic"'
mutate "$CHK" 'FLEET_ELIGIBLE_TYPES="task bug feature"' 'FLEET_ELIGIBLE_TYPES="task bug feature decision"'
check "M3 decision-type-admitted (the marker outranks the type)" \
      "T14.1 T14.2" "T1.1 T16.1 T15.1"

# M4 — THE FREEZE IS IGNORED. demesne-freeze exists because a timer firing
# mid-cutover hits half-retargeted paths; a drain that dispatches through one
# is the worst possible tick to have running. The comparison still runs, still
# costs a subshell, and always answers "not frozen".
fresh_copy
mutate "$CHK" 'if [ "$(freeze_state)" = "active" ]; then' 'if [ "$(freeze_state)" = "never-frozen" ]; then'
check "M4 freeze-ignored (the drain dispatches into a cutover)" \
      "T11.1 T11.2 T11b" "T1.1 T3.5"

# M5 — THE DEGRADE STOPS BEING CONSERVATIVE. "I could not measure the budget"
# turns into "spend freely", which is the precise shape 69qr's budget section
# forbids: never a silent huge number. Note the JSON keeps saying the floor —
# so only the VERDICT diverges, which is exactly the sort of half-truth a
# reviewer reading the brief would never catch.
fresh_copy
mutate "$CHK" '  BUDGET_TOKENS=$floor' '  BUDGET_TOKENS=999999999'
check "M5 degraded-budget-is-huge (unmeasurable becomes unlimited)" \
      "T15.1 T15b.1 T3e.2" "T15.2 T3.5"

# M6 — THE TAP FILTER LOOSENS. Drop the epoch-1 `work:` exclusion and the
# WORK tap's spend is counted as Zig's personal spend. Both halves of the
# budget move at once and neither is absent: the window looks more spent than
# it is AND the daytime reserve looks bigger than it is. Every number stays
# plausible; the classification is simply wrong, which is the whole reason
# ~/.agents/infra.md says to classify rows by VALUE.
fresh_copy
mutate "$CHK" "NOT LIKE 'work:%'" "NOT LIKE 'zzz-no-such-tap:%'"
check "M6 tap-filter-loosened (the work tap's spend becomes Zig's)" \
      "T3.1 T3.3 T3.4 T3.5" "T15.1 T1.1"

# M7 — THE TICK FOLD IS DROPPED (dotfiles-iez1). `tick` is a jail PROFILE of
# `personal`, not a tap — ~/.claude and ~/.claude-tick carry the identical
# account fingerprint. Reverting the personal predicate's `IN ('personal','tick')`
# back to `= 'personal'` alone silently UNDERCOUNTS personal's weekly window
# exactly when budget-truth matters: the dive/digest jail's spend vanishes from
# both the window total and the daytime reserve, and every number still looks
# plausible. T3.1's OWN db has no `tick` rows, so it and M6's cases must keep
# passing untouched — only T3e (the isolated tick-fixture db) can see this one.
fresh_copy
mutate "$CHK" \
  "IN ('personal','tick') OR (COALESCE(agentgateway_group,'') NOT IN ('personal','work','tick') AND COALESCE(agentgateway_user,'') NOT LIKE 'work:%'))\"" \
  "= 'personal' OR (COALESCE(agentgateway_group,'') NOT IN ('personal','work','tick') AND COALESCE(agentgateway_user,'') NOT LIKE 'work:%'))\""
check "M7 tick-fold-dropped (tick jail spend vanishes from personal's budget)" \
      "T3e.1" "T3.1 T3.3 T3.4 T3.5 T3e.2 T15.1 T1.1"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The budget, the marker gate, the type list, the freeze or the"
  echo "    degrade path in $CHK is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
