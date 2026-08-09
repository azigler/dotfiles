#!/bin/bash
# Mutation harness for demesne-sync.sh's two silent decisions.
#
#   bash agents/scheduler/mutate-demesne-sync.sh [-v]
#
# WHY THIS EXISTS. Both of this script's load-bearing properties fail SILENTLY,
# in opposite directions, and neither turns anything red:
#
#   • THE EXCLUSION SET. Honour it in the sync but not in the gate and the gate
#     can never read empty, so the cutover's identity precondition is unpassable
#     — the exact state dotfiles-lg1z was filed for (96 entries, most of them
#     bytecode). Honour it in neither and the gate goes red for reasons nobody
#     will read past. There is no error either way; there is just a number.
#   • THE --delete SCOPE. Collapse the per-directory loop into one whole-tree
#     rsync and the command still exits 0, still prints OK, still passes the
#     gate — having deleted demesne's own docs/, audits/, CLAUDE.md and
#     host-service dirs, which exist in exactly one place. The first run is the
#     one that does it, and the report says success.
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites; only
# a mutant that dies is. test-demesne-sync.sh is green by construction — it was
# written alongside the script. This file is the evidence that its cases are
# load-bearing, and tools/githooks/pre-commit is its consumer.
#
# Modelled on mutate-pico-health.sh / mutate-tunnel-ownership.sh, INCLUDING
# their two hard-won properties:
#
#   1. ASSERT THE MUTATION APPLIED. Target present exactly once, replacement
#      absent before and present exactly once after, bytes changed, `bash -n`
#      still clean. Any failure is a HARNESS ERROR, never a killed mutant: an
#      over-escaped pattern that matches nothing produces a red suite too, and
#      by exit code alone the two are indistinguishable (dotfiles-47nf).
#   2. A KILLED MUTANT MUST DIE ON THE CASES IT NAMES. Red-somewhere says
#      nothing about the guard under test (dotfiles-77s4).
#
# Fixed strings, never regexes.
#
# SAFE TO RUN ANY TIME. The suite is hermetic under $TMPDIR except for its two
# read-only rule-2 cases, and those two SKIP here: the mutant copy lives outside
# any git work tree, which is exactly the condition case 22 skips on. No mutant
# ever runs against ~/dotfiles or ~/demesne.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC_DIR="$(cd "$(dirname "$0")" && pwd)" # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-demesne-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

CHK="demesne-sync.sh"
SUITE="test-demesne-sync.sh"
EXCL="demesne-sync.exclude"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$CHK" "$SUITE" "$EXCL"; do
  [ -f "$SRC_DIR/$f" ] || {
    echo "HARNESS ERROR: $SRC_DIR/$f does not exist" >&2
    exit 2
  }
  cp -a "$SRC_DIR/$f" "$WORK/pristine/$f"
done

# The suite finds both the script and the exclusion list via `dirname $0`, so
# the copy is self-contained and the real tree is never edited.
fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$CHK"   "$WORK/scheduler/$CHK"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
  cp -a "$WORK/pristine/$EXCL"  "$WORK/scheduler/$EXCL"
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

# mutate <file> <literal-from> <literal-to>
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
  [ $? -eq 0 ] || {
    harness_error "$file: mutation did not apply"
    return 1
  }

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

# M1 — THE EXCLUSION LIST IS IGNORED. Every pattern read from the committed file
# is replaced by one that matches nothing, so the list is still non-empty (the
# empty-list guard cannot mask this) and still loads cleanly — it just has no
# effect on either half. This is lg1z's founding condition restored: a gate that
# sees every __pycache__ and every node_modules and can therefore never read
# empty, plus a sync whose --delete now reaches the receiver's own build output.
# Cases 3, 6 and 7 must keep PASSING: real drift, the preservation boundary and
# the deletion scope are all independent of the exclusion set, and a mutant that
# broke them would be breaking the script rather than the guard under test.
fresh_copy
mutate "$CHK" \
  '    EXCLUDES+=("$line")' \
  '    EXCLUDES+=("__demesne_never_matches__")'
# Measured 2026-08-09: 5 8 16 17. Case 5 is the load-bearing one (the gate goes
# blind-free and therefore unpassable); 8 is the receiver's own build output
# being deleted; 16 and 17 are the blindness check, which reads the same list.
check "M1 exclusion-list-ignored (bytecode makes the gate unpassable again)" "5 8 16 17" "3 6 7"

# M2 — --delete WIDENED TO THE WHOLE TREE. The per-directory loop's endpoints
# replaced by the roots, which is the obvious simplification and the destructive
# one: demesne's docs/, audits/, CLAUDE.md and host-service dirs exist in one
# place only, and the shorter command deletes all of them on its first run while
# printing OK. Case 7 must keep PASSING — deletion INSIDE a synced dir is
# correct and required for identity — which is what shows case 6 detects the
# scope specifically rather than "--delete ran at all".
fresh_copy
mutate "$CHK" \
  '    out=$(rsync "${rs_args[@]}" "$SRC/$d/" "$DEST/$d/")' \
  '    out=$(rsync "${rs_args[@]}" "$SRC/" "$DEST/")'
# Measured 2026-08-09: 6 21. Case 6 is the load-bearing one; 21 falls out
# because a whole-tree rsync no longer names the directory it failed on.
check "M2 delete-outside-subtree (the sync eats demesne's own docs/ and audits/)" "6 21" "7 11"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The exclusion set or the --delete scope in $CHK is not guarded the"
  echo "    way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
