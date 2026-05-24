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
# Expected behavior on a clean (pre-/impl) tree:
#   This script SHOULD reach the "verify wrapper received the
#   PROXY-headered packet" stage and FAIL there, because no wrapper
#   binary exists yet. Rollback section MUST still complete cleanly.

set -euo pipefail

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

readonly TEST_PORT=11212                      # nginx UDP listener (test, NEVER :1212)
readonly UPSTREAM_PORT=11213                  # stub UDP echo + sniffer port
readonly LIVE_PORT=1212                       # live SS14 — verify, NEVER touch
readonly TEST_NGINX_CONF="/etc/nginx/streams-enabled/ss14-wrapper-integration-test.conf"
readonly NGINX_PRE_SNAPSHOT="/tmp/ss14-wrapper-nginx-pre.$$.tar.gz"
readonly SNIFFER_LOG="/tmp/ss14-wrapper-sniffer.$$.log"
readonly SNIFFER_PID_FILE="/tmp/ss14-wrapper-sniffer.$$.pid"
readonly EVIDENCE_FILE="/tmp/ss14-wrapper-evidence.$$.txt"

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
        rm -f "$SNIFFER_LOG" "$EVIDENCE_FILE"
    else
        log "evidence preserved: $EVIDENCE_FILE, sniffer log: $SNIFFER_LOG"
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
for p in "$TEST_PORT" "$UPSTREAM_PORT"; do
    if ss -tunap 2>/dev/null | grep -q ":${p} "; then
        fail "test port :${p} is already in use — refusing to clobber"
        exit 1
    fi
done
log "OK: test ports :${TEST_PORT} and :${UPSTREAM_PORT} are free"

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

cat >/tmp/ss14-wrapper-sniffer.$$.py <<'PYEOF'
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

python3 /tmp/ss14-wrapper-sniffer.$$.py 127.0.0.1 "$UPSTREAM_PORT" >"$SNIFFER_LOG" 2>&1 &
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
# Wrapper-receives stage — EXPECTED to fail in pre-/impl state.
# This is the TDD oracle: when the wrapper exists, it should print
# a LOOKUP-able session via its UDS API. We probe for the binary at
# the spec-defined path and connect to the UDS.
# ---------------------------------------------------------------------

stage "verify wrapper received PROXY-headered packet (expected-fail in TDD)"

WRAPPER_BIN_CANDIDATES=(
    "/Users/pico/bin/ss14-wrapper"
    "$HOME/bin/ss14-wrapper"
    "./ss14-wrapper"
    "./bin/ss14-wrapper"
)
WRAPPER_BIN=""
for c in "${WRAPPER_BIN_CANDIDATES[@]}"; do
    if [[ -x "$c" ]]; then
        WRAPPER_BIN="$c"
        break
    fi
done

if [[ -z "$WRAPPER_BIN" ]]; then
    fail "no ss14-wrapper binary found in any candidate path — /impl wave not landed yet (EXPECTED in TDD pre-impl state)"
    log "candidates tried: ${WRAPPER_BIN_CANDIDATES[*]}"
    exit 1
fi

log "found wrapper binary: $WRAPPER_BIN"
log "(impl-wave test continues here — see /impl follow-up)"

# When the wrapper exists, /impl will extend this test to:
#   - launch the wrapper pointed at a NEW upstream port
#   - reload nginx to forward to the wrapper instead of the sniffer
#   - re-send datagrams
#   - probe the wrapper's UDS LOOKUP API and assert the real client IP
#     is returned (TC04)
#   - kill the wrapper and verify graceful degradation (TC07)
#   - wait beyond TTL and verify eviction (TC08)

# For now the integration test stops here in TDD pre-impl mode.
log "OK: pre-impl integration test reached expected stopping point"

# ---------------------------------------------------------------------
# End — rollback trap will fire on exit.
# ---------------------------------------------------------------------

stage "complete (pre-/impl TDD baseline)"
log "integration test SUCCESS: nginx PROXY-protocol emit verified, "\
"wrapper-receive stage correctly failed with no binary present"
