#!/bin/bash
# Mutation harness for pre-ask-user-question-seat-guard.sh (dotfiles-9i39).
#
#   bash agents/hooks/test/mutate-ask-user-question-guard.sh [-v]
#
# WHY THIS EXISTS. This guard sits on a tool EVERY session on the machine uses,
# and both directions it can rot in are silent:
#
#   fail closed   an unreadable roster, an unknown verdict, or a widened tool
#                 belt turns "I cannot tell" into "no one may ask Zig anything".
#                 Nothing errors; questions simply stop working fleet-wide.
#   fail open     the mark is read leniently or the block stops routing, and the
#                 2026-08-09 freeze comes back — a 🔔 in a scheduled window that
#                 pulse-inject then defers behind, indefinitely.
#
# And a third that is neither: the block message losing its REDIRECT. A block
# that only denies invites a retry or a stall, and a stalled seat in a scheduled
# window is the same freeze by another route. M4 is that mutant, and B3/B6a are
# its only detectors — every other case stays green while the guard turns into a
# dead end.
#
# Per this repo's rule 1, a green suite is not evidence that a guard bites; only
# a mutant that dies is. Modelled on agents/scheduler/mutate-tunnel-ownership.sh
# (and its sibling agents/hooks/test/mutate-seat-identity.sh), including both
# hard-won clauses: ASSERT THE MUTATION APPLIED — an unapplied mutation over a
# red suite is indistinguishable from a kill by exit code alone — and A KILLED
# MUTANT MUST FAIL THE CASE(S) IT NAMES.
#
# Measured on this box:
#   test-pre-ask-user-question-seat-guard.sh   ~7s
#   this harness (6 mutants + baseline)        ~50s

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of the file it patches. `$_AQ_ROSTER`, `$(seat_roster_path)`
# and friends must NOT expand — they are matched byte-for-byte against the file
# on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")/../.." && pwd)"      # agents/
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-aq-guard.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

HOOK="hooks/pre-ask-user-question-seat-guard.sh"
SUITE="hooks/test/test-pre-ask-user-question-seat-guard.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

# One full copy of the two dirs the suite rebuilds its fixture tier from; the
# real tree is never edited.
mkdir -p "$WORK/agents" "$WORK/pristine"
cp -r "$SRC/hooks" "$WORK/agents/hooks"
cp -r "$SRC/lib"   "$WORK/agents/lib"
for f in "$HOOK" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  mkdir -p "$WORK/pristine/$(dirname "$f")"
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  local f
  for f in "$HOOK" "$SUITE"; do
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
# the five applied-ness assertions mutate-tunnel-ownership.sh documents: target
# present exactly once, replacement absent, bytes changed, replacement present
# exactly once, still valid bash.
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

# M1 — FAIL CLOSED ON A MISSING REGISTRY. The one-character version of "if I
# cannot tell, be safe", which is precisely backwards here: a machine with no
# agents/seats.yml (a fresh clone, a jailed tick, a foreign repo) would lose
# AskUserQuestion entirely, in every window, with a 🚫 that names a roster the
# reader does not have. A4 is its sole detector.
fresh_copy
mutate "$HOOK" \
  '_AQ_ROSTER=$(seat_roster_path) || exit 0' \
  '_AQ_ROSTER=$(seat_roster_path) || exit 2'
check "M1 fail-closed-on-missing-registry" "A4" "B1 A1 A5 A10 C1"

# M2 — BLOCK EVERY SEAT. The registry lookup still runs, its answer is simply
# ignored: every window that resolves to ANY seat is refused, whether the roster
# marks it or not. This is the scoping the design comment promises ("interactive
# windows are NEVER touched") deleted in one line, and nothing about the block
# message changes — the seat name in it is even correct.
fresh_copy
mutate "$HOOK" \
  '    if row.get("interactive") is False:' \
  '    if True:'
check "M2 block-every-seat (the mark ignored)" "A1 A7 A8" "B1 A2 A4 C1"

# M3 — THE MARK READ LENIENTLY. `interactive: "false"` (a STRING — the shape a
# hand-edit produces) starts blocking. The direction matters: a lenient read
# means the roster can gate a seat by ACCIDENT, and the accident is invisible
# because validate-seats.py has no opinion on this key's type. A8 is its sole
# detector, which is why A8 is not decoration.
fresh_copy
mutate "$HOOK" \
  '    if row.get("interactive") is False:' \
  '    if str(row.get("interactive")).lower() == "false":'
check "M3 mark-read-leniently (truthiness instead of identity)" "A8" "B1 A1 A7 A4 C1"

# M4 — THE REDIRECT STRIPPED. The guard still blocks, still names the seat,
# still cites AGENTS.md — and hands back no way forward. A model reading only
# this message has two options left, retry or stall, and a stalled seat in a
# scheduled window is the same freeze by another route. Every fail-open case
# and every scoping case stays green; B3/B3b/B3c/B6a are the whole detection.
fresh_copy
mutate "$HOOK" \
  '\`\`\`bash
br create -t task -p 1 "human: <the decision, in one line>" -d "## Context
<what this seat was doing, and the fork it reached>

## Options
- A: <option> — <what choosing it implies>
- B: <option> — <what choosing it implies>

## Acceptance Criteria
- [ ] Zig rules between the options
- [ ] ${_AQ_SEAT} proceeds on that ruling at its next scheduled tick"
\`\`\`' \
  '   (file a P1 human: bead capturing the question and its options)'
check "M4 redirect-stripped (block denies without routing)" "B3 B3b B3c B6a" "B1 B4 B5 A1"

# M5 — THE CHEAP GATE REMOVED. Everything still LOOKS right: the same windows
# block, the same windows pass. What changes is that every AskUserQuestion on
# the machine now pays a seat resolution plus two python3 spawns to be told
# "allow" — including on a roster where nobody is marked, which is the state the
# fleet was in until 2026-08-09 and returns to if the mark is ever dropped. Only
# C1 can see it, which is why it records the stub's invocations instead of
# trusting a comment.
fresh_copy
mutate "$HOOK" \
  "grep -qE '^[[:space:]]*interactive:[[:space:]]*false[[:space:]]*\$' \"\$_AQ_ROSTER\" || exit 0" \
  ': # mutant: cheap gate removed'
check "M5 cheap-gate-removed (every question pays the full probe)" "C1" "B1 A1 A4 A6"

# M6 — THE TOOL BELT WIDENED. The settings.json matcher is the only thing left
# scoping this hook, so the day someone edits that matcher (or adds this hook to
# an existing AskUserQuestion|ExitPlanMode entry — which is exactly the shape
# already in settings.json) the guard silently starts refusing plan mode in the
# marked seat's window too. A9 is its sole detector.
fresh_copy
mutate "$HOOK" \
  'case "$TOOL" in
  ""|AskUserQuestion) ;;
  *) exit 0 ;;
esac' \
  'case "$TOOL" in
  *) ;;
esac'
check "M6 tool-belt-widened (ExitPlanMode gated too)" "A9" "B1 A1 A4"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The AskUserQuestion seat guard is not guarded the way the suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
