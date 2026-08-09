#!/bin/bash
# Mutation harness for pre-worktree-remove-guard.sh's refusal logic.
#
#   bash agents/hooks/test/mutate-worktree-remove-guard.sh [-v]
#
# WHY THIS EXISTS (dotfiles-3135). This guard decides WHETHER A DIRECTORY
# HOLDING UNCOMMITTED, UNRECOVERABLE WORK GETS DELETED. Every way it can be
# wrong is silent: a refusal that stops refusing looks exactly like a clean
# tree, a debris rule that swallows live work looks exactly like a removal that
# was fine, and an override that is always on looks exactly like a guard nobody
# needed. None of those turn anything red — the removal just succeeds and prints
# nothing, which is precisely what the incident looked like. Per this repo's
# rule 1, a green test-pre-worktree-remove-guard.sh is not evidence that the
# guard bites; only a mutant that dies is. This file is that evidence, and
# tools/githooks/pre-commit is its consumer.
#
# Same five-assertions-before-trusting-a-result discipline as
# agents/scheduler/mutate-tunnel-ownership.sh and agents/bin/mutate-orphan-reaper.sh:
# assert the target text exists exactly once in the pristine file, assert the
# replacement is not already present (not a no-op), assert the bytes changed,
# assert the replacement landed exactly once, assert `bash -n` is still clean (a
# mutant must die of the bug it NAMES, not of a syntax error that fails every
# case). And a killed mutant must fail the case(s) it names — red-somewhere
# proves nothing about the guard under test.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of pre-worktree-remove-guard.sh. `$comm`, `$SKEL` and friends
# inside them must NOT expand — they are matched byte-for-byte against the file
# on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")/.." && pwd)"        # agents/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-wt-remove-guard.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

HOOK_NAME="pre-worktree-remove-guard.sh"
SUITE_NAME="test-pre-worktree-remove-guard.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/hooks/test" "$WORK/hooks/lib" "$WORK/pristine"
[ -f "$SRC/$HOOK_NAME" ]        || { echo "HARNESS ERROR: $SRC/$HOOK_NAME does not exist" >&2; exit 2; }
[ -f "$SRC/test/$SUITE_NAME" ]  || { echo "HARNESS ERROR: $SRC/test/$SUITE_NAME does not exist" >&2; exit 2; }
cp -a "$SRC/$HOOK_NAME"       "$WORK/pristine/$HOOK_NAME"
cp -a "$SRC/test/$SUITE_NAME" "$WORK/pristine/$SUITE_NAME"
# The hook resolves lib/hook-helpers.sh relative to its OWN path, and the suite
# resolves the hook relative to its own — so the copy has to keep that shape.
cp -a "$SRC/lib/hook-helpers.sh" "$WORK/hooks/lib/hook-helpers.sh"

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$HOOK_NAME"  "$WORK/hooks/$HOOK_NAME"
  cp -a "$WORK/pristine/$SUITE_NAME" "$WORK/hooks/test/$SUITE_NAME"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/hooks/test/$SUITE_NAME" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <literal-from> <literal-to> — against the HOOK (the only mutated file).
mutate() {
  local from=$1 to=$2
  local path="$WORK/hooks/$HOOK_NAME" pristine="$WORK/pristine/$HOOK_NAME"

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
  [ $? -eq 0 ] || { harness_error "$HOOK_NAME: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$HOOK_NAME: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$HOOK_NAME: the mutant is not valid bash -- it would fail every case for the wrong reason"
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

# M1 -- THE REFUSAL REMOVED. The whole guard, reduced to a very informative log
# line: it still detects the live owner, still prints the block message, and
# then lets the removal through. This is the incident itself, and it is the
# mutant that matters most, because a guard that prints and allows is
# indistinguishable from a guard that works right up until the day it isn't.
# Every live-work case must go red; the debris case (7) must NOT, since it was
# already an allow.
fresh_copy
mutate \
  '} >&2
exit 2' \
  '} >&2
exit 0'
check "M1 refusal-removed (live work sails through)" "5 6 8b 13 14 15 16 17 18" "7"

# M2 -- DEBRIS BLOCKS CLEANUP. The classification inverted at the source: with
# is_debris_comm short-circuited to false, NOTHING is ever debris, so a stale
# pane shell refuses a legitimate cleanup. This is the failure mode that gets a
# guard routed around and then deleted, and it is why the bead names it as its
# own acceptance criterion. Case 7 is the direct detector; case 17 is the second
# one (its debris must be reported as NOT the reason for the block). The live
# cases must keep passing -- this mutant makes the guard MORE restrictive, so if
# they went red the mutant broke something else.
fresh_copy
mutate \
  'if is_debris_comm "$comm" && [ "$cpu" -lt "$CPU_FLOOR" ]' \
  'if false && is_debris_comm "$comm" && [ "$cpu" -lt "$CPU_FLOOR" ]'
check "M2 debris-blocks-cleanup (nothing is ever reapable)" "7 17" "4 5 18"

# M3 -- THE OVERRIDE IGNORED. WORKTREE_REMOVE_OVERRIDE_LIVE=1 stops being
# honoured, so the only documented escape hatch is gone and the guard becomes
# unbypassable. Case 8 is its detector. 8b must keep passing: it asserts the
# same tree still blocks WITHOUT the override, which is what makes case 8 a
# statement about the override rather than about that tree.
fresh_copy
mutate \
  'if echo "$SKEL" | grep -q '"'"'WORKTREE_REMOVE_OVERRIDE_LIVE='"'"' \' \
  'if false && echo "$SKEL" | grep -q '"'"'WORKTREE_REMOVE_OVERRIDE_LIVE='"'"' \'
check "M3 override-ignored (the documented escape hatch is dead)" "8" "5 8b"

# M4 -- THE PATH BOUNDARY DROPPED. path_under degraded to a plain string-prefix
# match, so /…/wt-sibling reads as "under" /…/wt. Nobody notices until the day a
# sibling agent's tree shares a prefix and a legitimate cleanup is refused with
# a pid that has nothing to do with it. Case 12 exists for exactly this mutant
# (its fixture sibling is named to share the prefix); everything else must keep
# passing, since a prefix match is a superset of the correct one.
fresh_copy
mutate \
  'path_under() { case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac }' \
  'path_under() { case "$1" in "$2"*) return 0 ;; *) return 1 ;; esac }'
check "M4 path-boundary-dropped (a prefix-sharing sibling reads as inside)" "12" "4 5 7"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR -- at least one mutation never applied. ========"
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The refusal, the debris split, the override or the path boundary in"
  echo "    $HOOK_NAME is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
