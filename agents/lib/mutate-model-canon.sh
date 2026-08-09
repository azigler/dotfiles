#!/bin/bash
# Mutation harness for agents/lib/model-canon.sh — the model-alias table
# (dotfiles-lstn).
#
#   bash agents/lib/mutate-model-canon.sh [-v]
#
# WHY THIS EXISTS. This file is four lines of DATA that decide the context
# window of every session the fleet launches, and both ways of being wrong are
# silent:
#
#   * a row that LOSES its `[1m]` — the seat still runs the right model, at
#     200,000 tokens instead of 1,000,000. Nothing errors. The statusline is
#     identical. The only symptom is compaction, days later, blamed on the work.
#   * a row that GAINS a `[1m]` it must not have (haiku) — that one is an API
#     400 at run time, on a scheduled tick, at 3am.
#
# So a green suite proves nothing here on its own; only a mutant that dies does
# (this repo's rule 1). Every check below carries a must-FAIL and a must-PASS
# list, and every mutation is asserted to have APPLIED before its exit code is
# allowed to mean anything — the five checks from
# agents/scheduler/mutate-tunnel-ownership.sh, reproduced rather than
# re-derived (dotfiles-47nf, dotfiles-77s4).
#
# HERMETIC. The lib and its suite are copied into a throwaway tree and the suite
# is pointed at the copy with MODEL_CANON_LIB; agents/lib/ is never edited.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")" && pwd)"          # agents/lib
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-model-canon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

LIB="model-canon.sh"
SUITE="test-model-canon.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/lib" "$WORK/pristine"
for f in "$LIB" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
done
cp -a "$SRC/$LIB" "$WORK/pristine/$LIB"
cp -a "$SRC/$SUITE" "$WORK/lib/$SUITE"

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$LIB" "$WORK/lib/$LIB"
  chmod +x "$WORK/lib/$LIB"
}

run_suite() {
  SUITE_OUT=$(MODEL_CANON_LIB="$WORK/lib/$LIB" bash "$WORK/lib/$SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <literal-from> <literal-to> — fixed strings, never regexes.
mutate() {
  local from=$1 to=$2
  local path="$WORK/lib/$LIB" pristine="$WORK/pristine/$LIB"

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
  [ $? -eq 0 ] || { harness_error "$LIB: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$LIB: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$LIB: the mutant is not valid bash — it would fail every case for the wrong reason"
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

# M1 — A 1M FAMILY LOSES ITS TAG. This is the live 2026-08-09 shape, moved into
# the table: `fable` resolves to the 200k form and every consumer — the launch
# string, the /model instruction, the settings-drift alarm — dutifully names it.
# C7 is the direct detector; C10 catches it too because the drift message would
# then propose the wrong id. C8 must keep passing: this mutant must not be
# confusable with one that touched the haiku row.
# The mutation carries the NEXT ROW with it, unchanged: `fable claude-fable-5`
# on its own is a substring of the pristine row, so the harness's own no-op
# assertion would (correctly) refuse it. Extending the match to a line boundary
# is the fix — never relaxing the assertion.
fresh_copy
mutate 'fable claude-fable-5[1m]
opus' 'fable claude-fable-5
opus'
check "M1 fable-canonical-loses-the-[1m]-tag (silently the 200k window)" \
      "C7 C10" "C1 C2 C8"

# M2 — HAIKU GAINS A TAG IT MUST NOT HAVE. The other failure direction, and the
# louder one: probed 2026-08-09, `--model 'claude-haiku-4-5[1m]'` is an HTTP 400
# ("the long context beta is not yet available for this subscription"). Every
# haiku-pinned row would die at run time, on a schedule, with nobody watching.
# C8 is its sole direct detector; C11 goes with it because the drift check's
# other direction inverts. C7 must keep passing — a mutant that also broke the
# 1M families is not evidence about this row.
fresh_copy
mutate 'haiku claude-haiku-4-5' 'haiku claude-haiku-4-5[1m]'
check "M2 haiku-canonical-gains-a-[1m]-tag (an API 400 on every haiku tick)" \
      "C3 C5 C8 C9 C11" "C1 C2 C7"

# M3 — THE FULL-ID BRANCH REMOVED, so only a bare alias resolves. That leaves
# `claude-fable-5` — the shape a settings file lands in once an alias has been
# resolved ONCE, and the shape the transcript reports — passing through as
# "not ours", i.e. as clean. The detector would then be blind to exactly the
# half of the drift that is already one step down the road.
fresh_copy
mutate '    if [ "$root" = "$alias" ] || [ "$root" = "$(_model_canon_root "$canon")" ]; then' \
       '    if [ "$root" = "$alias" ]; then'
check "M3 bare-full-id-not-recognised (claude-fable-5 reads as clean)" \
      "C4 C5 C10 C11 C13" "C1 C2 C3"

# M4 — THE DRIFT COMPARISON DISARMED: everything reports clean. The alarm still
# runs, still costs a fork, still logs nothing — the exact shape of a guard that
# is present and dead. C9 must keep passing, since "silent on a canonical id" is
# equally satisfied by a detector that is silent on everything; that asymmetry
# is why C10/C11/C12 exist.
fresh_copy
mutate '  [ "$tok" = "$canon" ] && return 0' \
       '  [ "$tok" != "" ] && return 0'
check "M4 drift-detector-always-reports-clean" \
      "C10 C11 C12 C15" "C1 C3 C9"

# M5 — CASE FOLDING REMOVED. `/model Fable` is a thing a human types, and the
# lookup would silently miss it — the token then travels to the launch string
# unrecognised and unfixed, which is a drift the detector reports as clean.
fresh_copy
mutate "| tr '[:upper:]' '[:lower:]'" "| cat"
check "M5 case-folding-removed (a capitalised alias resolves to nothing)" \
      "C13" "C1 C3 C7 C8"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "RESULT: HARNESS ERROR — at least one mutation did not apply. That is not a"
  echo "        kill and must not be read as one; re-derive the mutant from source."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "RESULT: FAIL — a mutant survived or died on the wrong cases."
  exit 1
fi
echo "RESULT: all mutants killed, each on the case(s) it names."
exit 0
