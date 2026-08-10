#!/bin/bash
# Mutation harness for the dotfiles-o3qj MOLT-REFUSAL arm — both halves.
#
#   bash agents/scheduler/mutate-o3qj-molt-refusal.sh [-v]
#
# WHY THIS EXISTS. AGENTS.md's it06 says "a failed/refused molt (twice) is the
# only context event that summons Zig". Until o3qj that sentence had no mechanical
# arm: seat-molt.sh refused, wrote a ledger row, and NOTHING READ IT. Measured
# twice on 2026-08-09 — the dream seat at 100% context for 3+ hours after
# `refused-not-offboarded`, and the marshal at 73% at 21:22:12Z after
# `refused-rate-limited`. Both times the DECISION was right and the SILENCE was
# the bug.
#
# The arm has two halves and BOTH fail silently in the dangerous direction:
#
#   * seat-molt.sh must RECORD every refusal (with its reason). A recorder that
#     quietly stops writing a verdict looks exactly like a seat that stopped
#     refusing — the ledger just gets shorter.
#   * pulse-escalate.sh must ACT on the second one, once. A watcher that stops
#     summoning looks exactly like a quiet night; a watcher that summons on every
#     5-minute tick looks like a busy one, and both are indistinguishable from
#     correct until someone counts beads.
#
# Per this repo's rule 1: a green suite is not evidence that a guard bites; only a
# mutant that dies is. This file is that evidence.
#
# MODELLED ON mutate-t5fj-staleness.sh, deliberately, including both clauses that
# harness burned in:
#
#   * ASSERT THE MUTATION APPLIED. Every mutation is checked five ways (target text
#     present exactly once, replacement absent beforehand, bytes changed,
#     replacement present exactly once afterwards, `bash -n` still clean) before its
#     suite result is allowed to mean anything. A suite that goes red under an
#     UNAPPLIED mutation is a HARNESS ERROR, not a kill (dotfiles-47nf).
#   * A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES. Red-somewhere says nothing
#     about the guard under test (dotfiles-77s4). Each mutant declares the case ids
#     that must FAIL and the ones that must keep PASSING.
#
# COST, measured on this box 2026-08-09: 5m29s wall for baseline + 2 recorder
# mutants + 9 watcher mutants. The seat-molt suite (real tmux fixtures, ~50s a run)
# is three of those runs and most of the clock; the escalate suite is fully shimmed
# and cheap. That is why pre-commit fires this on five files — the two scripts,
# their two suites, and this harness — and not on every scheduler edit.
#
# ⚠️ Runs both suites against scratch COPIES; the real tree is never edited. The
# seat-molt suite drives its own private tmux server on an absolute socket path
# inside its own mktemp dir, so it cannot reach Zig's session — but do not run this
# concurrently with test-seat-molt.sh or mutate-seat-molt.sh: no benefit, six tmux
# servers.

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE TEXT
# copied out of the scripts. `$reason`, `$MOLT_WINDOW_S`, `${MOK[$mseat]:-0}` and
# friends inside them must NOT expand — they are matched byte-for-byte against the
# file on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="${SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}"   # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-o3qj.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

SM="seat-molt.sh"
SM_SUITE="test-seat-molt.sh"
PE="pulse-escalate.sh"
PE_SUITE="test-pulse-escalate.sh"

# The case COUNTS each suite must report at baseline. Neither suite is run through
# a section filter here, so a zero-case run is not the hazard mutate-t5fj-staleness
# guards against — the hazard is a suite that lost cases to a bad merge or a
# half-applied edit, which would let a mutant "die" against coverage that is no
# longer there. Bump these when a case is added, deliberately.
EXPECT_MOLT_CASES=69
EXPECT_ESC_CASES=45

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$SM" "$SM_SUITE" "$PE" "$PE_SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done
# seat-molt.sh and its suite resolve siblings through ../hooks and ../lib
# (portable.sh's _p_mtime, handoff-path.sh's per-window scoping). Symlink the REAL
# dirs beside the copies so the mutant is the ONLY difference from a real checkout;
# copying those trees would silently change what "unchanged" means.
ln -sfn "$SRC/../hooks" "$WORK/hooks"
ln -sfn "$SRC/../lib"   "$WORK/lib"

