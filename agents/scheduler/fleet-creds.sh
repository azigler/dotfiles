#!/bin/bash
# fleet-creds.sh — fetch the fleet credentials from zig-computer, into MEMORY.
#
# Runs on marketing-vps. The credential half of the same self-service idea as
# ensure-fleet-tunnel.sh: the box reaches back over its own ssh link for what it
# needs, instead of being stranded waiting to be handed something.
#
# ---------------------------------------------------------------------------
# The gap this closes
# ---------------------------------------------------------------------------
# pulse-dispatch-remote.sh brokers FLEET_API_TOKEN (and friends) into the box's
# tmux environment for ONE run, then unsets them on teardown — deliberately: "the
# token must not outlive the tunnel." That is right for a dispatched tick.
#
# But an agent working on the box OUTSIDE a dispatch — Zig's own session, a
# follow-up after a tick ended — inherits a live tunnel and NO token. Every proxy
# call then returns 401, which looks like a broken proxy rather than a missing
# credential. Observed 2026-07-28: "Tunnel is up but the token isn't brokered,
# and Asana returns 401."
#
# ---------------------------------------------------------------------------
# Why this is not a new exposure
# ---------------------------------------------------------------------------
# The ssh key this uses already grants a shell on zig-computer as `ubuntu`, which
# can read ~/.secrets directly. Anything that can run this could already read the
# value. What this adds is convenience and DISCIPLINE, not access:
#   * the secret is never written to disk on the box — tmux env + the current
#     shell only, both memory;
#   * `status` and the default output report PRESENCE and LENGTH, never a value;
#   * `clear` exists so a session can drop them deliberately.
# It stays consistent with the standing rule: secrets live in ~/.secrets and are
# referenced by name, never pasted into notes, memory, or a repo.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   fleet-creds.sh status                 presence + length per var, no values
#   fleet-creds.sh ensure                 fetch -> tmux session env (new panes)
#   eval "$(fleet-creds.sh ensure --export)"    ALSO load into THIS shell
#   fleet-creds.sh clear                  unset from the tmux session env
#
# `--export` prints `export VAR=...` lines to stdout — that is the only way into
# an already-running shell, so it necessarily emits the value. Use it only inside
# `eval "$( ... )"`, never bare in a pane whose output gets transcribed.
#
# Exit: 0 ok · 1 could not reach zig-computer · 2 a var was missing upstream

set -uo pipefail

PEER=zig-computer
CMD=status
EXPORT=0
VARS=(FLEET_API_TOKEN SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD)

while [ $# -gt 0 ]; do
  case "$1" in
    status|ensure|clear) CMD=$1; shift ;;
    --export) EXPORT=1; shift ;;
    --host) PEER=$2; shift 2 ;;
    -h|--help) sed -n '36,44p' "$0"; exit 0 ;;
    *) echo "fleet-creds: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

say() { printf 'fleet-creds: %s\n' "$*" >&2; }   # stderr, so --export stdout stays pure

in_tmux() { [ -n "${TMUX:-}" ]; }
session()  { tmux display-message -p '#S' 2>/dev/null || echo work; }

report() {
  local name=$1 val=$2
  if [ -n "$val" ]; then say "  $name: PRESENT (len=${#val})"; else say "  $name: ABSENT"; fi
}

case "$CMD" in
  status)
    say "credential state (values are never printed):"
    for v in "${VARS[@]}"; do
      cur="${!v:-}"
      if [ -z "$cur" ] && in_tmux; then
        line=$(tmux show-environment -t "$(session)" "$v" 2>/dev/null | head -1)
        case "$line" in "$v="?*) cur="${line#*=}" ;; esac
      fi
      report "$v" "$cur"
    done
    exit 0
    ;;
  clear)
    if in_tmux; then
      for v in "${VARS[@]}"; do tmux setenv -u -t "$(session)" "$v" 2>/dev/null; done
      say "cleared from tmux session $(session). Already-running shells keep theirs until they exit."
    else
      say "not inside tmux — nothing to clear"
    fi
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# ensure
# ---------------------------------------------------------------------------
# One ssh round-trip; print each var as NAME<TAB>VALUE. Reading ~/.secrets and
# echoing only the four we want keeps the blast radius to those four.
say "fetching from $PEER (memory only, never written to disk here)"
FETCHED=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$PEER" \
  "set -a; . ~/.secrets 2>/dev/null; set +a; for v in ${VARS[*]}; do printf '%s\t%s\n' \"\$v\" \"\${!v:-}\"; done" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  say "FAILED to reach $PEER (rc=$RC):"
  printf '%s\n' "$FETCHED" | sed 's/^/    /' >&2
  say "  Check: ssh -o BatchMode=yes $PEER true"
  say "  If this says 'Connection refused', zig-computer's ufw may be rate-limiting ssh"
  say "  (the LIMIT rule REJECTs, and every retry refreshes the window — back off, do not hammer)."
  exit 1
fi

MISSING=0
while IFS=$'\t' read -r name value; do
  [ -z "$name" ] && continue
  if [ -z "$value" ]; then
    say "  $name: MISSING upstream — not set in $PEER:~/.secrets"
    MISSING=1
    continue
  fi
  in_tmux && tmux setenv -t "$(session)" "$name" "$value" 2>/dev/null
  [ "$EXPORT" = 1 ] && printf 'export %s=%q\n' "$name" "$value"
  say "  $name: loaded (len=${#value})"
done <<< "$FETCHED"

if in_tmux; then
  say "set in tmux session $(session) — NEW panes inherit it."
else
  say "not inside tmux — only --export can help a bare shell."
fi
[ "$EXPORT" = 1 ] || say 'to load into THIS shell:  eval "$('"$0"' ensure --export)"'

[ "$MISSING" = 1 ] && exit 2
exit 0
