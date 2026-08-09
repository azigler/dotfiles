#!/bin/bash
# Mutation harness for orphan-reaper.sh's two load-bearing guarantees.
#
#   bash agents/bin/mutate-orphan-reaper.sh [-v]
#
# WHY THIS EXISTS (dotfiles-415c). This script decides WHICH PROCESSES TO
# KILL, unattended, on a timer. Its whole reason to exist is the safety
# property in its own header: the sweep must NEVER match a LIVE (non-deleted)
# worktree cwd. A green test-orphan-reaper.sh is not evidence that property
# holds -- per this repo's rule 1, only a mutant that dies is. This file is
# that evidence, and tools/githooks/pre-commit is its consumer.
#
# Same five-assertions-before-trusting-a-result discipline as
# agents/scheduler/mutate-tunnel-ownership.sh: assert the mutation text exists
# exactly once in the pristine file, assert the replacement is not already
# present (not a no-op), assert the bytes actually changed, assert the
# replacement landed exactly once, assert `bash -n` is still clean (a mutant
# must die of the bug it NAMES, not of a syntax error that fails every case).
# And a killed mutant must fail the case(s) it names -- red-somewhere proves
# nothing about the guard under test.

# shellcheck disable=SC2016
# ^ every mutation argument below is LITERAL SOURCE TEXT copied out of
# orphan-reaper.sh. Variable references inside them must NOT expand.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/bin
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-orphan-reaper.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SCRIPT_NAME="orphan-reaper.sh"
SUITE_NAME="test-orphan-reaper.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/bin" "$WORK/pristine"
for f in "$SCRIPT_NAME" "$SUITE_NAME"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$SCRIPT_NAME" "$WORK/bin/$SCRIPT_NAME"
  cp -a "$WORK/pristine/$SUITE_NAME" "$WORK/bin/$SUITE_NAME"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/bin/$SUITE_NAME" 2>&1)
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
  local path="$WORK/bin/$file" pristine="$WORK/pristine/$file"

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
                     "file -- this mutation would be a no-op.\n")
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
    harness_error "$file: the mutant is not valid bash -- it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

# check <mutant-name> <must-FAIL cases> [<must-PASS cases>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply -- see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  ($SUITE_NAME is still green)"
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
  echo "  ok      $SUITE_NAME: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
else
  echo "  BROKEN  $SUITE_NAME is RED before any mutation -- nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -20 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 -- the LIVE-worktree safety gate removed. Case 4 is the survival case:
# a process whose cwd is a LIVE (non-deleted) .claude/worktrees/... dir must
# NOT be reaped. Dropping the `[ "$deleted" -eq 1 ] &&` guard makes
# match_worktree_deleted fire on a live worktree too -- this is the exact
# defect the bead was filed to prevent, live: a builder mid-test gets killed.
# Cases 1/2/3/7-12 are untouched by this mutant (they don't exercise a LIVE
# worktree cwd through the general-sweep path), and case 5/6 go through the
# separate --worktree code path entirely.
fresh_copy
mutate "$SCRIPT_NAME" \
  '[ "$deleted" -eq 1 ] && match_worktree_deleted "$clean" && matched=1' \
  '[ "$deleted" -ge 0 ] && match_worktree_deleted "$clean" && matched=1'
check "M1 live-worktree-predicate inverted (deleted-gate always-true)" "4"

# M2 -- the ledger write removed. Reaping still happens (kill still fires),
# so RC/alive-check/result-tag assertions still pass, but nothing lands in
# $ORPHAN_REAPER_LEDGER -- the fleet loses the recurrence record the bead's
# acceptance criteria call for. Cases 2 and 10 both assert ledger content;
# case 2 also asserts a reap happened via other means, so it degrades rather
# than vanishing -- both must go red on their ledger assertions.
fresh_copy
mutate "$SCRIPT_NAME" \
  '  mkdir -p "$(dirname "$LEDGER")"
  printf '"'"'{"ts":"%s","pid":%s,"age":%s,"comm":"%s","cwd":"%s"}\n'"'"' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" "$age" "$(json_escape "$comm")" "$(json_escape "$cwd")" \
    >> "$LEDGER"' \
  '  : # ledger write removed by mutant'
check "M2 ledger-write-removed" "2 10"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR -- at least one mutation never applied. ========"
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The safety/ledger guarantees in $SCRIPT_NAME are not guarded the way"
  echo "    the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
