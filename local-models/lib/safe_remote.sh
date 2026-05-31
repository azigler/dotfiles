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
#
# Usage:
#   source "/path/to/safe_remote.sh"
#   safe_pkill_remote pico "ollama"     # kills + verifies + retries once + fails if still alive
#   safe_pgrep_remote pico "mlx_lm"     # returns 0 if zero matches, 1 if matches
#
# Why a sourced lib instead of a CLI tool: bench-matrix.sh and friends invoke
# these in the middle of shell flow; sourcing keeps the calls inline + lets
# `set -e` propagate failures.

# ---- safe_pgrep_remote HOST PATTERN ----
# Returns 0 if NO processes match (exclusive of pgrep itself + ssh wrapper).
# Returns 1 if any matches found; prints matches to stderr.
safe_pgrep_remote() {
    local host="$1" pattern="$2"
    local matches
    matches=$(ssh -o ConnectTimeout=5 "$host" "pgrep -af '$pattern' 2>/dev/null | grep -v 'grep' | head -20" 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        return 0
    else
        printf 'safe_pgrep_remote(%s,%s) found surviving matches:\n%s\n' "$host" "$pattern" "$matches" >&2
        return 1
    fi
}

# ---- safe_pkill_remote HOST PATTERN [WAIT_SEC] ----
# pkill on host, verify absence, retry once if survivors, fail if still alive.
# WAIT_SEC defaults to 3 seconds between kill and verify.
safe_pkill_remote() {
    local host="$1" pattern="$2" wait="${3:-3}"
    ssh -o ConnectTimeout=5 "$host" "pkill -9 -f '$pattern' 2>/dev/null; sleep $wait" 2>/dev/null || true
    if safe_pgrep_remote "$host" "$pattern"; then
        return 0
    fi
    # Retry once — kernel may have been mid-reap on first check.
    echo "safe_pkill_remote(${host},${pattern}): survivors found; retrying once..." >&2
    ssh -o ConnectTimeout=5 "$host" "pkill -9 -f '$pattern' 2>/dev/null; sleep $((wait * 2))" 2>/dev/null || true
    if safe_pgrep_remote "$host" "$pattern"; then
        return 0
    fi
    echo "ERROR: safe_pkill_remote(${host},${pattern}): FAILED to eliminate all matches after retry." >&2
    return 1
}
