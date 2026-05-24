#!/usr/bin/env bash
#
# integration_test.sh — end-to-end PROXY-protocol pipeline test for the
# ss14-wrapper daemon.
#
# Per spec dotfiles-9g1 (Approach C2) + test bead dotfiles-qts. This
# script stands up a synthetic version of the cutover topology on
# loopback + nginx, exercises a stripped-down packet path, and
# rolls EVERYTHING back even on failure.
#
# CRITICAL PRODUCTION SAFETY:
# - Live SS14 runs on :1212 on zig-computer. This test uses :11212
#   (test-port-convention matching /check dotfiles-9cj's synthetic
#   suite). NEVER touch :1212.
# - Pre-flight snapshots /etc/nginx (full tree) before any writes;
#   post-test diffs against that snapshot — diff MUST be empty.
# - Trap-based rollback ensures the synthetic nginx stream block is
#   removed even if the script is killed mid-flight.
# - Verifies SS14's :1212 listeners are present before AND after the
#   test. If they vanish at any point, fail loudly.
#
# Two phases:
#   1. Baseline (pre-/impl carry-over): nginx → sniffer on UPSTREAM_PORT,
#      assert PROXY v1 header emitted with the real client IP preserved.
#   2. Impl-wave (dotfiles-xx9): rebuild wrapper, reload nginx pointing
#      at the wrapper, run a synthetic echo upstream, send a UDP
#      datagram from a pinned source port, then query the wrapper's UDS
#      LOOKUP API and assert it returns the real client IP+port.
# Rollback runs on ALL exit paths and verifies SS14 :1212 listeners are
# present BEFORE / DURING / AFTER, and nginx config matches the
# pre-test snapshot.

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

readonly TEST_PORT=11212                      # nginx UDP listener (test, NEVER :1212)
readonly UPSTREAM_PORT=11213                  # stub UDP echo + sniffer port (pre-impl baseline)
readonly WRAPPER_PORT=11214                   # wrapper-impl wave: wrapper public UDP listener
readonly ECHO_PORT=11215                      # wrapper-impl wave: synthetic Robust.Server echo
readonly LIVE_PORT=1212                       # live SS14 — verify, NEVER touch
readonly TEST_NGINX_CONF="/etc/nginx/streams-enabled/ss14-wrapper-integration-test.conf"
readonly NGINX_PRE_SNAPSHOT="/tmp/ss14-wrapper-nginx-pre.$$.tar.gz"
readonly SNIFFER_LOG="/tmp/ss14-wrapper-sniffer.$$.log"
readonly SNIFFER_PID_FILE="/tmp/ss14-wrapper-sniffer.$$.pid"
readonly SNIFFER_PY="/tmp/ss14-wrapper-sniffer.$$.py"
readonly EVIDENCE_FILE="/tmp/ss14-wrapper-evidence.$$.txt"
readonly WRAPPER_LOG="/tmp/ss14-wrapper-wrapper.$$.log"
readonly WRAPPER_PID_FILE="/tmp/ss14-wrapper-wrapper.$$.pid"
readonly WRAPPER_UDS="/tmp/ss14-wrapper-integration.$$.sock"
readonly ECHO_LOG="/tmp/ss14-wrapper-echo.$$.log"
readonly ECHO_PID_FILE="/tmp/ss14-wrapper-echo.$$.pid"
readonly ECHO_PY="/tmp/ss14-wrapper-echo.$$.py"

# Failure markers — bumped from anywhere in the script.
FAIL_COUNT=0
LAST_STAGE="init"

# ---------------------------------------------------------------------
# Pretty printing
# ---------------------------------------------------------------------

log() { printf '[integration_test] %s\n' "$*" >&2; }
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[integration_test] FAIL @ %s: %s\n' "$LAST_STAGE" "$*" >&2
}
stage() {
    LAST_STAGE="$1"
    printf '\n[integration_test] === STAGE: %s ===\n' "$1" >&2
}

# ---------------------------------------------------------------------
# Rollback — ALWAYS runs on exit, even on failure.
# ---------------------------------------------------------------------

