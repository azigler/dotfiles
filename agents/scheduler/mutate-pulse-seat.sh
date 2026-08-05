#!/bin/bash
# Mutation harness for pulse-inject.sh's CLAUDE-SEAT logic (--config-dir).
#
#   bash agents/scheduler/mutate-pulse-seat.sh [-v]
#
# WHY THIS EXISTS. --config-dir decides WHICH ANTHROPIC ACCOUNT a tick bills and
# attributes to. Seven LinearB pulse rows are moving back onto zig-computer, and
# the cutover they are reversing existed precisely to keep that work off Zig's
# personal subscription. Every failure mode here is silent by construction:
#
#   * a launch-time env that never reaches the launched process — nothing errors
#   * a durable window REUSED on the wrong seat — no launch, no error
#   * a credential-less seat — Claude says "Not logged in" in a pane nobody reads
#
# None of those turn a timer red. `PASS: 113/113` on test-pulse-inject.sh says
# the assertions ran; it does not say they would notice. Per this repo's rule 1,
# only a mutant that dies is evidence, and the tunnel-ownership harness beside
# this file is the model for what "dies" has to mean:
#
#   1. the target text occurs EXACTLY ONCE in the pristine file
#   2. the replacement text occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed
#   4. the replacement occurs exactly once afterwards
#   5. `bash -n` is still clean (it dies of the bug it NAMES, not a syntax error)
#
# Any of those failing is a HARNESS ERROR, never a killed mutant — an unapplied
# mutation that reddens a suite is indistinguishable, by exit code, from a real
# kill (dotfiles-47nf). And a killed mutant must fail the case(s) it NAMES, with
# the cases it must NOT break asserted too (dotfiles-77s4): "red somewhere" is
# frequently evidence the mutant broke something unrelated.
#
# THE SIXTH CHECK, specific to this harness: it runs the suite with
# PULSE_TEST_ONLY=seat (cases 18-22 only; the other ~60s per run are about
# things no mutant here touches) and ASSERTS THE BASELINE CASE COUNT. A filter
# that silently matched nothing would otherwise produce a green "PASS: 0/0"
# baseline and five meaningless kills.
#
# Cost, measured on this box: ~45s per suite run, 6 runs (baseline + 5 mutants)
# ≈ 4.5 min. tools/githooks/pre-commit fires it on three filenames only.
#
# ⚠️ Safe to run beside other work: every tmux object it touches lives on a
# private `-L pulseseat-<pid>` server. It never touches the default server where
# Zig's `work` session lives.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of pulse-inject.sh. `$CONFIG_DIR_ABS`, `$PANE`, `$(printf …)`
# and friends inside them must NOT expand — they are matched byte-for-byte
# against the file on disk, and an expanded one would match nothing.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-pulse-seat.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

INJ="pulse-inject.sh"
SUITE="test-pulse-inject.sh"

# The seat-only subset's exact case count. If you add or remove a seat case,
# update this number — that is the point: a drifting count must stop the harness
# rather than quietly shrink what it proves.
EXPECT_CASES=48

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
  SUITE_OUT=$(PULSE_TEST_ONLY=seat bash "$WORK/scheduler/$SUITE" 2>&1)
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
# every seat case's label starts with a tag of the form S<number><letter>.
failing_tags() {
  printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | grep -oE '\bS[0-9]+[a-z]\b' | sort -u | tr '\n' ' '
}

# check <mutant-name> <must-FAIL tags> [<must-PASS tags>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  ($SUITE is still green with the seat logic broken)"
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
    echo "           (this mutant is meant to break the seat logic while leaving those intact)"
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
  echo "  ok      $SUITE (PULSE_TEST_ONLY=seat): $BASE_LINE"
  if [ "$BASE_LINE" != "PASS: $EXPECT_CASES/$EXPECT_CASES test cases" ]; then
    echo "  HARNESS ERROR: expected 'PASS: $EXPECT_CASES/$EXPECT_CASES test cases'."
    echo "                 Either PULSE_TEST_ONLY=seat matched a different set of"
    echo "                 cases than this harness was written against, or seat"
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

# M1 — THE SEAT IS NEVER SET AT LAUNCH. The export typed into the pane before
# the launcher starts is the entire mechanism; drop it and the tick runs on
# whatever seat the tmux server happened to have — which is Zig's personal one.
# Nothing about the flag, the parsing, or the preflight changes, so this is
# exactly the shape a test that only checks "the flag was accepted" would miss.
fresh_copy
mutate "$INJ" \
  'if [ -n "$CONFIG_DIR_ABS" ]; then
    "$TMUX_BIN" send-keys -t "$PANE" "export CLAUDE_CONFIG_DIR=$(printf '"'"'%q'"'"' "$CONFIG_DIR_ABS")" Enter' \
  'if false; then
    "$TMUX_BIN" send-keys -t "$PANE" "export CLAUDE_CONFIG_DIR=$(printf '"'"'%q'"'"' "$CONFIG_DIR_ABS")" Enter'
