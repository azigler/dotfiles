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
FUTURE_US=$(( (NOW + 3600) * 1000000 ))   # next fire an hour out
PAST_US=$(( (NOW - 3600) * 1000000 ))     # next fire an hour ago

# setup_case: fresh state dir + fake control dir; exports HARNESS_STATE_DIR + PRT_FAKE.
setup_case() {
  CASE_STATE=$(mktemp -d)
  PRT_FAKE=$(mktemp -d)
  mkdir -p "$PRT_FAKE/nextfire" "$PRT_FAKE/execstart" "$PRT_FAKE/windows"
  export HARNESS_STATE_DIR="$CASE_STATE"
  export PRT_FAKE
}
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