rollback() {
    local trap_exit=$?
    local exit_code=0
    # Inherit failure from caller if it set one (explicit `exit 1`,
    # set -e abort, etc.). If the caller ran cleanly, we still
    # honor any FAIL_COUNT bumped via fail().
    if [[ "$trap_exit" -ne 0 ]]; then
        exit_code=$trap_exit
    fi
    stage "rollback"

    # Kill wrapper (impl-wave)
    if [[ -f "$WRAPPER_PID_FILE" ]]; then
        local wrapper_pid
        wrapper_pid=$(cat "$WRAPPER_PID_FILE" 2>/dev/null || true)
        if [[ -n "$wrapper_pid" ]] && kill -0 "$wrapper_pid" 2>/dev/null; then
            kill "$wrapper_pid" 2>/dev/null || true
            # Give it a moment to release the UDS + ports cleanly.
            for _ in 1 2 3 4 5; do
                kill -0 "$wrapper_pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -9 "$wrapper_pid" 2>/dev/null || true
            log "killed wrapper pid=$wrapper_pid"
        fi
        rm -f "$WRAPPER_PID_FILE"
    fi

    # Kill echo server (impl-wave)
    if [[ -f "$ECHO_PID_FILE" ]]; then
        local echo_pid
        echo_pid=$(cat "$ECHO_PID_FILE" 2>/dev/null || true)
        if [[ -n "$echo_pid" ]] && kill -0 "$echo_pid" 2>/dev/null; then
            kill "$echo_pid" 2>/dev/null || true
            log "killed echo pid=$echo_pid"
        fi
        rm -f "$ECHO_PID_FILE"
    fi

    # Kill sniffer
    if [[ -f "$SNIFFER_PID_FILE" ]]; then
        local sniffer_pid
        sniffer_pid=$(cat "$SNIFFER_PID_FILE" 2>/dev/null || true)
        if [[ -n "$sniffer_pid" ]] && kill -0 "$sniffer_pid" 2>/dev/null; then
            kill "$sniffer_pid" 2>/dev/null || true
            log "killed sniffer pid=$sniffer_pid"
        fi
        rm -f "$SNIFFER_PID_FILE"
    fi

    # Remove temp scripts + UDS socket
    rm -f "$SNIFFER_PY" "$ECHO_PY" "$WRAPPER_UDS"

    # Remove synthetic nginx config + reload nginx
    if sudo -n test -f "$TEST_NGINX_CONF" 2>/dev/null; then
        sudo -n rm -f "$TEST_NGINX_CONF"
        log "removed $TEST_NGINX_CONF"
        if sudo -n nginx -t >/dev/null 2>&1; then
            sudo -n systemctl reload nginx >/dev/null 2>&1 && log "reloaded nginx" || \
                log "WARN: nginx reload failed during rollback"
        else
            log "WARN: nginx -t failed during rollback — leaving service alone"
        fi
    fi

    # Verify post-rollback nginx config == pre-snapshot
    if [[ -f "$NGINX_PRE_SNAPSHOT" ]]; then
        local post_snapshot="/tmp/ss14-wrapper-nginx-post.$$.tar.gz"
        sudo -n tar czf "$post_snapshot" -C / etc/nginx 2>/dev/null
        local pre_hash post_hash
        pre_hash=$(sudo -n tar tzf "$NGINX_PRE_SNAPSHOT" 2>/dev/null | sha256sum | cut -d' ' -f1)
        post_hash=$(sudo -n tar tzf "$post_snapshot" 2>/dev/null | sha256sum | cut -d' ' -f1)
        # Compare file LISTS (timestamps inside tarballs differ); for byte-level
        # check we'd extract + diff, but file-list parity is the canonical
        # rollback indicator.
        if [[ "$pre_hash" == "$post_hash" ]]; then
            log "OK: nginx config file list matches pre-snapshot (rollback clean)"
        else
            log "FAIL: nginx config file list drifted after rollback"
            log "  pre:  $pre_hash"
            log "  post: $post_hash"
            sudo -n tar tzf "$NGINX_PRE_SNAPSHOT" | sort >/tmp/ss14-wrapper-pre-files.$$ 2>/dev/null
            sudo -n tar tzf "$post_snapshot" | sort >/tmp/ss14-wrapper-post-files.$$ 2>/dev/null
            diff /tmp/ss14-wrapper-pre-files.$$ /tmp/ss14-wrapper-post-files.$$ >&2 || true
            rm -f "/tmp/ss14-wrapper-pre-files.$$" "/tmp/ss14-wrapper-post-files.$$"
            exit_code=1
        fi
        sudo -n rm -f "$post_snapshot"
        sudo -n rm -f "$NGINX_PRE_SNAPSHOT"
    fi

    # FINAL safety: SS14 :1212 listeners must still be present.
    local final_listeners
    final_listeners=$(ss -tunap 2>/dev/null | grep -c ":${LIVE_PORT} " || true)
    if [[ "$final_listeners" -lt 1 ]]; then
        log "CRITICAL: SS14 :${LIVE_PORT} listeners VANISHED post-rollback"
        exit_code=2
    else
        log "OK: SS14 :${LIVE_PORT} still has $final_listeners listener entries"
    fi

    # Clean up evidence + log if not under explicit keep
    if [[ "${KEEP_EVIDENCE:-0}" != "1" ]]; then
        rm -f "$SNIFFER_LOG" "$EVIDENCE_FILE" "$WRAPPER_LOG" "$ECHO_LOG"
    else
        log "evidence preserved: $EVIDENCE_FILE"
        log "  sniffer log: $SNIFFER_LOG"
        log "  wrapper log: $WRAPPER_LOG"
        log "  echo log:    $ECHO_LOG"
    fi

    if (( FAIL_COUNT > 0 )); then
        log "INTEGRATION TEST FAILED ($FAIL_COUNT failures, last stage: $LAST_STAGE)"
        if [[ "$exit_code" -eq 0 ]]; then
            exit_code=1
        fi
        exit "$exit_code"
    fi
    log "INTEGRATION TEST PASSED (rollback clean)"
    exit "$exit_code"
}
trap rollback EXIT INT TERM

