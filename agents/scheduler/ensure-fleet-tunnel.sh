#!/bin/bash
# ensure-fleet-tunnel.sh — make http://127.0.0.1:<port> answer ON THIS BOX.
#
# Runs on marketing-vps (or any box that can ssh to zig-computer). It is the
# self-heal half of the dispatch tunnel.
#
# It is NOT fleet-proxy-specific. The forward target, the probe path and the
# healthy status code are all flags; the defaults are the fleet proxy
# (`127.0.0.1:$PORT`, `/api/health`, `200`) so the original invocation is
# unchanged. The second live user is pico's agentgateway, whose healthy
# signature is `--target 100.72.47.4:17017 --probe-path /claude/v1/models
# --expect 401` — 401 IS health there (transparent passthrough to
# api.anthropic.com with no key attached). Do not "fix" it to 200.
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
#     answers the probe path with the expected code it does nothing at all — a
#     reverse tunnel from an in-flight dispatch is the normal case, and binding
#     over it would break the very thing it is meant to protect.
#   * It only ever kills a listener IT started (tracked by pidfile). Killing "the
#     process on port 7100" on a shared box is how you murder another run's
#     dispatch.
#   * Three-valued probe, same contract as /vps: <expected> up / 000 no tunnel /
#     anything else = BLOCKED, which is a real answer and must not be retried
#     into a false "healed".
#   * Loud. Every failure path prints why, and stderr is never suppressed.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   ensure-fleet-tunnel.sh [ensure|status|down] [--port N] [--host NAME]
#                          [--target HOST:PORT] [--probe-path PATH]
#                          [--expect CODE]
#
#   ensure   (default) probe; if down, open a local forward and re-probe.
#   status   probe only, change nothing. Exit 0 up / 1 down / 2 blocked.
#   down     tear down ONLY a forward this script started.
#
#   --port N            local port to bind on THIS box          (default 7100)
#   --host NAME         ssh peer that does the forwarding       (default zig-computer)
#   --target HOST:PORT  what the peer forwards TO, resolved on
#                       the FAR end                             (default 127.0.0.1:<port>)
#   --probe-path PATH   health path on the local port           (default /api/health)
#   --expect CODE       HTTP code that means healthy            (default 200)
#
#   `--target`/`--port` together identify a tunnel: they select the pidfile AND
#   the pgrep pattern. Pass the SAME flags to `down` that you passed to `ensure`,
#   or `down` will (correctly) report it owns nothing.
#
#   Examples:
#     ensure-fleet-tunnel.sh ensure                      # the fleet proxy
#     ensure-fleet-tunnel.sh ensure --port 17017 \
#         --target 100.72.47.4:17017 \
#         --probe-path /claude/v1/models --expect 401    # pico's agentgateway
#
# Exit: 0 healthy · 1 could not heal · 2 upstream answered with an unexpected
#       code (blocked)

set -uo pipefail

PORT=7100
PEER=zig-computer
CMD=ensure
TARGET=""
PROBE_PATH=""
EXPECT=""
# "was the flag given at all?" — distinct from "is the value empty?". A systemd
# unit with an unset variable expands to `--expect ""`, and silently falling back
# to the fleet-proxy default would give a GATEWAY tunnel fleet-proxy semantics.
# It would fail safe (read BLOCKED) — but silently, which is the wrong shape.
TARGET_SET=0
PROBE_PATH_SET=0
EXPECT_SET=0
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-tunnel"

# Print the Usage block above verbatim. Range-matched on CONTENT, never on line
# numbers: the previous `sed -n '43,52p'` silently printed the wrong ten lines
# the moment anything above it grew — and adding these very flags grew it.
usage() { sed -n '/^# Usage$/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    ensure|status|down) CMD=$1; shift ;;
    --port) PORT=$2; shift 2 ;;
    --host) PEER=$2; shift 2 ;;
    --target) TARGET=$2; TARGET_SET=1; shift 2 ;;
    --probe-path) PROBE_PATH=$2; PROBE_PATH_SET=1; shift 2 ;;
    --expect) EXPECT=$2; EXPECT_SET=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ensure-fleet-tunnel: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

