#!/bin/bash
# Mutation harness for the TAP-FAILOVER chain (dotfiles-kecb).
#
#   bash agents/lib/mutate-tap-failover.sh [-v]
#
# WHY THIS EXISTS. This chain decides WHICH ANTHROPIC ACCOUNT A LAUNCH BILLS
# TO, and every way it can be wrong is SILENT. Not one of these turns a timer
# red, and every one of them leaves both suites green in isolation:
#
#   * a rollover that changes the headers but not the config dir — the request
#     then announces a tap it is not running on, which is the 19:23Z
#     misattribution rebuilt out of the tap system's own machinery;
#   * a rollover with the attribution pair dropped — right account, and
#     byte-identical downstream to a launch whose home tap was always that
#     pool, so nothing can ever count rollovers or notice one becoming
#     permanent;
#   * the per-seat home-tap override ignored — LinearB's overflow lands on
#     Zig's personal subscription while LinearB's sits idle;
#   * the model-scoped (Fable) dimension ignored — the unified windows have
#     headroom, the Fable weekly does not, and the launch stalls anyway;
#   * a rollover made on data nobody could read — one network blip moves the
#     fleet's billing;
#   * the inherited-header strip removed — the measured env-bypass defect
#     comes straight back, and it is invisible: the request succeeds.
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites;
# only a mutant that dies is. tools/githooks/pre-commit is this file's consumer.
#
# ---------------------------------------------------------------------------
# MODELLED ON agents/scheduler/mutate-tunnel-ownership.sh — READ THAT FIRST.
# ---------------------------------------------------------------------------
# Both of its clauses are implemented here and neither is optional:
#
#   ASSERT THE MUTATION APPLIED. Five checks before a suite's exit code is
#   allowed to mean anything: the target text occurs EXACTLY ONCE in the
#   pristine file; the replacement occurs ZERO times there; the bytes actually
#   changed; the replacement occurs exactly once afterwards; `bash -n` is still
#   clean. Any failure is a HARNESS ERROR, never a killed mutant — a mutant
#   that "dies" without applying is a false pass of the harness itself.
#
#   A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES. Red-somewhere says nothing
#   about the guard under test. Every mutant below names its must-FAIL cases
#   AND, where it matters, the cases that must keep PASSING — which is what
#   distinguishes "this mutant broke the one property" from "this mutant broke
#   the script".
#
# ---------------------------------------------------------------------------
# THE WORK TREE IS A MIRROR OF SYMLINKS.
# ---------------------------------------------------------------------------
# Both suites resolve their subjects by RELATIVE PATH from their own directory
# — the wrapper suite reads ../seats.yml, ../../zsh/.zshenv and (through a
# fixture ~/.agents tier) its sibling tap-headroom.sh; the headroom suite reads
# ../scheduler/taps.conf. So $WORK holds a agents/lib + agents/scheduler +
# zsh skeleton in which every file is a SYMLINK to the real tree, and only the
# file a mutant edits is replaced by a real (mutated) copy. Nothing under the
# repo is ever written.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of the file it targets. `$_cfg`, `$fable_flag` and friends
# inside them must NOT expand — they are matched byte-for-byte against the file
# on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

LIBDIR="$(cd "$(dirname "$0")" && pwd)"          # agents/lib
AGENTS="$(cd "$LIBDIR/.." && pwd)"               # agents
ROOT="$(cd "$AGENTS/.." && pwd)"                 # repo root

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-tapfail.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

WRAPPER="claude-identity-wrapper.sh"
HEADROOM="tap-headroom.sh"
ZSHENV="zsh/.zshenv"
WSUITE="$WORK/agents/lib/test-claude-identity-wrapper.sh"
HSUITE="$WORK/agents/lib/test-tap-headroom.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0
SUITE_OUT=""

mkdir -p "$WORK/agents/lib" "$WORK/agents/scheduler" "$WORK/zsh" "$WORK/pristine"