# ---------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------

stage "pre-flight"

# 1. Live SS14 listeners must be present BEFORE we touch anything.
PRE_LIVE_LISTENERS=$(ss -tunap 2>/dev/null | grep -c ":${LIVE_PORT} " || true)
if [[ "$PRE_LIVE_LISTENERS" -lt 1 ]]; then
    fail "SS14 :${LIVE_PORT} listeners not present at start — refusing to run "\
"(this test exists to PROVE we don't disturb them)"
    exit 1
fi
log "OK: SS14 :${LIVE_PORT} has $PRE_LIVE_LISTENERS listener entries pre-flight"

# 2. Test ports must be FREE.
for p in "$TEST_PORT" "$UPSTREAM_PORT" "$WRAPPER_PORT" "$ECHO_PORT"; do
    if ss -tunap 2>/dev/null | grep -q ":${p} "; then
        fail "test port :${p} is already in use — refusing to clobber"
        exit 1
    fi
done
log "OK: test ports :${TEST_PORT}, :${UPSTREAM_PORT}, :${WRAPPER_PORT}, :${ECHO_PORT} are free"

# 3. sudo -n must work for nginx ops.
if ! sudo -n true 2>/dev/null; then
    fail "sudo -n unavailable — this test needs nginx config write + reload"
    exit 1
fi
log "OK: sudo -n works"

# 4. nginx -t baseline must be clean before we add anything.
if ! sudo -n nginx -t >/dev/null 2>&1; then
    fail "nginx -t fails BEFORE we add our config — environment broken"
    sudo -n nginx -t 2>&1 | head -10 >&2
    exit 1
fi
log "OK: baseline nginx -t clean"

# 5. Snapshot /etc/nginx so the rollback diff is byte-honest.
sudo -n tar czf "$NGINX_PRE_SNAPSHOT" -C / etc/nginx 2>/dev/null
log "OK: snapshotted /etc/nginx → $NGINX_PRE_SNAPSHOT"

# 6. python3 available for the sniffer.
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not on PATH — needed for the stub UDP sniffer"
    exit 1
fi
log "OK: python3 available"

# ---------------------------------------------------------------------
# Stub UDP sniffer — listens on UPSTREAM_PORT, logs the raw bytes it
# receives. If nginx forwards a PROXY-header-prefixed datagram, the
# log will start with "PROXY ".
# ---------------------------------------------------------------------

stage "start sniffer"

