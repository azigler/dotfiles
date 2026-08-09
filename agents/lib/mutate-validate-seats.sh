#!/bin/bash
# Mutation harness for validate-seats.py's ROSTER-TRUTH rules: the GLYPH
# PROPERTY rule (dotfiles-gl6z) and the SEAT-TAP rule (Zig, 2026-08-09).
#
#   bash agents/lib/mutate-validate-seats.sh [-v]
#
# WHY THIS EXISTS. The rule this guards is the one that was already wrong once:
# for weeks the validator checked the emoji RANGE and the roster carried four
# Emoji_Presentation=No sigils, so `validate-seats: OK` was printed over a
# court view whose rows were visibly stilted. A green test-validate-seats.sh
# was true and meaningless the whole time — this repo's rule 1 in its purest
# form: only a mutant that dies is evidence.
#
# Every way the new rule can rot is SILENT in the same way:
#   * the property check disarmed  -> OK over text-default sigils again
#   * the data made fail-OPEN      -> exactly the No-list failure mode the
#                                     module comment argues against, and it
#                                     LOOKS like a working rule for every
#                                     glyph anyone happens to test
#   * a range dropped in a refresh -> good glyphs start being rejected, which
#                                     someone "fixes" by widening the rule
#
# Same discipline as agents/bin/mutate-orphan-reaper.sh and
# agents/scheduler/mutate-tunnel-ownership.sh: assert the target text occurs
# exactly once, assert the replacement is not already there, assert the bytes
# changed, assert the mutant still COMPILES (a mutant must die of the bug it
# names, not of a syntax error), and require it to fail the case(s) it NAMES.
#
# The suite runs against a scratch TREE, not the repo: $WORK/agents/lib/ plus a
# copy of the real agents/seats.yml, so test-validate-seats.sh's REAL-ROSTER
# case exercises the mutant against the roster the fleet actually ships.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"          # agents/lib
ROOT="$(cd "$SRC/../.." && pwd)"              # repo root
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-validate-seats.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SCRIPT_NAME="validate-seats.py"
SUITE_NAME="test-validate-seats.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/tree/agents/lib" "$WORK/pristine"
for f in "$SCRIPT_NAME" "$SUITE_NAME"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done
[ -f "$ROOT/agents/seats.yml" ] || { echo "HARNESS ERROR: $ROOT/agents/seats.yml does not exist" >&2; exit 2; }
cp -a "$ROOT/agents/seats.yml" "$WORK/tree/agents/seats.yml"

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$SCRIPT_NAME" "$WORK/tree/agents/lib/$SCRIPT_NAME"
  cp -a "$WORK/pristine/$SUITE_NAME"  "$WORK/tree/agents/lib/$SUITE_NAME"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/tree/agents/lib/$SUITE_NAME" 2>&1)
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
  local path="$WORK/tree/agents/lib/$file" pristine="$WORK/pristine/$file"

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
  if ! python3 -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$path"; then
    harness_error "$file: the mutant does not compile -- it would fail every case for the wrong reason"
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

# M1 -- the property check itself disarmed. This is the PRE-gl6z validator,
# exactly: block ban + denylist and nothing else, so all four text-default
# sigils and an ASCII 'x' sail through, and the rendered-output rule
# (glyph_violation) stops catching anything. The replacements must still pass
# -- a mutant that rejected everything would also go red, and would prove
# nothing.
fresh_copy
mutate "$SCRIPT_NAME" \
  '        if not is_emoji_presentation(cp):' \
  '        if False and not is_emoji_presentation(cp):'
check "M1 property-check-disarmed (back to the range rule)" \
  "SIGIL-EPRES-KEY SIGIL-EPRES-SHIELD SIGIL-EPRES-CANDLE SIGIL-EPRES-DOVE SIGIL-ASCII GLYPH-VS-SIGIL" \
  "SIGIL-EPRES-GOOD REAL-ROSTER"

# M2 -- the data made FAIL-OPEN. `unknown codepoint => accepted, if it looks
# emoji-ish` is precisely the No-list design the module comment rejects, and it
# is the seductive one: every emoji anyone spot-checks still passes, only the
# text-default ones inside the blocks are silently readmitted. ASCII is still
# refused (it is below the cutoff), which is why SIGIL-ASCII must keep passing
# -- that asymmetry is the mutant's signature.
fresh_copy
mutate "$SCRIPT_NAME" \
  '            return True
    return False' \
  '            return True
    return cp >= 0x1F000'
check "M2 data-fails-open (No-list semantics restored)" \
  "SIGIL-EPRES-KEY SIGIL-EPRES-SHIELD SIGIL-EPRES-CANDLE SIGIL-EPRES-DOVE GLYPH-VS-SIGIL" \
  "SIGIL-ASCII SIGIL-EPRES-GOOD REAL-ROSTER"

# M3 -- a RANGE dropped, as a botched data refresh would. U+1FA90-U+1FABD
# holds 🪶 (U+1FAB6), the Envoy's new sigil, so the roster the fleet ships
# stops validating -- and the suite must say so through the REAL-ROSTER case,
# not only through a fixture. The four text-default cases must keep passing:
# this mutant is about the data being load-bearing, not about the rule.
fresh_copy
mutate "$SCRIPT_NAME" \
  '(0x1FA90, 0x1FABD)' \
  '(0x1FA90, 0x1FA90)'
