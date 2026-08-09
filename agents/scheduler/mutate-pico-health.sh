#!/bin/bash
# Mutation harness for pico-health.sh's FINDING logic.
#
#   bash agents/scheduler/mutate-pico-health.sh [-v]
#
# WHY THIS EXISTS. pico-health.sh decides WHETHER THE WORKS ARE FINE, and every
# way it can be wrong is silent. A watcher that reports `ok` past a failing job,
# past an unreachable host, past a listener nobody documented, or past a verdict
# it never wrote down, does not error — it exits 0 and everybody relaxes. That
# is precisely the state pico was in for two months before the 2026-08-09 audit:
# green-looking, unread, and wrong.
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites; only
# a mutant that dies is. test-pico-health.sh is green by construction — it was
# written alongside the checker. This file is the evidence that its cases are
# load-bearing, and tools/githooks/pre-commit is its consumer.
#
# Modelled on mutate-tunnel-ownership.sh, INCLUDING its two hard-won properties:
#
#   1. ASSERT THE MUTATION APPLIED. Every mutation is checked five ways before
#      its suite result is allowed to mean anything — target present exactly
#      once, replacement absent, bytes changed, replacement present exactly once
#      after, `bash -n` still clean. Any failure is a HARNESS ERROR, never a
#      killed mutant: an over-escaped pattern that matches nothing produces a red
#      suite too, and by exit code alone the two are indistinguishable
#      (dotfiles-47nf).
#   2. A KILLED MUTANT MUST DIE ON THE CASES IT NAMES. Red-somewhere says nothing
#      about the guard under test and is usually evidence the mutant broke
#      something else (dotfiles-77s4).
#
# Fixed strings, never regexes: over-escaping a pattern is the exact failure this
# design makes impossible, so there is no pattern to over-escape.
#
# SAFE TO RUN ANY TIME. Unlike the tunnel harness, nothing here touches a real
# process, a real host or a real port — test-pico-health.sh is hermetic behind
# the $PICO_SSH stub — so concurrent runs cannot adopt each other's fixtures.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)" # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-pico-health.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

CHK="pico-health.sh"
SUITE="test-pico-health.sh"
MANIFEST="pico-ports.manifest"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$CHK" "$SUITE" "$MANIFEST"; do
  [ -f "$SRC/$f" ] || {
    echo "HARNESS ERROR: $SRC/$f does not exist" >&2
    exit 2
  }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

# The suite finds both the checker and the manifest via `dirname $0`, so the
# copy is self-contained and the real tree is never edited.
fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$CHK" "$WORK/scheduler/$CHK"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
  cp -a "$WORK/pristine/$MANIFEST" "$WORK/scheduler/$MANIFEST"
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

# M1 — FINDING SUPPRESSED. The failing-job filter made vacuous, so a job that
# ran and exited non-zero never registers. This IS the two-month bug, expressed
# in the watcher instead of in launchd: a column that is read and then ignored is
# worth exactly as much as a column nobody reads.
fresh_copy
mutate "$CHK" \
  "FAILED_JOBS=\$(rows JOB | awk -F'\t' '\$3 > 0 && \$2 == \"-\" { print \$4 \" (exit \" \$3 \")\" }' | sort)" \
  "FAILED_JOBS=\$(rows JOB | awk -F'\t' '\$3 > 9999 && \$2 == \"-\" { print \$4 \" (exit \" \$3 \")\" }' | sort)"
check "M1 finding-suppressed (failing launchd jobs never register)" "2 12 14" "1 3 4"

# M2 — UNREACHABLE READS OK. The ssh-failure path reports a healthy host. The
# most dangerous mutant in the file and the cheapest one to write by accident:
# "we could not ask" and "the answer was fine" become the same output, which is
# the vs14d contract's founding complaint (`exit 0, no verdict`).
fresh_copy
mutate "$CHK" \
  '  VERDICT="unreachable"
  exit 10
}' \
  '  VERDICT="ok"
  exit 0
}'
check "M2 unreachable-reads-ok (a dead works reports healthy)" "11" "1"

