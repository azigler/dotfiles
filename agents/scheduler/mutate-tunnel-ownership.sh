#!/bin/bash
# Mutation harness for ensure-fleet-tunnel.sh's OWNERSHIP logic.
#
#   bash agents/scheduler/mutate-tunnel-ownership.sh [-v]
#
# WHY THIS EXISTS. ensure-fleet-tunnel.sh decides WHICH PROCESS TO KILL, and it
# runs on marketing-vps — a box shared with four other human accounts and with
# two of these tunnels live at once (the fleet proxy on 7100, pico's agentgateway
# on 17017). A target-blind pgrep pattern there does not fail a test, it kills
# somebody else's forward mid-dispatch. That was observed live during
# dotfiles-47nf: with the pattern stopped at the local port, bringing up tunnel B
# printed `closed our local forward (pid …)` against tunnel A.
#
# The four mutants below were proven to bite by a THROWAWAY harness written in a
# scratchpad and then discarded, which left the next edit to this logic with a
# green 28-case suite and no mutant check. Per this repo's rule 1: a green suite
# is not evidence that a guard bites; only a mutant that dies is. This file is
# that evidence, and tools/githooks/pre-commit is its consumer.
#
# ---------------------------------------------------------------------------
# THE PROPERTY THAT MAKES THIS HARNESS HONEST: assert the mutation APPLIED.
# ---------------------------------------------------------------------------
# The 47nf agent's first attempt over-escaped a sed pattern, so the mutant
# matched nothing and the file was never touched. The suite failed anyway (for an
# unrelated reason) and BY EXIT CODE ALONE that is indistinguishable from a
# mutant that died properly. So every mutation here is checked five ways before
# its suite result is allowed to mean anything:
#
#   1. the target text occurs EXACTLY ONCE in the pristine file  (it still exists)
#   2. the replacement text occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed                          (it was written)
#   4. the replacement occurs exactly once afterwards             (fully applied)
#   5. `bash -n` is still clean                                   (it died of the
#      bug it NAMES, not of a syntax error that fails every case)
#
# A failure of any of those is a HARNESS ERROR — reported and exited non-zero as
# such, never as a killed mutant. That distinction is the whole point: a mutant
# that "dies" without applying is a false pass of the harness itself.
#
# And a killed mutant must die on the cases it names. The suite's header carries
# a measured mutant -> case map; this harness ASSERTS it rather than trusting the
# comment, so a mutant killed only by some unrelated assertion is visible instead
# of reassuring.
#
# ⚠️ NOT SAFE TO RUN CONCURRENTLY WITH test-ensure-fleet-tunnel.sh. The suite's
# ownership cases use a real pgrep against real stand-in processes, keyed on a
# synthetic peer name that is the SAME in every run. Two copies at once adopt
# each other's fixtures. pre-commit runs them sequentially; keep it that way.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of ensure-fleet-tunnel.sh. `$PORT`, `$(re_escape …)` and
# friends inside them must NOT expand — they are matched byte-for-byte against
# the file on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"        # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-tunnel.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

EFT="ensure-fleet-tunnel.sh"
SUITE="test-ensure-fleet-tunnel.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$EFT" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

# fresh_copy — a pristine ensure-fleet-tunnel.sh + its suite in $WORK/scheduler.
# The suite finds the script via `dirname $0`, so the copy is self-contained and
# the real tree is never edited.
fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$EFT" "$WORK/scheduler/$EFT"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
}

# run_suite -> rc, output in $SUITE_OUT
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
# Literal substring swap with all five applied-ness assertions above. Fixed
# strings, never regexes: over-escaping a pattern is the exact failure this
# harness was written to make impossible, so there is no pattern to over-escape.
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
# Expects the suite to FAIL, on the named cases. `must-PASS` is how a mutant
# asserts it broke ownership WITHOUT collapsing into a different failure — see
# M5, which must leave the recorded pids non-empty.
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
    echo "           (this mutant is meant to break ownership while leaving those intact)"
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