check "M1 launch-time-export-dropped (the tick runs on the personal seat)" \
      "S19a S19b S19c" "S21a S21b S21c S21d"

# M2 — THE REUSE PATH STOPS CHECKING. This is the one the bead calls the nastier
# half: the durable window already holds a launcher, so the branch that sets the
# seat never runs, and without this guard the wrong-seat pane is simply reused.
# Note the must-PASS set: a cold launch is unaffected, so a mutant that reddens
# case 19 too has broken something else.
fresh_copy
mutate "$INJ" \
  'if [ -n "$CONFIG_DIR_ABS" ] && [ "$WAS_WARM" = 1 ]; then
  assert_seat "reuse"' \
  'if false && [ "$WAS_WARM" = 1 ]; then
  assert_seat "reuse"'
check "M2 reuse-path-seat-check-removed (wrong-seat window silently reused)" \
      "S20a S20b S20f S20g S20h" "S19a S19b S19c S21a S21b S21c"

# M3 — THE CREDENTIAL PREFLIGHT STOPS FIRING. A credential-less seat does not
# error: Claude Code starts, prints "Not logged in · Please run /login", and
# holds the window. The tick then produces nothing and writes no ledger row —
# the "fired but no ledger row" class. S18a must keep passing: the missing-dir
# check is a DIFFERENT guard, and a mutant that takes out both is not isolating
# either.
fresh_copy
mutate "$INJ" \
  'if [ -n "$CRED_FILE" ] && [ ! -s "$CONFIG_DIR_ABS/$CRED_FILE" ]; then' \
  'if false && [ ! -s "$CONFIG_DIR_ABS/$CRED_FILE" ]; then'
check "M3 credential-preflight-removed ('Not logged in' burns the window)" \
      "S18b S18c" "S18a S18d S19a S19b"

# M4 — SEAT READ OFF THE WRONG PROCESS. _pane_launcher_pid deliberately finds
# the pane's FOREGROUND process-group leader rather than #{pane_pid}, because
# /proc/<pid>/environ is a snapshot taken at exec: the export typed into the
# pane's shell is INVISIBLE in that shell's environ and only appears in the
# children it starts afterwards. Reading the shell would therefore report
# "unset" for a correctly-seated pane — a guard that fails on the good case, and
# in production that means every seated row refusing to run. This mutant is why
# the suite records the seat from inside the launcher rather than asking tmux.
fresh_copy
mutate "$INJ" \
  '  fg=$(ps -o pid=,pgid=,stat= -t "${tty#/dev/}" 2>/dev/null \
       | awk '"'"'$3 ~ /\+/ && $1 == $2 { print $1 }'"'"' | tail -n1)' \
  '  fg=$ppid'
check "M4 seat-read-from-the-pane-SHELL-not-the-launcher" \
      "S19a S19c" "S21a S21b S21c"

# M5 — THE NON-VACUITY MUTANT, and the no-regression one. Everything above
# breaks the seat logic; this one breaks its OPT-IN-NESS by applying the reuse
# check to loops that never asked for a seat. dive/desk/dream/digest pass no
# --config-dir, and dive's launcher (tick-jailed.sh) sets CLAUDE_CONFIG_DIR
# itself via bwrap --setenv — so an unconditional check would refuse the jailed
# loop for having the "wrong" seat, i.e. for working correctly.
#
# It also answers the fair question about the seat cases: are they detecting
# seat pinning, or just detecting that a flag exists? S21d is a warm pane that
# IS on a seat, invoked with NO --config-dir, and it must still inject. Every
# seat case must keep passing, which is what makes this a probe of the guard's
# scope rather than of its existence.
fresh_copy
mutate "$INJ" \
  'if [ -n "$CONFIG_DIR_ABS" ] && [ "$WAS_WARM" = 1 ]; then' \
  'if [ "$WAS_WARM" = 1 ]; then'
check "M5 seat-check-applied-to-loops-that-asked-for-no-seat" \
      "S21d" "S18a S18b S18d S19a S19b S19c S20a S20f S20h S21a S21b S21c"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The --config-dir seat logic in $INJ is not guarded the way the suite"
  echo "    claims, and a tick can run on the wrong Anthropic account silently."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
