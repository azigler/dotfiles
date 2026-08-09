#!/bin/bash
# Mutation harness for gateway-health.sh — the keep's probe-and-reopen guard.
#
#     bash agents/scheduler/mutate-gateway-health.sh [-v]
#
# WHY THIS EXISTS. gateway-health.sh decides WHETHER TO SIGKILL THE FLEET'S ONE
# DOOR, unattended, every two minutes. Both directions are silent: too eager and
# a merely-slow gateway is `kickstart -k`ed out from under every in-flight fleet
# request, over and over for as long as the latency lasts; too shy and the
# 2026-08-09 outage (dotfiles-kviw: 12:36–15:08Z, every seat on the fleet without
# claude) repeats with a green timer. Nothing turns red either way.
#
# The nine mutants that shipped with dotfiles-nhc8 were run from a live session
# and then lost with it — the exact shape repo rule 1 was written against
# (mutate-tunnel-ownership.sh's header: a throwaway harness leaves the next edit
# with a green suite and no mutant check). This file is that evidence, made
# repeatable, and tools/githooks/pre-commit is its consumer.
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
# AND A KILLED MUTANT MUST FAIL THE CASE(S) IT NAMES (dotfiles-77s4). Unlike the
# tunnel suite, test-gateway-health.sh names its cases in PROSE rather than by
# number — `bad "probe-degraded ⇒ NO kickstart, pico untouched (…)"` — so each
# mutant below names a distinctive FRAGMENT of the failure message it must
# produce, and check() asserts that fragment appears among the reported
# failures. Same property, matched on text instead of on an integer.
#
# The `must keep PASSING` column is the sharper half of several mutants here:
# M3 and M8 change NOTHING about the verdict and are visible only in the ledger
# and the probe count, and M9 changes no behaviour at all — it is caught solely
# by the static assertion that this guard never invokes gateway-switch.sh.
#
# HERMETIC. The suite it drives fakes curl and ssh on PATH and points GW_LEDGER
# at a per-case tmpdir; pico is never touched and the real gateway is never
# probed. Both the script and the suite are copied into a scratch dir, so the
# real tree is never edited (the suite finds its subject by `dirname $0`).

# shellcheck disable=SC2016
# ^ file-wide and deliberate: every mutation argument below is LITERAL SOURCE
# TEXT copied out of gateway-health.sh. `$P_RC`, `$JOB`, `$LEDGER` and friends
# inside them must NOT expand — they are matched byte-for-byte against the file
# on disk, and an expanded one would match nothing (a harness error).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SRC="${SRC_DIR:-$(cd "$(dirname "$0")" && pwd)}"   # agents/scheduler
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mutate-gateway.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

GH="gateway-health.sh"
SUITE="test-gateway-health.sh"

FAILED=0
HARNESS_ERR=0
MUTANT_OK=0

mkdir -p "$WORK/scheduler" "$WORK/pristine"
for f in "$GH" "$SUITE"; do
  [ -f "$SRC/$f" ] || { echo "HARNESS ERROR: $SRC/$f does not exist" >&2; exit 2; }
  cp -a "$SRC/$f" "$WORK/pristine/$f"
done

