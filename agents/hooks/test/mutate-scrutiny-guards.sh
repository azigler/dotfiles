#!/bin/bash
# Mutation harness for the scrutiny-verdict guards.
#
#   bash agents/hooks/test/mutate-scrutiny-guards.sh [-v]
#
# WHY THIS EXISTS. On 2026-08-01 a 13-mutant sweep against these two hooks
# found three survivors while both suites were green (58/58 and 60/60):
#   * the pulse proof gate's `grep -q 'SHIP'` could be replaced by `true`;
#   * the empty-`cmd` proof check could be deleted;
#   * SCRUTINY_NEGATED_RE could be neutered — caught ONLY by
#     `pre-bead-close.sh --selftest`, which had no caller (dotfiles-jm1c).
# A green suite is not evidence that a guard bites. This harness is the
# evidence, and tools/githooks/pre-commit is its consumer.
#
# Each mutant is applied to a THROWAWAY COPY of agents/hooks; the real tree is
# never edited. A mutant must make its NAMED suite fail — and the harness
# prints which test cases died, so a mutant killed by an unrelated assertion
# is visible rather than reassuring.
#
# ⚠️ BASH ONLY. scrutiny_verdict_ok ends in `grep -qv` over possibly-empty
# input, which exits 0 under zsh and 1 under bash: a zsh run reports the
# no-verdict cases as ACCEPTED and hides a real false-accept.

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")/.." && pwd)"     # agents/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-scrutiny.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PCC="pre-commit-checks.sh"
PBC="pre-bead-close.sh"
LIB="lib/scrutiny-verdict.sh"

FAILED=0

# fresh_copy — a pristine agents/hooks in $WORK/hooks
fresh_copy() {
  rm -rf "$WORK/hooks"
  cp -a "$SRC" "$WORK/hooks"
}

# run_suite <test-file> -> rc, output in $SUITE_OUT
run_suite() {
  SUITE_OUT=$(bash "$WORK/hooks/test/$1" 2>&1)
  return $?
}

# mutate <file> <python-expression-file> — applies a literal substring swap.
# A substring swap that matches NOTHING is itself a failure: a mutant aimed at
# a line that has since moved reports a false green, which is the trap this
# harness exists to avoid.
mutate() {
  local file=$1 from=$2 to=$3
  python3 - "$WORK/hooks/$file" "$from" "$to" <<'PY' || return 1
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
n = s.count(frm)
if n != 1:
    sys.stderr.write(f"MUTANT DID NOT APPLY: {n} occurrences of the target in {path}\n")
    sys.exit(1)
open(path, "w").write(s.replace(frm, to))
PY
}

# check <mutant-name> <suite> — expects the suite to FAIL (mutant killed).
check() {
  local name=$1 suite=$2
  if run_suite "$suite"; then
    echo "SURVIVED  $name  ($suite still green)"
    echo "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
  else
    echo "killed    $name  (by $suite)"
    echo "$SUITE_OUT" | grep -E '^  - ' | sed 's/^/          /'
    [ "$VERBOSE" -eq 1 ] && echo "$SUITE_OUT" | sed 's/^/          | /'
  fi
}

# check_selftest <mutant-name> — expects --selftest to report broken cases.
check_selftest() {
  local name=$1 out rc
  out=$(bash "$WORK/hooks/$PBC" --selftest 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "SURVIVED  $name  (--selftest still 0 broken)"
    FAILED=1
  else
    echo "killed    $name  (by pre-bead-close --selftest)"
    echo "$out" | grep '^BROKEN' | sed 's/^/          /'
  fi
}

echo "=== baseline: the unmutated copy must be GREEN ============================"
fresh_copy
for s in test-pre-commit-checks.sh test-pre-bead-close.sh; do
  if run_suite "$s"; then
    echo "  ok      $s: $(echo "$SUITE_OUT" | tail -1)"
  else
    echo "  BROKEN  $s is RED before any mutation — nothing below means anything"
    echo "$SUITE_OUT" | tail -5 | sed 's/^/          /'
    exit 1
  fi
done
if bash "$WORK/hooks/$PBC" --selftest >/dev/null 2>&1; then
  echo "  ok      pre-bead-close --selftest: 0 broken"
else
  echo "  BROKEN  --selftest is RED before any mutation"; exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — the pulse proof gate stops checking the verdict at all.
fresh_copy
mutate "$PCC" '! scrutiny_verdict_ok "$(br show "$B" 2>/dev/null)"' 'false' || FAILED=1
check "M1 scrutinize-guard-neutered (verdict check -> false)" test-pre-commit-checks.sh

# M1b — the historical defect, restored verbatim: the four letters SHIP
# anywhere in the bead body. This is the mutant that SURVIVED 58/58 before
# 2026-08-01, so it is the one that proves the new cases are the regression
# test and not decoration.
fresh_copy
mutate "$PCC" '! scrutiny_verdict_ok "$(br show "$B" 2>/dev/null)"' \
               '! br show "$B" 2>/dev/null | grep -q '"'"'SHIP'"'"'' || FAILED=1
check "M1b regressed to the historical bare grep -q 'SHIP'" test-pre-commit-checks.sh

# M2 — an empty (or whitespace-only) cmd proof is accepted; `bash -c ""`
# exits 0, so this is a free `done` for any tick that omits the command.
fresh_copy
mutate "$PCC" 'if [ -z "${C//[[:space:]]/}" ]; then' 'if false; then' || FAILED=1
check "M2 empty-cmd-proof-accepted" test-pre-commit-checks.sh

# M3 — SCRUTINY_NEGATED_RE neutered, so "Verdict: do NOT SHIP" reads as SHIP.
# Before this change it survived test-pre-bead-close.sh at 60/60 and was
# caught only by --selftest. It is now checked in three places; all three are
# asserted, because "some other suite happens to catch it" is not a guard.
fresh_copy
mutate "$LIB" "SCRUTINY_NEGATED_RE='\\b[Nn][Oo][Tt][[:space:]]+(SHIP|OVERRIDE)\\b'" \
              "SCRUTINY_NEGATED_RE='zzz-never-matches-zzz'" || FAILED=1
check_selftest "M3 scrutiny-negated-re-neutered"
check "M3 scrutiny-negated-re-neutered" test-pre-commit-checks.sh
check "M3 scrutiny-negated-re-neutered" test-pre-bead-close.sh

# M4 — the verdict regex matches any text at all.
fresh_copy
mutate "$LIB" "SCRUTINY_VERDICT_RE='(Verdict:" "SCRUTINY_VERDICT_RE='(.|Verdict:" || FAILED=1
check "M4 verdict-regex-matches-anything" test-pre-bead-close.sh

# M5 — the shared lib is deleted outright. The loaders must fail CLOSED: a
# missing matcher can never read as "verdict accepted".
fresh_copy
rm -f "$WORK/hooks/$LIB"
check "M5 shared-lib-deleted (loaders must fail closed)" test-pre-commit-checks.sh
check "M5 shared-lib-deleted (loaders must fail closed)" test-pre-bead-close.sh

echo
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: at least one mutant SURVIVED — a guard here does not bite. ==="
  exit 1
fi
echo "=== RESULT: all mutants killed. ========================================="
exit 0
