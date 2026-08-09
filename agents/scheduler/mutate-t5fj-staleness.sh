#!/bin/bash
# Mutation harness for the dotfiles-t5fj STALENESS guards — both arms.
#
#   bash agents/scheduler/mutate-t5fj-staleness.sh [-v]
#
# WHY THIS EXISTS. Two scripts now decide whether a scheduled tick is delivered:
# pulse-retry.sh re-verifies a bounce against the present before re-firing it
# (step 3d.5), and pulse-inject.sh refuses a --fresh injection whose target pane
# is running a tick of the SAME loop. Both decisions fail SILENTLY in the
# dangerous direction — a guard that quietly stops biting looks exactly like a
# quiet night, right up until a /clear lands on a live run and takes its context
# with it (the 2026-08-09 incident, dotfiles-t5fj).
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites; only
# a mutant that dies is. This file is that evidence.
#
# MODELLED ON mutate-tunnel-ownership.sh, deliberately, including both of the
# clauses that harness burned in:
#
#   * ASSERT THE MUTATION APPLIED. Every mutation is checked five ways (target
#     text present exactly once, replacement absent beforehand, bytes changed,
#     replacement present exactly once afterwards, `bash -n` still clean) before
#     its suite result is allowed to mean anything. A suite that goes red under
#     an UNAPPLIED mutation is a HARNESS ERROR, not a kill.
#   * A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES. Red-somewhere says nothing
#     about the guard under test. Each mutant below declares the case TAGS that
#     must fail and (where it matters) the ones that must keep PASSING.
#
# The injector's cases run under PULSE_TEST_ONLY=t5fj — the existing section
# filter — and the harness asserts the section's exact case COUNT first, so a
# filter that silently matched nothing is a harness error rather than a green run.
#
# ⚠️ Runs BOTH suites against scratch COPIES; the real tree is never edited. The
# injector's t5fj section drives its own private tmux server (-L), so this is
# safe beside a live session — but do not run it concurrently with
# test-pulse-inject.sh, which uses $$-derived socket names that a second copy
# could collide with.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of the scripts. `$resolved`, `$WIN_NAME` and friends inside
# them must NOT expand — they are matched byte-for-byte against the file on disk,
# and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-t5fj.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

RETRY="pulse-retry.sh"
RETRY_SUITE="test-pulse-retry.sh"
INJECT="pulse-inject.sh"
INJECT_SUITE="test-pulse-inject.sh"

# The injector's t5fj section has this many assertions. Asserted against the
# BASELINE run: a filter that matched nothing would otherwise report PASS: 0/0
# and every mutant below would "die" against an empty suite.
EXPECT_T5FJ_CASES=19

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$RETRY" "$RETRY_SUITE" "$INJECT" "$INJECT_SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  for f in "$RETRY" "$RETRY_SUITE" "$INJECT" "$INJECT_SUITE"; do
    cp -a "$WORK/pristine/$f" "$WORK/scheduler/$f"
  done
}

