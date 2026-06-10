#!/usr/bin/env bash
# pico_lock.sh — exclusive-access lock convention for pico inference.
#
# The matrix (and any future bench / training / heavy workload) requires pico
# to be the SOLE inference consumer for measurement validity. Hermes-dispatched
# workers (autonovel-phase2-worker, future LSRA, etc.) and ad-hoc dev claude
# calls routed through CCR-local can all silently violate that.
#
# This lib provides three primitives — acquire, release, check — that turn the
# "pico exclusive access" invariant from a comment into a checked file. Every
# pico consumer should:
#
#   - Before starting: `pico_acquire <owner> <duration>` — refuses (exit 1)
#     if someone else holds the lock; prints who + when + ETA.
#   - On exit: `pico_release <owner>` — only succeeds if the caller owns the lock.
#
# Lock file: /tmp/pico-busy.lock (JSON). Lives on zig-computer because BOTH
# the matrix AND the Hermes gateway (which spawns autonovel workers) run here.
# A consumer on a different host would need to either ssh-read this file or
# we'd promote the lock to pico itself (deferred).
#
# Stale-lock policy: if the holder's PID is dead OR expires_at is in the past,
# acquire steals the lock with a warning. This handles matrix crashes / SIGKILL
# without requiring manual cleanup.
#
# PID semantics: the lock records the holder's PID for liveness checks and
# for release authorization (release requires owner AND pid to match — a
# refused second instance's cleanup trap must never release the running
# holder's lock, KNOWN-GAPS #7). Sourced usage records $$. CLI usage records
# $PPID (the invoking shell) because the wrapper process dies immediately —
# recording its $$ produced an instantly-stale lock (KNOWN-GAPS #8). Either
# mode can override via PICO_LOCK_SELF_PID for long-lived supervisors that
# acquire on behalf of another process.
#
# Bead: local-coding-models-3p4 (the pico-exclusive-access study).
# Bead: dotfiles-afx (release pid check + CLI PPID, KNOWN-GAPS #7/#8).
# MEMORY: feedback-silent-success-pattern habit #3 (enforce in code, not docs).

PICO_LOCK_FILE="${PICO_LOCK_FILE:-/tmp/pico-busy.lock}"

# ---- helpers ----
_pico_lock_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_pico_lock_now_epoch() { date -u +%s; }

_pico_lock_self_pid() {
    # The PID this process acts as for acquire/release identity. Defaults to
    # $$; the CLI dispatcher (and any supervisor) overrides via
    # PICO_LOCK_SELF_PID — see "PID semantics" in the header.
    echo "${PICO_LOCK_SELF_PID:-$$}"
}

