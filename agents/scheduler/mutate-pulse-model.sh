#!/bin/bash
# Mutation harness for pulse-inject.sh's MODEL-PIN logic (--model / seats.yml).
#
#   bash agents/scheduler/mutate-pulse-model.sh [-v]
#
# WHY THIS EXISTS. --model decides WHICH QUALITY TIER (and therefore which rate)
# every pulse row runs at. Before it, all 24 timers ran the machine default by
# inheritance; the roster now pins per seat under DEFAULT-UP / PIN-DOWN
# (dotfiles-pulse-row-model-seat-d0bk). Every failure mode is silent by
# construction, exactly as the seat's were:
#
#   * a pin that never reaches the launched process — nothing errors, the tick
#     runs on the default and looks identical in every log the harness keeps
#   * a durable warm pane still running last week's model — no launch, no error
#   * a roster lookup that resolves to nothing — reads as "this row has no pin"
#   * a pin spliced into a launch string is TYPED INTO A SHELL, so a non-token
#     value is a keystroke-injection, and it too fails silently when it works
#
# `PASS: 45/45` on the model subset says the assertions ran; it does not say they
# would notice. Per this repo's rule 1 only a mutant that dies is evidence, and
# mutate-tunnel-ownership.sh / mutate-pulse-seat.sh beside this file are the
# model for what "dies" has to mean:
#
#   1. the target text occurs EXACTLY ONCE in the pristine file
#   2. the replacement text occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed
#   4. the replacement occurs exactly once afterwards
#   5. `bash -n` is still clean (it dies of the bug it NAMES, not a syntax error)
#
# Any of those failing is a HARNESS ERROR, never a killed mutant (dotfiles-47nf),
# and a killed mutant must fail the case(s) it NAMES, with the cases it must NOT
# break asserted too (dotfiles-77s4).
#
# THE SIXTH CHECK: it runs the suite with PULSE_TEST_ONLY=model (cases 23-31
# only) and ASSERTS THE BASELINE CASE COUNT, so a filter that silently matched
# nothing cannot read as a green baseline.
#
# It also exports PULSE_SEAT_RESOLVE. The injector under test is a COPY in a
# scratch dir, so its own `dirname $0/../lib` resolution would find no resolver
# and every model case would degrade to "no pin" — which is a green baseline for
# the wrong reason. Pointing both at the REAL agents/lib is what keeps the
# mutants meaningful.
#
# Cost, measured on this box: ~25s per suite run, 5 runs (baseline + 4 mutants)
# ≈ 2 min. tools/githooks/pre-commit fires it on three filenames only.
#
# ⚠️ Safe to run beside other work: every tmux object it touches lives on a
# private `-L pulsemodel-<pid>` server. It never touches the default server.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of pulse-inject.sh. `$MODEL`, `$LAUNCH_BASE` and friends inside
# them must NOT expand — they are matched byte-for-byte against the file on disk,
# and an expanded one would match nothing.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-pulse-model.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

INJ="pulse-inject.sh"
SUITE="test-pulse-inject.sh"

# The REAL resolver, from the real tree — never a copy. There is one roster
# parser on this box and a mutation harness must not become the second.
SEATLIB="$SRC/../lib/seat-resolve.sh"
if [ ! -f "$SEATLIB" ]; then
  echo "HARNESS ERROR: seat resolver not found at $SEATLIB" >&2
  exit 2
fi
export PULSE_SEAT_RESOLVE="$SEATLIB"

# The model-only subset's exact case count. If you add or remove a model case,
# update this number — that is the point: a drifting count must stop the harness
# rather than quietly shrink what it proves.
EXPECT_CASES=45

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$INJ" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$INJ" "$WORK/scheduler/$INJ"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
}