fresh_copy() {
  MUTANT_OK=1
  for f in "$SM" "$SM_SUITE" "$PE" "$PE_SUITE"; do
    cp -a "$WORK/pristine/$f" "$WORK/scheduler/$f"
  done
}

run_molt_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$SM_SUITE" 2>&1)
  return $?
}
run_esc_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$PE_SUITE" 2>&1)
  return $?
}

harness_error() {
  echo "HARNESS ERROR  $*" >&2
  HARNESS_ERR=1
  MUTANT_OK=0
}

# mutate <file> <literal-from> <literal-to> — literal substring swap with all five
# applied-ness assertions. Fixed strings, never regexes: over-escaping a pattern is
# the exact failure this shape exists to make impossible.
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

# check <runner> <mutant-name> <must-FAIL ids> [<must-PASS ids>]
# Both suites print `  - <id> <description>` for every failure, so the id is field
# 2 — the same contract mutate-seat-molt.sh and mutate-pulse-escalate.sh rely on.
# Renumbering a case in either suite means updating this file.
check() {
  local runner=$1 name=$2 want_fail=$3 want_pass=${4:-} got c missing="" wrongly=""

  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply — see HARNESS ERROR above)"
    return
  fi

  if "$runner"; then
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

# want_cases <label> <expected> — the baseline's case count must match, or every
# mutant below is being measured against unknown coverage.
want_cases() {
  local label=$1 want=$2 got
  got=$(printf '%s\n' "$SUITE_OUT" | tail -1 | sed -n -E 's/^PASS: ([0-9]+)\/([0-9]+).*/\2/p')
  if [ "${got:-0}" -ne "$want" ]; then
    echo "  HARNESS ERROR: $label ran ${got:-0} cases, expected $want."
    echo "  A suite that lost (or gained) cases makes every mutant below meaningless."
    exit 2
  fi
}

echo "=== baseline: the unmutated copies must be GREEN =========================="
fresh_copy
if run_molt_suite; then
  echo "  ok      $SM_SUITE: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
  want_cases "$SM_SUITE" "$EXPECT_MOLT_CASES"
else
  echo "  BROKEN  $SM_SUITE is RED before any mutation — nothing below means anything"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi
if run_esc_suite; then
  echo "  ok      $PE_SUITE: $(printf '%s\n' "$SUITE_OUT" | tail -1)"
  want_cases "$PE_SUITE" "$EXPECT_ESC_CASES"
else
  echo "  BROKEN  $PE_SUITE is RED before any mutation"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== ARM 1: seat-molt.sh — the refusal RECORD =============================="

# S1 [refusal-unrecorded] — THE PRE-o3qj STATE OF THE WORLD, near enough: the
# refusal paths stop writing a ledger row, so the watcher has nothing to read and
# a wedged seat leaves no trace at all. The successful-molt row keeps being written
# (case 7, 26l), which is what makes this a targeted kill rather than "the ledger
# broke" — and it is also the shape the defect would really take, since the happy
# path is the one everyone tests.
fresh_copy
mutate "$SM" \
  'finish() {
  ledger_row "$1" "${3:-}"' \
  'finish() {
  case "$1" in refused-*|failed-*|aborted-*) ;; *) ledger_row "$1" "${3:-}" ;; esac'
check run_molt_suite "S1 [refusal-unrecorded] refusals never reach the ledger" \
  "26a 26b 26d 26f 26h 26j" \
  "7 26 26c 26e 26g 26i 26k 26l"

