#!/bin/bash
# Mutation harness for the HALL's interactive court — the raw input loop and the
# compact breakpoint's live-only filter.
#
#   bash agents/bin/mutate-hall-prompt.sh [-v]
#
# WHY THIS EXISTS (dotfiles-hnhl). Every defect this file guards was reported by
# ZIG, LIVE, against a suite that was green at the time: the first typed
# character could not be erased, Esc typed instead of closing once the buffer
# held anything, any arrow key on an empty buffer dismissed the popup, and the
# phone's court was a roster dump of seats that were not running. None of them
# turns anything red — a popup that closes when it should not, or refuses to,
# exits 0 either way, and a court with too many rows renders perfectly. That is
# exactly this repo's rule 1: a green test-hall.sh is not evidence the guards
# bite; only a mutant that dies is.
#
# Same five-assertions-before-trusting-a-result discipline as
# agents/bin/mutate-orphan-reaper.sh and agents/scheduler/mutate-tunnel-
# ownership.sh: assert the mutation text exists exactly once in the pristine
# file, assert the replacement is not already present (not a no-op), assert the
# bytes actually changed, assert the replacement landed exactly once, assert
# `bash -n` is still clean (a mutant must die of the bug it NAMES, not of a
# syntax error that fails every case). And a killed mutant must fail the case(s)
# it names -- red-somewhere proves nothing about the guard under test.
#
# THE MIRROR (why this one is not a flat temp dir). test-hall.sh resolves its
# own ROOT from $0 and reads the REAL validator, the REAL roster and the REAL
# tmux.conf out of it. So the mutant runs inside a tree SHAPED like the repo:
# agents/bin/{hall,test-hall.sh} are the mutated copies, everything else the
# suite reaches is a symlink back to this checkout. Copying the whole repo would
# work too and would silently diverge the day someone adds a fixture path.

# shellcheck disable=SC2016
# ^ every mutation argument below is LITERAL SOURCE TEXT copied out of hall.
# Variable references inside them must NOT expand.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/bin
ROOT="$(cd "$SRC/.." && cd .. && pwd)"      # the repo root
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-hall-prompt.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SCRIPT_NAME="hall"
SUITE_NAME="test-hall.sh"
BIN="$WORK/agents/bin"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$BIN" "$WORK/pristine"
for f in "$SCRIPT_NAME" "$SUITE_NAME"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done
for p in agents/lib agents/scheduler agents/seats.yml tmux; do
  [ -e "$ROOT/$p" ] || { echo "HARNESS ERROR: $ROOT/$p does not exist" >&2; exit 2; }
  ln -s "$ROOT/$p" "$WORK/$p"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$SCRIPT_NAME" "$BIN/$SCRIPT_NAME"
  cp -a "$WORK/pristine/$SUITE_NAME" "$BIN/$SUITE_NAME"
}

run_suite() {
  SUITE_OUT=$(bash "$BIN/$SUITE_NAME" 2>&1)
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
  local path="$BIN/$file" pristine="$WORK/pristine/$file"

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

  # test-hall.sh reports failures as `  - <TAG> <what> (want [x] got [y])`, so
  # the case tag is field 2 (field 1 is the dash).
  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | awk '{ print $2 }' | sort -u | tr '\n' ' ')
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

# M1 -- the escape-sequence drain removed, so every ESC byte reads as the bare
# Esc key. This IS bug 3, restored: an arrow key is ESC [ A, and the popup
# dismisses itself the moment Zig nudges the cursor. PROMPTARROWLIVE is the only
# case that can see it — the arrows are followed by a name, and a popup that
# closed on the first arrow never reads it. PROMPTARROW cannot: closing early
# and handling the arrows correctly BOTH leave the court untouched and exit 0,
# which is precisely why it is not the case this mutant names.
fresh_copy
mutate "$SCRIPT_NAME" \
  '  IFS= read -rsn1 -t "${HALL_ESC_DRAIN:-0.01}" b || return 1' \
  '  return 1  # the drain is removed by this mutant: every ESC is a bare Esc'
check "M1 esc-drain-removed (an arrow key closes the popup again)" \
       "PROMPTARROWLIVE" "PROMPTARROW PROMPTESC PROMPTESCMID PROMPTBKSP"

# M2 -- backspace stops one character short, which is bug 1 exactly: the FIRST
# typed character is undeletable, so the buffer can never return to the empty
# state Enter closes on. The tell is not the exit code (unchanged) but that the
# leftover character gets SUBMITTED as a seat name — `no seat 'a'` on stderr,
# which PROMPTBKSP asserts is absent. PROMPTBKSPFLOOR keeps passing on purpose:
# the at-empty no-op is a separate guard, and a mutant that took both with it
# would not tell you which one bit.
fresh_copy
mutate "$SCRIPT_NAME" \
  '        _buf=${_buf%?}' \
  '        [ "${#_buf}" -gt 1 ] && _buf=${_buf%?}'
check "M2 backspace-floor-removed (the first char is undeletable again)" \
       "PROMPTBKSP" "PROMPTBKSPFLOOR PROMPTESCMID PROMPTARROWLIVE"

# M3 -- the compact breakpoint's live-only filter INVERTED: the phone shows the
# seats that are NOT running and hides the ones that are. It renders perfectly
# and every glyph/alignment/width property still holds, which is what makes it
# the right mutant — the only thing wrong is WHICH ROWS, and only a case that
# counts and names them can see that. The wide layouts must stay green: this
# filter is the phone's, not the renderer's.
fresh_copy
mutate "$SCRIPT_NAME" \
  '        [ "$glyph" = "$G_ASLEEP" ] && continue' \
  '        [ "$glyph" != "$G_ASLEEP" ] && continue'
check "M3 asleep-filter-inverted (the phone shows only the sleeping seats)" \
       "BPLIVE BPASLEEP BPCOMPACT" "BPLIVEWIDE BPASLEEPWIDE BPMEDIUM PROMPTBKSP"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR -- at least one mutation never applied. ========"
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The interactive court's input loop / compact filter are not guarded"
  echo "    the way $SUITE_NAME claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
