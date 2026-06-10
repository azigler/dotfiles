#!/usr/bin/env bash
# safe_remote.sh — harness for verify-the-negation discipline.
#
# Source this from any script that needs to "make X stop on host H." Replaces
# raw `ssh H pkill ...` (which exits 0 whether or not processes are gone) with
# variants that VERIFY the processes are actually gone after the kill, and
# fail loudly if not.
#
# Bead: local-coding-models-u3y (the 7-orphan-ollama-runner case that
# motivated this). MEMORY: feedback-silent-success-pattern habit #1.
# Bead: dotfiles-afx (fail-CLOSED on transport failure, KNOWN-GAPS #1/#2).
#
# Usage:
#   source "/path/to/safe_remote.sh"
#   safe_pkill_remote pico "ollama"     # kills + verifies + retries once + fails if still alive
#   safe_pgrep_remote pico "mlx_lm"     # returns 0 if zero matches, 1 if matches
#
# Exit codes (both functions):
#   0 — verified: zero matching processes on the host
#   1 — survivors remain (pkill: even after one retry)
#   2 — VERIFY IMPOSSIBLE: ssh transport failure (host down, timeout,
#       tailnet drop). The host's state is UNKNOWN — never reported as
#       all-clear. Callers must treat 2 as a hard stop, not as "clean".
#
# Why a sourced lib instead of a CLI tool: bench-matrix.sh and friends invoke
# these in the middle of shell flow; sourcing keeps the calls inline + lets
# `set -e` propagate failures.

# Sentinel echoed by the remote side proving the command actually ran.
# Without it, a dead transport's empty output is indistinguishable from
# "zero matches" and the guard fails OPEN (KNOWN-GAPS #1/#2): we require
# BOTH ssh exit 0 AND the sentinel in the captured output before trusting
# an empty result.
SAFE_REMOTE_SENTINEL="__SAFE_REMOTE_RAN__"

# ---- safe_pgrep_remote HOST PATTERN ----
# Returns 0 if NO processes match (exclusive of pgrep itself + ssh wrapper).
# Returns 1 if any matches found; prints matches to stderr.
# Returns 2 if the host could not be verified (transport failure) — fail CLOSED.
safe_pgrep_remote() {
    local host="$1" pattern="$2"
    local raw rc matches
    raw=$(ssh -o ConnectTimeout=5 "$host" \
        "pgrep -af '$pattern' 2>/dev/null | grep -v 'grep' | head -20; echo $SAFE_REMOTE_SENTINEL" \
        2>/dev/null) && rc=0 || rc=$?
    if [[ $rc -ne 0 || "$raw" != *"$SAFE_REMOTE_SENTINEL"* ]]; then
        printf 'ERROR: safe_pgrep_remote(%s,%s): VERIFY IMPOSSIBLE — ssh transport failure (exit %s, sentinel %s). Host state is UNKNOWN; refusing to report all-clear.\n' \
            "$host" "$pattern" "$rc" \
            "$(if [[ "$raw" == *"$SAFE_REMOTE_SENTINEL"* ]]; then echo present; else echo missing; fi)" >&2
        return 2
    fi
    matches=$(printf '%s\n' "$raw" | grep -v "$SAFE_REMOTE_SENTINEL" || true)
    if [[ -z "$matches" ]]; then
        return 0
    else
        printf 'safe_pgrep_remote(%s,%s) found surviving matches:\n%s\n' "$host" "$pattern" "$matches" >&2
        return 1
    fi
}

# ---- _safe_remote_kill HOST PATTERN WAIT_SEC ----
# Internal: pkill + settle sleep on the host, with proof the command ran.
# Returns 0 if the remote command provably executed; 1 on transport failure
# (reported to stderr).
_safe_remote_kill() {
    local host="$1" pattern="$2" wait="$3"
    local raw rc
    raw=$(ssh -o ConnectTimeout=5 "$host" \
        "pkill -9 -f '$pattern' 2>/dev/null; sleep $wait; echo $SAFE_REMOTE_SENTINEL" \
        2>/dev/null) && rc=0 || rc=$?
    if [[ $rc -ne 0 || "$raw" != *"$SAFE_REMOTE_SENTINEL"* ]]; then
        printf 'ERROR: safe_pkill_remote(%s,%s): KILL UNVERIFIABLE — ssh transport failure (exit %s). Nothing was provably killed; failing CLOSED.\n' \
            "$host" "$pattern" "$rc" >&2
        return 1
    fi
    return 0
}

# ---- safe_pkill_remote HOST PATTERN [WAIT_SEC] ----
# pkill on host, verify absence, retry once if survivors, fail if still alive.
# WAIT_SEC defaults to 3 seconds between kill and verify.
# Returns 2 (fail CLOSED) if the kill or any verification cannot reach the host.
safe_pkill_remote() {
    local host="$1" pattern="$2" wait="${3:-3}"
    local prc

    if ! _safe_remote_kill "$host" "$pattern" "$wait"; then
        return 2
    fi
    prc=0
    safe_pgrep_remote "$host" "$pattern" || prc=$?
    case $prc in
        0) return 0 ;;
        2) return 2 ;;  # transport died between kill and verify — already reported
    esac
    # Retry once — kernel may have been mid-reap on first check.
    echo "safe_pkill_remote(${host},${pattern}): survivors found; retrying once..." >&2
    if ! _safe_remote_kill "$host" "$pattern" $((wait * 2)); then
        return 2
    fi
    prc=0
    safe_pgrep_remote "$host" "$pattern" || prc=$?
    case $prc in
        0) return 0 ;;
        2) return 2 ;;
    esac
    echo "ERROR: safe_pkill_remote(${host},${pattern}): FAILED to eliminate all matches after retry." >&2
    return 1
}
