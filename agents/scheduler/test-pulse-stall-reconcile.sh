#!/bin/bash
# Test for pulse-stall-reconcile.py — the TIMER-vs-SERVICE discriminator, and the
# PER-TRIGGER matching that discriminator needs to be right (Cases 7-9).
#
# THE DEFECT THIS SUITE EXISTS FOR (dotfiles-05jn). `systemctl enable --now` starts the
# TIMER unit and stamps its LastTriggerUSec WITHOUT running the service. The reconciler
# read only the timer, so every re-arm / install / rename manufactured a `stalled` row
# for a tick that was never invoked. Live instance 2026-08-01: re-arming autonoveld's
# four timers produced four phantom stall rows pinned to the enable-time second, while
# all four services showed an EMPTY ExecMainStartTimestamp.
#
# Case 1 is the regression: it MUST fail against the pre-fix script. Case 2 is the
# positive control — without it, a script that simply never writes anything would pass
# Case 1 and look fixed. A suite that can only prove absence proves nothing.
#
# Hermetic: a fake `systemctl` on PATH, fixture manifest + ledger in a per-run tmpdir.
# Touches no real unit and no real ledger.

set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pulse-stall-reconcile.py"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- fake systemctl: answers from files the cases write -----------------------
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'FAKE'
#!/bin/bash
# args: --user show <unit> -p <Property>
unit=""; prop=""
for a in "$@"; do
  case "$a" in
    *.timer|*.service) unit="$a" ;;
    LastTriggerUSec|ExecMainStartTimestamp) prop="$a" ;;
  esac
done
printf '%s=%s\n' "$prop" "$(cat "$FAKE_STATE/$unit.$prop" 2>/dev/null)"
FAKE
chmod +x "$T/bin/systemctl"

# --- fake journalctl ----------------------------------------------------------
# Answers the per-invocation question ExecMainStartTimestamp cannot (dotfiles-gxqc).
# Fixture: $FAKE_STATE/<unit>.journal, one EPOCH SECOND per line = one service start.
# The stub honours --since/--until @<epoch> exactly as the real journalctl does, and
# emits the same shape the script parses (`-o json`, __REALTIME_TIMESTAMP in µs, the
# systemd MESSAGE_ID for "Starting <unit>…"). Missing fixture = no entries = a service
# that never ran, which is what every pre-gxqc case wants.
cat > "$T/bin/journalctl" <<'FAKE'
#!/bin/bash
unit=""; since=""; until_=""
prev=""
for a in "$@"; do
  case "$prev" in
    -u) unit="$a" ;;
    --since) since="${a#@}" ;;
    --until) until_="${a#@}" ;;
  esac
  prev="$a"
done
f="$FAKE_STATE/$unit.journal"
[ -r "$f" ] || exit 0
while read -r sec; do
  [ -n "$sec" ] || continue
  [ "$sec" -ge "${since:-0}" ] || continue
  [ "$sec" -le "${until_:-99999999999}" ] || continue
  printf '{"__REALTIME_TIMESTAMP":"%s000000","MESSAGE_ID":"7d4958e842da4a758f6c1cdc7b36dcc5"}\n' "$sec"
done < "$f"
FAKE
chmod +x "$T/bin/journalctl"

export PATH="$T/bin:$PATH"
export FAKE_STATE="$T/state"; mkdir -p "$FAKE_STATE"

# Hermetic log + dedup state: without these the suite appends to the REAL
# ~/.local/state/harness/ files, and the dedup assertions below could not be made
# at all (they read the log this run produced).
export PULSE_STALL_RECONCILE_LOG="$T/reconcile.log"
export PULSE_STALL_RECONCILE_STATE="$T/reconcile-state.jsonl"

