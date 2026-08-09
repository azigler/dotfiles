#!/bin/bash
# Mutation harness for api-stall-recover.sh — the killed-turn revival guard.
#
#     bash agents/scheduler/mutate-api-stall-recover.sh [-v]
#
# WHY THIS EXISTS. api-stall-recover.sh decides WHICH PANE ON THE BOX GETS TYPED
# INTO, unattended, every two minutes — and what it types is a paragraph of
# English. Its failure directions are asymmetric and both silent: too shy and the
# 2026-08-09 outage repeats (four seats sat idle for 2.5h with no bell, no retry
# and no signal of any kind — dotfiles-kviw); too eager and it types that
# paragraph into a raw shell, which RUNS it, or into Zig's open modal dialog,
# where the follow-up Enter answers his question with the default. The reviewer
# demonstrated the first of those against this very script on 2026-08-09, which
# is where the pane-identity gate came from.
#
# The fifteen mutants that shipped with dotfiles-r3sm were run from a live
# session and lost with it — the shape repo rule 1 exists for. This file is that
# evidence made repeatable, and tools/githooks/pre-commit is its consumer.
#
# ---------------------------------------------------------------------------
# THE PROPERTY THAT MAKES THIS HARNESS HONEST: assert the mutation APPLIED.
# ---------------------------------------------------------------------------
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh, five checks before any
# suite result is allowed to mean anything (dotfiles-47nf):
#
#   1. the target text occurs EXACTLY ONCE in the pristine file
#   2. the replacement text occurs ZERO times in the pristine file (not a no-op)
#   3. the file's bytes actually changed
#   4. the replacement occurs exactly once afterwards
#   5. `bash -n` is still clean (it dies of the bug it NAMES, not of a syntax
#      error that fails every case)
#
# Any of those failing is a HARNESS ERROR — never a killed mutant.
#
# AND A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES (dotfiles-77s4).
# test-api-stall-recover.sh names its cases in PROSE rather than by number, so
# each mutant below names a distinctive FRAGMENT of the failure message it must
# produce and check() asserts that fragment appears. Same property, matched on
# text instead of on an integer.
#
# The `must keep PASSING` column carries most of the sharpness here. M2 keeps the
# refusal and breaks only its ORDER (identity before capture). M6 leaves the real
# 529 fixture skipped and is caught only by the constructed 503-that-mentions-
# connecting. M10 leaves every single-error case green and is visible only where
# a stale error sits ABOVE a fresh one. M12 still sends two send-keys calls, so
# counting alone cannot see it — only the assertion that the FIRST call does not
# end in ` Enter`.
#
# HERMETIC. The suite it drives fakes tmux and curl on PATH and points
# HARNESS_STATE_DIR at a per-case tmpdir: the live tmux server is never
# contacted, no real pane is ever typed into, and the real gateway is never
# probed. Both the script and the suite are copied into a scratch dir, so the
# real tree is never edited (the suite finds its subject by `dirname $0`).

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of api-stall-recover.sh. `$block`, `$pane`, `$NUDGE` and
# friends inside them must NOT expand — they are matched byte-for-byte against
# the file on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="${SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}"   # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-apistall.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ASR="api-stall-recover.sh"
SUITE="test-api-stall-recover.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$ASR" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$ASR" "$WORK/scheduler/$ASR"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$SUITE" 2>&1)
  return $?
}

harness_error() { echo "HARNESS ERROR  $*" >&2; HARNESS_ERR=1; MUTANT_OK=0; }

# mutate <file> <literal-from> <literal-to> — the five assertions above. Fixed
# strings, never regexes: over-escaping a pattern is the exact failure this
# shape was written to make impossible, so there is no pattern to over-escape.
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
    sys.stderr.write("  replacement text is ALREADY present — the mutation is a no-op.\n")
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
    harness_error "$file: bytes IDENTICAL to pristine after a 'successful' write"; return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$file: the mutant is not valid bash — it would fail every case for the wrong reason"; return 1
  fi
  return 0
}

