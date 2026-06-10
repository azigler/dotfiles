#!/bin/bash
# healthcheck.sh — pre-flight health probe for the local-models stack
# (round 2 — CC-native serving; the CCR / llama-swap layers are GONE).
#
# Topology this checks (refs/eval-round-2-manifest.md in
# ~/explore/local-coding-models):
#   - pico reachable on the tailnet
#   - pico disk + memory headroom
#   - serving binaries present (/Users/pico/ollama-0.30.7/{ollama,llama-server})
#   - serving endpoints REPORTED ONLY (informational): bench-matrix.sh owns
#     the server lifecycle per cohort, so "nothing running" is a VALID
#     pre-flight state — a down endpoint here is not a failure.
#
# Exits 0 on healthy, 1 on warnings, 2 on critical (pico unreachable /
# disk-critical / binaries missing). bench-matrix.sh aborts on ANY
# non-zero exit, so warnings block a matrix launch too — by design
# (gates abort, never warn-and-continue).
#
# Companion: bench-matrix.sh, serving.conf, GUARDRAILS.md.
# Bead: dotfiles-6go

set -u

PICO_HOST="${PICO_HOST:-100.72.47.4}"
PICO_SSH_HOST="${PICO_SSH_HOST:-pico}"
OLLAMA_BIN="/Users/pico/ollama-0.30.7/ollama"
LLAMA_SERVER_BIN="/Users/pico/ollama-0.30.7/llama-server"
OLLAMA_URL="http://${PICO_HOST}:11434"
LLAMA_SERVER_URL="http://${PICO_HOST}:8082"

# Exit code accumulator
WARN=0
CRIT=0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; WARN=1; }
crit()   { printf '\033[31;1m%s\033[0m\n' "$*"; CRIT=1; }

# Quick HTTP probe with hard timeout; returns: 0=responsive, non-zero otherwise
probe_endpoint() {
    local url="$1" timeout="${2:-5}"
    local code
    code=$(curl -sS --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || return 2
    [[ "$code" == "200" || "$code" == "404" ]] && return 0
    return 1
}

echo "=== local-models healthcheck (round 2) — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo

# ---- 1. Pico reachability ----
if ping -c 1 -W 2 "$PICO_HOST" >/dev/null 2>&1; then
    green "✓ pico reachable ($PICO_HOST)"
else
    crit "✗ PICO UNREACHABLE — tailnet / network down — skipping all pico checks"
    exit 2
fi

# ---- 2. Serving binaries (official tarball — the brew bottle is BROKEN:
#         it ships no llama-server runner; verified 2026-06-10) ----
for bin in "$OLLAMA_BIN" "$LLAMA_SERVER_BIN"; do
    if ssh -o ConnectTimeout=5 "$PICO_SSH_HOST" "test -x '$bin'" 2>/dev/null; then
        green "✓ serving binary present: $bin"
    else
        crit "✗ serving binary MISSING/non-executable on pico: $bin (re-install the official ollama tarball)"
    fi
done

# ---- 3. Pico disk ----
disk_pct=$(ssh -o ConnectTimeout=5 "$PICO_SSH_HOST" 'df -h ~ | tail -1 | awk "{print \$5}" | tr -d %' 2>/dev/null)
if [[ -n "$disk_pct" ]]; then
    if [[ "$disk_pct" -gt 90 ]]; then
        crit "✗ pico disk ${disk_pct}% full — CRITICAL, clean up before any model work"
    elif [[ "$disk_pct" -gt 80 ]]; then
        red "⚠ pico disk ${disk_pct}% full — clean up before next download"
    else
        green "✓ pico disk ${disk_pct}% used"
    fi
else
    red "⚠ could not read pico disk usage over ssh"
fi

# ---- 4. Serving-process inventory (INFORMATIONAL) ----
# bench-matrix.sh owns server lifecycle: it evicts everything pre-flight and
# launches per cohort. Residents here are not an error for a standalone
# healthcheck run, but the count is worth eyeballing (u3y orphan lesson —
# bench-matrix's own orphan audit is the blocking version of this check).
resident=$(ssh -o ConnectTimeout=5 "$PICO_SSH_HOST" "pgrep -af 'ollama|llama-server' 2>/dev/null | grep -v pgrep | head -10" 2>/dev/null)
if [[ -n "$resident" ]]; then
    yellow "○ serving processes currently resident on pico (bench-matrix evicts these pre-flight):"
    while IFS= read -r proc_line; do printf '    %s\n' "$proc_line"; done <<< "$resident"
else
    green "✓ no serving processes resident on pico (clean slate)"
fi

# ---- 5. Serving endpoints (INFORMATIONAL — lifecycle belongs to bench-matrix) ----
if probe_endpoint "$OLLAMA_URL/api/tags" 5; then
    yellow "○ Ollama :11434 responding (will be evicted/relaunched by bench-matrix as needed)"
else
    green "✓ Ollama :11434 not serving (valid pre-flight state)"
fi
if probe_endpoint "$LLAMA_SERVER_URL/v1/models" 5; then
    yellow "○ llama-server :8082 responding (will be evicted/relaunched by bench-matrix as needed)"
else
    green "✓ llama-server :8082 not serving (valid pre-flight state)"
fi

echo
if [[ "$CRIT" -eq 1 ]]; then
    crit "RESULT: CRITICAL issues — fix before continuing local-model work"
    exit 2
elif [[ "$WARN" -eq 1 ]]; then
    yellow "RESULT: warnings (bench-matrix treats any non-zero exit as blocking)"
    exit 1
else
    green "RESULT: healthy"
    exit 0
fi
