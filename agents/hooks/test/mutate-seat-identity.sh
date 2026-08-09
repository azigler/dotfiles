#!/bin/bash
# Mutation harness for the WAKE-TIME SEAT IDENTITY injection (dotfiles-z10i).
#
#   bash agents/hooks/test/mutate-seat-identity.sh [-v]
#
# WHY THIS EXISTS. session-start.sh runs at every session start on the whole
# fleet, and the two properties this feature must hold are both SILENT when
# broken:
#
#   silent-skip        an unresolvable window must add NOTHING — no refusal, no
#                      blank line. seat_resolve is loud BY DESIGN (it is an
#                      operator command that must never guess), so the only
#                      thing standing between a scratch window and a 🚫 on
#                      every session start is one `--quiet`.
#   never-guess        a window that is not a seat must resolve to NO seat.
#                      A one-word fallback turns every unregistered window into
#                      a fabricated office — an identity the roster never
#                      granted, printed as fact.
#
# Neither turns anything red. Per this repo's rule 1, a green suite is not
# evidence that a guard bites; only a mutant that dies is. Modelled on
# agents/scheduler/mutate-tunnel-ownership.sh, including its two hard-won
# clauses: ASSERT THE MUTATION APPLIED (an unapplied mutation over a red suite
# is indistinguishable from a kill, by exit code alone), and A KILLED MUTANT
# MUST FAIL THE CASE(S) IT NAMES (red-somewhere says nothing about the guard
# under test).
#
# Two more mutants cover the CACHE, whose both failure directions are equally
# quiet: never expiring serves last month's office forever, never hitting pays
# the full ~200ms compose in every session on the machine. Neither changes a
# single byte of what the header SAYS.
#
# Measured on this box:
#   test-session-start-seat-identity.sh   ~5s
#   this harness (6 mutants + baseline)   ~40s

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of the file it patches. `$_SI_OUT`, `$(seat_self_name …)` and
# friends must NOT expand — they are matched byte-for-byte against the file on
# disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")/../.." && pwd)"      # agents/
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-seat-identity.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

HOOK="hooks/session-start.sh"
COMP="lib/seat-identity.sh"
SUITE="hooks/test/test-session-start-seat-identity.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

