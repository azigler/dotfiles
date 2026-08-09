#!/bin/bash
# Mutation harness for the LAURELS guards (bead dotfiles-qnfk).
#
# WHY. This repo's rule 1: a green suite is not evidence that a guard bites;
# only a mutant that dies is. Every guard here fails SILENTLY — a citation
# check that stops checking still writes a well-formed entry and exits 0; a cap
# that stops capping just places more; a dropped ledger row leaves a history
# entry that looks perfectly fine in isolation; a rollback that stops rolling
# back leaves a brief line for a laurel that was never recorded. None of those
# turns anything red on its own, which is exactly the class this exists for.
#
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh and
# agents/skills/dream/tests/mutate-fleet-guards.sh, including both clauses
# burned in during the dotfiles-ogkz arc:
#
#   * ASSERT THE MUTATION APPLIED — a pattern that does not match, or a file
#     unchanged afterwards, is a HARNESS ERROR, not a kill (dotfiles-47nf).
#   * A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES — each mutant below names
#     its detectors and ONLY those are run, via the suite's case filter
#     (dotfiles-77s4).
#
# Three files are in scope, because the chain is the subject:
#   agents/lib/seat-history.sh              the refusals + the integrity stamp
#   agents/skills/dream/dream.py            the cap, the ledger, the rollback
#   agents/scheduler/seneschal-gather.py    "no ceremony without substance"
#
# Usage:  bash agents/lib/mutate-laurels.sh [repo-root]
# Runtime: ~30s (8 mutants + baseline, each running only its named cases).
set -uo pipefail

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
SUITE=agents/lib/test-seat-history.sh
[ -f "$ROOT/$SUITE" ] || { echo "mutate: FAIL — no $SUITE under $ROOT" >&2; exit 1; }

# Exactly the files the suite drives, in their repo-relative layout. NOT a copy
# of agents/ — that is 36M per mutant, and eight of those is a real cost on a
# commit gate.
FILES="
agents/lib/seat-history.sh
agents/lib/seat-resolve.sh
agents/lib/tmux-pane-resolve.sh
agents/lib/agents-root.sh
agents/lib/validate-seats.py
agents/lib/test-seat-history.sh
agents/skills/dream/dream.py
agents/scheduler/seneschal-gather.py
"

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT   # allow-suppress: teardown
FAILED=0
KILLED=0
SEP='|@MUT@|'

stage() { # <dir>
  local d=$1 f
  for f in $FILES; do
    mkdir -p "$d/$(dirname "$f")"
    cp -p "$ROOT/$f" "$d/$f" || return 1
  done
}

echo "=== BASELINE (must be green, or every kill below is meaningless) ==="
stage "$WORK/baseline" || { echo "mutate: FAIL — could not stage baseline" >&2; exit 1; }
if ! bash "$WORK/baseline/$SUITE" | tail -1; then
  echo "mutate: FAIL — baseline suite is not green; fix that first" >&2
  exit 1
fi

echo "=== MUTANTS ==="
mutant() { # <name> <repo-relative file> <old|@MUT@|new> <case> [more cases...]
  local name=$1 rel=$2 expr=$3
  shift 3
  local d="$WORK/$name"
  rm -rf "$d"
  stage "$d" || { echo "!! $name: HARNESS ERROR — could not stage"; FAILED=1; return; }

  MUT_EXPR=$expr MUT_SEP=$SEP python3 - "$d/$rel" <<'PY'
import os, sys
path = sys.argv[1]
old, new = os.environ["MUT_EXPR"].split(os.environ["MUT_SEP"])
src = open(path, encoding="utf-8").read()
if old not in src:
    sys.stderr.write("HARNESS ERROR: mutation pattern not found in source\n")
    sys.exit(9)
open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "!! $name: HARNESS ERROR — mutation did not apply to $rel"
    FAILED=1
    return
  fi
  if diff -q "$ROOT/$rel" "$d/$rel" >/dev/null; then
    echo "!! $name: HARNESS ERROR — $rel unchanged after mutation"
    FAILED=1
    return
  fi

  local out
  out=$(bash "$d/$SUITE" "$@" 2>&1 | tail -4)
  if printf '%s' "$out" | grep -qE '^PASS: '; then
    echo "!! $name: SURVIVED — its named case(s) still pass"
    printf '%s\n' "$out" | sed 's/^/     /'
    FAILED=1
  else
    KILLED=$((KILLED + 1))
    echo "OK $name — killed by: $*"
    printf '%s\n' "$out" | grep -E '^FAIL: |^  - ' | head -4 | sed 's/^/     /'
  fi
}