fresh_copy() {
  MUTANT_OK=1
  cp -a "$WORK/pristine/$GH" "$WORK/scheduler/$GH"
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

# M1 — THE HEALTHY SIGNATURE NARROWED TO 401. The header forbids this in as many
# words: :17017 is a transparent passthrough, so 401 is what an unauthenticated
# probe gets — but a 429 or a 500 from Anthropic ALSO proves the relay is
# listening and forwarding. Narrowing the accepted set turns an upstream blip
# into a `kickstart -k` of a perfectly healthy gateway, every two minutes.
fresh_copy
mutate "$GH" \
  '  if [ "$P_RC" -eq 0 ] && [ "$P_CODE" != "000" ]; then' \
  '  if [ "$P_RC" -eq 0 ] && [ "$P_CODE" = "401" ]; then'
check "M1 healthy-signature-narrowed-to-401" \
  "HTTP 500 → still 'up'" \
  "401 → ok/exit0
down→kickstart→up ⇒ restored/exit10"

# M2 — THE rc7/rc28 SPLIT COLLAPSED: any non-zero curl rc is treated as DOWN.
# This is the FIX-FIRST blocker the reviewer sent back on 2026-08-09 — curl
# prints `000` for a refusal AND for a timeout, and a gateway that completed the
# TCP handshake and is merely slow would be SIGKILLed every two minutes for as
# long as the latency lasted, dropping every in-flight fleet request each time.
fresh_copy
mutate "$GH" \
  '  elif [ "$P_RC" -eq 7 ] || { [ "$P_RC" -eq 28 ] && [ "$connected" -eq 0 ]; }; then' \
  '  elif [ "$P_RC" -ne 0 ]; then'
check "M2 kickstart-on-timeout (slow read as dead)" \
  "connected-then-slow (rc 28, time_connect>0) ⇒ probe-degraded/exit10
probe-degraded ⇒ NO kickstart, pico untouched
probe-degraded → ledger row
degraded AFTER the restart ⇒ probe-degraded, no further kickstart" \
  "down→kickstart→up ⇒ restored/exit10
connect-phase timeout ⇒ still down ⇒ kickstart ⇒ restored"

# M3 — THE NOT-LOADED LADDER NEVER FIRES. `launchctl kickstart` on a job launchd
# has never heard of does nothing at all, and that IS the 2026-08-09 shape: pico
# rebooted into Tahoe and came back with no com.zig.* agents loaded. Note what
# this mutant does NOT change: the fixture's second probe still answers, so the
# VERDICT is still `restored` — only the ssh transcript and the ledger know the
# recovery ladder was never climbed.
fresh_copy
mutate "$GH" \
  'case "$SSH_OUT" in
*"Could not find service"*)' \
  'case "$SSH_OUT" in
*"ZZ-NEVER-MATCHES"*)'
check "M3 bootstrap-never (the not-loaded shape unhandled)" \
  "'Could not find service' → kickstart, bootstrap, kickstart in ORDER
bootstrap targets the derived domain gui/501 with the plist
ledger records the bootstrap it performed" \
  "not-loaded → bootstrap path still ends restored"

# M4 — BOOTSTRAP AFTER THE RETRY KICKSTART instead of before it. Ordering is the
# whole content of step 2b: kickstarting a job that is not loaded is a no-op, so
# a bootstrap that arrives afterwards leaves the recovery depending on the NEXT
# tick. Every other observable is unchanged — the bootstrap still happens, the
# ledger still counts it, the verdict is still `restored`.
fresh_copy
mutate "$GH" \
  '  ssh_run "launchctl bootstrap $DOMAIN $PLIST"
  [ $? -eq 255 ] && unreachable
  M_BOOTSTRAPS=$((M_BOOTSTRAPS + 1))
  ssh_run "launchctl kickstart -k $JOB"
  [ $? -eq 255 ] && unreachable
  M_KICKSTARTS=$((M_KICKSTARTS + 1))' \
  '  ssh_run "launchctl kickstart -k $JOB"
  [ $? -eq 255 ] && unreachable
  M_KICKSTARTS=$((M_KICKSTARTS + 1))
  ssh_run "launchctl bootstrap $DOMAIN $PLIST"
  [ $? -eq 255 ] && unreachable
  M_BOOTSTRAPS=$((M_BOOTSTRAPS + 1))'
check "M4 bootstrap-ordering-inverted (kickstart, kickstart, bootstrap)" \
  "'Could not find service' → kickstart, bootstrap, kickstart in ORDER" \
  "not-loaded → bootstrap path still ends restored
ledger records the bootstrap it performed"

# M5 — ssh's OWN 255 NO LONGER MEANS `pico-unreachable`. "the keep cannot reach
# pico" and "the gateway is down" are different facts with different audiences:
# the first is the one where waking a human is right, and it is the one this
# guard can do nothing about. Conflated, an unreachable pico is reported as a
# gateway that was restarted and did not come back. (Case 7 — the unwritable
# ledger — reddens too, because it builds its fixture on the unreachable path;
# that is collateral, not what this mutant names, so it is not listed below.)
fresh_copy
mutate "$GH" \
  '# --- 2. kickstart ------------------------------------------------------------
ssh_run "launchctl kickstart -k $JOB"
[ $? -eq 255 ] && unreachable' \
  '# --- 2. kickstart ------------------------------------------------------------
ssh_run "launchctl kickstart -k $JOB"
[ $? -eq 9999 ] && unreachable'
check "M5 ssh-255-not-pico-unreachable" \
  "down+ssh 255 ⇒ pico-unreachable/exit10
pico-unreachable → ledger row"