# M1 — FORWARD_PAT made TARGET-BLIND. This is the cross-kill, and it is the one
# that was demonstrated LIVE: with the pattern stopped at the local port,
# bringing tunnel B up printed "closed our local forward (pid …)" at tunnel A.
fresh_copy
mutate "$EFT" \
  'FORWARD_PAT="ssh .*-L 127\.0\.0\.1:$PORT:$(re_escape "$TARGET") $(re_escape "$PEER")\$"' \
  'FORWARD_PAT="ssh .*-L .* $PEER\$"'
check "M1 forward-pat-target-blind (the cross-kill)" "23 24 25 26 27 28"

# M2 — the PRE-GENERALIZATION pattern, restored verbatim: the target hardwired to
# 127.0.0.1:$PORT. B's pgrep then matches nothing, B's pidfile lands empty, and
# ownership of the gateway tunnel is simply lost — it leaks instead of closing.
fresh_copy
mutate "$EFT" \
  'FORWARD_PAT="ssh .*-L 127\.0\.0\.1:$PORT:$(re_escape "$TARGET") $(re_escape "$PEER")\$"' \
  'FORWARD_PAT="ssh .*-L 127\.0\.0\.1:$PORT:127\.0\.0\.1:$PORT $PEER\$"'
check "M2 forward-pat-hardwired-to-127.0.0.1:PORT (pre-generalization)" "23 24 25 26 27 28"

# M3 — ONE SHARED PIDFILE for every tunnel. Same defect as a target-blind
# pattern, by a different road: the gateway tunnel writes its pid where the fleet
# tunnel reads it, so `down` kills a forward it does not own.
fresh_copy
mutate "$EFT" \
  'PIDFILE="$STATE_DIR/local-forward-$TUNNEL_SLUG.pid"' \
  'PIDFILE="$STATE_DIR/local-forward.pid"'
check "M3 one-shared-pidfile-for-all-tunnels" "10 23 24 25 26 27 28"

# M4 — re_escape neutered to an IDENTITY function, so an unescaped `.` in the
# target is an ERE wildcard. THIS IS WHY THE HARNESS MATTERS: it survived the
# suite 26/26 before case 28 was written, because 127.0.0.1 and 100.72.47.4 are
# different lengths and nothing else depended on the escaping. Measured live: the
# unescaped pattern matched TWO forwards (`3210491 3210539`) where the escaped
# one matched exactly one. Case 28 is its sole detector, which is exactly the
# shape of finding that a green suite cannot give you.
fresh_copy
mutate "$EFT" \
  're_escape() {
  local s=$1 out="" c i' \
  're_escape() {
  printf '"'"'%s'"'"' "$1"; return 0
  local s=$1 out="" c i'
check "M4 re_escape-neutered-to-identity" "28"

# M5 — the NON-VACUITY check for cases 24-28.
#
# Those cases assert `[ -n "$A_PID" ]` because a mutant that loses ownership can
# leave the pid variable EMPTY, `alive ""` then reads as "dead", and the case
# passes VACUOUSLY — M2 passed case 26 that way once. The guards turn that into a
# failure, but they raise a fair question: are 24-28 now detecting ownership, or
# only detecting empty strings? So this mutant breaks ownership while leaving
# BOTH pidfiles correct and both pids non-empty — case 23 must keep PASSING,
# which is precisely the assertion that the emptiness guards are not doing the
# work.
#
# Note which mutation achieves that, because the obvious one does not: pointing
# `our_pid`'s discovery pgrep at a target-blind pattern (leaving the NEWPID write
# correct) ALSO reddens case 23 — bringing tunnel B up finds A by discovery,
# takes the recycle path and kills A before the case ever runs. That is the live
# cross-kill again, not an isolated probe. `tunnel_down` is the place where
# ownership can be broken without disturbing setup: both tunnels come up
# normally, then `down A` kills B.
fresh_copy
mutate "$EFT" \
  'tunnel_down() {
  local p
  if p=$(our_pid); then' \
  'tunnel_down() {
  local p
  if p=$(pgrep -n -f "ssh .*-L .* $PEER\$" 2>/dev/null); then'
check "M5 tunnel_down-target-blind (both pids stay CORRECT and non-empty)" \
      "24 25 27 28" "23"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The ownership logic in $EFT is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