# One full copy of the two dirs the suite rebuilds its fixture tier from; the
# real tree is never edited.
mkdir -p "$WORK/agents" "$WORK/pristine"
cp -r "$SRC/hooks" "$WORK/agents/hooks"
cp -r "$SRC/lib"   "$WORK/agents/lib"
for f in "$HOOK" "$COMP" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  mkdir -p "$WORK/pristine/$(dirname "$f")"
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  local f
  for f in "$HOOK" "$COMP" "$SUITE"; do
    cp -a "$WORK/pristine/$f" "$WORK/agents/$f"
  done
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/agents/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file-rel> <literal-from> <literal-to> — literal substring swap with
# the same five applied-ness assertions mutate-tunnel-ownership.sh documents:
# target present exactly once, replacement absent, bytes changed, replacement
# present exactly once, still valid bash.
mutate() {
  local file=$1 from=$2 to=$3
  local path="$WORK/agents/$file" pristine="$WORK/pristine/$file"

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

# check <mutant-name> <must-FAIL case ids> [<must-PASS case ids>]
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite; then
    echo "SURVIVED  $name  (the suite is still green)"
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
  echo "  ok      $(printf '%s\n' "$SUITE_OUT" | tail -1)"
else
  echo "  BROKEN  the suite is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — SILENT-SKIP BROKEN. Drop the --quiet, and seat_resolve's operator-facing
# refusal ("🚫 seat: window 'personal' is NOT a registered seat", plus the whole
# roster listing) lands in the context of every session whose window is not a
# seat. R1/U1 must keep passing: a real seat still resolves, and a window the
# roster never mentions is still gated out before the composer runs at all.
fresh_copy
mutate "$COMP" \
  '    seat=$(seat_self_name --quiet) || return 1' \
  '    seat=$(seat_self_name) || return 1'
check "M1 silent-skip-broken (--quiet dropped)" "P1 P3 C1" "R1 U1"

# M2 — IDENTITY INJECTED FOR AN UNREGISTERED WINDOW. The refusal becomes a
# guess: the window name itself is used as the seat. The header then prints an
# office the roster never granted ("· personal — (unrecorded)") plus the
# constitution pointer, as fact. This is the failure mode seat-resolve.sh's R5
# exists to prevent, re-introduced one layer up in the consumer.
fresh_copy
mutate "$COMP" \
  '    seat=$(seat_self_name --quiet) || return 1' \
  '    seat=$(seat_self_name --quiet) || seat="${SEAT_WINDOW:-}"'
check "M2 identity-injected-for-unregistered (guess the seat)" "P1 P3 C1" "R1 U1"

# M3 — THE COST GATE REMOVED. Everything still LOOKS right — the header is
# correct, the silence is correct — but the composer (bash + python3 + a roster
# parse) now spawns on every session start on the machine, including every
# window that will never be a seat. Only G1 can see it, which is exactly why
# case 6 records the stub's own invocations instead of trusting a comment.
# (G2 falls with it — the stub log then holds the unregistered run's entry too,
# so the "exactly once" count is 2. That is a consequence of G1, not a second
# detector, which is why only G1 is named.)
fresh_copy
mutate "$HOOK" \
  '  if [ -r "$_SI_LIB" ] && [ -r "$_SI_ROSTER" ] \
     && grep -qF -- "$SESSION_WINDOW" "$_SI_ROSTER"; then' \
  '  if [ -r "$_SI_LIB" ] && [ -r "$_SI_ROSTER" ]; then'
check "M3 precheck-dropped (composer spawned for every window)" "G1" "R1 U1 P1"

# M4 — THE EMPTINESS GUARD REMOVED, so a composer that resolved nothing still
# emits its leading blank line. A marker grep cannot see that; P3's
# byte-identical comparison is its SOLE detector, and this mutant is the proof
# that P3 is not decoration.
fresh_copy
mutate "$HOOK" \
  '    if [ -n "$_SI_OUT" ]; then
      echo ""' \
  '    if true; then
      echo ""'
check "M4 emptiness-guard-dropped (stray blank line)" "P3" "R1 U1 P1 G1"

# M5 — THE CACHE NEVER EXPIRES. The header keeps printing, correctly formatted,
# forever: a new laurel never appears, a renamed office never appears, and an
# edit to the composer itself never takes effect on any box that already has a
# warm cache. Nothing anywhere goes red — the only symptom is an identity that
# quietly stopped tracking the roster.
fresh_copy
mutate "$HOOK" \
  '      _SI_WARM=1
      while IFS= read -r _SI_DEP; do
        [ -n "$_SI_DEP" ] || continue
        if [ "$_SI_DEP" -nt "$_SI_HDR" ]; then _SI_WARM=0; break; fi
      done < "$_SI_DEPS"' \
  '      _SI_WARM=1   # mutant: dep freshness never checked'
check "M5 cache-never-expires (stale header served forever)" "X3 X2c" "R1 X1 X2 X2b"

# M6 — THE CACHE NEVER HITS. The mirror image, and the reason X2b watches for a
# `python3` that should not run: the header is still right, so nothing looks
# wrong, while every session on the machine pays the full ~200ms compose for an
# answer that changes about weekly.
fresh_copy
mutate "$HOOK" \
  '    if [ -s "$_SI_HDR" ] && [ -s "$_SI_DEPS" ] \' \
  '    if false && [ -s "$_SI_DEPS" ] \'
check "M6 cache-never-hits (full compose every session)" "X2 X2b" "R1 X1 X3"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The wake-time identity injection is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
