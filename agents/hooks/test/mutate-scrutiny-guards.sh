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
# never edited.
#
# ---------------------------------------------------------------------------
# THE TWO PROPERTIES THAT MAKE A MUTATION HARNESS HONEST (CLAUDE.md rule 1)
# ---------------------------------------------------------------------------
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh, deliberately — the
# rule cites one reference so that harnesses look alike. Same vocabulary
# (`killed` / `SURVIVED` / `MIS-KILLED` / `HARNESS ERROR`), same exit codes
# (0 all killed / 1 survived-or-mis-killed / 2 harness error).
#
# 1. ASSERT THE MUTATION APPLIED, before its suite result is allowed to mean
#    anything. In dotfiles-47nf an over-escaped sed pattern matched nothing,
#    the suite went red anyway, and BY EXIT CODE ALONE that is
#    indistinguishable from a proper kill. So every mutation is checked five
#    ways:
#      a. the target text occurs EXACTLY ONCE in the pristine file
#      b. the replacement occurs ZERO times in the pristine file (not a no-op)
#      c. the file's bytes actually changed                     (it was written)
#      d. the replacement occurs exactly once afterwards        (fully applied)
#      e. `bash -n` is still clean  (it dies of the bug it NAMES, not of a
#         syntax error that fails every case)
#    M5 deletes a file rather than editing one; `remove_file` asserts the
#    analogous three (present in pristine, present before, absent after).
#    Any failure is a HARNESS ERROR — reported and exited 2 as such, never as
#    a killed mutant.
#
# 2. A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES. Red-somewhere says nothing
#    about the guard under test and is frequently evidence the mutant broke
#    something else (dotfiles-77s4). Every `check` therefore declares the case
#    names it must redden, and optionally — after `--` — case names that must
#    keep PASSING. The must-pass list is how a mutant asserts it made the gate
#    OVER-PERMISSIVE rather than globally broken: M5 (lib deleted) must redden
#    the `allow:` cases while leaving every `block:` case green, which is the
#    literal statement "the loaders fail CLOSED".
#
#    Case names are matched as literal substrings of the suite's `  - <name>`
#    failure lines. A declared name that does not exist in the suite source at
#    all is itself a HARNESS ERROR: a must-pass case that matches nothing is
#    vacuous, and a must-fail case that matches nothing would mark every future
#    run MIS-KILLED for a typo.
#
# ⚠️ BASH ONLY. scrutiny_verdict_ok ends in `grep -qv` over possibly-empty
# input, which exits 0 under zsh and 1 under bash: a zsh run reports the
# no-verdict cases as ACCEPTED and hides a real false-accept.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of the hooks. `$B`, `$C` and friends inside them must NOT
# expand — they are matched byte-for-byte against the file on disk, and an
# expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="$(cd "$(dirname "$0")/.." && pwd)"     # agents/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-scrutiny.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PCC="pre-commit-checks.sh"
PBC="pre-bead-close.sh"
LIB="lib/scrutiny-verdict.sh"

SUITE_PCC="test-pre-commit-checks.sh"
SUITE_PBC="test-pre-bead-close.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