# run_suite -> rc, output in $SUITE_OUT. The suite resolves the injector via
# `dirname $0`, so the copy is self-contained and the real tree is never edited.
run_suite() {
  SUITE_OUT=$(PULSE_TEST_ONLY=model bash "$WORK/scheduler/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to> — fixed strings, never regexes:
# over-escaping a pattern is the exact failure this shape exists to prevent.
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

# failing_tags — the case tags in the suite's FAIL list. The suite prints
# `  - <tag> …` (or `  - <tag>: …` via assert_verdict) for each failure, and
# every model case's label starts with a tag of the form MD<number><letter>.
failing_tags() {
  printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | grep -oE '\bMD[0-9]+[a-z]\b' | sort -u | tr '\n' ' '
}

# check <mutant-name> <must-FAIL tags> [<must-PASS tags>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  ($SUITE is still green with the model logic broken)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  got=$(failing_tags)
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
    echo "           (this mutant is meant to break the model logic while leaving those intact)"
    echo "           actually failing: ${got:-<none>}"
    FAILED=1
  else
    echo "killed    $name"
    echo "          failing cases: $got"
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/          | /'
  return 0
}

echo "=== baseline: the unmutated copy must be GREEN, on the expected case count ="
fresh_copy
if run_suite; then
  BASE_LINE=$(printf '%s\n' "$SUITE_OUT" | tail -1)
  echo "  ok      $SUITE (PULSE_TEST_ONLY=model): $BASE_LINE"
  if [ "$BASE_LINE" != "PASS: $EXPECT_CASES/$EXPECT_CASES test cases" ]; then
    echo "  HARNESS ERROR: expected 'PASS: $EXPECT_CASES/$EXPECT_CASES test cases'."
    echo "                 Either PULSE_TEST_ONLY=model matched a different set of"
    echo "                 cases than this harness was written against, or model"
    echo "                 cases were added/removed. Nothing below means anything"
    echo "                 until EXPECT_CASES matches the suite."
    exit 2
  fi
else
  echo "  BROKEN  $SUITE is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — THE PIN NEVER REACHES THE LAUNCH STRING. The splice is the entire
# mechanism; drop it and every row runs the machine default while the flag still
# parses, the roster still resolves, and the log still says the pin was found.
# This is precisely the shape a test that only checked "the flag was accepted"
# would miss. The must-PASS set is the backward-compatibility half: rows with no
# pin are not supposed to change, so a mutant that reddens them broke something
# other than the pin.
fresh_copy
mutate "$INJ" \
  'if [ -n "$MODEL" ]; then
  if [ "$LAUNCH_BASE" = "claude" ]; then' \
  'if false; then
  if [ "$LAUNCH_BASE" = "claude" ]; then'
check "M1 pin-never-spliced (every pinned row silently runs the default)" \
      "MD23b MD23d MD26a MD27c MD27d MD28a MD29b" \
      "MD24a MD24b MD24c MD25a MD25b MD30b MD30c MD31a MD31b MD31c MD31d MD31e MD31f"

# M2 — THE REUSE PATH STOPS CHECKING. The nastier half, same as the seat's: a
# durable window already holds a launcher, so the branch that applies the pin
# never runs, and without this check the pane is simply reused on whatever model
# it came up with — days ago, possibly before the pin existed. Note the must-PASS
# set: the COLD launch is unaffected, so a mutant reddening case 23 broke
# something else.
fresh_copy
mutate "$INJ" \
  'if [ "$MODEL_ACTIVE" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  verify_model "reuse"' \
  'if false && [ "$WAS_WARM" = 1 ]; then
  verify_model "reuse"'
check "M2 warm-pane-model-check-removed (last week's model, silently reused)" \
      "MD27c MD27d MD28a MD29b" \
      "MD23a MD23b MD23c MD23d MD24a MD24b MD25a MD25b MD31a MD31b MD31c"

# M3 — THE PIN IS SPLICED WITHOUT BEING A TOKEN. The launch string is TYPED INTO
# A SHELL, so the roster value is a keystroke sequence. seats.yml has its own
# commit-time validator, but this injector must not borrow another file's gate
# for its own safety — a hand-edited roster, a --model from a script, or a
# roster that lands before the validator does are all the same keystrokes.
# MD31f is the one that actually proves it: the fixture pin carries a command
# substitution, so the mutant leaves a file behind on disk.
fresh_copy
mutate "$INJ" \
  '    *[!A-Za-z0-9._-]*|"")' \
  '    "")'
check "M3 pin-token-guard-removed (a roster value becomes keystrokes in a shell)" \
      "MD31e MD31f" \
      "MD23a MD23b MD23c MD23d MD24b MD25b MD27c MD27d MD28a MD29b"

# M4 — THE NON-VACUITY MUTANT, and the scope one. Everything above breaks the
# pin; this one breaks its SCOPE, by pinning launchers that are not claude.
# dive's launcher is tick-jailed.sh, which execs bwrap: `--model` would be
# swallowed as bwrap's own argument and the jailed launch would break — a pin
# turning a working row into a broken one. It also answers the fair question
# about the cases above: are they detecting the PIN, or merely detecting that a
# flag exists? MD31b/MD31c are a pinned SEAT with a non-claude launcher, and
# every other case must keep passing, which makes this a probe of the guard's
# scope rather than of its existence.
fresh_copy
mutate "$INJ" \
  'if [ "$LAUNCH_BASE" = "claude" ]; then
    LAUNCH="$LAUNCH --model $MODEL"' \
  'if true; then
    LAUNCH="$LAUNCH --model $MODEL"'
check "M4 pin-applied-to-launchers-that-are-not-claude (the jail breaks)" \
      "MD31b MD31c" \
      "MD23a MD23b MD23c MD23d MD24a MD24b MD24c MD25a MD25b MD26a MD27a MD27c MD27d MD28a MD29a MD29b MD30b MD30c"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The --model pin logic in $INJ is not guarded the way the suite"
  echo "    claims, and a pulse row can silently run on the wrong model tier."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
