#!/bin/bash
# Mutation sweep for pulse-escalate.sh's ladder guards (dotfiles-9z3o).
# Modelled on agents/scheduler/mutate-tunnel-ownership.sh: five applied-ness
# assertions before any suite result is allowed to mean anything, and every killed
# mutant must fail the case(s) it NAMES.

# shellcheck disable=SC2016
set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# THE ONE LINE THAT CHANGED ON PROMOTION (dotfiles-w4z9). In the scratchpad this
# harness lived outside the tree and had to be told where the tree was
# (`SRC_DIR:?`). Committed, it lives IN agents/scheduler, and tools/githooks/
# pre-commit invokes every mutation harness bare — `bash "$ROOT/<path>"`, no env —
# so it must resolve its own directory the way mutate-tunnel-ownership.sh does.
# SRC_DIR still overrides, so the scratchpad invocation keeps working verbatim.
SRC="${SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}"   # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-escalate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PE="pulse-escalate.sh"
SUITE="test-pulse-escalate.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$PE" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$PE" "$WORK/scheduler/$PE"
  cp -a "$WORK/pristine/$SUITE" "$WORK/scheduler/$SUITE"
}

run_suite() {
  SUITE_OUT=$(bash "$WORK/scheduler/$SUITE" 2>&1)
  return $?
}

harness_error() { echo "HARNESS ERROR  $*" >&2; HARNESS_ERR=1; MUTANT_OK=0; }

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
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || { harness_error "$file: mutation did not apply"; return 1; }
  if cmp -s "$pristine" "$path"; then
    harness_error "$file: bytes IDENTICAL to pristine after a 'successful' write"; return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$file: the mutant is not valid bash"; return 1
  fi
  return 0
}

# mutate_more <file> <from> <to>
#   A SECOND swap on an ALREADY-mutated file. mutate() deliberately re-reads the
#   pristine copy every time (so one mutant can never leak into the next), which
#   makes it useless for a compound mutant — and a compound one is exactly what the
#   wrapped-chrome blocker needs, because each layer of that fix independently
#   refuses the rename and only DROPPING BOTH reproduces the reviewer's chain. So
#   this applies the same five assertions against the CURRENT file instead.
mutate_more() {
  local file=$1 from=$2 to=$3
  local path="$WORK/scheduler/$file" before_sum
  before_sum=$(cksum < "$path")
  python3 - "$path" "$from" "$to" <<'PY'
import sys
path, frm, to = sys.argv[1:4]
before = open(path).read()
n = before.count(frm)
if n != 1:
    sys.stderr.write(f"  target text occurs {n}x (want exactly 1) in the ALREADY-MUTATED {path}\n")
    sys.exit(1)
if to in before:
    sys.stderr.write("  replacement text is ALREADY present — the second mutation is a no-op.\n")
    sys.exit(1)
after = before.replace(frm, to)
open(path, "w").write(after)
if after.count(to) != 1:
    sys.stderr.write("  replacement is not present exactly once after the write\n")
    sys.exit(1)
PY
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || { harness_error "$file: second mutation did not apply"; return 1; }
  if [ "$before_sum" = "$(cksum < "$path")" ]; then
    harness_error "$file: bytes UNCHANGED by the second mutation"; return 1
  fi
  if ! bash -n "$path"; then
    harness_error "$file: the compound mutant is not valid bash"; return 1
  fi
  return 0
}