# S2 [refusal-reason-dropped] — the row survives, the REASON does not. This is the
# subtle half: `result` alone tells the watcher a refusal happened and nothing at
# all about which rail refused, so the P1 bead it files degrades from "the offboard
# marker names a different session, then the 30m rate limit" to "refused twice" —
# a summon with no evidence in it, which is a summon Zig has to reproduce by hand.
fresh_copy
mutate "$SM" \
  '    "$(_json_esc "$reason")" \
' \
  '    "" \
'
check run_molt_suite "S2 [refusal-reason-dropped] the row lands with an empty reason" \
  "26a 26d 26f 26h 26j" \
  "7 26 26c 26e 26g 26i 26k 26l"

echo
echo "=== ARM 2: pulse-escalate.sh — the CONSUMER =============================="

# E1 [refusal-unread] — THE o3qj DEFECT ITSELF, restored in one line: the ledger is
# never opened. Every refusal is recorded perfectly and read by nobody, which is
# exactly the state the dream seat sat in for three hours. Cases 31/33/34 keep
# passing because they assert that NOTHING happens — proof that "silent" and
# "correctly silent" are different, and that this suite can tell them apart.
fresh_copy
mutate "$PE" \
  'if [ "$MOLT_WATCH" = on ] && [ -s "$MOLT_LEDGER" ]; then' \
  'if false; then'
check run_esc_suite "E1 [refusal-unread] the molt ledger has no consumer (the bug)" \
  "27 28 29 30 30b 32 33b" \
  "31 33 34 35"

# E2 [second-refusal-does-not-summon] — the arm it06 actually names. Refusals are
# read, notes are written, and the SECOND one never escalates: the ladder becomes a
# diary. This is the failure that reads as working software — the log fills with
# MOLT-NOTE lines and nobody is ever told.
fresh_copy
mutate "$PE" \
  'if [ "$mcount" -lt 2 ]; then' \
  'if [ "$mcount" -lt 99 ]; then'
check run_esc_suite "E2 [second-refusal-does-not-summon] it06's rule loses its arm" \
  "28 30b 33b" \
  "27 29 31 32 33 34 35"

# E3 [summon-spams-every-tick] — the opposite failure, and the one that discredits
# the mechanism rather than merely disabling it. The ledger is APPEND-ONLY and this
# script ticks every 5 minutes, so without the per-episode memory the same two rows
# file a P1 bead and buzz Zig's phone twelve times an hour, all night, about one
# wedge. A summon that cries wolf is worse than no summon.
fresh_copy
mutate "$PE" \
  '[ "$m_stage" = summoned ] && continue' \
  '[ "$m_stage" = zz-never-matches ] && continue'
check run_esc_suite "E3 [summon-spams-every-tick] the episode memory is ignored" \
  "29" \
  "27 28 30 31 32 33 34 35"

# E4 [rolling-window-ignored] — the episode gap stops bounding anything, so two
# refusals four hours apart are read as one escalating wedge. A seat that refuses
# once each morning then pages Zig on the second morning, forever.
fresh_copy
mutate "$PE" \
  '[ $((m_prev - _e)) -le "$MOLT_WINDOW_S" ] || break' \
  '[ $((m_prev - _e)) -le 999999999 ] || break'
check run_esc_suite "E4 [rolling-window-ignored] refusals never fall out of an episode" \
  "30" \
  "27 28 29 31 32 33 34 35"

# E5 [stale-episode-summons] — the "nothing has refused inside the window" check
# dropped. The ledger keeps every row forever, so the watcher starts acting on
# refusals from days ago: a wedge that resolved on its own becomes a note (and, with
# E4 alongside, a summon) about a seat that is fine right now.
fresh_copy
mutate "$PE" \
  '[ $((now - m_newest_ep)) -le "$MOLT_WINDOW_S" ] || continue' \
  '[ $((now - m_newest_ep)) -le 999999999 ] || continue'
check run_esc_suite "E5 [stale-episode-summons] an episode that is over still acts" \
  "31" \
  "27 28 29 30 32 33 34 35"