# --- fixtures ----------------------------------------------------------------
mkdir -p "$T/proj/refs"
LEDGER="$T/proj/refs/pulse-ledger.jsonl"
cat > "$T/manifest.json" <<CONF
{"projects":[{"path":"$T/proj","loops":[
  {"timer":"pulse-fixture","ledger":"refs/pulse-ledger.jsonl","ledger_row":"write","grace_minutes":90}
]}]}
CONF

FIRE="Sat 2026-08-01 19:05:30 UTC"
NOW="2026-08-01T21:13:59+00:00"     # >90m + margin after the trigger

run() { python3 "$SCRIPT" --manifest "$T/manifest.json" --now "$NOW" "$@" 2>&1; }
# NB: `grep -c` prints 0 AND exits 1 on no-match, so a `|| echo 0` fallback emits
# "0\n0" and every comparison fails. Take grep's stdout; default only if it is empty
# (missing file). Same empty-vs-error trap the stderr rule is about.
stall_rows() { local n; n=$(grep -c '"outcome": *"stalled"' "$LEDGER" 2>/dev/null); echo "${n:-0}"; }
never_ran_lines() { local n; n=$(grep -c 'service-never-ran' "$PULSE_STALL_RECONCILE_LOG" 2>/dev/null); echo "${n:-0}"; }
written_lines() { local n; n=$(grep -c 'stalled-row-written' "$PULSE_STALL_RECONCILE_LOG" 2>/dev/null); echo "${n:-0}"; }
reset_state() { : > "$LEDGER"; : > "$PULSE_STALL_RECONCILE_LOG"; : > "$PULSE_STALL_RECONCILE_STATE"; }

check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1));
  else echo "  FAIL $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi
}

# === Case 1 — THE REGRESSION ==================================================
# Timer armed (`enable --now`), service NEVER ran. Must write ZERO stall rows.
: > "$LEDGER"
printf '%s' "$FIRE" > "$FAKE_STATE/pulse-fixture.timer.LastTriggerUSec"
: > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"   # empty = never ran
run >/dev/null
check "armed-but-never-ran writes NO stall row" 0 "$(stall_rows)"

# === Case 2 — POSITIVE CONTROL ===============================================
# A real fire: the service DID execute at the trigger, and nothing reported.
# Must write exactly ONE. Without this, a do-nothing script passes Case 1.
: > "$LEDGER"
printf '%s' "$FIRE" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
run >/dev/null
check "real unreported fire writes exactly ONE stall row" 1 "$(stall_rows)"

# === Case 3 — the service ran BEFORE this trigger (a previous fire) ===========
: > "$LEDGER"
printf '%s' "Sat 2026-08-01 10:00:00 UTC" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
run >/dev/null
check "service older than the trigger is not this fire" 0 "$(stall_rows)"

# === Case 4 — the honest-note contract =======================================
# The note must NOT claim things the script never checks.
: > "$LEDGER"
printf '%s' "$FIRE" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
run >/dev/null
NOTE=$(grep '"outcome": *"stalled"' "$LEDGER" | head -1)
if echo "$NOTE" | grep -q "reported the tick INJECTED"; then
  echo "  FAIL note still claims pulse-inject reported INJECTED (never checked)"; FAIL=$((FAIL+1))
else echo "  ok   note does not claim an inject marker it never read"; PASS=$((PASS+1)); fi
if echo "$NOTE" | grep -q "NOT CHECKED HERE"; then
  echo "  ok   note names what it did NOT establish"; PASS=$((PASS+1))
else echo "  FAIL note does not name its own limits"; FAIL=$((FAIL+1)); fi

# === Case 5 — ATTRIBUTION WINDOW (the second half of dotfiles-05jn) ==========
# A manual `systemctl start` hours after the trigger must NOT be blamed on it.
# Live instance 2026-08-01: a start at 22:44 was attributed to the 19:05 re-arm
# stamp, 3.5h earlier, and wrote a stall for a fire that never happened.
: > "$LEDGER"
printf '%s' "$FIRE" > "$FAKE_STATE/pulse-fixture.timer.LastTriggerUSec"
printf '%s' "Sat 2026-08-01 22:44:00 UTC" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
run >/dev/null
check "a start 3.5h after the trigger is NOT that fire" 0 "$(stall_rows)"