run_retry_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$RETRY_SUITE" 2>&1)
  return $?
}
run_inject_suite() {
  SUITE_OUT=$(PULSE_TEST_ONLY=t5fj bash "$WORK/scheduler/$INJECT_SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to> — literal substring swap with all
# five applied-ness assertions. Fixed strings, never regexes: over-escaping a
# pattern is the exact failure this shape exists to make impossible.
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

# check <runner> <mutant-name> <must-FAIL tags> [<must-PASS tags>]
# Tags are matched as substrings of the suite's `  - <name>` failure lines, which
# is why every t5fj case name opens with a stable tag (t5fj-… / T33…).
check() {
  local runner=$1 name=$2 want_fail=$3 want_pass=${4:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if "$runner"; then
    echo "SURVIVED  $name  (the suite is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ' | sed 's/^  - //')
  for c in $want_fail; do
    printf '%s\n' "$got" | grep -qF "$c" || missing="$missing $c"
  done
  for c in $want_pass; do
    printf '%s\n' "$got" | grep -qF "$c" && wrongly="$wrongly $c"
  done

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name"
    echo "           the suite went red but NOT on the case(s) this mutant names:$missing"
    echo "           actually failing: $(printf '%s' "$got" | tr '\n' '|')"
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name"
    echo "           case(s) that had to keep PASSING went red:$wrongly"
    echo "           actually failing: $(printf '%s' "$got" | tr '\n' '|')"
    FAILED=1
  else
    echo "killed    $name"
    printf '%s\n' "$got" | sed 's/^/          fail: /'
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/          | /'
  return 0
}

echo "=== baseline: the unmutated copies must be GREEN =========================="
fresh_copy
if run_retry_suite; then
  echo "  ok      $RETRY_SUITE: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
else
  echo "  BROKEN  $RETRY_SUITE is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi
if run_inject_suite; then
  BASE_INJ=$(printf '%s\n' "$SUITE_OUT" | tail -1)
  echo "  ok      $INJECT_SUITE (PULSE_TEST_ONLY=t5fj): $BASE_INJ"
else
  echo "  BROKEN  $INJECT_SUITE (t5fj section) is RED before any mutation"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi
BASE_N=$(printf '%s' "$BASE_INJ" | sed -n -E 's/^PASS: ([0-9]+)\/([0-9]+).*/\2/p')
if [ "${BASE_N:-0}" -ne "$EXPECT_T5FJ_CASES" ]; then
  echo "  HARNESS ERROR: PULSE_TEST_ONLY=t5fj ran ${BASE_N:-0} cases, expected $EXPECT_T5FJ_CASES."
  echo "  A filter that matched nothing (or a section that grew) makes every mutant below meaningless."
  exit 2
fi

echo
echo "=== ARM 1: pulse-retry.sh — re-verify the bounce before re-firing ========="

# R1 — the resolution is COMPUTED and then IGNORED. This is the pre-t5fj engine
# restored in effect: every signal is read, and the watcher re-fires anyway. It is
# the mutant that reproduces the incident itself.
fresh_copy
mutate "$RETRY" \
  '  if [ -n "$resolved" ]; then
    note "skip $loop: bounce $bts is RESOLVED' \
  '  if false; then
    note "skip $loop: bounce $bts is RESOLVED'
check run_retry_suite "R1 resolution-computed-then-ignored (the incident itself)" \
  "t5fj-ledger-resolves t5fj-ledger-log t5fj-delivery-resolves t5fj-delivery-log t5fj-running-resolves t5fj-running-log t5fj-running-ttl-knob" \
  "t5fj-live-bounce-refires t5fj-delivery-scoped t5fj-manifest-broken"

# R2 — the ALREADY-RUNNING arm alone is disabled; the two "newer than the bounce"
# arms keep working. Isolates the half that catches a live run whose injection
# PREDATES the bounce — the incident's second, nastier shape.
fresh_copy
mutate "$RETRY" \
  '       && turn_in_flight "$target_name" && [ "$iage" -le "$SAME_LOOP_TTL" ]; then' \
  '       && false; then'
check run_retry_suite "R2 already-running-arm-disabled" \
  "t5fj-running-resolves t5fj-running-log" \
  "t5fj-ledger-resolves t5fj-delivery-resolves t5fj-live-bounce-refires"

# R3 — turn_in_flight() made VACUOUSLY TRUE: every window reads as mid-turn. The
# guard then refuses to re-fire a genuinely live bounce into an IDLE pane, i.e. it
# silently becomes "never retry". Caught only by the non-vacuity case.
#
# It ALSO reddens t5fj-delivery-log, and that is expected rather than collateral
# noise: case 20 still resolves correctly (no re-fire, marked acted) but now does
# so through the already-running arm, so the log says "tick already running"
# instead of "already delivered at". Deliberately left out of the must-pass list —
# the mutant changes which OBSERVATION the line reports, which is a real
# difference, not an accident.
fresh_copy
mutate "$RETRY" \
  'turn_in_flight() {
  [ "$1" != "${1#🧠}" ] && return 0' \
  'turn_in_flight() {
  return 0
  [ "$1" != "${1#🧠}" ] && return 0'
check run_retry_suite "R3 turn_in_flight-vacuously-true (guard becomes never-retry)" \
  "t5fj-live-bounce-refires" \
  "t5fj-ledger-resolves t5fj-delivery-resolves t5fj-running-resolves"

# R4 — the delivery signal loses its SESSION/WINDOW scoping: any delivery of this
# loop anywhere counts as "the turn running in THIS pane is ours". A row for the
# same loop delivered to a different window then suppresses a needed re-fire.
fresh_copy
mutate "$RETRY" \
  '    if [ "$found" = 1 ] && [ "$isess" = "$session" ] && [ "$iwin" = "$window" ] \' \
  '    if [ "$found" = 1 ] && [ -n "$isess" ] && [ -n "$iwin" ] \'
check run_retry_suite "R4 delivery-signal-unscoped" \
  "t5fj-delivery-scoped" \
  "t5fj-ledger-resolves t5fj-delivery-resolves t5fj-running-resolves"

# R5 — the LEDGER comparison stops comparing: any row at all resolves the bounce,
# including one written long BEFORE it. A loop that finished yesterday would then
# never be retried today.
fresh_copy
mutate "$RETRY" \
  '      if [ -n "$lts" ] && [ "${lkey:-0}" -gt "${bkey_s:-0}" ]; then' \
  '      if [ -n "$lts" ]; then'
check run_retry_suite "R5 ledger-row-not-compared-to-bounce" \
  "t5fj-live-bounce-refires" \
  "t5fj-ledger-resolves t5fj-delivery-resolves t5fj-running-resolves"

# R6 — the ALREADY-RUNNING branch's TTL dropped (adversarial review, 2026-08-09).
# That branch is the only one in step 3d.5 that compares nothing against the
# bounce: it reads a delivery row plus a GLYPH, and a glyph can lie. Unbounded, a
# weeks-old row (the file retains ~1000) plus a stale 🧠 marks a genuine bounce
# acted FOREVER — outliving even the injector's own 24h bound on the same claim.
# This mutant is the reviewed code restored verbatim.
fresh_copy
mutate "$RETRY" \
  '       && turn_in_flight "$target_name" && [ "$iage" -le "$SAME_LOOP_TTL" ]; then' \
  '       && turn_in_flight "$target_name"; then'
check run_retry_suite "R6 branch-1-ttl-dropped (an ancient row + a lying 🧠 acts a bounce forever)" \
  "t5fj-running-ttl" \
  "t5fj-ledger-resolves t5fj-delivery-resolves t5fj-running-resolves t5fj-live-bounce-refires"

echo
echo "=== ARM 2: pulse-inject.sh — --fresh never queues behind a live run ======="

# I1 — record_injection() neutered. The delivery row is the fact BOTH arms read;
# without it the injector cannot recognise its own live tick, and pulse-retry
# loses its delivery signal too. Kills the write case and the refusal it feeds.
fresh_copy
mutate "$INJECT" \
  'record_injection() {
  [ -n "$LOOP" ] || return 0' \
  'record_injection() {
  return 0
  [ -n "$LOOP" ] || return 0'
check run_inject_suite "I1 record_injection-neutered (no delivery row is ever written)" \
  "T33a T33b" \
  "T33c T33d T33e T33f T33i"

# I2 — the guard removed outright: --fresh types /clear into the live run again.
# The literal pre-t5fj behaviour, and the one that cost a context.
fresh_copy
mutate "$INJECT" \
  '  elif _same_loop_running "$WIN_NAME"; then' \
  '  elif false; then'
check run_inject_suite "I2 same-loop-guard-removed (the /clear lands in the live run)" \
  "T33b T33h" \
  "T33a T33c T33d T33e T33f T33g T33i"

# I3 — _turn_in_flight() vacuously true: an IDLE pane reads as mid-turn, so a
# --fresh loop with any delivery history can never tick again. The failure
# direction the header calls SAFE is still a failure, and it must be visible.
fresh_copy
mutate "$INJECT" \
  '_turn_in_flight() {
  [ "$1" != "${1#🧠}" ] && return 0' \
  '_turn_in_flight() {
  return 0
  [ "$1" != "${1#🧠}" ] && return 0'
check run_inject_suite "I3 turn-in-flight-vacuously-true (--fresh can never tick again)" \
  "T33c" \
  "T33a T33b T33d T33e T33i"

# I4 — the identity check dropped: ANY live turn in the pane is treated as this
# loop's. Two loops sharing a window would then permanently block each other.
fresh_copy
mutate "$INJECT" \
  '  if [ "$_sess" != "$SESSION" ] || [ "$_win" != "$WINDOW" ]; then' \
  '  if false; then'
# T33i, not T33d, is its detector — and that distinction is what this harness
# found: T33d's loop has NO delivery row at all, so it returns before the identity
# comparison is ever reached and the mutant SURVIVED a green 15-case suite. T33i
# was written in response (a recent row for THIS loop naming ANOTHER pane).
check run_inject_suite "I4 same-loop-identity-dropped (any live turn counts as ours)" \
  "T33i" \
  "T33a T33b T33c T33d T33e"

# I5 — the TTL dropped: a delivery row stays load-bearing forever, so one ancient
# row plus a busy pane refuses every future tick of that loop.
fresh_copy
mutate "$INJECT" \
  '  if [ "$_age" -gt "$SAME_LOOP_TTL" ]; then' \
  '  if false; then'
check run_inject_suite "I5 ttl-dropped (an ancient delivery row claims the live turn)" \
  "T33f" \
  "T33a T33b T33c T33d T33e T33i"

# I6 — the guard escapes its --fresh scope and starts refusing PLAIN ticks. A
# plain tick queueing behind a live turn is the composer working as designed;
# gating it turns a correct delivery into a bounce.
fresh_copy
mutate "$INJECT" \
  'if [ "$FRESH" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  if [ -z "$LOOP" ]; then' \
  'if [ "$WAS_WARM" = 1 ]; then
  if [ -z "$LOOP" ]; then'
check run_inject_suite "I6 guard-escapes-its---fresh-scope (plain ticks refused too)" \
  "T33e" \
  "T33a T33b T33c T33d T33f T33i"

# I7 — the failed-write WARN silenced back to a best-effort note (adversarial
# review). The delivery row is the only evidence a tick was delivered; a write
# that fails silently means the NEXT --fresh tick sees no row and proceeds — an
# unknown resolving to NOT-running, i.e. the original incident, with no trail.
# The residual cannot be closed retroactively, so LOUDNESS is the guard, and this
# mutant is what proves the loudness is real rather than documented.
#
# Note the `to` text: a bare `    return 0` occurs many times in this file, and
# the harness REFUSED that first attempt as a would-be no-op rather than running
# it — the applied-ness assertion doing its job on its own author. The
# replacement is the pre-review best-effort note, which is both unique and the
# honest restoration of the reviewed behaviour.
#
# Two mutants, because the loudness has two independent halves and either one
# going missing is the defect: I7 silences the machine-readable stdout marker,
# I8 silences the human-readable stderr sentence.
fresh_copy
mutate "$INJECT" \
  "    printf 'PULSE_INJECT_WARN=delivery-unrecorded\\n'
    return 0" \
  "    note \"injection-record failed (non-fatal)\"
    return 0"
check run_inject_suite "I7 write-failure-silent-stdout (no machine-readable WARN marker)" \
  "T33k" \
  "T33a T33b T33c T33d T33e T33f T33i T33j"

# I8 — the same residual, the other half: the operator-facing sentence goes to
# /dev/null. A marker with no explanation is nearly as useless as no marker.
fresh_copy
mutate "$INJECT" \
  'Fix the state dir." >&2' \
  'Fix the state dir." >/dev/null'
check run_inject_suite "I8 write-failure-silent-stderr (no operator-facing sentence)" \
  "T33k" \
  "T33a T33b T33c T33d T33e T33f T33i T33j"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The t5fj staleness guards are not guarded the way the suites claim."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