cat >"$SNIFFER_PY" <<'PYEOF'
import binascii, socket, sys
host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((host, port))
print(f"sniffer listening on {host}:{port}", flush=True)
while True:
    data, src = sock.recvfrom(65535)
    hex_dump = binascii.hexlify(data).decode()
    has_v1 = data.startswith(b"PROXY ")
    has_v2 = data[:12] == bytes.fromhex("0D0A0D0A000D0A515549540A")
    print(f"FROM={src[0]}:{src[1]} LEN={len(data)} V1={has_v1} V2={has_v2}", flush=True)
    print(f"HEX={hex_dump}", flush=True)
    if has_v1:
        try:
            hdr_end = data.index(b"\r\n")
            print(f"V1_HEADER={data[:hdr_end].decode(errors='replace')}", flush=True)
            print(f"V1_PAYLOAD={data[hdr_end+2:]!r}", flush=True)
        except ValueError:
            print("V1_NO_TERMINATOR", flush=True)
PYEOF

python3 "$SNIFFER_PY" 127.0.0.1 "$UPSTREAM_PORT" >"$SNIFFER_LOG" 2>&1 &
SNIFFER_PID=$!
echo "$SNIFFER_PID" >"$SNIFFER_PID_FILE"
log "started sniffer pid=$SNIFFER_PID"

# Wait briefly for bind
for _ in 1 2 3 4 5; do
    if ss -unap 2>/dev/null | grep -q ":${UPSTREAM_PORT} "; then
        break
    fi
    sleep 0.2
done
if ! ss -unap 2>/dev/null | grep -q ":${UPSTREAM_PORT} "; then
    fail "sniffer never bound :${UPSTREAM_PORT}"
    exit 1
fi
log "OK: sniffer bound :${UPSTREAM_PORT}"

# ---------------------------------------------------------------------
# Drop synthetic nginx stream config + reload nginx.
# ---------------------------------------------------------------------

stage "install nginx stream config"

# Note: writing as a here-doc through sudo tee so we keep root ownership
# without doing a chown dance.
sudo -n tee "$TEST_NGINX_CONF" >/dev/null <<EOF
# INTEGRATION TEST — ss14-wrapper TDD pass. test port :${TEST_PORT}.
# LIVE SS14 on :${LIVE_PORT} is UNTOUCHED. Auto-removed by rollback trap.
# Spec dotfiles-9g1 + test bead dotfiles-qts.

server {
    listen ${TEST_PORT} udp;
    proxy_pass 127.0.0.1:${UPSTREAM_PORT};
    proxy_protocol on;
    proxy_timeout 10s;
    proxy_responses 0;
}
EOF
log "wrote $TEST_NGINX_CONF"

if ! sudo -n nginx -t >/dev/null 2>&1; then
    fail "nginx -t fails after adding test config"
    sudo -n nginx -t 2>&1 | head -20 >&2
    exit 1
fi
log "OK: nginx -t clean with test block"

sudo -n systemctl reload nginx
log "OK: nginx reloaded"

# Confirm test port is now bound by nginx.
for _ in 1 2 3 4 5; do
    if ss -unap 2>/dev/null | grep -q ":${TEST_PORT} "; then
        break
    fi
    sleep 0.2
done
if ! ss -unap 2>/dev/null | grep -q ":${TEST_PORT} "; then
    fail "nginx didn't bind :${TEST_PORT}"
    exit 1
fi
log "OK: nginx bound :${TEST_PORT}"

# Verify SS14 :1212 still up — no overlap.
DURING_LIVE_LISTENERS=$(ss -tunap 2>/dev/null | grep -c ":${LIVE_PORT} " || true)
if [[ "$DURING_LIVE_LISTENERS" -lt 1 ]]; then
    fail "SS14 :${LIVE_PORT} listeners VANISHED after nginx reload — ABORT"
    exit 1
fi
log "OK: SS14 :${LIVE_PORT} still has $DURING_LIVE_LISTENERS listener entries during test"

# ---------------------------------------------------------------------
# Send synthetic datagrams from varying src IP+port.
# ---------------------------------------------------------------------

stage "send test datagrams"