check() {
  local name=$1 want_fail=$2 want_pass=${3:-} got c missing="" wrongly=""
  if [ "$MUTANT_OK" -ne 1 ]; then
    echo "NOT RUN   $name  (its mutation did not apply)"; return
  fi
  if run_suite; then
    echo "SURVIVED  $name  ($SUITE is still green)"
    printf '%s\n' "$SUITE_OUT" | tail -1 | sed 's/^/          /'
    FAILED=1; return
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
    echo "           red, but NOT on the case(s) this mutant names:$missing"
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
  echo "  BROKEN  $SUITE is RED before any mutation"
  printf '%s\n' "$SUITE_OUT" | tail -12 | sed 's/^/          /'
  exit 1
fi

echo
echo "=== mutants ==============================================================="

# M1 — NAME-ONLY TRUST RESTORED. The exact defect dotfiles-jisc names, moved to the
# consumer side: reconcile on the 🔔 NAME without consulting the pane. A live
# AskUserQuestion then gets its glyph cleared and its loop re-fired.
fresh_copy
mutate "$PE" \
  '      if [ "$pm" = 1 ]; then
        stripped=$(strip_lexicon "$wname")' \
  '      if [ "$pm" != 99 ]; then
        stripped=$(strip_lexicon "$wname")'
check "M1 name-only-trust (rename whatever the pane says)" "3 4 15 16 19 20"

# M11 — RENAME ON CHROME-ABSENCE ALONE: signal 2 deleted, so "the chrome ERE did not
# match" is once again sufficient to clear a 🔔. This is the first cut's rule, and the
# ambiguous pane is where an absence stops being evidence.
fresh_copy
mutate "$PE" \
  '  [ -n "$IDLE_MARKER" ] || return 2
  printf '"'"'%s\n'"'"' "$pane" | grep -Eq "$IDLE_MARKER" && return 1
  return 2                                            # neither signal => cannot tell' \
  '  return 1 # MUTANT: chrome-absence alone'
check "M11 rename-on-chrome-absence-alone (signal 2 deleted)" "20"

# M12 — -J DROPPED from the capture. The refusal survives (via the ambiguity
# fallback), so the only thing that notices is the CLASSIFICATION: a joined dialog
# reads CHROME PRESENT, an unjoined one reads AMBIGUOUS. Case 19 asserts the former.
fresh_copy
mutate "$PE" \
  'pane=$("$TMUX_BIN" capture-pane -pJ -t "=$session:$idx" 2>>"$LOG")' \
  'pane=$("$TMUX_BIN" capture-pane -p -t "=$session:$idx" 2>>"$LOG")'
check "M12 capture-not-joined (-J dropped)" "19"

# M13 — BOTH LAYERS DROPPED: the reviewer's demonstrated chain, end to end. Unjoined
# capture + rename-on-absence => a LIVE modal in a narrow pane gets its 🔔 cleared,
# after which pulse-retry re-fires and the injection's Enter answers Zig's dialog.
# Case 19 catches it on the rename itself, not merely on the classification.
fresh_copy
mutate "$PE" \
  'pane=$("$TMUX_BIN" capture-pane -pJ -t "=$session:$idx" 2>>"$LOG")' \
  'pane=$("$TMUX_BIN" capture-pane -p -t "=$session:$idx" 2>>"$LOG")'
mutate_more "$PE" \
  '  [ -n "$IDLE_MARKER" ] || return 2
  printf '"'"'%s\n'"'"' "$pane" | grep -Eq "$IDLE_MARKER" && return 1
  return 2                                            # neither signal => cannot tell' \
  '  return 1 # MUTANT: chrome-absence alone'
check "M13 wrapped-modal-renamed (both layers dropped — the reviewer's chain)" "19"

# M14 — THE WRITE PROBE REMOVED, leaving the `mkdir -p` mask. mkdir -p SUCCEEDS on an
# existing read-only directory, so the ladder acts with no way to remember that it did.
fresh_copy
mutate "$PE" \
  'if ! mkdir -p "$STATE_DIR" || ! : > "$_probe"; then' \
  'if ! mkdir -p "$STATE_DIR"; then'
check "M14 acts-without-persistable-memory (write probe removed)" "21"

# M15 — ROW ARITY UNCHECKED. `${row#*:}` returns the whole string with no colon, so a
# colonless row drives the ladder with a unit name where a window name belongs.
fresh_copy
mutate "$PE" \
  '  if ! printf '"'"'%s'"'"' "$row" | grep -qE '"'"'^[^:]+:[^:]+:[^:]+$'"'"'; then' \
  '  if [ -z "$row" ]; then'
check "M15 loops-row-arity-unchecked" "22"

# M9 — SECOND OWNER OF THE RE-FIRE DECISION (dotfiles-t5fj). The reconcile rung
# re-fires the blocked loop itself, racing pulse-retry — the exact defect measured
# live on 2026-08-09, where the two owners were two seconds apart and a stale
# '/clear + /marshal night' pair landed in a live run's composer.
fresh_copy
mutate "$PE" \
  '          note "RENAMED $loop: window $widx' \
  '          "$SYSTEMCTL_BIN" --user start "$loop.service" >>"$LOG" 2>&1
          note "RENAMED $loop: window $widx'
check "M9 reconciler-re-fires-the-loop-itself (the t5fj race)" "2b"

# M2 — GRACE REMOVED. The supervising session never gets the first move.
fresh_copy
mutate "$PE" \
  '  if [ $((now - ep_start_ep)) -lt "$GRACE_S" ]; then' \
  '  if [ $((now - ep_start_ep)) -lt 0 ]; then'
check "M2 grace-removed" "1"

# M3 — INJECT INTO A 🔔 SENESCHAL. pulse-retry's precedent dropped: the nudge lands
# in the front desk's own modal and its Enter answers Zig's question.
fresh_copy
mutate "$PE" \
  '      if [ "$sname" != "${sname#🔔}" ]; then
        note "$loop: seneschal window '"'"'$sname'"'"' is itself 🔔 — not injecting; raising instead"' \
  '      if [ "$sname" = "ZZ-NEVER" ]; then
        note "$loop: seneschal window '"'"'$sname'"'"' is itself 🔔 — not injecting; raising instead"'
check "M3 injects-into-a-blocked-seneschal" "5"

# M4 — UNVERIFIED RENAME. tmux said yes; the guard stops checking whether the glyph
# actually cleared, so the loop is re-fired straight back into a 🔔 window.
fresh_copy
mutate "$PE" \
  '        if [ -n "$after" ] && [ "$after" = "$(strip_lexicon "$after")" ]; then' \
  '        if true; then'
check "M4 rename-not-verified" "17"

# M10 — THE LOG CLAIMS AN OUTCOME IT DOES NOT OWN: the reconcile line asserts the
# loop was re-fired. Nothing about behaviour changes; only the telemetry lies. That
# is precisely the defect t5fj found in pulse-retry's own log.
fresh_copy
mutate "$PE" \
  'No re-fire issued here — pulse-retry owns that decision."' \
  'and re-fired the loop."'
check "M10 log-claims-a-refire-it-did-not-do" "2c"

# M5 — IN-FLIGHT GUARD REMOVED. A human is nudged about work that is running.
fresh_copy
mutate "$PE" \
  '    active|activating|reloading)' \
  '    zz-never-matches)'
check "M5 in-flight-guard-removed" "10"

# M6 — COOLDOWN REMOVED. Rungs fire back-to-back on every 5-minute tick.
fresh_copy
mutate "$PE" \
  '    if [ -n "$acted_ep" ] && [ $((now - acted_ep)) -lt "$COOLDOWN_S" ]; then' \
  '    if [ -n "$acted_ep" ] && [ $((now - acted_ep)) -lt 0 ]; then'
check "M6 cooldown-removed" "11"

# M7 — THE PUSH HALF OF THE FLOOR INVERTED. The bead is filed, the phone never buzzes:
# the floor degrades to exactly the surface Zig is not watching.
fresh_copy
mutate "$PE" \
  '  if [ -n "$PUSH_URL" ]; then' \
  '  if [ -z "$PUSH_URL" ]; then'
check "M7 floor-never-pushes" "7"

# M8 — not_ready FILTERED OUT: pulse-retry.sh's hole, restored. A composer that never
# comes up stalls the loop and escalates to nobody.
fresh_copy
mutate "$PE" \
  '    case "$r" in blocked_on_andrew|deferred-blocked-on-human|not_ready|already_running|deferred-already-running) ;; *) continue ;; esac' \
  '    case "$r" in blocked_on_andrew|deferred-blocked-on-human|already_running|deferred-already-running) ;; *) continue ;; esac'
check "M8 not_ready-not-escalated (the pulse-retry hole)" "8"

# M16 — already_running FILTERED OUT (dotfiles-t5fj): the state this script was in
# BEFORE this change. pulse-inject's --fresh same-loop refusal is the reason a lying
# glyph makes every scheduled tick defer, and with it dropped from the trigger set the
# whole class is invisible to the only watcher that would act on it — the bounces pile
# up in the log and nothing here ever reads them. Every case built on the new reason
# goes dark at once, which is the measure of how much the one word carries.
fresh_copy
mutate "$PE" \
  '    case "$r" in blocked_on_andrew|deferred-blocked-on-human|not_ready|already_running|deferred-already-running) ;; *) continue ;; esac' \
  '    case "$r" in blocked_on_andrew|deferred-blocked-on-human|not_ready) ;; *) continue ;; esac'
check "M16 already_running-not-escalated (the reason filter's blind spot)" "23 24 24b 25 26 26b"

# M17 — THE LYING 🧠 UNCOVERED: rung 1 back to 🔔-only, which is where it was when four
# panes sat stalled all morning with pulse-inject deferring into each of them. The 🔔
# cases are untouched, so this mutant is precisely the missing coverage and nothing else.
fresh_copy
mutate "$PE" \
  '    case "$wname" in
      🔔*) glyph=🔔 ;;
      🧠*) glyph=🧠 ;;
      🌀*) glyph=🌀 ;;
    esac' \
  '    case "$wname" in
      🔔*) glyph=🔔 ;;
    esac'
