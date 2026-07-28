#!/bin/bash
# ensure-fleet-tunnel.sh — make http://127.0.0.1:<port> answer ON THIS BOX.
#
# Runs on marketing-vps (or any box that can ssh to zig-computer). It is the
# self-heal half of the dispatch tunnel.
#
# ---------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------
# The dispatch tunnel is opened by zig-computer as a REVERSE forward
# (`ssh -R 7100:127.0.0.1:7100 marketing-vps`). That works, but it is
# one-directional in a way that matters: only zig-computer can open it. If the
# ssh master dies mid-tick — network blip, laptop sleep, a killed run — the box
# is STRANDED. Every Asana/Slack/gdoc call starts returning 000, the tick has no
# way to reopen the forward, and (per /vps) a 000 must never be read as "no
# data". Zig, 2026-07-28: "if the tunnel closes like it is now then the other
# machine doesn't have an ability to reopen it."
#
# With an ssh key from this box to zig-computer, the box can open the SAME path
# itself as a LOCAL forward (`ssh -L 7100:127.0.0.1:7100 zig-computer`). From
# this side the two are indistinguishable: 127.0.0.1:7100 reaches zig-computer's
# fleet proxy either way. The difference is who can initiate — and that is the
# whole point.
#
# ---------------------------------------------------------------------------
# The rules it follows
# ---------------------------------------------------------------------------
#   * IDEMPOTENT, and it never fights a healthy tunnel. If the port already
#     answers /api/health it does nothing at all — a reverse tunnel from an
#     in-flight dispatch is the normal case, and binding over it would break the
#     very thing it is meant to protect.
#   * It only ever kills a listener IT started (tracked by pidfile). Killing "the
#     process on port 7100" on a shared box is how you murder another run's
#     dispatch.
#   * Three-valued probe, same contract as /vps: 200 up / 000 no tunnel /
#     anything else = BLOCKED, which is a real answer and must not be retried
#     into a false "healed".
#   * Loud. Every failure path prints why, and stderr is never suppressed.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   ensure-fleet-tunnel.sh [ensure|status|down] [--port N] [--host NAME]
#
#   ensure   (default) probe; if down, open a local forward and re-probe.
#   status   probe only, change nothing. Exit 0 up / 1 down / 2 blocked.
#   down     tear down ONLY a forward this script started.
#
# Exit: 0 healthy · 1 could not heal · 2 upstream answered but not 200 (blocked)

set -uo pipefail

PORT=7100
PEER=zig-computer
CMD=ensure
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-tunnel"
PIDFILE="$STATE_DIR/local-forward.pid"

while [ $# -gt 0 ]; do
  case "$1" in
    ensure|status|down) CMD=$1; shift ;;
    --port) PORT=$2; shift 2 ;;
    --host) PEER=$2; shift 2 ;;
    -h|--help) sed -n '43,52p' "$0"; exit 0 ;;
    *) echo "ensure-fleet-tunnel: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

mkdir -p "$STATE_DIR"
say()  { printf 'fleet-tunnel: %s\n' "$*"; }
warn() { printf 'fleet-tunnel: %s\n' "$*" >&2; }

# Three-valued probe. Prints exactly one code; caller interprets.
#
# NOT `curl ... || echo 000`: on a refused connection curl BOTH prints "000" and
# exits nonzero, so the fallback fires too and the caller sees "000\n000" — which
# matches neither 200 nor 000 and lands in the `*` branch, reporting a healthy-
# but-blocked upstream when in fact nothing is listening. Caught on the first
# live run. Capture, then substitute only when the output is genuinely empty.
probe() {
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$PORT/api/health" 2>/dev/null)
  printf '%s' "${code:-000}"
}

# Is the forward we started still alive?
our_pid() {
  [ -f "$PIDFILE" ] || return 1
  local p; p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
  printf '%s' "$p"
}

tunnel_down() {
  local p
  if p=$(our_pid); then
    kill "$p" 2>/dev/null && say "closed our local forward (pid $p)"
  else
    say "no local forward of ours to close"
  fi
  rm -f "$PIDFILE"
}

case "$CMD" in
  status)
    code=$(probe)
    case "$code" in
      200) say "up (200)"; exit 0 ;;
      000) say "DOWN (000 — nothing listening on 127.0.0.1:$PORT)"; exit 1 ;;
      *)   warn "BLOCKED ($code) — something answered but not 200. This is NOT 'no data'; do not treat it as an empty result."; exit 2 ;;
    esac
    ;;
  down)
    tunnel_down; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# ensure
# ---------------------------------------------------------------------------
code=$(probe)
case "$code" in
  200) say "already up (200) — nothing to do"; exit 0 ;;
  000) say "down (000) — opening a local forward to $PEER" ;;
  *)   warn "BLOCKED ($code) — the port answers but not 200. Reopening the tunnel will NOT fix an upstream fault; refusing to churn the socket."; exit 2 ;;
esac

# A dead-but-bound listener of OURS would make ExitOnForwardFailure refuse the
# new forward. Clear only our own; never touch a stranger's.
if our_pid >/dev/null; then
  say "our previous forward is alive but the port does not answer — recycling it"
  tunnel_down
  sleep 1
fi

# ExitOnForwardFailure=yes is load-bearing for the same reason as in
# pulse-dispatch-remote.sh: without it ssh exits 0 when the bind fails, leaving a
# connection that forwards nothing while looking healthy.
if ! ssh -f -N \
      -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=accept-new \
      -L "127.0.0.1:$PORT:127.0.0.1:$PORT" "$PEER" 2>&1; then
  warn "FAILED to open the local forward to $PEER."
  warn "  Check: ssh -o BatchMode=yes $PEER true    (key + Host block in ~/.ssh/local)"
  warn "  Check: is 127.0.0.1:$PORT already bound by another run? ss -tlnH 'sport = :$PORT'"
  exit 1
fi

# Record the pid so `down` and the recycle path above only ever touch ours.
NEWPID=$(pgrep -n -f "ssh.*-L 127.0.0.1:$PORT:127.0.0.1:$PORT.*$PEER" || true)
[ -n "$NEWPID" ] && printf '%s\n' "$NEWPID" > "$PIDFILE"

# Re-probe. Opening a socket is not the same as the proxy answering — the whole
# point of this harness is to never confuse "I did a thing" with "it works".
for _ in 1 2 3 4 5; do
  code=$(probe); [ "$code" = "200" ] && break; sleep 1
done

case "$code" in
  200) say "HEALED — 127.0.0.1:$PORT now answers 200 (local forward to $PEER, pid ${NEWPID:-?})"; exit 0 ;;
  000) warn "forward opened but 127.0.0.1:$PORT still silent — is the fleet proxy running ON $PEER? (systemctl --user status lb-fleet)"; exit 1 ;;
  *)   warn "forward opened but upstream returns $code — proxy is up and refusing. NOT 'no data'."; exit 2 ;;
esac