# check <mutant-name> <must-FAIL fragments> [<must-PASS fragments>]
# Fragments are newline-separated substrings of the suite's `bad "…"` names.
check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got frag missing="" wrongly=""

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

  got=$(printf '%s\n' "$SUITE_OUT" | grep -E '^  - ')
  while IFS= read -r frag; do
    [ -z "$frag" ] && continue
    case "$got" in *"$frag"*) ;; *) missing="$missing"$'\n'"             · $frag" ;; esac
  done <<<"$want_fail"
  while IFS= read -r frag; do
    [ -z "$frag" ] && continue
    case "$got" in *"$frag"*) wrongly="$wrongly"$'\n'"             · $frag" ;; esac
  done <<<"$want_pass"

  if [ -n "$missing" ]; then
    echo "MIS-KILLED $name"
    echo "           the suite went red but NOT on the case(s) this mutant names:$missing"
    echo "           actually failing:"
    printf '%s\n' "$got" | sed 's/^  - /             ✗ /'
    FAILED=1
  elif [ -n "$wrongly" ]; then
    echo "MIS-KILLED $name"
    echo "           case(s) that had to keep PASSING went red:$wrongly"
    echo "           actually failing:"
    printf '%s\n' "$got" | sed 's/^  - /             ✗ /'
    FAILED=1
  else
    echo "killed    $name"
    printf '%s\n' "$got" | sed 's/^  - /          ✗ /'
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

# M1 — THE IDENTITY ALLOW-LIST WIDENED TO THE SHELL. Precisely the "fix a missed
# nudge by deleting this gate" the header forbids. A plain zsh pane DISPLAYING
# captured error text — someone `cat`s api-error-captures.jsonl, greps a log,
# opens this suite's own fixtures — satisfies every content rule below, and under
# Zig's p10k prompt it even has the `❯`. The guard then types a paragraph of
# English into a raw shell, which runs it. (The bounded-log cases redden as
# collateral: a nudged run flushes its skip buffer. Not what this mutant names.)
fresh_copy
mutate "$ASR" \
  'PANE_CMDS="${ASR_PANE_CMDS:-claude bwrap node}"' \
  'PANE_CMDS="${ASR_PANE_CMDS:-claude bwrap node zsh}"'
check "M1 identity-allow-list-widened-to-zsh" \
  "a zsh pane displaying error text is NOT a claude pane ⇒ skipped
a non-claude pane is refused BEFORE capture-pane" \
  "control: the SAME content on a claude pane IS nudged
ASR_PANE_CMDS extends the allow-list"

# M2 — IDENTITY STILL CHECKED, BUT AFTER THE CAPTURE. The refusal survives
# untouched: the zsh pane is still skipped, still not typed into, and the run's
# counts are identical. What is lost is the ORDER the header insists on — a
# non-claude pane's scrollback is none of this guard's business, and reading it
# first is how a content rule ends up being the thing that decides. Only the
# `zero captures` assertion sees it.
fresh_copy
mutate "$ASR" \
  '  if ! is_claude_pane "$pcmd"; then' \
  '  tail_text=$("$TMUX_BIN" capture-pane -p -t "$pane" | tail -n "$TAIL_LINES") # MUTANT: capture first
  if ! is_claude_pane "$pcmd"; then'
check "M2 capture-before-identity (refusal intact, order lost)" \
  "a non-claude pane is refused BEFORE capture-pane" \
  "a zsh pane displaying error text is NOT a claude pane ⇒ skipped
control: the SAME content on a claude pane IS nudged"

# M3 — THE UPSTREAM GATE REMOVED. Nudging a session into a gateway that is still
# down re-errors it immediately AND burns its 15-minute cooldown, so the one
# recovery this guard had for that pane is spent on a dead door. The pair's whole
# ordering (gateway-health on the even minutes, this on the odd ones) exists to
# make this gate meaningful.
fresh_copy
mutate "$ASR" \
  'if [ "$PROBE_RC" -ne 0 ] || [ "${CODE:-000}" = "000" ]; then' \
  'if false; then'
check "M3 upstream-gate-removed (nudges into a dead gateway)" \
  "upstream down ⇒ upstream-down/exit0
upstream down ⇒ zero send-keys AND zero pane captures
connected-but-slow upstream ⇒ upstream-down, no captures, no nudges
connect-phase timeout ⇒ upstream-down, no nudges
a 401 with curl rc 28 is NOT cleanly up ⇒ upstream-down, no nudges"