check "M17 lying-brain-not-reconciled (rung 1 back to 🔔-only)" "24 24b 25 26" "2 3 19 20"

# M18 — THE LIVE-TURN GUARD DROPPED for exactly the glyphs it protects: "🔔 needs the
# pane's permission because a dialog may be live; 🧠 is just a stale label" is the
# tempting reasoning, and it strips the glyph off work that is still running. Signal 3
# is what refutes a 🧠, the way signal 1 refutes a 🔔; the 🔔 refusal cases must stay
# green, or the mutant broke something other than the guard under test.
fresh_copy
mutate "$PE" \
  '      if [ "$pm" = 1 ]; then' \
  '      if [ "$pm" = 1 ] || [ "$glyph" != "🔔" ]; then'
check "M18 live-turn-renamed (the 🧠 half of the asymmetry deleted)" "25" "3 15 16 19 20"

# M19 — UNLISTED LOOP GETS THE FULL LADDER. The scope split's whole point is that rung 1
# is fleet-safe (it summons nobody) while rungs 2-4 are not (the floor is a P1 bead and a
# buzz on Zig's phone). Drop the split and a bounce log — a file this script does not
# even write — starts granting consent to wake a human about any seat on the box.
fresh_copy
mutate "$PE" \
  '  if [ "$listed" != 1 ]; then continue; fi' \
  '  if [ "$listed" != 1 ]; then :; fi'
# 22/22b are named too, and they are not collateral: a MALFORMED `loops` row leaves its
# loop unlisted, so without the split a config typo silently promotes that seat to the
# full ladder instead of demoting it to the fleet-safe rung.
check "M19 unlisted-loop-gets-full-ladder (the scope split removed)" "9 22 22b 26b"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