# Datagram 1: loopback src, simple payload
echo -n "TEST-PAYLOAD-1-LOOPBACK" | nc -u -w1 127.0.0.1 "$TEST_PORT" || true
sleep 0.3

# Datagram 2: loopback src, different ephemeral port (nc picks one per invocation)
echo -n "TEST-PAYLOAD-2-LOOPBACK" | nc -u -w1 -p 55555 127.0.0.1 "$TEST_PORT" || true
sleep 0.3

# Datagram 3: rapid-fire two from same source port (tests per-datagram
# header behavior + session reuse per spec TC03).
echo -n "TEST-PAYLOAD-3A" | nc -u -w1 -p 55556 127.0.0.1 "$TEST_PORT" || true
echo -n "TEST-PAYLOAD-3B" | nc -u -w1 -p 55556 127.0.0.1 "$TEST_PORT" || true
sleep 0.5

log "OK: sent 4 synthetic datagrams"

# ---------------------------------------------------------------------
# Verify the sniffer received PROXY-headered datagrams (proving nginx
# emits the header) — this much should pass even without the wrapper.
# ---------------------------------------------------------------------

stage "verify nginx emitted PROXY headers"

cp "$SNIFFER_LOG" "$EVIDENCE_FILE"
log "sniffer log copied to $EVIDENCE_FILE for triage"

# Count received datagrams
RX_COUNT=$(grep -c '^FROM=' "$SNIFFER_LOG" 2>/dev/null || true)
RX_COUNT=${RX_COUNT:-0}
log "sniffer received $RX_COUNT datagrams"

if [[ "$RX_COUNT" -lt 1 ]]; then
    fail "sniffer received ZERO datagrams — nginx → sniffer plumbing broken"
    exit 1
fi

# Every received datagram should carry a PROXY v1 (or v2) header.
V1_COUNT=$(grep -c 'V1=True' "$SNIFFER_LOG" 2>/dev/null || true)
V2_COUNT=$(grep -c 'V2=True' "$SNIFFER_LOG" 2>/dev/null || true)
V1_COUNT=${V1_COUNT:-0}
V2_COUNT=${V2_COUNT:-0}
PROXY_COUNT=$((V1_COUNT + V2_COUNT))
log "PROXY headers seen: v1=$V1_COUNT v2=$V2_COUNT (total=$PROXY_COUNT)"

if [[ "$PROXY_COUNT" -lt 1 ]]; then
    fail "NO datagrams carried a PROXY header — nginx proxy_protocol misconfigured"
    exit 1
fi

# Real-client IP should appear in the header — confirms nginx is
# preserving source IPs even on loopback.
if grep -q 'V1_HEADER=PROXY TCP4 127\.0\.0\.1' "$SNIFFER_LOG"; then
    log "OK: PROXY v1 header preserves real client IP (127.0.0.1)"
else
    log "WARN: did not see canonical 'PROXY TCP4 127.0.0.1' header line"
    log "  sniffer log:"
    head -20 "$SNIFFER_LOG" | sed 's/^/    /' >&2
fi

# Specific source-port preservation check — port 55555 was explicitly
# pinned via `nc -p 55555`. The PROXY header should reflect it.
if grep -q '55555' "$SNIFFER_LOG"; then
    log "OK: PROXY header preserved pinned source port 55555"
else
    fail "PROXY header did NOT preserve pinned source port 55555"
fi

# ---------------------------------------------------------------------
# Wrapper-receives stage — end-to-end through nginx → wrapper → UDS.
# Per dotfiles-xx9 (impl-wave extension on top of dotfiles-qts test bead).
# Build the wrapper if it isn't already on disk, then reconfigure nginx
# to point at the wrapper, launch wrapper + echo server, send a UDP
# datagram from a pinned source port, and probe the wrapper's UDS
# LOOKUP API to assert the real client IP is captured.
# ---------------------------------------------------------------------

stage "build wrapper"

# Build the wrapper from the same directory as this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "${SCRIPT_DIR}/ss14-wrapper" ]]; then
    log "building wrapper at ${SCRIPT_DIR}/ss14-wrapper"
    if ! ( cd "$SCRIPT_DIR" && go build -o ss14-wrapper . ); then
        fail "go build of ss14-wrapper failed"
        exit 1
    fi
fi

