#!/bin/bash
# Mutation harness for seat-molt.sh's SAFETY RAILS (dotfiles-it06).
#
#   bash agents/scheduler/mutate-seat-molt.sh [-v]
#
# WHY THIS EXISTS. seat-molt.sh decides WHETHER TO DESTROY A LIVE SESSION'S
# CONTEXT. Every one of its rails fails SILENTLY when it stops biting: a /clear
# into an un-offboarded session loses the arc and looks exactly like a
# successful molt; a send-keys into an open dialog answers Zig's question with
# the default and reports `molted`; a missing rate limit burns a subscription in
# a loop with every mechanical signal green; a skipped idle-wait types into a
# pane mid-turn. None of those turn anything red. Per this repo's rule 1, a
# green suite is not evidence that a guard bites — only a mutant that dies is,
# and this file is that evidence. tools/githooks/pre-commit is its caller.
#
# Modeled on mutate-tunnel-ownership.sh, deliberately and structurally: the five
# applied-ness assertions and the named-case check are that file's, not a
# re-derivation.
#
# ---------------------------------------------------------------------------
# THE PROPERTY THAT MAKES THIS HONEST: assert the mutation APPLIED.
# ---------------------------------------------------------------------------
# An unapplied mutation whose suite goes red for an unrelated reason is, BY EXIT
# CODE ALONE, indistinguishable from a mutant that died properly (dotfiles-47nf).
# So every mutation is checked five ways before its suite result means anything:
#
#   1. the target text occurs EXACTLY ONCE in the pristine file
#   2. the replacement occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed
#   4. the replacement occurs exactly once afterwards
#   5. `bash -n` is still clean (it dies of the bug it NAMES, not of a syntax
#      error that fails every case)
#
# Any failure there is a HARNESS ERROR, exited non-zero as such — never a kill.
# And a killed mutant must fail the case(s) it NAMES; several also assert cases
# that must keep PASSING, which is what distinguishes "this rail broke" from
# "the script broke" (dotfiles-77s4).
#
# COST, measured on this box: test-seat-molt.sh is ~43s a run (dotfiles-ygf8's
# four new --self cases add real wall time, mostly MOLT_SELF_IDLE_TIMEOUT
# waits), so baseline + 6 mutants is ~5.5 min. That is why pre-commit fires
# this on three files (the script, its suite, this harness) and not on every
# scheduler edit.
#
# ⚠️ NOT SAFE TO RUN CONCURRENTLY WITH ITSELF. Each suite run builds its own
# private tmux server on a socket inside its own mktemp dir, so it does not
# collide with test-seat-molt.sh — but two harnesses at once would put six tmux
# servers and a dozen fixture panes on the box for no benefit. pre-commit runs
# them sequentially; keep it that way.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of seat-molt.sh. `$REFUSE`, `${2:-0}`, `$(date +%s)` and
# friends inside them must NOT expand — they are matched byte-for-byte against
# the file on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-molt.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SM="seat-molt.sh"
SUITE="test-seat-molt.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$SM" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done
# Both the script and its suite resolve siblings through ../hooks and ../lib
# (portable.sh's _p_mtime, handoff-path.sh's per-window scoping). Symlink the
# real dirs beside the copy so the mutant is the ONLY difference from a real
# checkout — copying those trees would silently mutate what "unchanged" means.
ln -sfn "$SRC/../hooks" "$WORK/hooks"
ln -sfn "$SRC/../lib"   "$WORK/lib"

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$SM"    "$WORK/scheduler/$SM"
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

# mutate <file> <literal-from> <literal-to> — literal substring swap with all
# five applied-ness assertions. Fixed strings, never regexes: over-escaping a
# pattern is the exact failure this harness exists to make impossible.
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

# M1 — THE OFFBOARD-FRESHNESS RAIL REMOVED. The refusal is computed and then
# never acted on, so an un-offboarded, stale, or foreign-session pane is cleared
# anyway. This is the mutant that destroys un-recoverable context: nothing about
# the resulting `molted` verdict looks wrong.
fresh_copy
mutate "$SM" \
  'if [ -n "$REFUSE" ]; then' \
  'if [ -n "" ]; then'
# 26c/26d are named too (dotfiles-o3qj): with the rail gone the pane is CLEARED
# instead of refused, so no refusal row is written at all — and the row is what
# pulse-escalate's molt-refusal watcher reads. A rail that stops biting also stops
# leaving evidence, which is why the record cases belong in this mutant's list.
check "M1 offboard-freshness-rail-removed (clears un-offboarded context)" \
      "12 12n 13 13n 14 16 16n 24 24n 24m 26c 26d" "6 15"

