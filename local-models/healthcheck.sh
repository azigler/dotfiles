#!/bin/bash
# healthcheck.sh — pre-flight health probe for the local-models stack.
#
# Run at iter-start and after any failed completion. Catches hung processes,
# memory bloat, disk pressure, network issues, backend connectivity gaps.
#
# Exits 0 on healthy, 1 on warnings, 2 on critical (hung server / OOM-risk).
#
# Companion: trinity_shim.py, qwen_sampler.py, GUARDRAILS.md.

set -u

PICO_HOST="${PICO_HOST:-100.72.47.4}"
MLX_URL="http://${PICO_HOST}:8081"
OLLAMA_URL="http://${PICO_HOST}:11434"
LLAMASWAP_URL="http://${PICO_HOST}:8090"
CCR_URL="http://127.0.0.1:3456"

# Exit code accumulator
WARN=0
CRIT=0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; WARN=1; }
crit()   { printf '\033[31;1m%s\033[0m\n' "$*"; CRIT=1; }

# Quick HTTP probe with hard timeout; returns: 0=responsive, 1=connect-fail, 2=hung (timeout)
probe_endpoint() {
    local url="$1" timeout="${2:-5}"
    local code
    code=$(curl -sS --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || return 2
    [[ "$code" == "200" || "$code" == "404" ]] && return 0
    return 1
}

# Check whether a small completion request actually returns content (catches hang-after-handshake)
probe_completion() {
    local url="$1" model="$2" timeout="${3:-15}"
    local response
    response=$(curl -sS --max-time "$timeout" -X POST "$url/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"PONG?\"}],\"max_tokens\":10,\"temperature\":0,\"stream\":false}" 2>&1)
    [[ -z "$response" ]] && return 2
    echo "$response" | grep -q 'content' && return 0
    return 1
}

echo "=== local-models healthcheck — $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo

# ---- 1. Pico reachability ----
if ping -c 1 -W 2 "$PICO_HOST" >/dev/null 2>&1; then
    green "✓ pico reachable ($PICO_HOST)"
else
    crit "✗ PICO UNREACHABLE — tailnet / network down — skipping all pico checks"
    exit 2
fi

# ---- 2. MLX server (8081) ----
if probe_endpoint "$MLX_URL/v1/models" 5; then
    green "✓ MLX server :8081 responding (/v1/models)"
else
    crit "✗ MLX server :8081 not responding — try: ssh pico 'launchctl kickstart -k gui/501/com.zig.mlx'"
fi

# Check MLX process state
mlx_state=$(ssh -o ConnectTimeout=5 pico 'pid=$(pgrep -f mlx_lm.server | head -1); [[ -n "$pid" ]] && ps -o rss,etime -p $pid 2>/dev/null | tail -1' 2>/dev/null)
if [[ -n "$mlx_state" ]]; then
    rss_kb=$(echo "$mlx_state" | awk '{print $1}')
    etime=$(echo "$mlx_state" | awk '{print $2}')
    rss_gb=$((rss_kb / 1024 / 1024))
    if [[ "$rss_gb" -gt 30 ]]; then
        red "⚠ MLX RSS ${rss_gb} GB (>30) — possible model accumulation; consider kickstart if no active jobs"
    else
        green "✓ MLX RSS ${rss_gb} GB, uptime $etime"
    fi
fi

# ---- 3. Ollama server (11434) ----
if probe_endpoint "$OLLAMA_URL/api/tags" 5; then
    green "✓ Ollama server :11434 responding (/api/tags)"
else
    crit "✗ Ollama server :11434 not responding — try: ssh pico '/opt/homebrew/opt/ollama/bin/ollama serve'"
fi

# ---- 4. llama-swap (8090) — optional ----
if probe_endpoint "$LLAMASWAP_URL/v1/models" 5 2>/dev/null; then
    green "✓ llama-swap :8090 responding"
else
    yellow "○ llama-swap :8090 not running (optional; start with /tmp/llama-swap-start.sh on pico)"
fi

# ---- 5. CCR (local 3456) — optional ----
if probe_endpoint "$CCR_URL/v1/models" 3 2>/dev/null; then
    green "✓ CCR :3456 responding"
else
    yellow "○ CCR :3456 not running (optional; start with 'ccr start')"
fi

# ---- 6. Functional completion probe (catches hang-after-handshake) ----
# Use the smallest fastest model that's likely already warm — qwen3-coder via Ollama (Ollama keeps it warm 24h)
if probe_completion "$OLLAMA_URL" "qwen3-coder:30b" 30; then
    green "✓ Qwen3 Ollama completion roundtrip OK (proves stack actually serves, not just handshakes)"
else
    crit "✗ Qwen3 Ollama completion hung or failed — stack may be wedged even if handshake works"
fi

# ---- 7. Pico disk ----
disk_pct=$(ssh -o ConnectTimeout=5 pico 'df -h ~ | tail -1 | awk "{print \$5}" | tr -d %' 2>/dev/null)
if [[ -n "$disk_pct" ]]; then
    if [[ "$disk_pct" -gt 80 ]]; then
        red "⚠ pico disk ${disk_pct}% full — clean up before next download"
    else
        green "✓ pico disk ${disk_pct}% used"
    fi
fi

echo
if [[ "$CRIT" -eq 1 ]]; then
    crit "RESULT: CRITICAL issues — fix before continuing local-model work"
    exit 2
elif [[ "$WARN" -eq 1 ]]; then
    yellow "RESULT: warnings (non-blocking, but worth attention)"
    exit 1
else
    green "RESULT: healthy"
    exit 0
fi