# M3 — MANIFEST DIFF IGNORED, in the UNEXPECTED direction only. The romd/RomM
# stack ran undocumented for months; this mutant is that blindness made
# permanent. Case 9 must keep PASSING — the missing-listener direction is
# untouched — which is what shows case 8 detects the unexpected direction
# specifically rather than "the port section ran at all".
fresh_copy
mutate "$CHK" \
  'if [ "$M_PORTS_UNEXPECTED" -gt 0 ]; then' \
  'if [ "$M_PORTS_UNEXPECTED" -gt 99 ]; then'
check "M3 manifest-diff-ignored (the next undocumented listener walks in)" "8" "9 1"

# M4 — THE FROZEN PWA GOES UNNOTICED. The state-age comparison put out of reach,
# so a document that has not moved in a week reads exactly like a fresh one —
# the single finding of the audit that was hardest to see by eye.
fresh_copy
mutate "$CHK" \
  'if [ "$M_STATE_AGE_H" -gt "$STATE_MAX_AGE_H" ]; then' \
  'if [ "$M_STATE_AGE_H" -gt 999999 ]; then'
check "M4 stale-state-unnoticed (a 7-day-frozen document reads fresh)" "6 12" "1"

# M5 — THE VERDICT IS NEVER WRITTEN DOWN. The ledger append dropped from the
# exit path. Every verdict then lives only in a user journal that holds ~6h, so
# the record of a failing night is gone before anyone is awake to read it — and
# nothing about the run looks any different.
fresh_copy
mutate "$CHK" \
  '  rc=$?
  ledger_append' \
  '  rc=$?
  : # ledger_append'
check "M5 verdict-not-durable (the ledger append silently dropped)" "14 15" "1"

# M6 — A DYNAMIC ENTRY BECOMES A WILDCARD. The process name dropped from the
# match, so `127.0.0.1:dynamic` stops meaning "limactl's ephemeral control port"
# and starts meaning "anything at all on a loopback ephemeral port". That is the
# manifest failing OPEN — the exact way the ephemeral-port fix (dotfiles-c9yi)
# could have bought quiet at the cost of the guard. Case 24 must keep passing:
# the range check is a different clause and M8 is its mutant.
fresh_copy
mutate "$CHK" \
  'if (host == raddr[i] && proc == rproc[i] && port + 0 >= emin && port + 0 <= emax) {' \
  'if (host == raddr[i] && port + 0 >= emin && port + 0 <= emax) {'
check "M6 dynamic-entry-is-a-wildcard (any process launders itself)" "22" "1 21 23 24"

# M7 — THE VOID CACHE IS REPORTED ANYWAY. The build comparison made vacuous, so
# a softwareupdate count measured on the PREVIOUS macOS build is served as
# current. This is dotfiles-c9yi verbatim: six hours of "macOS Sonoma 14.8.9;
# macOS Tahoe 26.6.1 pending" against a live `softwareupdate -l` on the same box
# that showed neither, because the upgrade that consumed them left the cache's
# 20h clock untouched.
fresh_copy
mutate "$CHK" \
  '  if [ "$SU_CACHE_BUILD" != "$OS_BUILD" ]; then' \
  '  if [ 1 = 0 ]; then'
check "M7 void-cache-reported (an OS upgrade leaves the cached count standing)" "25" "1 10 19 26"

# M8 — THE EPHEMERAL RANGE OPENED TO EVERY PORT. A dynamic entry then whitelists
# a SERVICE port by naming its process, which is a manifest line that documents
# nothing. Case 22 must keep passing: the process clause still bites.
fresh_copy
mutate "$CHK" \
  'port + 0 >= emin && port + 0 <= emax' \
  'port + 0 >= 1 && port + 0 <= 65535'
check "M8 ephemeral-range-opened (a dynamic entry whitelists a service port)" "24" "1 21 22 23"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The finding logic in $CHK is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