# 1. THE CITATION CHECK STOPS CHECKING. This is T4's guard and the one the
#    spec names: a laurel with no bead and no commit becomes placeable, which
#    turns recognition from evidence into opinion.
mutant citation-removed agents/lib/seat-history.sh \
  $'  if [ -z "$bead" ] || [ -z "$commit" ]; then|@MUT@|  if false; then' \
  T4

# 2. THE LEDGER WRITE IS DROPPED. The history entry still lands, so the seat
#    file looks right — and the brief, which is DERIVED from the ledger, shows
#    nothing. That is the all-three-or-none property failing in the direction
#    nobody would notice by reading the history file.
mutant ledger-dropped agents/skills/dream/dream.py \
  $'            with ledger.open("a", encoding="utf-8") as fh:\n                fh.write(json.dumps(row, ensure_ascii=False) + "\\n")|@MUT@|            pass' \
  T2

# 3. THE ROLLBACK STOPS UNWINDING. The other direction of the same property: a
#    ledger row (and a brief line) for a history entry that was never written.
mutant no-rollback agents/skills/dream/dream.py \
  $'                with ledger.open("r+b") as fh:\n                    fh.truncate(before)|@MUT@|                pass' \
  T2R

# 4. THE CAP STOPS CAPPING. 0-3 a week is what keeps a laurel scarce; without
#    it the tick can place one on every seat and the currency is gone.
mutant cap-removed agents/skills/dream/dream.py \
  $'        if len(placed) >= max(0, args.cap):|@MUT@|        if False:' \
  T3

# 5. THE REMEMBRANCER EXCLUSION STOPS EXCLUDING — the office that places
#    laurels can place one on itself (R6's unfarmability, directly).
mutant exclusion-removed agents/lib/seat-history.sh \
  $'  if [ -n "$remembrancer" ] && [ "$seat" = "$remembrancer" ] && [ "$bylord" -eq 0 ]; then|@MUT@|  if false; then' \
  T8

# 6. THE GENERATED FILE BECOMES WRITABLE — the first of T6's two mechanisms.
#    `>> history.md` starts working, so a seat can append its own laurel with
#    a one-liner. (T6 also names the checksum; this mutant is killed by the
#    filesystem assertion specifically.)
mutant history-writable agents/lib/seat-history.sh \
  $'  chmod 0444 "$tmp" || { rm -f "$tmp"; return 1; }|@MUT@|  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }' \
  T6

# 7. THE INTEGRITY COMPARISON ALWAYS AGREES — the second mechanism. Note the
#    shape: verify still RUNS and still prints, it just always says OK, which
#    is precisely what a silent guard failure looks like.
mutant integrity-blind agents/lib/seat-history.sh \
  $'    if [ "$want" = "$got" ]; then|@MUT@|    if true; then' \
  T6

# 8. THE BRIEF RENDERS THE SECTION UNCONDITIONALLY — ceremony without
#    substance. A standing empty LAURELS heading trains the reader to skip the
#    heading, which costs the placement its only human touchpoint.
mutant brief-always agents/scheduler/seneschal-gather.py \
  $'    if laurels or laurel_err:|@MUT@|    if True:' \
  T10

echo
if [ $FAILED -eq 0 ]; then
  echo "mutate: ALL $KILLED MUTANTS KILLED BY THEIR NAMED CASES"
  exit 0
fi
echo "mutate: FAIL — a mutant survived (or the harness itself erred). See above."
exit 1