check "M3 data-range-dropped (refresh regression)" \
  "SIGIL-EPRES-GOOD REAL-ROSTER" \
  "SIGIL-EPRES-KEY SIGIL-ASCII"

# M4 -- the SEATTAP rule made presence-optional, written the way the "be
# lenient, personal IS the default anyway" instinct writes it: default the
# missing value instead of refusing it. A seat with NO tap sails through while
# an undeclared one is still caught, so the rule keeps LOOKING like it works —
# and the roster goes back to a file you have to infer defaults from, which is
# the thing Zig's 2026-08-09 ruling is against. The unknown-tap case must keep
# passing: that asymmetry is this mutant's signature.
#
# (The obvious mutant — disarming `if tap is None:` — is a NO-OP here, because
# the `elif tap not in taps` arm catches None anyway. Recorded because a
# no-op mutant that "survives" reads exactly like a missing guard.)
fresh_copy
mutate "$SCRIPT_NAME" \
  '        tap = seat.get("tap")' \
  '        tap = seat.get("tap") or "personal"'
check "M4 seat-tap-presence-optional" \
  "SEATTAP-MISSING" \
  "SEATTAP-UNKNOWN SIGIL-EPRES-GOOD REAL-ROSTER"

# M5 -- the UNIT/UNIT-ORPHAN strict promotion silently disarmed (dotfiles-hfm5).
# The whole point of --strict-units is that it turns the same WARN findings
# into a block. A mutant that stops appending `uviol` to `errors` under
# strict mode makes it a no-op flag -- exactly the shape this bead's own
# caution warns about, just inverted: not a validator that flakes, one that
# goes quiet forever under the flag meant to make it strict. Case 11 and 14
# both invoke --strict-units expecting a non-zero exit and a tagged
# violation; under this mutant they get exit 0 instead, which the harness
# reads back as those two named cases (UNIT, UNIT-ORPHAN). Case 12 (warn
# mode) and case 13/15 (already-passing strict cases) are untouched by this
# mutant and must keep passing -- that asymmetry is the signature.
fresh_copy
mutate "$SCRIPT_NAME" \
  '        if strict_units:
            errors += uviol' \
  '        if False and strict_units:
            errors += uviol'
check "M5 strict-units-promotion-disarmed" \
  "UNIT UNIT-ORPHAN" \
  "REAL-ROSTER"

# M6 -- the FAILOVER cross-type check disarmed (dotfiles-kf2i, spec d3ky).
# d3ky's own rule is "same-TYPE failover is free; cross-type failover
# FORBIDDEN v1" -- this is the ONE clause among FAILOVER's three that is
# actually new policy (the empty/null and unknown-target checks are the same
# shape as every other "name a real X" rule already guarded elsewhere). A
# mutant that turns `target_type != ttype` into an always-false comparison
# lets a seat's charter work silently fail over to a different vendor
# mid-loop -- exactly the "silent-quality event" the rule's own error text
# names. The empty/null and unknown-target cases are untouched by this
# mutant and must keep passing -- that asymmetry is the signature.
fresh_copy
mutate "$SCRIPT_NAME" \
  '            if target_type != ttype:' \
  '            if target_type != ttype and False:'
check "M6 failover-cross-type-disarmed" \
  "FAILOVER" \
  "REAL-ROSTER"

# M7 -- SIGIL-UNIQUE's own-name exclusion widened into a full disarm
# (dotfiles-e8l0). The guard is `sigil_owner[sigil] != seat_name` -- narrowing
# it to `!= None` (i.e. "never equal, always flag or never flag") is the wrong
# shape to catch directly, so instead this mutant disarms the check outright,
# the same silent-rot mode as M1/M5/M6: the court's glyph column goes back to
# ambiguous the moment two seats collide, and validate-seats keeps printing OK.
fresh_copy
mutate "$SCRIPT_NAME" \
  '        if sigil in sigil_owner and sigil_owner[sigil] != seat_name:' \
  '        if False and sigil in sigil_owner and sigil_owner[sigil] != seat_name:'
check "M7 sigil-unique-disarmed" \
  "SIGIL-UNIQUE" \
  "SIGIL-EPRES-GOOD REAL-ROSTER"

# M8 -- SEATTAP-CONSISTENCY disarmed outright (dotfiles-e8l0): a seat's own
# tap and its schedules' taps can silently disagree again, the exact drift
# this bead was filed against ("a seat could declare tap: personal while its
# schedules bind work"). Same disarm shape as M6/M7 (`and False`) rather than
# an inversion -- SEATTAP-CONSISTENCY's condition is true on the COMMON path
# (every well-formed seat has sched_tap == seat_tap), so flipping it to
# require EQUALITY instead breaks every fixture in the suite, not just this
# rule's own case -- exactly the "red-somewhere, not red on the case it
# names" trap rule 1 in this repo's CLAUDE.md warns about.
fresh_copy
mutate "$SCRIPT_NAME" \
  '                and sched_tap != seat_tap' \
  '                and sched_tap != seat_tap and False'
check "M8 seattap-consistency-disarmed" \
  "SEATTAP-CONSISTENCY" \
  "SIGIL-EPRES-GOOD REAL-ROSTER"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR -- at least one mutation never applied. ========"
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The glyph property rule in $SCRIPT_NAME is not guarded the way the"
  echo "    suite claims. See dotfiles-gl6z."
  exit 1
fi
echo "=== RESULT: all mutants died on the cases they name. ====================="