# M4 — THE PROBE'S EXIT CODE IGNORED, READ THE BODY ONLY. The sharp half of the
# `000 is three facts` rule: headers can come back with a real HTTP status and
# the transfer still time out. The body then says 401 — the healthy signature,
# indistinguishable from health — while curl's rc 28 says the gateway is limping.
# Refused and blackholed still print 000 and are still caught, so the ordinary
# down cases stay green and this is invisible everywhere but the sharp one.
fresh_copy
mutate "$ASR" \
  'if [ "$PROBE_RC" -ne 0 ] || [ "${CODE:-000}" = "000" ]; then' \
  'if [ "${CODE:-000}" = "000" ]; then'
check "M4 probe-rc-ignored (a 401 that timed out reads as health)" \
  "a 401 with curl rc 28 is NOT cleanly up ⇒ upstream-down, no nudges" \
  "upstream down ⇒ upstream-down/exit0
connected-but-slow upstream ⇒ upstream-down, no captures, no nudges"

# M5 — THE 🔔 REFUSAL DROPPED. pulse-inject §3.5 and pulse-retry's same rule:
# never inject into a bell. A 🔔 window is Zig sitting in a modal dialog, so
# send-keys feeds the DIALOG and the Enter that follows answers his open question
# with whatever the default happens to be.
fresh_copy
mutate "$ASR" \
  '  if [ "$window" != "${window#🔔}" ]; then' \
  '  if [ "$window" = "ZZ-NEVER" ]; then'
check "M5 injects-into-a-bell" \
  "🔔 window ⇒ skipped, zero send-keys
mixed fleet ⇒ ok:nudged:1:skipped:3 / exit 10
mixed fleet ⇒ only the stalled pane is typed into"

# M6 — 3-DIGIT PRECEDENCE LOST. A settled HTTP status is harnessd's bell and may
# be something a human must answer; re-running the turn can repeat a rejected
# request or feed an overload. Note what does NOT catch this: the REAL 529
# fixture has no connection words, so the whitelist skips it either way and it
# stays green. Only the constructed proxy-503-that-mentions-connecting — where
# the two rules genuinely disagree — can see the precedence.
fresh_copy
mutate "$ASR" \
  "  if printf '%s\\n' \"\$block\" | grep -qE 'API Error: *[0-9]{3}'; then" \
  "  if printf '%s\\n' \"\$block\" | grep -qE 'ZZ-NEVER-MATCHES'; then"
check "M6 3-digit-precedence-lost (a settled 503 re-run by a timer)" \
  "a 3-digit code WINS over connection words in the same error ⇒ skipped" \
  "3-digit API Error (529) ⇒ skipped
an unrecognised API Error shape ⇒ skipped"

# M7 — THE RETRY TAIL IGNORED. The client is already handling it; typing into a
# session mid-retry races its own recovery and lands a stray turn in the composer
# the moment the retry succeeds.
fresh_copy
mutate "$ASR" \
  "  if printf '%s\\n' \"\$block\" | grep -qiE 'Retrying|attempt [0-9]+/[0-9]+'; then" \
  "  if printf '%s\\n' \"\$block\" | grep -qiE 'ZZ-NEVER-MATCHES'; then"
check "M7 retry-tail-ignored (races the client's own recovery)" \
  "retry tail ⇒ skipped, zero send-keys, exit 0
mixed fleet ⇒ ok:nudged:1:skipped:3 / exit 10
mixed fleet ⇒ only the stalled pane is typed into"

# M8 — THE IN-FLIGHT GUARD REMOVED. `esc to interrupt` means a turn is RUNNING:
# the error above it was survived, not fatal. Typing here interrupts live work
# with an instruction to redo work that is already being done.
fresh_copy
mutate "$ASR" \
  "  if printf '%s\\n' \"\$block\" | grep -qF 'esc to interrupt'; then" \
  "  if printf '%s\\n' \"\$block\" | grep -qF 'ZZ-NEVER-MATCH-esc'; then"
check "M8 in-flight-guard-removed (types over a live turn)" \
  "in-flight turn ('esc to interrupt') ⇒ skipped" \
  "healthy pane ⇒ skipped, zero send-keys, exit 0"

# M9 — THE IDLE-COMPOSER REQUIREMENT DROPPED. An error the session has already
# moved PAST is not a stall; without a composer marker after it there is no
# evidence the pane is at a prompt at all, and a pane that is not at a prompt is
# a pane where this text goes somewhere nobody chose.
fresh_copy
mutate "$ASR" \
  "  if ! printf '%s\\n' \"\$block\" | grep -qE '❯|new task\\?'; then" \
  '  if false; then'
