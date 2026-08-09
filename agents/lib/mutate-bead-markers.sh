#!/bin/bash
# Mutation harness for bead-markers.sh's grammar (dotfiles-dh89).
#
# WHY. This repo's rule 1: a green suite is not evidence that a guard bites;
# only a mutant that dies is. The property under test is the whole POINT of
# the marker grammar being STRICT rather than a loose grep: `fleet: yes`
# must be fleet-eligible, `fleetish: yes` and `fleet: yesterday` must NOT.
# The single highest-value mutant is loosening marker_bool_from_value's
# exact match to a PREFIX match — the natural "helpful" edit ("just check it
# starts with yes") that silently admits `fleet: yesterday` as truthy. That
# is the exact failure the eligibility rule (69qr R1c) depends on never
# happening: an unmarked-in-spirit bead getting claimed by the drain.
#
# Modelled on agents/lib/mutate-laurels.sh and
# agents/scheduler/mutate-tunnel-ownership.sh: assert the mutation pattern
# is found (unapplied mutation = HARNESS ERROR, not a kill), assert the
# bytes changed, assert the mutant still runs (a syntax break is a harness
# error too), and require the mutant to fail the case(s) it NAMES (T9/T13a).
#
# Usage: bash agents/lib/mutate-bead-markers.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SCRIPT_NAME="bead-markers.sh"
SUITE_NAME="test-bead-markers.sh"

for f in "$SCRIPT_NAME" "$SUITE_NAME"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
done

echo "=== BASELINE (must be green, or the kill below is meaningless) ==="
mkdir -p "$WORK/baseline"
cp -a "$SRC/$SCRIPT_NAME" "$SRC/$SUITE_NAME" "$WORK/baseline/"
if ! bash "$WORK/baseline/$SUITE_NAME" | tail -1; then
  echo "mutate: FAIL — baseline suite is not green; fix that first" >&2
  exit 1
fi

echo "=== MUTANT: grammar-loosened (exact 'yes' -> prefix 'yes*') ==="
mkdir -p "$WORK/mutant"
cp -a "$SRC/$SCRIPT_NAME" "$SRC/$SUITE_NAME" "$WORK/mutant/"

OLD='  case "$1" in
    [Yy][Ee][Ss]) return 0 ;;
    *)            return 1 ;;
  esac'
NEW='  case "$1" in
    [Yy][Ee][Ss]*) return 0 ;;
    *)             return 1 ;;
  esac'

TARGET="$WORK/mutant/$SCRIPT_NAME"
if ! grep -qF "$OLD" "$TARGET"; then
  echo "HARNESS ERROR: mutation pattern not found in $SCRIPT_NAME" >&2
  exit 2
fi

# OLD/NEW travel via env vars (not shell-quoted into the heredoc) — a
# multi-line string with embedded double quotes is exactly the case bash's
# @Q quoting mangles into non-Python-valid $'...' syntax.
MUT_OLD="$OLD" MUT_NEW="$NEW" MUT_PATH="$TARGET" python3 <<'PY'
import os
import pathlib

p = pathlib.Path(os.environ["MUT_PATH"])
src = p.read_text()
old = os.environ["MUT_OLD"]
new = os.environ["MUT_NEW"]
assert old in src, "pattern vanished between grep and python read"
p.write_text(src.replace(old, new, 1))
PY

if diff -q "$SRC/$SCRIPT_NAME" "$TARGET" >/dev/null; then
  echo "HARNESS ERROR: $SCRIPT_NAME unchanged after mutation" >&2
  exit 2
fi

bash -n "$TARGET" || { echo "HARNESS ERROR: mutant does not even parse" >&2; exit 2; }

OUT=$(bash "$WORK/mutant/$SUITE_NAME" 2>&1)
RC=$?
echo "$OUT" | tail -6

if [ "$RC" -eq 0 ]; then
  echo
  echo "mutate: FAIL — mutant SURVIVED (suite stayed green with a loosened grammar)"
  exit 1
fi

# The kill must come from the cases that NAME this property (T9's
# not-truthy assertions and T13a's 'fleet: yesterday' check), not from an
# unrelated break.
if echo "$OUT" | grep -qE "T9: 'yesterday' should NOT be truthy" \
  && echo "$OUT" | grep -qE "T13a: 'Fleet: yesterday' must not be fleet-eligible"; then
  echo
  echo "mutate: MUTANT KILLED by its named cases (T9, T13a)"
  exit 0
fi

echo
echo "mutate: FAIL — suite went red, but NOT via the cases this mutant names (T9/T13a)"
exit 1
