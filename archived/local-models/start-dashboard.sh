#!/usr/bin/env bash
#
# start-dashboard.sh — nohup-wrapper for bench-dashboard.py.
#
# Starts the dashboard SPA in the background, redirecting stdout+stderr
# to /tmp/bench-dashboard.log. Survives shell exit. Idempotent-ish:
# does NOT auto-kill a previous instance — if a process is already
# bound to PORT the new one will exit with an error, which is the
# right behavior (operator inspects, then `pkill -f bench-dashboard.py`
# explicitly).
#
# Env / args:
#   PORT          (default 8765)
#   LOG           (default /tmp/bench-dashboard.log)
#   RESULTS_DIR   (passes through if set)
#   LOG_PATH      (passes through if set — fixes a specific driver-log)
#
# Spec: dotfiles-vgb §3 (Process management)
# Bead: dotfiles-vgb

set -euo pipefail

PORT="${PORT:-8765}"
LOG="${LOG:-/tmp/bench-dashboard.log}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD="$SCRIPT_DIR/bench-dashboard.py"

if [[ ! -f "$DASHBOARD" ]]; then
  echo "error: dashboard script not found at $DASHBOARD" >&2
  exit 1
fi

# Build optional flag passthroughs.
extra_args=()
if [[ -n "${RESULTS_DIR:-}" ]]; then
  extra_args+=(--results-dir "$RESULTS_DIR")
fi
if [[ -n "${LOG_PATH:-}" ]]; then
  extra_args+=(--log-path "$LOG_PATH")
fi

nohup python3 "$DASHBOARD" --port "$PORT" "${extra_args[@]}" \
  >> "$LOG" 2>&1 &
PID=$!
disown

echo "bench-dashboard started: PID=$PID port=$PORT log=$LOG"
echo "  tail with: tail -f $LOG"
echo "  stop with: kill $PID  (or pkill -f bench-dashboard.py)"