# fresh_copy — rebuild the mirror: every path a suite can reach becomes a
# symlink to the real tree, so a mutant that does not touch a file cannot
# possibly diverge from it.
fresh_copy() {
  MUTANT_OK=1
  rm -rf "$WORK/agents" "$WORK/zsh"
  mkdir -p "$WORK/agents/lib" "$WORK/agents/scheduler" "$WORK/zsh"
  local f
  for f in "$LIBDIR"/*; do ln -sfn "$f" "$WORK/agents/lib/$(basename "$f")"; done
  ln -sfn "$AGENTS/seats.yml" "$WORK/agents/seats.yml"
  ln -sfn "$AGENTS/scheduler/taps.conf" "$WORK/agents/scheduler/taps.conf"
  ln -sfn "$ROOT/$ZSHENV" "$WORK/zsh/.zshenv"
}

# realize <relative-path-under-$WORK> — turn one mirror symlink into a real
# file so it can be mutated. The pristine copy is kept for the applied-ness
# assertions.
realize() {
  local rel=$1 target
  target="$WORK/$rel"
  local real
  real=$(readlink "$target") || { echo "HARNESS ERROR: $rel is not a symlink" >&2; HARNESS_ERR=1; return 1; }
  rm -f "$target"
  cp -a "$real" "$target"
  cp -a "$real" "$WORK/pristine/$(basename "$rel")"
}

run_suite() { # <wrapper|headroom>
  case "$1" in
    wrapper)  SUITE_OUT=$(bash "$WSUITE" 2>&1) ;;
    headroom) SUITE_OUT=$(bash "$HSUITE" 2>&1) ;;
    *) echo "HARNESS ERROR: unknown suite '$1'" >&2; return 2 ;;
  esac
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <relative-path> <literal-from> <literal-to>
# Literal substring swap with all five applied-ness assertions. Fixed strings,
# never regexes: over-escaping a pattern is the exact failure the tunnel
# harness was written to make impossible, so there is no pattern to
# over-escape.
mutate() {
  local rel=$1 from=$2 to=$3
  local path="$WORK/$rel" pristine
  pristine="$WORK/pristine/$(basename "$rel")"
  realize "$rel" || { MUTANT_OK=0; return 1; }

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
  [ $? -eq 0 ] || { harness_error "$rel: mutation did not apply"; return 1; }

  if cmp -s "$pristine" "$path"; then
    harness_error "$rel: bytes are IDENTICAL to pristine after a 'successful' write"
    return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$rel: the mutant is not valid bash — it would fail every case for the wrong reason"
    return 1
  fi
  return 0
}

# check <mutant-name> <suite> <must-FAIL cases> [<must-PASS cases>]
check() {
  local name=$1 suite=$2 want_fail=$3 want_pass=${4:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if run_suite "$suite"; then
    echo "SURVIVED  $name  ($suite suite is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1
    return
  fi

  # The suites print `  FAIL <case-id> <prose…>`; awk collapses the leading
  # spaces, so the case id is field 2.
  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  FAIL ' | awk '{ print $2 }' | tr '\n' ' ')
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

echo "=== baseline: the unmutated mirror must be GREEN ========================="
fresh_copy
for s in headroom wrapper; do
  if run_suite "$s"; then
    echo "  ok      $s: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
  else
    echo "  BROKEN  the $s suite is RED before any mutation — nothing below means anything"
    printf '%s\n' "$SUITE_OUT" | tail -14 | sed 's/^/          /'
    exit 1
  fi
done

echo
echo "=== mutants =============================================================="

# M1 — THE ROLLOVER THAT DOES NOT MOVE. The headers say `secondary`, the
# launched process still reads ~/.claude. This is the 19:23Z defect rebuilt out
# of the tap system's own machinery, and it is the one shape where the loud
# attribution makes things WORSE: the ledger, the stderr line and the header
# pair all confidently record a rollover that never happened.
fresh_copy
mutate "agents/lib/$WRAPPER" \
  '      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" CLAUDE_CONFIG_DIR="$_cfg" \
        command claude --dangerously-skip-permissions "$@"' \
  '      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" \
        command claude --dangerously-skip-permissions "$@"'
check "M1 rollover-announces-a-tap-it-is-not-running-on" wrapper \
      "T20 T22b" "T20b T20c T20c2 T20e"

# M2 — THE SILENT ROLLOVER. Right account, no explicit marker. `X-Tap` alone is
# honest but not visible: a rolled-over row becomes byte-identical to a launch
# whose home tap was that pool all along, so nothing downstream can count them
# or notice one becoming permanent. Zero silent cross-billing is the design
# goal of the whole system and this is what "silent" means.
fresh_copy
mutate "agents/lib/$WRAPPER" \
  '    _hdrs=$(_ciw_add "$_hdrs" X-Home-Tap "$_home_tap")
    _hdrs=$(_ciw_add "$_hdrs" X-Tap-Rollover "1")' \
  '    : M2-dropped-the-rollover-attribution-pair'
check "M2 silent-rollover-attribution-pair-dropped" wrapper \
      "T20c T20c2" "T20 T20b T20e"

# M3 — THE LEDGER ROW DROPPED. The other half of M2: the pane's stderr line
# scrolls away in a window nobody is watching, and the durable record is the
# only thing that survives to the morning brief.
fresh_copy
mutate "agents/lib/$WRAPPER" \
  '    _ciw_ledger "$_home_tap" "$_tap" "$_pool" "${_addr:-?}"' \
  '    : M3-dropped-the-rollover-ledger-row'
check "M3 silent-rollover-ledger-row-dropped" wrapper \
      "T20e" "T20 T20b T20c T20c2"

# M4 — THE PER-SEAT HOME-TAP OVERRIDE IGNORED. The candidate order behind home
# falls back to the global one, so a LinearB seat's overflow lands on Zig's
# personal subscription while LinearB's own sits idle. Note which cases must
# keep PASSING: T22c and G14b are the no-override launches, and a mutant that
# broke ordering generally would redden those too.
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '  for p in $(th_order_from "$(th_home_pool "$seat")"); do' \
  '  for p in $(th_order_from "$home"); do'
check "M4 seat-home-tap-override-ignored" headroom \
      "G14 G15c" "G13 G13b G14b G15"
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '  for p in $(th_order_from "$(th_home_pool "$seat")"); do' \
  '  for p in $(th_order_from "$home"); do'
check "M4b seat-home-tap-override-ignored (at the launch seam)" wrapper \
      "T22" "T22c"

# M5 — THE FABLE DIMENSION IGNORED. `--fable` stops arming the model-scoped
# arm, so a launch whose Fable weekly allotment is exhausted reads as ok on the
# unified windows and stalls. Invisible by construction: the unified windows
# really do have headroom, and the gateway cannot see the other dimension at
# all. T23b/G12c/G12f must keep passing — they are the non-fable launches.
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '  [ "${2:-}" = "--fable" ] && want_fable=1' \
  '  [ "${2:-}" = "--never-matches" ] && want_fable=1'
check "M5 fable-dimension-ignored" headroom \
      "G12 G12d" "G12c G12f G8d"
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '  [ "${2:-}" = "--fable" ] && want_fable=1' \
  '  [ "${2:-}" = "--never-matches" ] && want_fable=1'
check "M5b fable-dimension-ignored (at the launch seam)" wrapper \
      "T23" "T23b"

# M6 — ROLLING OVER ON DATA NOBODY COULD READ. `unavailable` collapsed into
# `ok` for a candidate pool, so one network blip, one expired token or one
# 401 moves the fleet's billing into an account that may not even
# authenticate. T20 must keep passing: a REAL rollover on REAL evidence still
# has to work, which is what makes this a mutant about evidence rather than
# about rollover.
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '    if th_pool_headroom "$p" $fable_flag >/dev/null; then' \
  '    if th_pool_headroom "$p" $fable_flag >/dev/null; [ $? -ne 10 ]; then'
check "M6 rollover-onto-an-unmeasurable-pool" headroom \
      "G16 G16b" "G15 G15b"
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '    if th_pool_headroom "$p" $fable_flag >/dev/null; then' \
  '    if th_pool_headroom "$p" $fable_flag >/dev/null; [ $? -ne 10 ]; then'
check "M6b rollover-onto-an-unmeasurable-pool (at the launch seam)" wrapper \
      "T21 T21a T24" "T20 T20b"

# M7 — A READ THAT RETURNED NOTHING SCORED AS HEADROOM. The gateway writes the
# EMPTY STRING, not NULL, when Anthropic sends no ratelimit header — measured on
# the secondary tap's one logged request — so a row can arrive with a source, a
# timestamp and no numbers. With the all-empty check gone, both windows compare
# false against the ceiling and the pool falls through to `ok`: a pool nobody
# measured, reported as having room. G11/G11b must keep passing — a real reading
# still has to be read.
fresh_copy
mutate "agents/lib/$HEADROOM" \
  '  elif [ -z "$u5h" ] && [ -z "$u7d" ] && [ -z "$fable" ]; then' \
  '  elif [ -z "$u5h" ] && [ -z "$u7d" ] && [ -z "$fable" ] && false; then'
check "M7 a-source-that-returned-no-numbers-scored-as-headroom" headroom \
      "G9c" "G11 G11b G8g G8h"

# M8 — THE ENV-BYPASS STRIP DISARMED. The `case` pattern in the committed
# zsh/.zshenv stops matching our own header block, so a Bash-tool shell inside
# a session keeps its parent's `X-Tap` and `env … claude` bills one account
# while attributing another. Exactly the 19:23Z defect, and its failure mode is
# that the request SUCCEEDS. T26b/T26c must keep passing: a foreign header is
# still left alone, and an unset one is still a no-op — a mutant that simply
# broke the block would redden those too.
fresh_copy
mutate "$ZSHENV" \
  '  *"X-Tap: "*) unset ANTHROPIC_CUSTOM_HEADERS ;;' \
  '  *"X-Nope: "*) unset ANTHROPIC_CUSTOM_HEADERS ;;'
check "M8 env-bypass-header-strip-disarmed" wrapper \
      "T26" "T26b T26c"

# M9 — THE WRAPPER'S OWN PASS-THROUGH RESTORED. The launch branch that sends NO
# header lets an inherited one through instead of removing it, so a launch this
# wrapper deliberately declined to attribute is attributed anyway, by whoever
# ran the parent. Only case 4s regresses: T25b and T25c drive the OTHER two
# declining branches, and each branch is covered separately on purpose (the R4
# lesson — a mutation sweep once survived this suite by asserting argv off
# another test's launch).
fresh_copy
mutate "agents/lib/$WRAPPER" \
  '    env -u ANTHROPIC_CUSTOM_HEADERS claude --dangerously-skip-permissions "$@"
  fi
}' \
  '    command claude --dangerously-skip-permissions "$@"
  fi
}'
check "M9 inherited-header-passed-through-on-an-unattributed-launch" wrapper \
      "T25" "T25b T25c T25d"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    The tap-failover chain is not guarded the way the suites claim."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