# === Case 6 — but a start WITHIN the window still counts =====================
# Guards the fix from over-correcting into "never attribute anything".
: > "$LEDGER"
printf '%s' "Sat 2026-08-01 19:07:00 UTC" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
run >/dev/null
check "a start 90s after the trigger IS that fire" 1 "$(stall_rows)"

# === Case 7 — THE dotfiles-gxqc REGRESSION ===================================
# A real fire, then a LATER manual `systemctl --user start`. The manual start
# advances ExecMainStartTimestamp past this trigger's attribution window, so a
# reconciler that reads only that marker concludes the REAL fire never ran.
#
# Live shape, 2026-08-09, replayed second-for-second: pulse-digest.timer fired at
# 14:00:10; pulse-digest.service started 14:00:16 and logged
# PULSE_INJECT_RESULT=injected; the hardening seat manually re-fired at 15:15:08.
# From 17:32 to 18:42 the reconciler flagged the 14:00 trigger
# `skipped-timer-armed-but-service-never-ran` eight times.
#
# The fire IS attributable, so the correct behaviour is the ordinary one: no false
# skip, and — the ledger being empty — the honest `stalled` row this script exists
# to write. Both halves fail against the pre-fix script (0 rows, 1 skip line).
reset_state
printf '%s' "Sun 2026-08-09 14:00:10 UTC" > "$FAKE_STATE/pulse-fixture.timer.LastTriggerUSec"
printf '%s' "Sun 2026-08-09 15:15:08 UTC" > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"
echo 1786284016 > "$FAKE_STATE/pulse-fixture.service.journal"   # 14:00:16 — the real start
GXQC_NOW="2026-08-09T17:32:00+00:00"
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "$GXQC_NOW" >/dev/null 2>&1
# POSITIVE CONTROL for the log channel, and it is load-bearing: an absence
# assertion against a file nothing wrote is indistinguishable from a pass. A script
# that ignores PULSE_STALL_RECONCILE_LOG writes its skip line to ~/.local/state/
# instead, and `never_ran_lines` would then read an empty fixture file and report a
# cheerful 0. So first prove THIS run wrote to THIS log.
check "the reconciler log under test is the hermetic one" 1 "$(written_lines)"
check "real fire is NOT called service-never-ran after a later manual start" 0 "$(never_ran_lines)"
check "real unreported fire still earns its stalled row" 1 "$(stall_rows)"

# === Case 8 — the false-skip spam is silenced ================================
# 117 log lines in one day, three timers, the same three states re-announced every
# ten minutes. A steady state is worth one line when it begins.
reset_state
rm -f "$FAKE_STATE/pulse-fixture.service.journal"
: > "$FAKE_STATE/pulse-fixture.service.ExecMainStartTimestamp"   # never ran, genuinely
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "$GXQC_NOW" >/dev/null 2>&1
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "$GXQC_NOW" >/dev/null 2>&1
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "$GXQC_NOW" >/dev/null 2>&1
check "three cycles of one steady skip state log ONE line" 1 "$(never_ran_lines)"

# === Case 9 — dedup must not over-suppress ===================================
# Guards the fix from becoming "log the first one and go silent forever": a NEW
# fire in the same state is new information and re-announces exactly once.
printf '%s' "Sun 2026-08-09 18:00:10 UTC" > "$FAKE_STATE/pulse-fixture.timer.LastTriggerUSec"
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "2026-08-09T21:00:00+00:00" >/dev/null 2>&1
python3 "$SCRIPT" --manifest "$T/manifest.json" --now "2026-08-09T21:00:00+00:00" >/dev/null 2>&1
check "a NEW fire in the same state re-announces once" 2 "$(never_ran_lines)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
