#!/bin/bash
# Test for gateway-health.sh — the keep's probe-and-reopen guard (dotfiles-nhc8).
#
# HERMETIC. Fake `curl` and `ssh` shims on PATH; GW_LEDGER in a per-case tmpdir.
# No real ssh runs, the real gateway is never probed, and pico is never touched.
# Style mirrors test-pulse-retry.sh (fakes on PATH, PASS/FAIL summary last).
#
# The shims read $GWT_FAKE (a per-case control dir):
#   $GWT_FAKE/codes        — one HTTP code per line; the Nth curl call prints the
#                            Nth line (the last line repeats once exhausted).
#                            000 = connect failure, and the fake exits 7 like the
#                            real curl does on a refused connection.
#   $GWT_FAKE/curl-calls   — every curl invocation, one per line
#   $GWT_FAKE/ssh-calls    — every remote command, one per line (ORDER MATTERS:
#                            the bootstrap case asserts bootstrap-then-kickstart)
#   $GWT_FAKE/ssh-unreachable — present ⇒ ssh exits 255 (transport failure)
#   $GWT_FAKE/kick-out.<n> — stdout for the Nth kickstart (e.g. the launchctl
#                            "Could not find service" complaint)

set -u

GH="$(cd "$(dirname "$0")" && pwd)/gateway-health.sh"
# A deliberately broken variant can be dropped in via GH_UNDER_TEST (that is how
# the mutation demonstrations for repo rule 1 are driven); default is the real one.
GH="${GH_UNDER_TEST:-$GH}"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
}

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# --- Fake binaries on PATH ---------------------------------------------------
BIN="$ROOT/bin"
mkdir -p "$BIN"

cat >"$BIN/fake-curl" <<'EOCURL'
#!/bin/bash
printf '%s\n' "$*" >> "$GWT_FAKE/curl-calls"
n=$(wc -l < "$GWT_FAKE/curl-calls" | tr -d ' ')
code=$(sed -n "${n}p" "$GWT_FAKE/codes")
[ -n "$code" ] || code=$(tail -n 1 "$GWT_FAKE/codes")
printf '%s' "$code"
[ "$code" = "000" ] && exit 7
exit 0
EOCURL

cat >"$BIN/fake-ssh" <<'EOSSH'
#!/bin/bash
# Fake ssh — the remote command is the LAST argument, as with the real one.
cmd="${!#}"
printf '%s\n' "$cmd" >> "$GWT_FAKE/ssh-calls"
if [ -f "$GWT_FAKE/ssh-unreachable" ]; then
  echo "ssh: connect to host pico port 22: Connection refused" >&2
  exit 255
fi
case "$cmd" in
  *kickstart*)
    n=$(grep -c kickstart "$GWT_FAKE/ssh-calls")
    [ -f "$GWT_FAKE/kick-out.$n" ] && cat "$GWT_FAKE/kick-out.$n"
    ;;
  *bootstrap*) : ;;
esac
exit 0
EOSSH

chmod +x "$BIN/fake-curl" "$BIN/fake-ssh"
export PATH="$BIN:$PATH"

# setup_case <code...> — fresh control dir + ledger; each argument is one
# scripted HTTP code, consumed by successive curl calls.
setup_case() {
  GWT_FAKE=$(mktemp -d)
  export GWT_FAKE
  : >"$GWT_FAKE/curl-calls"
  : >"$GWT_FAKE/ssh-calls"
  printf '%s\n' "$@" >"$GWT_FAKE/codes"
  export GW_CURL="$BIN/fake-curl"
  export GW_SSH="$BIN/fake-ssh"
  export GW_LEDGER="$GWT_FAKE/gateway.jsonl"
  export GW_SETTLE=0     # no real waiting in a test
  export GW_PROBE_TRIES=2
  export GW_HOST=pico
}

