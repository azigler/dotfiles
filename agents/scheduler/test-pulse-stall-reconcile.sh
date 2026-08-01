#!/bin/bash
# Test for pulse-stall-reconcile.py — specifically the TIMER-vs-SERVICE discriminator.
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
export PATH="$T/bin:$PATH"
export FAKE_STATE="$T/state"; mkdir -p "$FAKE_STATE"

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

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
