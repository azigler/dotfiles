#!/bin/bash
# Test for pulse-retry.sh — the bounced-tick early-retry watcher (harnessd-dbp).
#
# Hermetic: HARNESS_STATE_DIR in a per-case tmpdir + FAKE `systemctl` and `tmux`
# shims on PATH (recording + scriptable). No real systemd units or tmux server is
# touched. Mirrors test-pulse-inject.sh's HARNESS_STATE_DIR-override style.
#
# The shims read $PRT_FAKE (a per-case control dir):
#   $PRT_FAKE/started              — fake systemctl appends each `start`ed unit
#   $PRT_FAKE/calls                — fake systemctl appends every invocation
#   $PRT_FAKE/nextfire/<unit>      — value printed for `show ... NextElapseUSecRealtime --value`
#   $PRT_FAKE/execstart/<unit>     — value printed for `show ... -p ExecStart`
#   $PRT_FAKE/windows/<session>    — fake tmux `list-windows` output (one name per line)
#
# Convention matches test/: executable bash, non-zero exit = failure, PASS/FAIL
# summary on the last line.

set -u

RETRY="$(cd "$(dirname "$0")" && pwd)/pulse-retry.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# --- Fake binaries on PATH ---------------------------------------------------
BIN="$ROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/systemctl" <<'EOSC'
#!/bin/bash
# Fake systemctl — records calls; scriptable show/start via $PRT_FAKE.
echo "$*" >> "$PRT_FAKE/calls"
sub=""; unit=""; prop=""
i=1
while [ "$i" -le "$#" ]; do
  a="${!i}"
  case "$a" in
    show)  sub=show ;;
    start) sub=start ;;
    -p)    i=$((i + 1)); prop="${!i}" ;;
    *.timer|*.service) unit="$a" ;;
  esac
  i=$((i + 1))
done
case "$sub" in
  start)
    echo "$unit" >> "$PRT_FAKE/started"
    ;;
  show)
    case "$prop" in
      NextElapseUSecRealtime) f="$PRT_FAKE/nextfire/$unit" ;;
      ExecStart)              f="$PRT_FAKE/execstart/$unit" ;;
      *)                      f="" ;;
    esac
    [ -n "$f" ] && [ -f "$f" ] && cat "$f"
    ;;
esac
exit 0
EOSC

cat > "$BIN/tmux" <<'EOTM'
#!/bin/bash
# Fake tmux — only `list-windows -t =SESSION -F ...`; prints scripted names.
if [ "${1:-}" = "list-windows" ]; then
  sess=""
  i=1
  while [ "$i" -le "$#" ]; do
    if [ "${!i}" = "-t" ]; then j=$((i + 1)); sess="${!j}"; fi
    i=$((i + 1))
  done
  sess="${sess#=}"
  f="$PRT_FAKE/windows/$sess"
  [ -f "$f" ] && cat "$f"
fi
exit 0
EOTM

chmod +x "$BIN/systemctl" "$BIN/tmux"
export PATH="$BIN:$PATH"

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

NOW=$(date +%s)
FUTURE_US=$(( (NOW + 3600) * 1000000 ))   # next fire an hour out (systemd ≤256 raw-µs form)
PAST_US=$(( (NOW - 3600) * 1000000 ))     # next fire an hour ago  (raw-µs form)

# systemd 257+ renders NextElapseUSecRealtime as a FORMATTED TIMESTAMP, not raw µs. These are the
# regression guard for harnessd-95w — the exact form that silently broke pulse-retry in production
# (the old all-digit guard classified it "unbounded" and skipped every OnCalendar loop).
FUTURE_HUMAN=$(date -u -d '+1 hour' '+%a %Y-%m-%d %H:%M:%S UTC')
PAST_HUMAN=$(date -u -d '-1 hour' '+%a %Y-%m-%d %H:%M:%S UTC')