# The pristine snapshot is taken ONCE. Every applied-ness assertion compares
# against it rather than against the live tree, so a sibling process editing
# agents/hooks mid-run cannot quietly change what "unmutated" means.
cp -a "$SRC" "$WORK/pristine"
for f in "$PCC" "$PBC" "$LIB" "test/$SUITE_PCC" "test/$SUITE_PBC"; do
  [ -f "$WORK/pristine/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
done

# fresh_copy — a pristine agents/hooks in $WORK/hooks
fresh_copy() {
  MUTANT_OK=1
  rm -rf "$WORK/hooks"
  cp -a "$WORK/pristine" "$WORK/hooks"
}

# run_suite <test-file> -> rc, output in $SUITE_OUT
run_suite() {
  SUITE_OUT=$(bash "$WORK/hooks/test/$1" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to>
# Literal substring swap with assertions (a)-(e) above. Fixed strings, never
# regexes: over-escaping a pattern is the exact failure this harness exists to
# make impossible, so there is no pattern to over-escape.
mutate() {
  local file=$1 from=$2 to=$3
  local path="$WORK/hooks/$file" pristine="$WORK/pristine/$file"

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

# remove_file <file> — the deletion mutation (M5), with the applied-ness
# assertions that make sense for a delete: it existed in the pristine tree, it
# existed in this copy before the rm, and it is gone afterwards.
remove_file() {
  local file=$1
  local path="$WORK/hooks/$file" pristine="$WORK/pristine/$file"
  if [ ! -f "$pristine" ]; then
    harness_error "$file: not present in the pristine tree — there is nothing to delete"
    return 1
  fi
  if [ ! -f "$path" ]; then
    harness_error "$file: already absent from the working copy before the delete"
    return 1
  fi
  rm -f "$path"
  if [ -e "$path" ]; then
    harness_error "$file: still present after rm — the deletion did not apply"
    return 1
  fi
  return 0
}

# _assert_cases_exist <haystack-file> <case-name>...
# A declared case name must occur literally in the file that defines the cases.
# Returns 1 (and raises a harness error) if any does not.
_assert_cases_exist() {
  local hay=$1 c missing=0
  shift
  for c in "$@"; do
    if ! grep -qF -- "$c" "$hay"; then
      harness_error "declared case is not defined in $(basename "$hay"): '$c'"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

# check <mutant-name> <suite> <must-FAIL case>... [-- <must-PASS case>...]
# Expects the suite to FAIL, on the named cases.
check() {
  local name=$1 suite=$2
  shift 2
  local want_fail=() want_pass=() sep=0 a c got missing="" wrongly=""
  for a in "$@"; do
    if [ "$a" = "--" ]; then sep=1; continue; fi
    if [ "$sep" -eq 1 ]; then want_pass+=("$a"); else want_fail+=("$a"); fi
  done

  if [ ${#want_fail[@]} -eq 0 ]; then
    harness_error "$name: declares no must-fail case — a kill with nothing named is not a kill"
  else
    _assert_cases_exist "$WORK/hooks/test/$suite" \
      "${want_fail[@]}" ${want_pass[@]+"${want_pass[@]}"} || true
  fi

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation or its case list did not check out — see HARNESS ERROR above)"
    return
  fi

  if run_suite "$suite"; then
    echo "SURVIVED  $name  ($suite is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ')
  for c in "${want_fail[@]}"; do
    printf '%s\n' "$got" | grep -qF -- "$c" || missing="$missing
             - $c"
  done
  for c in ${want_pass[@]+"${want_pass[@]}"}; do
    printf '%s\n' "$got" | grep -qF -- "$c" && wrongly="$wrongly
             - $c"
  done

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name  ($suite)"
    echo "           the suite went red but NOT on the case(s) this mutant names:$missing"
    echo "           actually failing:"
    printf '%s\n' "${got:-           <none>}" | sed 's/^  - /             /'
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name  ($suite)"
    echo "           case(s) that had to keep PASSING went red:$wrongly"
    echo "           (this mutant is meant to make the gate over-permissive, not to break it)"
    FAILED=1
  else
    echo "killed    $name  (by $suite)"
    printf '%s\n' "$got" | sed 's/^/          /'
  fi
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$SUITE_OUT" | sed 's/^/          | /'
  return 0
}

# check_selftest <mutant-name> <must-BREAK sample>... [-- <must-stay-ok sample>...]
# Same contract against `pre-bead-close.sh --selftest`, whose "cases" are the
# sample bead bodies printed after `| ` on each matrix line.
check_selftest() {
  local name=$1
  shift
  local want_broken=() want_ok=() sep=0 a c out rc broken missing="" wrongly=""
  for a in "$@"; do
    if [ "$a" = "--" ]; then sep=1; continue; fi
    if [ "$sep" -eq 1 ]; then want_ok+=("$a"); else want_broken+=("$a"); fi
  done

  if [ ${#want_broken[@]} -eq 0 ]; then
    harness_error "$name: declares no must-break selftest case"
  else
    _assert_cases_exist "$WORK/hooks/$PBC" \
      "${want_broken[@]}" ${want_ok[@]+"${want_ok[@]}"} || true
  fi

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (--selftest; see HARNESS ERROR above)"
    return
  fi

  out=$(bash "$WORK/hooks/$PBC" --selftest 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "SURVIVED  $name  (--selftest still 0 broken)"
    FAILED=1
    return
  fi

  broken=$(printf '%s\n' "$out" | grep '^BROKEN')
  for c in "${want_broken[@]}"; do
    printf '%s\n' "$broken" | grep -qF -- "$c" || missing="$missing
             - $c"
  done
  for c in ${want_ok[@]+"${want_ok[@]}"}; do
    printf '%s\n' "$broken" | grep -qF -- "$c" && wrongly="$wrongly
             - $c"
  done

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name  (--selftest)"
    echo "           --selftest reported broken cases, but NOT the one(s) named:$missing"
    echo "           actually broken:"
    printf '%s\n' "${broken:-           <none>}" | sed 's/^BROKEN */             /'
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name  (--selftest)"
    echo "           case(s) that had to stay ok broke:$wrongly"
    FAILED=1
  else
    echo "killed    $name  (by pre-bead-close --selftest)"
    printf '%s\n' "$broken" | sed 's/^/          /'
  fi
}

echo "=== baseline: the unmutated copy must be GREEN ============================"
fresh_copy
for s in "$SUITE_PCC" "$SUITE_PBC"; do
  if run_suite "$s"; then
    echo "  ok      $s: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
  else
    echo "  BROKEN  $s is RED before any mutation — nothing below means anything"
    printf '%s\n' "$SUITE_OUT" | tail -5 | sed 's/^/          /'
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

# M1 — the pulse proof gate stops checking the verdict at all. `false` takes
# (and ignores) an argument, so the mutant reads as itself in a diff and is a
# unique string for the applied-ness assertions.
fresh_copy
mutate "$PCC" '! scrutiny_verdict_ok "$(br show "$B" 2>/dev/null)"' 'false "M1-neutered"'
check "M1 scrutinize-guard-neutered (verdict check -> false)" "$SUITE_PCC" \
  "block: scrutinize proof with 'do NOT SHIP'" \
  "block: scrutinize proof with prose 'before we SHIP'" \
  "block: scrutinize proof on a bead quoting another's verdict" \
  "block: scrutinize proof with unresolved FIX-FIRST" \
  "block: scrutinize proof whose bead body is empty" \
  -- \
  "allow: scrutinize proof with 'Verdict: SHIP'" \
  "block: done with an empty cmd proof"

# M1b — the historical defect, restored verbatim: the four letters SHIP
# anywhere in the bead body. This is the mutant that SURVIVED 58/58 before
# 2026-08-01, so it is the one that proves the new cases are the regression
# test and not decoration. It also breaks the OVERRIDE marker (bare `SHIP`
# does not match it), which is why that case is named as a KILL rather than
# as a must-pass.
fresh_copy
mutate "$PCC" '! scrutiny_verdict_ok "$(br show "$B" 2>/dev/null)"' \
               '! br show "$B" 2>/dev/null | grep -q '"'"'SHIP'"'"''
check "M1b regressed to the historical bare grep -q 'SHIP'" "$SUITE_PCC" \
  "block: scrutinize proof with 'do NOT SHIP'" \
  "block: scrutinize proof with prose 'before we SHIP'" \
  "block: scrutinize proof on a bead quoting another's verdict" \
  "allow: scrutinize proof with an OVERRIDE marker" \
  -- \
  "allow: scrutinize proof with 'Verdict: SHIP'" \
  "block: done with an empty cmd proof"

# M2 — an empty (or whitespace-only) cmd proof is accepted; `bash -c ""`
# exits 0, so this is a free `done` for any tick that omits the command.
fresh_copy
mutate "$PCC" 'if [ -z "${C//[[:space:]]/}" ]; then' 'if false "M2-neutered"; then'
check "M2 empty-cmd-proof-accepted" "$SUITE_PCC" \
  "block: done with an empty cmd proof" \
  "block: done with kind:cmd and no cmd key" \
  "block: done with a whitespace-only cmd proof" \
  -- \
  "block: scrutinize proof with 'do NOT SHIP'" \
  "allow: scrutinize proof with 'Verdict: SHIP'"

# M3 — SCRUTINY_NEGATED_RE neutered, so "Verdict: do NOT SHIP" reads as SHIP.
# Before this change it survived test-pre-bead-close.sh at 60/60 and was
# caught only by --selftest. It is now checked in three places; all three are
# asserted, because "some other suite happens to catch it" is not a guard.
# Only the negation is broken, so every non-negated case must stay green —
# that is what the must-pass lists say.
fresh_copy
mutate "$LIB" "SCRUTINY_NEGATED_RE='\\b[Nn][Oo][Tt][[:space:]]+(SHIP|OVERRIDE)\\b'" \
              "SCRUTINY_NEGATED_RE='zzz-never-matches-zzz'"
check_selftest "M3 scrutiny-negated-re-neutered" \
  "Verdict: do NOT SHIP" \
  -- \
  "Verdict: REJECT" \
  "no verdict recorded here at all"
check "M3 scrutiny-negated-re-neutered" "$SUITE_PCC" \
  "block: scrutinize proof with 'do NOT SHIP'" \
  -- \
  "allow: scrutinize proof with 'Verdict: SHIP'" \
  "block: scrutinize proof whose bead body is empty"
check "M3 scrutiny-negated-re-neutered" "$SUITE_PBC" \
  "block: impl bead whose verdict is 'do NOT SHIP'" \
  -- \
  "allow: impl bead with SHIP verdict" \
  "block: impl bead with no scrutiny verdict"

# M4 — the verdict regex matches any text at all.
fresh_copy
mutate "$LIB" "SCRUTINY_VERDICT_RE='(Verdict:" "SCRUTINY_VERDICT_RE='(.|Verdict:"
check "M4 verdict-regex-matches-anything" "$SUITE_PBC" \
  "block: impl bead with no scrutiny verdict" \
  "block: impl bead with gamed scrutiny prose" \
  "block: impl bead whose verdict is 'do NOT SHIP'" \
  "block: scrutinize-required bead with no verdict" \
  "block: impl bead with no verdict, closed via the newline form" \
  -- \
  "allow: impl bead with SHIP verdict" \
  "allow: impl bead with OVERRIDE verdict"

# M5 — the shared lib is deleted outright. The loaders must fail CLOSED: a
# missing matcher can never read as "verdict accepted". The must-pass lists
# are the load-bearing half of this mutant — every `block:` case staying green
# IS the statement that it fails closed rather than open.
fresh_copy
remove_file "$LIB"
check "M5 shared-lib-deleted (loaders must fail closed)" "$SUITE_PCC" \
  "allow: scrutinize proof with 'Verdict: SHIP'" \
  "allow: scrutinize proof with an OVERRIDE marker" \
  -- \
  "block: scrutinize proof with 'do NOT SHIP'" \
  "block: done with an empty cmd proof"
check "M5 shared-lib-deleted (loaders must fail closed)" "$SUITE_PBC" \
  "allow: impl bead with SHIP verdict" \
  "allow: impl bead with OVERRIDE verdict" \
  "allow: scrutinize-required bead with SHIP verdict" \
  "allow: scrutinize-required bead with OVERRIDE verdict" \
  -- \
  "block: impl bead with no scrutiny verdict" \
  "block: impl bead whose verdict is 'do NOT SHIP'"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — a mutation never applied, or a mutant named"
  echo "    a case that does not exist. A suite failure under an unapplied mutant"
  echo "    proves NOTHING. Fix the mutant against the current source before"
  echo "    reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    A guard here does not bite the way the suites claim."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