# E6 [successful-molt-does-not-reset] — the reset that TONIGHT'S REAL TRAIL needs.
# The marshal went refused-not-offboarded 19:22 -> molted 21:15 -> refused-rate-
# limited 21:22. Without the "drop everything at or before the newest successful
# molt" filter, that trail is two refusals inside the window and Zig gets paged
# about a seat that molted seven minutes ago. This mutant is the false positive
# that would have discredited the whole mechanism on its first night.
#
# The replacement keeps the `&& _melig+=` tail deliberately: the obvious mutant —
# dropping the guard entirely and leaving a bare `_melig+=("$_r")` — is REFUSED by
# the applied-ness assertion, because that text is already a substring of the line
# it replaces and the swap would be a silent no-op. The harness caught it on its
# own author, 2026-08-09, which is the whole reason assertion 2 exists.
fresh_copy
mutate "$PE" \
  '[ "$_e" -gt "${MOK[$mseat]:-0}" ] && _melig+=("$_r")' \
  '[ "$_e" -gt 0 ] && _melig+=("$_r")'
check run_esc_suite "E6 [successful-molt-does-not-reset] a molt no longer ends the episode" \
  "32" \
  "27 28 29 30 31 33 34 35"

# E7 [summon-never-pushes] — the bead is filed, the phone stays quiet. Same defect
# as M7 on the bounce floor and the same reasoning: the bead is the durable surface
# and the push is the one that reaches Zig tonight, so a floor that degrades to
# bead-only degrades to exactly the surface he is not watching. Case 7 must keep
# passing — the bounce ladder's own push shares push_now, and a mutant that broke
# both would be telling us nothing about this one.
fresh_copy
mutate "$PE" \
  'push_now "MOLT-SUMMON $mseat" "$m_win seat is wedged" "$m_title"' \
  ': # MUTANT: bead only, no push'
check run_esc_suite "E7 [summon-never-pushes] the summon files a bead and stays silent" \
  "28 30b 33b" \
  "7 27 29 31 32 33 34 35"

# E8 [kill-switch-inert] — `molt_refusal_watch=off` stops meaning off. Harmless
# today (the default is on), and exactly the kind of thing that is discovered at
# the worst moment: the one time someone needs to silence a misfiring watcher.
fresh_copy
mutate "$PE" \
  'MOLT_WATCH=$(cfg molt_refusal_watch on)' \
  'MOLT_WATCH=on'
check run_esc_suite "E8 [kill-switch-inert] molt_refusal_watch=off does nothing" \
  "34" \
  "27 28 29 31 33 35"

# E9 [empty-pct-shifts-fields] — the reviewer's defect, restored verbatim: the
# packed row parsed with `IFS=$'\t' read`. Tab is IFS WHITESPACE, so a run of tabs
# collapses to one delimiter, and `pct` is empty on every refusal recorded without
# a statusline reading — which is most of them, and ALL of the pre-o3qj rows. The
# reason then lands in the pct slot and the page reads "(context <the whole reason
# sentence>%) — <no reason recorded>": a fabricated percentage in the headline and
# the evidence gone from the body. It survives every other case in this suite,
# because they all carry a numeric pct — which is exactly why 36/36b had to be
# written with a null one.
fresh_copy
mutate "$PE" \
  'row_fields() {
  local rest
  R_EPOCH=${1%%$'"'"'\t'"'"'*}; rest=${1#*$'"'"'\t'"'"'}' \
  'row_fields() {
  local rest
  IFS=$'"'"'\t'"'"' read -r R_EPOCH R_RESULT R_PCT R_REASON <<< "$1"; return 0
  R_EPOCH=${1%%$'"'"'\t'"'"'*}; rest=${1#*$'"'"'\t'"'"'}'
check run_esc_suite "E9 [empty-pct-shifts-fields] a null pct shifts the reason into the pct slot" \
  "36 36b" \
  "27 28 29 30 31 32 33 34 35"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    it06's refused-twice rule is not armed the way the suites claim."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