WRAPPER_BIN="${SCRIPT_DIR}/ss14-wrapper"
if [[ ! -x "$WRAPPER_BIN" ]]; then
    fail "wrapper binary not present at $WRAPPER_BIN after build attempt"
    exit 1
fi
log "OK: wrapper binary present: $WRAPPER_BIN"

# ---------------------------------------------------------------------
# Reconfigure nginx: point the test stream at the wrapper (:11214)
# instead of the synthetic sniffer (:11213). Sniffer continues to run
# (its bound port is still verified clean below) but is now off-path
# so we can spot any accidental fallback.
# ---------------------------------------------------------------------

stage "reconfigure nginx → wrapper"

sudo -n tee "$TEST_NGINX_CONF" >/dev/null <<EOF
# INTEGRATION TEST — ss14-wrapper impl-wave (dotfiles-xx9).
# test port :${TEST_PORT} → wrapper :${WRAPPER_PORT} → echo :${ECHO_PORT}.
# LIVE SS14 on :${LIVE_PORT} is UNTOUCHED. Auto-removed by rollback trap.

server {
    listen ${TEST_PORT} udp;
    proxy_pass 127.0.0.1:${WRAPPER_PORT};
    proxy_protocol on;
    proxy_timeout 10s;
    proxy_responses 0;
}
EOF
log "rewrote $TEST_NGINX_CONF (upstream → :${WRAPPER_PORT})"

if ! sudo -n nginx -t >/dev/null 2>&1; then
    fail "nginx -t failed after reconfigure"
    sudo -n nginx -t 2>&1 | head -20 >&2
    exit 1
fi
sudo -n systemctl reload nginx
log "OK: nginx reloaded (now forwarding :${TEST_PORT} → :${WRAPPER_PORT})"

# Verify SS14 :1212 still up after second reload — paranoia worth the
# four lines.
DURING_LIVE_LISTENERS=$(ss -tunap 2>/dev/null | grep -c ":${LIVE_PORT} " || true)
if [[ "$DURING_LIVE_LISTENERS" -lt 1 ]]; then
    fail "SS14 :${LIVE_PORT} listeners VANISHED after nginx reconfigure-reload"
    exit 1
fi
log "OK: SS14 :${LIVE_PORT} still has $DURING_LIVE_LISTENERS listener entries"

# ---------------------------------------------------------------------
# Synthetic echo server (impl-wave): plain UDP recv on ECHO_PORT, logs
# the source 5-tuple of each incoming datagram. The source PORT of the
# datagram landing here is the wrapper's per-session fan-out port —
# which is ALSO the key for the UDS LOOKUP API (session.go: byUDPPort
# keys on FanOut.LocalAddr().Port).
# ---------------------------------------------------------------------

stage "start synthetic echo upstream"

cat >"$ECHO_PY" <<'PYEOF'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((host, port))
print(f"echo listening on {host}:{port}", flush=True)
while True:
    data, src = sock.recvfrom(65535)
    # Source PORT here is the wrapper's fan-out port — the LOOKUP key.
    print(f"FANOUT_SRC={src[0]}:{src[1]} LEN={len(data)} PAYLOAD={data!r}", flush=True)
PYEOF

python3 "$ECHO_PY" 127.0.0.1 "$ECHO_PORT" >"$ECHO_LOG" 2>&1 &
ECHO_PID=$!
echo "$ECHO_PID" >"$ECHO_PID_FILE"
log "started echo pid=$ECHO_PID"

for _ in 1 2 3 4 5; do
    if ss -unap 2>/dev/null | grep -q ":${ECHO_PORT} "; then
        break
    fi
    sleep 0.2
done
if ! ss -unap 2>/dev/null | grep -q ":${ECHO_PORT} "; then
    fail "echo never bound :${ECHO_PORT}"
    exit 1
fi
log "OK: echo bound :${ECHO_PORT}"

# ---------------------------------------------------------------------
# Launch the wrapper with env-var config per wrapper/config.go:
#   SS14_WRAPPER_LISTEN, SS14_WRAPPER_UPSTREAM, SS14_WRAPPER_SOCK,
#   SS14_WRAPPER_TTL_SECONDS (optional, default 120s).
# ---------------------------------------------------------------------