# M6 — THE RECOVERY ROW DROPPED. A plain `ok` appends nothing (720 runs/day must
# not bury the ledger), so the FIRST ok after a non-ok is the only record that an
# outage ever ended. Without it the ledger reads as a fleet that is still down —
# the one row a human scanning it after the fact actually needs.
fresh_copy
mutate "$GH" \
  '  if [ "$VERDICT" != "ok" ] || { [ -n "$prev" ] && [ "$prev" != "ok" ]; }; then' \
  '  if [ "$VERDICT" != "ok" ]; then'
check "M6 recovery-row-never-written" \
  "first ok AFTER a non-ok appends the recovery row
a second consecutive ok appends nothing" \
  "plain ok → appends NOTHING to the ledger"

# M7 — `restored` EXITS 0. A case pattern list is first-match-wins, so adding it
# beside `ok` silently outranks the exit-10 arm further down. The unit
# deliberately omits 10 from SuccessExitStatus precisely so a fleet-wide outage
# that had to be REPAIRED lands in `systemctl --user --failed`; at exit 0 the
# repair is invisible and the outage is never known to have happened.
fresh_copy
mutate "$GH" \
  '  ok) exit 0 ;;' \
  '  ok | restored) exit 0 ;;'
check "M7 restored-exits-0 (a repaired outage reported as routine)" \
  "down→kickstart→up ⇒ restored/exit10" \
  "restored → one ledger row carrying the verdict
401 → ok/exit0"

# M8 — THE RE-PROBE BUDGET IGNORED: GW_PROBE_TRIES is replaced by a hardcoded
# single try. A gateway that needs a moment to bind its port after a kickstart is
# then declared `down-unrecovered` and a human is summoned to a door that opened
# on its own two seconds later. Note the VERDICT is identical in the suite's
# still-down case — only the probe COUNT tells the two apart, which is why that
# assertion exists at all.
fresh_copy
mutate "$GH" \
  'while [ "$try" -le "$TRIES" ]; do' \
  'while [ "$try" -le 1 ]; do'
check "M8 reprobe-budget-ignored (GW_PROBE_TRIES unused)" \
  "down-unrecovered → 1 probe + GW_PROBE_TRIES re-probes" \
  "down→kickstart→still down ⇒ down-unrecovered/exit10"

# M9 — THE TIMER FLIPS THE FLEET'S ROUTING. gateway-switch.sh decides where every
# seat's traffic goes, what is attributed and which key pays; the header says in
# as many words that a 2-minute timer must not make that call. This mutant
# changes NO verdict, NO exit code and NO ledger row — the static assertion in
# case 8 is its sole detector, which is exactly the shape of finding a green
# suite cannot give you.
fresh_copy
mutate "$GH" \
  'finding "gateway STILL not answering after restarting ${JOB} on ${HOST}' \
  'ssh_run "bash gateway-switch.sh direct" # MUTANT: a timer flipping the fleet
finding "gateway STILL not answering after restarting ${JOB} on ${HOST}'
check "M9 timer-invokes-gateway-switch (behaviour unchanged; static assert is the only detector)" \
  "must never invoke gateway-switch.sh" \
  "down→kickstart→still down ⇒ down-unrecovered/exit10
down-unrecovered → 1 probe + GW_PROBE_TRIES re-probes"

# M10 — A LEDGER THAT CANNOT BE WRITTEN IS NOT A BROKEN CHECKER ANY MORE. The
# ledger is the only durable memory this guard has; losing it silently means the
# recovery-row logic above is reasoning off a file that is not there, and the
# fleet's health history quietly stops accumulating while every run exits
# "cleanly". Exit 1 (checker broken) is the honest answer and the unit reads it.
fresh_copy
mutate "$GH" \
  '  mkdir -p "$dir" || {
    broken "cannot create the ledger directory $dir"' \
  '  mkdir -p "$dir" || {
    note "cannot create the ledger directory $dir"'
check "M10 unwritable-ledger-not-a-broken-checker" \
  "unwritable ledger ⇒ exit 1 (checker broken) with the result line last" \
  "down+ssh 255 ⇒ pico-unreachable/exit10"

echo
if [ "$HARNESS_ERR" -ne 0 ]; then
  echo "=== RESULT: HARNESS ERROR — at least one mutation never applied. ========="
  echo "    A suite failure under an unapplied mutant proves NOTHING. Fix the"
  echo "    mutant against the current source before reading anything above."
  exit 2
fi
if [ "$FAILED" -ne 0 ]; then
  echo "=== RESULT: a mutant SURVIVED or died on the wrong case. ================="
  echo "    gateway-health.sh is not guarded the way its suite claims."
  exit 1
fi
echo "=== RESULT: all mutants killed, each on the case(s) it names. ==========="
exit 0