# M2 — THE MODAL ABORT REMOVED. is_modal() always says no, so a 🔔 window gets
# send-keys: the text feeds the DIALOG and the trailing Enter answers Zig's open
# question with the default (pulse-inject.sh:692). Case 11 still fails, but as
# aborted-not-idle rather than aborted-modal — the dialog pane has no composer
# marker — which is why 11n (typed nothing) is NOT in the must-fail list.
fresh_copy
mutate "$SM" \
  'is_modal() { # <window-name> <pane-text>
  case "$1" in 🔔*) return 0 ;; esac' \
  'is_modal() { # <window-name> <pane-text>
  return 1
  case "$1" in 🔔*) return 0 ;; esac'
check "M2 modal-abort-removed (types into an open dialog)" \
      "10 10n 11 26g 26h" "6 9"

# M3 — THE RATE LIMIT REMOVED. The ledger is never consulted, so a window that
# molted a minute ago molts again: the molt loop, which costs a subscription and
# shows up as a series of perfectly successful cycles.
fresh_copy
mutate "$SM" \
  'if [ -f "$LEDGER" ]; then' \
  'if false; then'
check "M3 rate-limit-removed (the molt loop)" \
      "19 19n 26 26a 26b" "6 20 21"

# M4 — THE IDLE-WAIT SKIPPED. wait_for_idle returns success immediately, so the
# cycle types into a pane that is mid-turn. Cases 10/11 must keep PASSING: the
# post-idle modal re-check is a SEPARATE rail and still catches a dialog, which
# is exactly the distinction the two checks exist to draw. --self no longer
# calls wait_for_idle at ALL (dotfiles-ygf8 replaced it with the turn-end wait,
# see M6 below) — 9/9n is therefore the SOLE detector now, and 23/23n must keep
# PASSING as proof the two paths are genuinely split: this mutation cannot
# touch --self's outcome.
fresh_copy
mutate "$SM" \
  'wait_for_idle() {
  local timeout=$1 grace=${2:-0} t0 deadline eligible stable=0 name text' \
  'wait_for_idle() {
  return 0
  local timeout=$1 grace=${2:-0} t0 deadline eligible stable=0 name text'
# 26e/26f are the record half of 9/9n. 26h ALSO goes red and is deliberately NOT
# named: with the idle-wait skipped, the 🔔 pane is caught by the SEPARATE post-idle
# modal re-check, which records a different (and correct) reason sentence — the same
# "which rail caught it" distinction the case-11 note above draws, showing up in the
# record instead of in the verdict.
check "M4 idle-wait-skipped (types into a pane mid-turn)" \
      "9 9n 26e 26f" "6 10 11 23 23n"

# M6 — --self REVERTS TO PANE-STABILITY (dotfiles-ygf8, undoing THE fix). The
# --self branch calls wait_for_idle instead of wait_for_turn_end, exactly the
# pre-fix bug: a pane whose glyph never clears (a background builder, or here
# the fixture that never flips) can structurally never read as idle, so a
# --self molt that a fresh turn-end stamp should have released now times out
# instead. 23b is the scenario this whole bead exists for.
fresh_copy
mutate "$SM" \
  '  wait_for_turn_end "$IDLE_TIMEOUT" "$T0" "$SESSION_ID"' \
  '  wait_for_idle "$IDLE_TIMEOUT" 0  # MUTANT: self reverted to pane-stability'
check "M6 self-still-uses-pane-stability (the dead-idle-wait bug returns)" \
      "23b 23b2 23b3" "6 9 9n 10 11 23 23n"

# M5 — THE NON-VACUITY CHECK for the freshness cases. M1 removes the whole rail,
# which a suite could pass by merely noticing "the marker file exists". This one
# keeps the file check, the session-id check and the fail-closed branch intact
# and only stops the AGE from mattering — so case 13 (a 2h-old marker) is its
# SOLE detector, and 12/14/24 must keep passing. If 13 ever stops being written
# against a genuinely aged file, this mutant survives and says so.
fresh_copy
mutate "$SM" \
  '  OFFBOARD_AGE=$(( $(date +%s) - OFFBOARD_MTIME ))' \
  '  OFFBOARD_AGE=0'
check "M5 freshness-window-ignored (a year-old offboard reads as fresh)" \
      "13 13n" "6 12 14 15 24"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The safety rails in $SM are not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
