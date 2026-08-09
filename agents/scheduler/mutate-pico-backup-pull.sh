#!/bin/bash
# Mutation harness for pico-backup-pull.sh's TWO POST-PULL GUARDS.
#
#   bash agents/scheduler/mutate-pico-backup-pull.sh [-v]
#
# WHY THIS EXISTS. This script's whole job is to be believed when it says the
# backup happened. rsync exits 0 for a long list of empty outcomes, and a
# backup that reports success while holding nothing is indistinguishable from a
# working one until the day you need it — which is the same silence that let
# pico's nightly jobs fail for two months (vs14d-jms) and the same silence the
# works audit found in its backup posture. Two guards stand between "it ran" and
# "it's right":
#
#   guard 1  the pulled file COUNT and BYTE TOTAL must equal what pico reported,
#            and the count must be >= 1
#   guard 2  up to two sampled files per dataset are SHA256-compared end to end
#
# Neither guard turns a timer red when it is removed. The suite stays green on a
# healthy fixture either way — so per this repo's rule 1, a green
# test-pico-backup-pull.sh is not evidence that these guards bite. Only a mutant
# that dies is, and this file is that evidence. tools/githooks/pre-commit is its
# caller.
#
# ---------------------------------------------------------------------------
# THE PROPERTY THAT MAKES THIS HARNESS HONEST: assert the mutation APPLIED.
# ---------------------------------------------------------------------------
# Modelled on mutate-tunnel-ownership.sh, whose header records why: an
# over-escaped pattern once matched nothing, the suite went red for an unrelated
# reason, and by exit code alone that is indistinguishable from a proper kill. So
# every mutation here is checked five ways before its suite result is allowed to
# mean anything — target text present exactly once, replacement absent, bytes
# changed, replacement present exactly once afterwards, `bash -n` still clean —
# and any failure of those is a HARNESS ERROR, never a killed mutant.
#
# And a killed mutant must die on the cases it NAMES. The suite header carries a
# measured mutant -> case map; this harness ASSERTS it.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of pico-backup-pull.sh. `$lfiles`, `$rbytes` and friends inside
# them must NOT expand — they are matched byte-for-byte against the file on disk.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-pbp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PBP="pico-backup-pull.sh"
SUITE="test-pico-backup-pull.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$PBP" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

# The suite finds the script via `dirname $0`, so a self-contained copy in $WORK
# is enough and the real tree is never edited.
fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$PBP" "$WORK/scheduler/$PBP"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to> — fixed strings, never regexes:
# over-escaping a pattern is the exact failure this harness makes impossible.
mutate() {
  local file=$1 from=$2 to=$3
  local path="$WORK/scheduler/$file" pristine="$WORK/pristine/$file"

  python3 - "$pristine" "$path" "$from" "$to" <<'PY'
import sys
pristine, path, frm, to = sys.argv[1:5]
before = open(pristine).read()
n = before.count(frm)
if n != 1:
    sys.stderr.write(f"  target text occurs {n}x (want exactly 1) in {path}\n")
    sys.stderr.write("  the line this mutant aims at has MOVED or CHANGED; "
                     "re-derive the mutant from the current source.\n")
    sys.exit(1)
if to in before:
    sys.stderr.write("  replacement text is ALREADY present in the pristine "
                     "file — this mutation would be a no-op.\n")
    sys.exit(1)
after = before.replace(frm, to)
open(path, "w").write(after)
if after.count(to) != 1:
    sys.stderr.write("  replacement is not present exactly once after the write\n")
    sys.exit(1)
PY
  # shellcheck disable=SC2181  # the heredoc'd python is the command; $? is it
  [ $? -eq 0 ] || { harness_error "$file: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$file: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$file: the mutant is not valid bash — it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

# check <mutant-name> <must-FAIL cases> [<must-PASS cases>]
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

# M1 — GUARD 1 DISARMED. The count/byte comparison is turned into a condition
# that can never be true, which is exactly what "we already know rsync exited 0"
# looks like when someone decides the check is redundant. Case 19 is its sole
# HONEST detector: there, every sampled file is intact and correct, and the only
# evidence that a file was lost in transit is the count. Case 8 dies too, but for
# the softer reason that an empty destination then reports the wrong finding.
fresh_copy
mutate "$PBP" \
  'if [ "${lfiles:-0}" -lt 1 ] || [ "$lfiles" != "$rfiles" ] || [ "$lbytes" != "$rbytes" ]; then' \
  'if false; then'
check "M1 guard1-count-and-bytes-disarmed" "8 19"

# M2 — GUARD 2 DISARMED: the sha256 values are still computed, still logged in
# spirit, and simply never compared. Case 9's corruption is LENGTH-PRESERVING, so
# guard 1 is blind to it by construction and case 9 is the sole detector. Case 19
# must keep PASSING — that is the assertion that this mutant isolates guard 2
# rather than collapsing the script into a different failure.
fresh_copy
mutate "$PBP" \
  '    if [ "$got" != "$ssum" ]; then' \
  '    if false; then'
check "M2 guard2-sha256-compare-disarmed" "9" "19"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The post-pull guards in $PBP do not bite the way the suite claims —"
  echo "    which means a backup that holds nothing can report ok."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