# setup_case: fresh state dir + fake control dir; exports HARNESS_STATE_DIR + PRT_FAKE.
#
# PULSE_SURFACE_DRAIN is pointed at a RECORDER stub (dotfiles-5ts2). pulse-retry.sh
# now also drains the deferred-surface queue, and the real drain would read the
# REAL ~/.local/state/pulse-dispatch-surfaces and could inject into the REAL
# work:pulse — this suite is hermetic and must touch neither. The stub also lets a
# case ASSERT the drain was invoked, which is the whole point of the wiring.
setup_case() {
  CASE_STATE=$(mktemp -d)
  PRT_FAKE=$(mktemp -d)
  mkdir -p "$PRT_FAKE/nextfire" "$PRT_FAKE/execstart" "$PRT_FAKE/windows"
  export HARNESS_STATE_DIR="$CASE_STATE"
  export PRT_FAKE
  cat > "$PRT_FAKE/surface-drain" <<'DRAINEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PRT_FAKE/drain-calls"
printf 'PULSE_SURFACE_RESULT=%s\n' "${DRAIN_VERDICT:-empty}"
exit 0
DRAINEOF
  chmod +x "$PRT_FAKE/surface-drain"
  export PULSE_SURFACE_DRAIN="$PRT_FAKE/surface-drain"
  # Same treatment for the LOCAL-loop ledger watcher (dotfiles-wqby): the real one
  # would read the REAL harness manifest, the REAL ledgers, and stage into the REAL
  # surface queue. A recorder stub keeps this suite hermetic and lets a case assert
  # that the watcher is invoked at all — which is the whole point of the wiring.
  cat > "$PRT_FAKE/ledger-watch" <<'LWEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PRT_FAKE/watch-calls"
printf 'PULSE_LEDGER_WATCH_RESULT=%s\n' "${WATCH_VERDICT:-staged:0:seeded:0:errors:0}"
exit 0
LWEOF
  chmod +x "$PRT_FAKE/ledger-watch"
  export PULSE_LEDGER_WATCH="$PRT_FAKE/ledger-watch"
  # The watcher is DISABLED by default in pulse-retry.sh (dotfiles-sxsv blocks it —
  # the queue's injected command is remote-only and tells the receiving session to
  # land a ledger row that a LOCAL tick has already written). These cases exercise the
  # WIRING, so they force it on; the default-off behavior gets its own case below.
  export PULSE_LEDGER_WATCH_ENABLE=1
}
drain_calls() { [ -f "$PRT_FAKE/drain-calls" ] && wc -l < "$PRT_FAKE/drain-calls" | tr -d ' ' || echo 0; }
watch_calls() { [ -f "$PRT_FAKE/watch-calls" ] && wc -l < "$PRT_FAKE/watch-calls" | tr -d ' ' || echo 0; }
started_count() { [ -f "$PRT_FAKE/started" ] && wc -l < "$PRT_FAKE/started" | tr -d ' ' || echo 0; }
state_acted_ts() { json_of "$HARNESS_STATE_DIR/pulse-retry-state.jsonl" "$1"; }
# read acted_ts for a given loop out of the retry-state jsonl
json_of() {
  [ -f "$1" ] || return 0
  grep -F "\"loop\":\"$2\"" "$1" 2>/dev/null | sed -n -E 's/.*"acted_ts":"([^"]*)".*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Case 1: pending + 🔔 CLEARED → exactly one `start`, state marked acted.
#   Also exercises ExecStart parsing (custom --session/--window explore).
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'ExecStart={ path=x ; argv[]=x --loop pulse-vibe --dir /home/ubuntu/explore --session explore --window explore --cmd "/pulse tick" ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf 'explore\n' > "$PRT_FAKE/windows/explore"     # NOT 🔔 → cleared
"$RETRY"
if [ "$(started_count)" = "1" ] && grep -qx "pulse-vibe.service" "$PRT_FAKE/started"; then
  ok
else
  bad "cleared 🔔 → exactly one 'systemctl start <loop>.service' (got $(started_count))"
fi
if [ "$(state_acted_ts pulse-vibe)" = "2026-07-09T05:00:00Z" ]; then
  ok
else
  bad "cleared 🔔 → retry-state marks loop acted at the bounce ts (got '$(state_acted_ts pulse-vibe)')"
fi

# ---------------------------------------------------------------------------
# Case 2: next_fire in the PAST → skip (natural timer takes over), no start.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$PAST_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'pulse\n' > "$PRT_FAKE/windows/work"          # cleared, but should not matter
"$RETRY"
if [ "$(started_count)" = "0" ]; then ok; else bad "next_fire in past → skip (no start)"; fi

# ---------------------------------------------------------------------------
# Case 3a: no timer / empty next_fire → skip.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
: > "$PRT_FAKE/nextfire/pulse-vibe.timer"            # empty → no schedule
printf 'pulse\n' > "$PRT_FAKE/windows/work"
"$RETRY"
if [ "$(started_count)" = "0" ]; then ok; else bad "empty next_fire → skip (no start)"; fi

# Case 3b: next_fire == 0 (unscheduled timer) → skip.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '0\n' > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'pulse\n' > "$PRT_FAKE/windows/work"
"$RETRY"
if [ "$(started_count)" = "0" ]; then ok; else bad "next_fire=0 → skip (no start)"; fi

# ---------------------------------------------------------------------------
# Case 4: window STILL 🔔 → skip, NO start recorded, state NOT updated.
#   Uses default session/window (ExecStart carries no --session/--window).
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'ExecStart={ path=x ; argv[]=x --loop pulse-vibe --dir /home/ubuntu/explore --cmd "/pulse tick" ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf '🔔 pulse\n' > "$PRT_FAKE/windows/work"       # default window 'pulse', still blocked
"$RETRY"
if [ "$(started_count)" = "0" ]; then ok; else bad "window still 🔔 → skip (no start)"; fi
if [ ! -f "$HARNESS_STATE_DIR/pulse-retry-state.jsonl" ]; then
  ok
else
  bad "window still 🔔 → leaves loop UNACTED (no retry-state written)"
fi

# ---------------------------------------------------------------------------
# Case 5: acted-dedup across two runs. Run 1 acts; run 2 (same bounce, no new
#   bounce) does NOT re-fire → idempotent.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'cleared\n' > "$PRT_FAKE/windows/work"        # window 'pulse' resolution falls to default; name 'cleared' ≠ 'pulse'
# window not found for 'pulse' (name is 'cleared') ⇒ absent ⇒ not blocked ⇒ re-fire.
"$RETRY"                                             # run 1
"$RETRY"                                             # run 2 (no new bounce)
if [ "$(started_count)" = "1" ]; then
  ok
else
  bad "acted-dedup: two runs with one bounce → exactly one start (got $(started_count))"
fi

# ---------------------------------------------------------------------------
# Case 6: coalesce latest-per-loop across multiple bounce lines. Three bounces
#   t1<t2<t3 for one loop; retry-state already acted at t2. Correct behavior:
#   latest=t3 > t2 ⇒ act, and state stored is t3 (proves LATEST wins, not first/any).
setup_case
{
  printf '{"ts":"2026-07-09T01:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n'
  printf '{"ts":"2026-07-09T02:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n'
  printf '{"ts":"2026-07-09T03:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n'
} > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '{"loop":"pulse-vibe","acted_ts":"2026-07-09T02:00:00Z"}\n' \
  > "$HARNESS_STATE_DIR/pulse-retry-state.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'pulse\n' > "$PRT_FAKE/windows/work"          # cleared
"$RETRY"
if [ "$(started_count)" = "1" ] && [ "$(state_acted_ts pulse-vibe)" = "2026-07-09T03:00:00Z" ]; then
  ok
else
  bad "coalesce: latest bounce (t3) wins → act + state=t3 (start=$(started_count), state=$(state_acted_ts pulse-vibe))"
fi

# ---------------------------------------------------------------------------
# Case 7: multi-loop best-effort isolation. Two loops in one run — one still 🔔
#   (skip), one cleared (act). Exactly one start, for the cleared loop only.
setup_case
{
  printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-blocked","reason":"blocked_on_andrew"}\n'
  printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-clear","reason":"blocked_on_andrew"}\n'
} > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-blocked.timer"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-clear.timer"
printf 'ExecStart={ argv[]=x --session sblk --window wblk ; }\n' > "$PRT_FAKE/execstart/pulse-blocked.service"
printf 'ExecStart={ argv[]=x --session sclr --window wclr ; }\n' > "$PRT_FAKE/execstart/pulse-clear.service"
printf '🔔 wblk\n' > "$PRT_FAKE/windows/sblk"        # still blocked
printf 'wclr\n'    > "$PRT_FAKE/windows/sclr"        # cleared
"$RETRY"
if [ "$(started_count)" = "1" ] && grep -qx "pulse-clear.service" "$PRT_FAKE/started" \
   && ! grep -qx "pulse-blocked.service" "$PRT_FAKE/started"; then
  ok
else
  bad "multi-loop: only the cleared loop is re-fired (started: $(tr '\n' ',' < "$PRT_FAKE/started" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# Case 8: absent / empty bounces file → clean no-op, no start.
setup_case
"$RETRY"                                             # no bounces file at all
if [ "$(started_count)" = "0" ] && [ ! -f "$HARNESS_STATE_DIR/pulse-retry-state.jsonl" ]; then
  ok
else
  bad "absent bounces → clean no-op (no start, no retry-state)"
fi

# ---------------------------------------------------------------------------
# Case 9 (harnessd-95w regression): systemd 257 renders next_fire as a HUMAN TIMESTAMP, not raw µs.
#   FUTURE human timestamp + cleared window → must RE-FIRE. The prior all-digit guard wrongly
#   classified this "unbounded" and skipped it, silently breaking every OnCalendar loop after the
#   systemd 257 upgrade. This is the case the old suite lacked (its mock only fed raw µs).
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_HUMAN" > "$PRT_FAKE/nextfire/pulse-vibe.timer"   # systemd-257 human format
printf 'ExecStart={ argv[]=x --session explore --window explore ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf 'explore\n' > "$PRT_FAKE/windows/explore"     # cleared (not 🔔)
"$RETRY"
if [ "$(started_count)" = "1" ] && grep -qx "pulse-vibe.service" "$PRT_FAKE/started"; then
  ok
else
  bad "systemd-257 human-format FUTURE next_fire + cleared → re-fire (got $(started_count) starts)"
fi

# Case 10 (harnessd-95w): human-format PAST next_fire → skip (natural timer takes over) — proves
#   the human timestamp is actually PARSED and compared to now, not blanket-accepted.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$PAST_HUMAN" > "$PRT_FAKE/nextfire/pulse-vibe.timer"     # human format, already due
printf 'pulse\n' > "$PRT_FAKE/windows/work"
"$RETRY"
if [ "$(started_count)" = "0" ]; then ok; else bad "human-format PAST next_fire → skip (no start)"; fi

# ---------------------------------------------------------------------------
# Case 11 (dotfiles-5ts2): the watcher also DRAINS DEFERRED SURFACES — and does it
#   BEFORE the no-bounces early exit. That ordering is the whole point: a surface is
#   an announcement for a tick that already RAN, so it is queued independently of
#   whether any tick bounced. On the common path the bounce log is empty, and if the
#   drain sat below that exit it would never run at all — which is exactly the
#   "staged and never redelivered" hole this bead closes.
setup_case
"$RETRY"                                             # no bounces file at all
if [ "$(drain_calls)" = "1" ] && grep -q '^drain' "$PRT_FAKE/drain-calls" 2>/dev/null; then
  ok
else
  bad "no bounces → the surface drain STILL runs (got $(drain_calls) drain calls)"
fi
if [ "$(started_count)" = "0" ]; then
  ok
else
  bad "the surface drain never re-fires a tick (a finished tick must not be re-run)"
fi

# Case 12 (dotfiles-5ts2): a drain that reports work done is logged, and still must
#   not disturb the bounced-tick path that follows it.
setup_case
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'ExecStart={ argv[]=x --session explore --window explore ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf 'explore\n' > "$PRT_FAKE/windows/explore"     # cleared
DRAIN_VERDICT='delivered:2' "$RETRY"
if [ "$(drain_calls)" = "1" ] && [ "$(started_count)" = "1" ]; then
  ok
else
  bad "a delivering drain coexists with a bounced-tick re-fire (drains=$(drain_calls) starts=$(started_count))"
fi
if grep -q 'surface-drain: delivered:2' "$HARNESS_STATE_DIR/pulse-retry.log" 2>/dev/null; then
  ok
else
  bad "a non-empty drain verdict is logged"
fi

# Case 13 (dotfiles-5ts2): a missing drain script is a skip, never a failure — the
#   bounced-tick retries must survive a half-installed harness.
setup_case
export PULSE_SURFACE_DRAIN=/nonexistent/pulse-surface-queue.sh
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'ExecStart={ argv[]=x --session explore --window explore ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf 'explore\n' > "$PRT_FAKE/windows/explore"
"$RETRY"; RC=$?
if [ "$RC" = 0 ] && [ "$(started_count)" = "1" ]; then
  ok
else
  bad "an absent drain script does not break the bounced-tick retry (rc=$RC starts=$(started_count))"
fi

# ---------------------------------------------------------------------------
# Case 14 (dotfiles-wqby): the watcher ALSO runs the local-loop ledger watch, and
#   like the drain it runs BEFORE the no-bounces early exit — a local tick finishes
#   whether or not anything bounced, so a watch below that exit would never fire on
#   the common path.
setup_case
"$RETRY"                                             # no bounces file at all
if [ "$(watch_calls)" = "1" ]; then
  ok
else
  bad "no bounces → the ledger watch STILL runs (got $(watch_calls) calls)"
fi
if [ "$(started_count)" = "0" ]; then
  ok
else
  bad "the ledger watch never re-fires a tick (a finished tick must not be re-run)"
fi

# Case 15 (dotfiles-wqby): the watch runs BEFORE the drain, so a surface it stages
#   is delivered on THIS run rather than waiting another 2 minutes. Proven by
#   ordering, not by inspection: both stubs append to one shared file.
setup_case
cat > "$PRT_FAKE/surface-drain" <<'DRAINEOF'
#!/bin/bash
printf 'drain\n' >> "$PRT_FAKE/order"
printf 'PULSE_SURFACE_RESULT=empty\n'
DRAINEOF
cat > "$PRT_FAKE/ledger-watch" <<'LWEOF'
#!/bin/bash
printf 'watch\n' >> "$PRT_FAKE/order"
printf 'PULSE_LEDGER_WATCH_RESULT=staged:1:seeded:0:errors:0\n'
LWEOF
chmod +x "$PRT_FAKE/surface-drain" "$PRT_FAKE/ledger-watch"
"$RETRY"
if [ "$(tr '\n' ',' < "$PRT_FAKE/order")" = "watch,drain," ]; then
  ok
else
  bad "the ledger watch runs BEFORE the drain (got '$(tr '\n' ',' < "$PRT_FAKE/order")')"
fi

# Case 16 (dotfiles-wqby): a watch verdict carrying ERRORS logs the watcher's whole
#   output, not just the verdict — the output is what names the drift, and a drift
#   that only ever shows as a count is the silence this bead exists to end.
setup_case
cat > "$PRT_FAKE/ledger-watch" <<'LWEOF'
#!/bin/bash
echo "pulse-ledger-watch: ERROR pulse-foo/ledger-missing: ledger /nope is unreadable" >&2
printf 'PULSE_LEDGER_WATCH_RESULT=staged:0:seeded:0:errors:1\n'
LWEOF
chmod +x "$PRT_FAKE/ledger-watch"
"$RETRY"
if grep -q 'ledger-watch: staged:0:seeded:0:errors:1' "$HARNESS_STATE_DIR/pulse-retry.log" \
   && grep -q 'ledger-watch| .*ERROR pulse-foo/ledger-missing' "$HARNESS_STATE_DIR/pulse-retry.log"; then
  ok
else
  bad "an ERROR verdict logs the watcher's full output, not only the count"
fi

# Case 17 (dotfiles-wqby): the all-quiet verdict is NOT logged (this runs every 2
#   minutes; a line per run per verb would bury the lines that matter), and a
#   missing watcher script is a skip rather than a failure — the bounced-tick
#   retries must survive a half-installed harness, same contract as the drain.
setup_case
"$RETRY"
if ! grep -q 'ledger-watch: staged:0:seeded:0:errors:0' "$HARNESS_STATE_DIR/pulse-retry.log"; then
  ok
else
  bad "the all-quiet ledger-watch verdict is not logged"
fi
setup_case
export PULSE_LEDGER_WATCH=/nonexistent/pulse-ledger-watch.sh
printf '{"ts":"2026-07-09T05:00:00Z","loop":"pulse-vibe","reason":"blocked_on_andrew"}\n' \
  > "$HARNESS_STATE_DIR/pulse-bounces.jsonl"
printf '%s\n' "$FUTURE_US" > "$PRT_FAKE/nextfire/pulse-vibe.timer"
printf 'ExecStart={ argv[]=x --session explore --window explore ; }\n' \
  > "$PRT_FAKE/execstart/pulse-vibe.service"
printf 'explore\n' > "$PRT_FAKE/windows/explore"
"$RETRY"; RC=$?
if [ "$RC" = 0 ] && [ "$(started_count)" = "1" ] && [ "$(drain_calls)" = "1" ]; then
  ok
else
  bad "an absent ledger-watch script breaks neither the drain nor the retry (rc=$RC starts=$(started_count) drains=$(drain_calls))"
fi

# Case 18 (dotfiles-sxsv): the watcher is OFF BY DEFAULT and the drain still runs.
#   Every other watcher case forces PULSE_LEDGER_WATCH_ENABLE=1, so without this one
#   the suite would pass identically whether the kill switch worked or not — the
#   disable would be untested and could be silently undone.
#   It is disabled because pulse-surface-queue.sh's injected command is hardcoded for
#   the REMOTE dispatcher: it tells the receiving session to "land the ledger row",
#   which a LOCAL tick has ALREADY written. The duplicate row carries a fresh ts, the
#   next run reads it as new, and the announcement re-stages itself forever.
setup_case
unset PULSE_LEDGER_WATCH_ENABLE
"$RETRY"; RC=$?
if [ "$RC" = 0 ] && [ "$(watch_calls)" = "0" ] && [ "$(drain_calls)" = "1" ]; then
  ok
else
  bad "the ledger watch is OFF by default while the drain still runs (rc=$RC watch=$(watch_calls) drains=$(drain_calls))"
fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