check "M9 composer-requirement-dropped (types at a pane that moved on)" \
  "no idle composer after the error ⇒ skipped" \
  "real seneschal tail ⇒ nudged, exit 10
real dotfiles tail (task-list overlay) ⇒ nudged"

# M10 — THE FIRST ERROR BLOCK INSTEAD OF THE LAST. One `if (!n)` and the guard
# reads the OLDEST error in the tail: a stale 529 from an hour ago then vetoes a
# fresh ConnectionRefused underneath it, and the pane stays stalled for exactly
# as long as the outage lasts. Invisible in every single-error case — which is
# every other case in the suite.
fresh_copy
mutate "$ASR" \
  '    /API Error:/ { n = NR }' \
  '    /API Error:/ { if (!n) n = NR }'
check "M10 first-error-block-not-last (a stale 529 vetoes a fresh outage)" \
  "a stale 529 above a fresh ConnectionRefused must not veto the nudge" \
  "real seneschal tail ⇒ nudged, exit 10
3-digit API Error (529) ⇒ skipped"

# M11 — THE COOLDOWN REMOVED. One nudge per outage per pane is the contract; at
# a 2-minute cadence, a pane that does not recover on the first nudge gets the
# same paragraph typed into it 30 times an hour, forever.
fresh_copy
mutate "$ASR" \
  '  if [ -n "$last" ] && [ "$((NOW - last))" -lt "$COOLDOWN_S" ]; then' \
  '  if [ -n "$last" ] && [ "$((NOW - last))" -lt 0 ]; then'
check "M11 cooldown-removed (the same nudge every two minutes)" \
  "cooldown: two runs, one nudge
cooldown expired ⇒ eligible again"

# M12 — TEXT AND ENTER IN ONE BURST. The pulse-inject §4 mechanism this mirrors
# sends the text, settles, and sends Enter SEPARATELY, because some TUIs
# mis-handle a combined burst — the composer can swallow the newline, or submit a
# half-typed line. Note this mutant still produces TWO recorded send-keys calls,
# so every count assertion in the suite stays green: only the assertion that the
# first call does not end in ` Enter` can see it.
fresh_copy
mutate "$ASR" \
  '  "$TMUX_BIN" send-keys -t "$pane" -- "$NUDGE"
  sleep "$SEND_SETTLE"' \
  '  "$TMUX_BIN" send-keys -t "$pane" -- "$NUDGE" Enter
  sleep "$SEND_SETTLE"'
check "M12 text-and-enter-in-one-burst (counts unchanged)" \
  "nudge = send-keys TEXT then a separate Enter" \
  "real seneschal tail ⇒ nudged, exit 10
control: the SAME content on a claude pane IS nudged
mixed fleet ⇒ only the stalled pane is typed into"

# M13 — THE OWN-PANE REFUSAL DROPPED. If this guard is ever run from inside tmux
# — by hand, or from a seat's own pane — TMUX_PANE is the only identity it has,
# and without the check it types its nudge into the session that launched it.
fresh_copy
mutate "$ASR" \
  '  if [ -n "${TMUX_PANE:-}" ] && [ "$pane" = "$TMUX_PANE" ]; then' \
  '  if [ -n "${TMUX_PANE:-}" ] && [ "$pane" = "ZZ-NEVER" ]; then'
check "M13 own-pane-refusal-dropped" \
  "the guard's own pane is skipped"

# M14 — THE STATE DIRECTORY STOPS BEING A PRECONDITION. The cooldown file is this
# guard's ONLY memory of whom it nudged; without it every run is the first run,
# and the fleet gets the same paragraph typed into it every two minutes forever.
# Fail-closed BEFORE any pane is read is the only safe posture, which is why the
# unwritable-state case asserts zero captures as well as zero send-keys.
fresh_copy
mutate "$ASR" \
  'mkdir -p "$STATE_DIR" || {
  printf '"'"'api-stall-recover: cannot create the state directory %s — refusing to\n'"'"' "$STATE_DIR" >&2
  printf '"'"'                   nudge anything without a cooldown to remember it by.\n'"'"' >&2
  CHECKER_BROKEN=1
  exit 1
}' \
  'mkdir -p "$STATE_DIR" # MUTANT: no longer a precondition'
check "M14 state-dir-not-a-precondition (acts with no memory)" \
  "unwritable state dir ⇒ exit 1, nothing typed, nothing captured" \
  "even a broken checker ends with the result marker"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    api-stall-recover.sh is not guarded the way its suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