# An EXPLICIT empty value is an error, never a silent default. Omitting the flag
# is the only way to ask for the default.
require_value() { # <flag> <was-it-given> <value>
  if [ "$2" -eq 1 ] && [ -z "$3" ]; then
    echo "ensure-fleet-tunnel: $1 was given an EMPTY value. Omit the flag to get the default; an unset variable in a systemd unit must not silently become one." >&2
    exit 64
  fi
}
[ -n "$PORT" ] || { echo "ensure-fleet-tunnel: --port must not be empty" >&2; exit 64; }
require_value --target "$TARGET_SET" "$TARGET"
require_value --probe-path "$PROBE_PATH_SET" "$PROBE_PATH"
require_value --expect "$EXPECT_SET" "$EXPECT"

# Defaults are resolved AFTER parsing so `--target` may precede or follow
# `--port` — the fleet-proxy default is "same port on the far end's loopback".
[ -n "$TARGET" ]     || TARGET="127.0.0.1:$PORT"
[ -n "$PROBE_PATH" ] || PROBE_PATH="/api/health"
[ -n "$EXPECT" ]     || EXPECT="200"

# Validate loudly. A malformed target silently produces a pgrep pattern that
# matches nothing (ownership lost) or, worse, matches too much.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

is_num "$PORT" || { echo "ensure-fleet-tunnel: --port must be numeric, got '$PORT'" >&2; exit 64; }
TARGET_HOST=""; TARGET_PORT=""
case "$TARGET" in *:*) TARGET_HOST=${TARGET%:*}; TARGET_PORT=${TARGET##*:} ;; esac
if [ -z "$TARGET_HOST" ] || ! is_num "$TARGET_PORT" \
   || [ "$TARGET_HOST" != "${TARGET_HOST%%:*}" ]; then
  echo "ensure-fleet-tunnel: --target must be HOST:PORT (one colon, numeric port), got '$TARGET'" >&2
  exit 64
fi
case "$PROBE_PATH" in
  /*) ;;
  *) echo "ensure-fleet-tunnel: --probe-path must start with '/', got '$PROBE_PATH'" >&2; exit 64 ;;
esac
case "$EXPECT" in
  [0-9][0-9][0-9]) ;;
  *) echo "ensure-fleet-tunnel: --expect must be a 3-digit HTTP code, got '$EXPECT'" >&2; exit 64 ;;
esac
# 000 is the script's own sentinel for "nothing is listening". Accepting it as
# the healthy code would collapse the three-valued contract into two values and
# make "stranded" indistinguishable from "up".
if [ "$EXPECT" = "000" ]; then
  echo "ensure-fleet-tunnel: --expect 000 is meaningless — 000 means nothing is listening" >&2
  exit 64
fi

# One pidfile PER TUNNEL. A single shared pidfile is the same defect as a
# target-blind pgrep pattern: the gateway tunnel would write its pid where the
# fleet tunnel reads it, and `down` would kill a forward it does not own. Old
# state written by the pre-flag version lands under the old name and is simply
# never read — `our_pid`'s pgrep re-adoption recovers ownership on first run.
TUNNEL_SLUG=$(printf '%s' "$PORT-$TARGET" | tr -c 'A-Za-z0-9._-' '_')
PIDFILE="$STATE_DIR/local-forward-$TUNNEL_SLUG.pid"

mkdir -p "$STATE_DIR"
say()  { printf 'fleet-tunnel: %s\n' "$*"; }
warn() { printf 'fleet-tunnel: %s\n' "$*" >&2; }

# Three-valued probe. Prints exactly one code; caller interprets.
#
# NOT `curl ... || echo 000`: on a refused connection curl BOTH prints "000" and
# exits nonzero, so the fallback fires too and the caller sees "000\n000" — which
# matches neither the expected code nor 000 and lands in the `*` branch,
# reporting a healthy-but-blocked upstream when in fact nothing is listening.
# Caught on the first live run. Capture, then substitute only when the output is
# genuinely empty.
probe() {
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$PORT$PROBE_PATH" 2>/dev/null)
  printf '%s' "${code:-000}"
}

# Escape a literal for use inside FORWARD_PAT (an ERE handed to pgrep -f). The
# target is usually an IP, and an unescaped `.` there is a wildcard.
#
# Done in bash rather than with a sed bracket expression on purpose: `[][.^$…]`
# reads `[.` as the start of a POSIX COLLATING SYMBOL, so the obvious one-liner
# dies with `unterminated 's' command` — and had it merely mis-escaped instead of
# erroring, FORWARD_PAT would have gone quietly wrong. Only true ERE
# metacharacters are escaped; `:` and `-` are left alone (a `\:` is undefined in
# ERE, so escaping "everything non-alphanumeric" is not the safer choice).
re_escape() {
  local s=$1 out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      \\|'.'|'['|']'|'^'|'$'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

# The distinctive command line of a forward THIS script opened. A reverse tunnel
# from zig-computer appears on this box as an `sshd` process, never as a local
# `ssh -L`, so this pattern cannot match someone else's dispatch.
#
# ⚠️ THE TARGET IS IN THE PATTERN ON PURPOSE, and it is the single most important
# correctness property in this script. This box runs more than one of these at
# once (the fleet proxy on 7100 and pico's agentgateway on 17017). A pattern that
# stopped at the local port would match the OTHER tunnel's `ssh -L`, and then
# `our_pid` — and therefore `tunnel_down` and the recycle path — would kill a
# forward this invocation does not own, on a shared box, mid-dispatch. Same
# reason $PIDFILE is per-tunnel above. test-ensure-fleet-tunnel.sh's
# "two concurrent tunnels" cases exist to keep this true.
FORWARD_PAT="ssh .*-L 127\.0\.0\.1:$PORT:$(re_escape "$TARGET") $(re_escape "$PEER")\$"

# Is a forward of ours alive? Prefer the pidfile; fall back to DISCOVERY.
#
# The fallback matters: the pidfile is only written at creation, so any path that
# clears or misses it (a `down` that found nothing to kill still rm'd the file,
# an `ensure` that short-circuited on an already-up port) orphaned a forward we
# genuinely own — after which `down` reported "none of ours" about our own
# process. Discovery makes ownership recoverable instead of write-once.
our_pid() {
  local p
  if [ -f "$PIDFILE" ]; then
    p=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then printf '%s' "$p"; return 0; fi
  fi
  p=$(pgrep -n -f "$FORWARD_PAT" 2>/dev/null)
  if [ -n "$p" ]; then
    printf '%s\n' "$p" > "$PIDFILE"      # re-adopt
    printf '%s' "$p"; return 0
  fi
  return 1
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
    if [ "$code" = "$EXPECT" ]; then
      say "up ($code)"; exit 0
    elif [ "$code" = "000" ]; then
      say "DOWN (000 — nothing listening on 127.0.0.1:$PORT)"; exit 1
    else
      warn "BLOCKED ($code) — something answered $PROBE_PATH but not $EXPECT. This is NOT 'no data'; do not treat it as an empty result."
      exit 2
    fi
    ;;
  down)
    tunnel_down; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# ensure
# ---------------------------------------------------------------------------
code=$(probe)
if [ "$code" = "$EXPECT" ]; then
  say "already up ($code) — nothing to do"; exit 0
elif [ "$code" = "000" ]; then
  say "down (000) — opening a local forward to $PEER -> $TARGET"
else
  warn "BLOCKED ($code) — the port answers $PROBE_PATH but not $EXPECT. Reopening the tunnel will NOT fix an upstream fault; refusing to churn the socket."
  exit 2
fi

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
      -L "127.0.0.1:$PORT:$TARGET" "$PEER" 2>&1; then
  warn "FAILED to open the local forward to $PEER ($TARGET)."
  warn "  Check: ssh -o BatchMode=yes $PEER true    (key + Host block in ~/.ssh/local)"
  warn "  Check: is 127.0.0.1:$PORT already bound by another run? ss -tlnH 'sport = :$PORT'"
  exit 1
fi

# Record the pid so `down` and the recycle path above only ever touch ours.
NEWPID=$(pgrep -n -f "$FORWARD_PAT" 2>/dev/null || true)
[ -n "$NEWPID" ] && printf '%s\n' "$NEWPID" > "$PIDFILE"

# Re-probe. Opening a socket is not the same as the proxy answering — the whole
# point of this harness is to never confuse "I did a thing" with "it works".
for _ in 1 2 3 4 5; do
  code=$(probe); [ "$code" = "$EXPECT" ] && break; sleep 1
done

if [ "$code" = "$EXPECT" ]; then
  say "HEALED — 127.0.0.1:$PORT$PROBE_PATH now answers $code (local forward to $PEER -> $TARGET, pid ${NEWPID:-?})"
  exit 0
elif [ "$code" = "000" ]; then
  warn "forward opened but 127.0.0.1:$PORT still silent — is $TARGET actually serving ON $PEER? (fleet proxy: systemctl --user status lb-fleet)"
  exit 1
else
  warn "forward opened but upstream returns $code, expected $EXPECT — it is up and refusing. NOT 'no data'."
  exit 2
fi