run_gh() {
  OUT=$("$GH" 2>&1)
  RC=$?
  LAST=$(printf '%s\n' "$OUT" | tail -n 1)
}
ledger_rows() { [ -f "$GW_LEDGER" ] && grep -c . "$GW_LEDGER" | tr -d ' ' || echo 0; }
ledger_verdict() { [ -f "$GW_LEDGER" ] && tail -n 1 "$GW_LEDGER" | sed -n -E 's/.*"verdict":"([^"]*)".*/\1/p'; }
ssh_calls() { [ -f "$GWT_FAKE/ssh-calls" ] && grep -c . "$GWT_FAKE/ssh-calls" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# Case 1: the door answers 401 → ok, exit 0, NO ssh, NO ledger row.
#   401 is the healthy signature (transparent passthrough, agents/infra.md).
setup_case 401
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=ok" ] && [ "$RC" = 0 ]; then ok; else bad "401 → ok/exit0 (got '$LAST' rc=$RC)"; fi
if [ "$(ssh_calls)" = "0" ]; then ok; else bad "401 → never touches pico over ssh (got $(ssh_calls) calls)"; fi
if [ "$(ledger_rows)" = "0" ]; then ok; else bad "plain ok → appends NOTHING to the ledger (720 runs/day)"; fi

# Case 1b: any other HTTP status is also up — a 500 from Anthropic must not
# trigger a kickstart of a perfectly healthy relay.
setup_case 500
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=ok" ] && [ "$(ssh_calls)" = "0" ]; then ok; else bad "HTTP 500 → still 'up' (any status means the relay is listening), no kickstart"; fi

# ---------------------------------------------------------------------------
# Case 2: down → kickstart → back up ⇒ restored, exit 10, one ledger row.
setup_case 000 401
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=restored" ] && [ "$RC" = 10 ]; then ok; else bad "down→kickstart→up ⇒ restored/exit10 (got '$LAST' rc=$RC)"; fi
if [ "$(ssh_calls)" = "1" ] && grep -q 'kickstart -k gui/501/com.zig.agentgateway' "$GWT_FAKE/ssh-calls"; then
  ok
else
  bad "restored → exactly one kickstart of the job (got: $(tr '\n' '|' <"$GWT_FAKE/ssh-calls"))"
fi
if [ "$(ledger_rows)" = "1" ] && [ "$(ledger_verdict)" = "restored" ]; then ok; else bad "restored → one ledger row carrying the verdict (rows=$(ledger_rows) verdict=$(ledger_verdict))"; fi

# ---------------------------------------------------------------------------
# Case 3: down + ssh cannot connect ⇒ pico-unreachable, exit 10, ledger row.
#   A DIFFERENT fact from "the gateway is down": nothing was restarted.
setup_case 000
touch "$GWT_FAKE/ssh-unreachable"
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=pico-unreachable" ] && [ "$RC" = 10 ]; then ok; else bad "down+ssh 255 ⇒ pico-unreachable/exit10 (got '$LAST' rc=$RC)"; fi
if [ "$(ledger_verdict)" = "pico-unreachable" ]; then ok; else bad "pico-unreachable → ledger row (got '$(ledger_verdict)')"; fi

# ---------------------------------------------------------------------------
# Case 4: down, kickstart succeeds, but the door STAYS shut ⇒ down-unrecovered.
#   Every re-probe try must actually be spent before giving up.
setup_case 000 000 000
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=down-unrecovered" ] && [ "$RC" = 10 ]; then ok; else bad "down→kickstart→still down ⇒ down-unrecovered/exit10 (got '$LAST' rc=$RC)"; fi
if [ "$(grep -c . "$GWT_FAKE/curl-calls")" = "3" ]; then ok; else bad "down-unrecovered → 1 probe + GW_PROBE_TRIES re-probes (got $(grep -c . "$GWT_FAKE/curl-calls"))"; fi

# ---------------------------------------------------------------------------
# Case 5: launchctl says "Could not find service" — the job is not LOADED, the
#   exact 2026-08-09 shape ⇒ bootstrap THEN kickstart, in that order.
setup_case 000 401
printf 'Could not find service "com.zig.agentgateway" in domain for login\n' >"$GWT_FAKE/kick-out.1"
run_gh
if [ "$LAST" = "GATEWAY_HEALTH_RESULT=restored" ]; then ok; else bad "not-loaded → bootstrap path still ends restored (got '$LAST')"; fi
SEQ=$(sed -n -E 's/^launchctl ([a-z]+).*/\1/p' "$GWT_FAKE/ssh-calls" | paste -sd, -)
if [ "$SEQ" = "kickstart,bootstrap,kickstart" ]; then
  ok
else
  bad "'Could not find service' → kickstart, bootstrap, kickstart in ORDER (got '$SEQ')"
fi
if grep -q 'bootstrap gui/501 /Users/pico/Library/LaunchAgents/com.zig.agentgateway.plist' "$GWT_FAKE/ssh-calls"; then
  ok
else
  bad "bootstrap targets the derived domain gui/501 with the plist"
fi
if [ "$(sed -n -E 's/.*"bootstraps":([0-9]+).*/\1/p' "$GW_LEDGER")" = "1" ]; then ok; else bad "ledger records the bootstrap it performed"; fi

# Case 5b: a kickstart that did NOT complain must NOT bootstrap.
setup_case 000 401
run_gh
if ! grep -q bootstrap "$GWT_FAKE/ssh-calls"; then ok; else bad "an ordinary kickstart must not bootstrap"; fi

# ---------------------------------------------------------------------------
# Case 6: the RECOVERY RECORD. An `ok` whose predecessor was NOT ok appends a
#   row — without it the ledger shows an outage that never ended.
setup_case 401
printf '{"ts":"2026-08-09T12:40:00Z","host":"pico","verdict":"down-unrecovered","http_code":"000","kickstarts":1,"bootstraps":0,"findings":[]}\n' >"$GW_LEDGER"
run_gh
if [ "$RC" = 0 ] && [ "$(ledger_rows)" = "2" ] && [ "$(ledger_verdict)" = "ok" ]; then
  ok
else
  bad "first ok AFTER a non-ok appends the recovery row (rc=$RC rows=$(ledger_rows) verdict=$(ledger_verdict))"
fi
# ...and the ok after THAT ok is silent again.
run_gh
if [ "$(ledger_rows)" = "2" ]; then ok; else bad "a second consecutive ok appends nothing (rows=$(ledger_rows))"; fi

# ---------------------------------------------------------------------------
# Case 7: an unwritable ledger is a BROKEN CHECKER (exit 1), never a verdict to
#   be trusted — and the result line is still the LAST line, so `tail -1` of the
#   merged stream never hands a consumer a sentence instead of a verdict.
setup_case 000
touch "$GWT_FAKE/ssh-unreachable"
mkdir -p "$GWT_FAKE/nowrite"
chmod 500 "$GWT_FAKE/nowrite"
GW_LEDGER="$GWT_FAKE/nowrite/sub/gateway.jsonl" run_gh
chmod 700 "$GWT_FAKE/nowrite"
if [ "$RC" = 1 ] && [ "$LAST" = "GATEWAY_HEALTH_RESULT=pico-unreachable" ]; then
  ok
else
  bad "unwritable ledger ⇒ exit 1 (checker broken) with the result line last (rc=$RC last='$LAST')"
fi

# ---------------------------------------------------------------------------
# Case 8: THE GUARD MAY NEVER FLIP THE FLEET'S ROUTING. gateway-switch.sh
#   changes where every seat's traffic goes and which key pays; a 2-minute timer
#   must not make that call. This is a static assertion because the dangerous
#   version of this script is one that never runs in a test at all.
if ! grep -q 'gateway-switch\.sh' <(sed '/^#/d' "$GH"); then
  ok
else
  bad "gateway-health.sh must never invoke gateway-switch.sh (found it in executable code)"
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