_pico_lock_parse_field() {
    # _pico_lock_parse_field <field> — extract a top-level string/number field
    # from the JSON lock file via python3 (stdlib, no jq dep).
    local field="$1"
    [[ -f "$PICO_LOCK_FILE" ]] || return 1
    python3 -c "
import json, sys
try:
    with open('$PICO_LOCK_FILE') as f:
        d = json.load(f)
    v = d.get('$field')
    print(v if v is not None else '')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

_pico_lock_holder_alive() {
    # Returns 0 if current lock holder's PID is alive, 1 if dead / lock empty.
    local pid
    pid=$(_pico_lock_parse_field pid)
    [[ -n "$pid" && "$pid" -gt 0 ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

_pico_lock_is_stale() {
    # Returns 0 if lock is stale (holder dead OR expired); 1 if still fresh.
    [[ -f "$PICO_LOCK_FILE" ]] || return 0  # no lock at all = "stale"
    if ! _pico_lock_holder_alive; then
        return 0
    fi
    local expires now
    expires=$(_pico_lock_parse_field expires_at_epoch)
    now=$(_pico_lock_now_epoch)
    if [[ -n "$expires" && "$now" -ge "$expires" ]]; then
        return 0
    fi
    return 1
}

# ---- pico_acquire OWNER DURATION_SECONDS [REASON...] ----
# Tries to claim pico exclusive use. Owner is a short string identifier
# (e.g. "bench-matrix-phase3"). Duration is the expected upper bound in
# seconds — the lock auto-expires after this so a crashed holder doesn't
# block forever. Returns 0 on success, 1 if held by someone else (fresh).
pico_acquire() {
    local owner="$1" duration="$2"
    shift 2
    local reason="${*:-no reason given}"
    local pid
    pid=$(_pico_lock_self_pid)
    local now_epoch now_iso expires_epoch expires_iso

    if [[ -z "$owner" || -z "$duration" ]]; then
        echo "pico_acquire: usage: pico_acquire OWNER DURATION_SECONDS [REASON...]" >&2
        return 2
    fi

    # If a lock exists and is fresh + held by someone else: refuse.
    # "Someone else" means a different PID — even same-owner-name from a
    # different PID is REFUSED, because two bench-matrix instances must NOT
    # silently overlap. (Same-owner-name-different-PID was a real bug found
    # during pico_lock.sh's own smoke test: would have orphaned a running
    # matrix when a second one started.)
    if [[ -f "$PICO_LOCK_FILE" ]] && ! _pico_lock_is_stale; then
        local hold_owner hold_pid hold_acquired hold_expires hold_reason
        hold_owner=$(_pico_lock_parse_field owner)
        hold_pid=$(_pico_lock_parse_field pid)
        hold_acquired=$(_pico_lock_parse_field acquired_at)
        hold_expires=$(_pico_lock_parse_field expires_at)
        hold_reason=$(_pico_lock_parse_field reason)
        if [[ "$hold_owner" == "$owner" && "$hold_pid" == "$pid" ]]; then
            # Same owner AND same PID = the same process refreshing its own lock.
            # Allow: fall through to overwrite with new expires_at / reason.
            echo "pico_acquire: refresh by current holder (owner=$owner, pid=$pid)" >&2
        else
            cat >&2 <<EOF
pico_acquire: REFUSED — pico is held by another consumer.
  current holder:  $hold_owner (pid $hold_pid)
  acquired at:     $hold_acquired
  expires at:      $hold_expires
  reason:          $hold_reason
  lock file:       $PICO_LOCK_FILE
  caller requested: owner=$owner pid=$pid duration=${duration}s reason=$reason
If the current holder is genuinely stuck, kill its pid and the lock will become stale.
EOF
            return 1
        fi
    fi

    # If lock is stale, note it before stealing.
    if [[ -f "$PICO_LOCK_FILE" ]] && _pico_lock_is_stale; then
        local stale_owner stale_pid
        stale_owner=$(_pico_lock_parse_field owner)
        stale_pid=$(_pico_lock_parse_field pid)
        echo "pico_acquire: stealing STALE lock from owner=$stale_owner pid=$stale_pid (holder dead or expired)" >&2
    fi

    # Write the new lock atomically.
    now_epoch=$(_pico_lock_now_epoch)
    now_iso=$(_pico_lock_now_iso)
    expires_epoch=$((now_epoch + duration))
    expires_iso=$(date -u -d "@$expires_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  python3 -c "import datetime; print(datetime.datetime.fromtimestamp($expires_epoch, tz=datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    python3 -c "
import json
d = {
  'owner': '''$owner''',
  'pid': $pid,
  'acquired_at': '''$now_iso''',
  'acquired_at_epoch': $now_epoch,
  'expires_at': '''$expires_iso''',
  'expires_at_epoch': $expires_epoch,
  'reason': '''$reason''',
}
with open('$PICO_LOCK_FILE.tmp', 'w') as f:
    json.dump(d, f, indent=2)
import os
os.rename('$PICO_LOCK_FILE.tmp', '$PICO_LOCK_FILE')
" 2>/dev/null || {
        echo "pico_acquire: ERROR — failed to write $PICO_LOCK_FILE" >&2
        return 2
    }
    echo "pico_acquire: OK — held by $owner (pid $pid), expires $expires_iso, reason=$reason"
    return 0
}

# ---- pico_release OWNER ----
# Drops the lock IFF the caller is the recorded owner AND the recorded PID.
# Owner name alone is not enough: acquire refuses same-owner-different-PID
# (two matrix instances must not overlap), so release must be symmetric —
# otherwise a refused second instance's cleanup trap releases the RUNNING
# holder's lock (KNOWN-GAPS #7). Stale locks are handled by the acquire-side
# steal path; genuinely manual cleanup is `rm -f $PICO_LOCK_FILE`.
pico_release() {
    local owner="$1"
    [[ -n "$owner" ]] || { echo "pico_release: usage: pico_release OWNER" >&2; return 2; }
    [[ -f "$PICO_LOCK_FILE" ]] || {
        echo "pico_release: no lock to release at $PICO_LOCK_FILE" >&2
        return 0
    }
    local hold_owner hold_pid self_pid
    hold_owner=$(_pico_lock_parse_field owner)
    hold_pid=$(_pico_lock_parse_field pid)
    self_pid=$(_pico_lock_self_pid)
    if [[ "$hold_owner" != "$owner" ]]; then
        echo "pico_release: REFUSED — caller ($owner) is not the current holder ($hold_owner)" >&2
        return 1
    fi
    if [[ "$hold_pid" != "$self_pid" ]]; then
        echo "pico_release: REFUSED — caller pid $self_pid is not the holder pid $hold_pid (owner=$owner). A second instance must not release the running holder's lock; if the holder is truly gone, the next pico_acquire steals the stale lock, or clean up manually: rm -f $PICO_LOCK_FILE" >&2
        return 1
    fi
    rm -f "$PICO_LOCK_FILE"
    echo "pico_release: OK — released by $owner"
    return 0
}

# ---- pico_check ----
# Reports current lock state without modifying it. Exit 0 if free, 1 if held.
pico_check() {
    if [[ ! -f "$PICO_LOCK_FILE" ]]; then
        echo "pico_check: FREE — no lock at $PICO_LOCK_FILE"
        return 0
    fi
    if _pico_lock_is_stale; then
        local stale_owner
        stale_owner=$(_pico_lock_parse_field owner)
        echo "pico_check: STALE — lock held by $stale_owner but holder dead/expired (next pico_acquire will steal)"
        return 0
    fi
    local hold_owner hold_pid hold_acquired hold_expires hold_reason
    hold_owner=$(_pico_lock_parse_field owner)
    hold_pid=$(_pico_lock_parse_field pid)
    hold_acquired=$(_pico_lock_parse_field acquired_at)
    hold_expires=$(_pico_lock_parse_field expires_at)
    hold_reason=$(_pico_lock_parse_field reason)
    cat <<EOF
pico_check: BUSY
  owner:         $hold_owner (pid $hold_pid)
  acquired at:   $hold_acquired
  expires at:    $hold_expires
  reason:        $hold_reason
  lock file:     $PICO_LOCK_FILE
EOF
    return 1
}

# ---- CLI if invoked directly (not sourced) ----
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # CLI mode: this wrapper process exits immediately, so recording its $$
    # would write an instantly-stale lock (KNOWN-GAPS #8). Act as the
    # invoking process ($PPID) instead, unless the caller already set
    # PICO_LOCK_SELF_PID explicitly.
    PICO_LOCK_SELF_PID="${PICO_LOCK_SELF_PID:-$PPID}"
    case "${1:-}" in
        acquire) shift; pico_acquire "$@" ;;
        release) shift; pico_release "$@" ;;
        check)   pico_check ;;
        *)
            cat <<EOF
usage: $0 {acquire OWNER DURATION_SEC [REASON...]|release OWNER|check}

  acquire bench-matrix-phase3 108000 'Phase 3 full matrix run'
  release bench-matrix-phase3
  check
EOF
            exit 2
            ;;
    esac
fi