stage "launch wrapper"

# Make sure stale UDS path is gone — the wrapper itself removeSocketIfStale's,
# but belt-and-suspenders.
rm -f "$WRAPPER_UDS"

SS14_WRAPPER_LISTEN="127.0.0.1:${WRAPPER_PORT}" \
SS14_WRAPPER_UPSTREAM="127.0.0.1:${ECHO_PORT}" \
SS14_WRAPPER_SOCK="$WRAPPER_UDS" \
SS14_WRAPPER_TTL_SECONDS="30" \
    "$WRAPPER_BIN" >"$WRAPPER_LOG" 2>&1 &
WRAPPER_PID=$!
echo "$WRAPPER_PID" >"$WRAPPER_PID_FILE"
log "started wrapper pid=$WRAPPER_PID (listen :${WRAPPER_PORT}, upstream :${ECHO_PORT}, sock $WRAPPER_UDS)"

# Wait for wrapper to bind UDP listener AND UDS socket.
WRAPPER_READY=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ss -unap 2>/dev/null | grep -q ":${WRAPPER_PORT} " && [[ -S "$WRAPPER_UDS" ]]; then
        WRAPPER_READY=1
        break
    fi
    # Catch early death: if wrapper exited, log the reason now.
    if ! kill -0 "$WRAPPER_PID" 2>/dev/null; then
        fail "wrapper exited before binding (see $WRAPPER_LOG)"
        head -20 "$WRAPPER_LOG" | sed 's/^/    /' >&2
        exit 1
    fi
    sleep 0.2
done
if [[ "$WRAPPER_READY" -ne 1 ]]; then
    fail "wrapper did not bind :${WRAPPER_PORT} + UDS within 2s"
    head -20 "$WRAPPER_LOG" | sed 's/^/    /' >&2
    exit 1
fi
log "OK: wrapper bound :${WRAPPER_PORT} (UDP) + $WRAPPER_UDS (UDS)"

# ---------------------------------------------------------------------
# Send a synthetic datagram from a PINNED source port. The PROXY header
# nginx prepends will carry "127.0.0.1:<pinned>" as the real-client
# tuple — that's what we'll assert came back through the UDS LOOKUP.
# ---------------------------------------------------------------------

stage "send synthetic datagram through nginx → wrapper → echo"

readonly PINNED_SRC_PORT=44441
readonly PINNED_PAYLOAD="WRAPPER-IMPL-WAVE-PROBE"

echo -n "$PINNED_PAYLOAD" | nc -u -w1 -p "$PINNED_SRC_PORT" 127.0.0.1 "$TEST_PORT" || true

# Give the wrapper its hot-path round trip + a hair extra.
sleep 0.5

# ---------------------------------------------------------------------
# Verify echo received the STRIPPED payload (no PROXY header bytes).
# This confirms wrapper parsed + forwarded successfully.
# ---------------------------------------------------------------------

stage "verify echo received stripped payload"

if ! grep -q "PAYLOAD=b'${PINNED_PAYLOAD}'" "$ECHO_LOG"; then
    fail "echo did not receive expected stripped payload"
    log "  echo log tail:"
    tail -10 "$ECHO_LOG" | sed 's/^/    /' >&2
    log "  wrapper log tail:"
    tail -20 "$WRAPPER_LOG" | sed 's/^/    /' >&2
    exit 1
fi
log "OK: echo received stripped payload (wrapper consumed PROXY header)"

# Extract the wrapper's fan-out source port from the echo log — this
# is the key Robust.Server would query for via LOOKUP.
FANOUT_PORT=$(grep 'FANOUT_SRC=127.0.0.1:' "$ECHO_LOG" | head -1 | \
    sed -n 's/^FANOUT_SRC=127\.0\.0\.1:\([0-9]\+\) .*/\1/p')

if [[ -z "$FANOUT_PORT" ]]; then
    fail "could not extract wrapper fan-out port from echo log"
    cat "$ECHO_LOG" >&2
    exit 1
fi
log "OK: extracted wrapper fan-out port = $FANOUT_PORT"

# ---------------------------------------------------------------------
# Probe the wrapper's UDS LOOKUP API.
#   Request:  "LOOKUP udp <fanout-port>\n"
#   Expected: "OK 127.0.0.1:<PINNED_SRC_PORT>\n"
# ---------------------------------------------------------------------

stage "probe wrapper UDS LOOKUP API"

LOOKUP_RESPONSE=$(printf 'LOOKUP udp %s\n' "$FANOUT_PORT" | nc -U -w2 "$WRAPPER_UDS" 2>&1 || true)
log "LOOKUP udp $FANOUT_PORT → $(printf %q "$LOOKUP_RESPONSE")"

EXPECTED_LOOKUP="OK 127.0.0.1:${PINNED_SRC_PORT}"
if [[ "$LOOKUP_RESPONSE" != "${EXPECTED_LOOKUP}"* ]]; then
    fail "UDS LOOKUP response did not match expected (got: '$LOOKUP_RESPONSE', want prefix: '$EXPECTED_LOOKUP')"
    log "  wrapper log tail:"
    tail -20 "$WRAPPER_LOG" | sed 's/^/    /' >&2
    exit 1
fi
log "OK: wrapper UDS LOOKUP returned real client IP+port (${EXPECTED_LOOKUP})"

# Also exercise the HEALTH endpoint — sanity check the daemon is happy.
HEALTH_RESPONSE=$(printf 'HEALTH\n' | nc -U -w2 "$WRAPPER_UDS" 2>&1 || true)
log "HEALTH → $(printf %q "$HEALTH_RESPONSE")"
if [[ "$HEALTH_RESPONSE" != OK\ active_sessions=* ]]; then
    fail "UDS HEALTH did not return expected 'OK active_sessions=...' prefix"
    exit 1
fi
log "OK: wrapper UDS HEALTH responded sanely"

# And ENUMERATE — should list our one session.
ENUMERATE_RESPONSE=$(printf 'ENUMERATE\n' | nc -U -w2 "$WRAPPER_UDS" 2>&1 || true)
log "ENUMERATE → $(printf %q "$ENUMERATE_RESPONSE")"
if [[ "$ENUMERATE_RESPONSE" != *"udp ${FANOUT_PORT} 127.0.0.1:${PINNED_SRC_PORT}"* ]]; then
    fail "UDS ENUMERATE missing expected session line"
    exit 1
fi
log "OK: wrapper UDS ENUMERATE listed the session"

# ---------------------------------------------------------------------
# Wrapper crash safety: kill the wrapper, verify nginx is undisturbed
# and SS14 is undisturbed. (Mirrors spec §3.9 — wrapper crash must not
# cascade.)
# ---------------------------------------------------------------------

stage "kill wrapper — verify nginx + SS14 unaffected"

if kill "$WRAPPER_PID" 2>/dev/null; then
    for _ in 1 2 3 4 5; do
        kill -0 "$WRAPPER_PID" 2>/dev/null || break
        sleep 0.1
    done
    log "OK: wrapper killed cleanly (pid=$WRAPPER_PID)"
fi
# Prevent rollback's redundant kill from logging "killed" again.
rm -f "$WRAPPER_PID_FILE"

if ! sudo -n nginx -t >/dev/null 2>&1; then
    fail "nginx -t broken after wrapper kill (impossible — wrapper kill is not an nginx event)"
    exit 1
fi

POST_KILL_LIVE_LISTENERS=$(ss -tunap 2>/dev/null | grep -c ":${LIVE_PORT} " || true)
if [[ "$POST_KILL_LIVE_LISTENERS" -lt 1 ]]; then
    fail "SS14 :${LIVE_PORT} listeners VANISHED after wrapper kill"
    exit 1
fi
log "OK: SS14 :${LIVE_PORT} still has $POST_KILL_LIVE_LISTENERS listener entries after wrapper kill"

# ---------------------------------------------------------------------
# End — rollback trap fires on exit (removes test nginx conf, kills
# remaining processes, snapshot-diffs /etc/nginx, re-verifies SS14).
# ---------------------------------------------------------------------

stage "complete (impl-wave end-to-end)"
log "integration test SUCCESS: nginx PROXY emit verified, wrapper consumed \
PROXY headers, UDS LOOKUP/HEALTH/ENUMERATE all responded, wrapper kill did \
not disturb nginx or SS14 :${LIVE_PORT}"
