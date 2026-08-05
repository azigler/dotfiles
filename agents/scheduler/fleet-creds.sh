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
# The brokered tmux env is a FIRST-CLASS source, not a courtesy to new panes
# ---------------------------------------------------------------------------
# `tmux setenv` populates the SESSION environment, which a shell samples once at
# startup. A pulse tick is delivered by `send-keys` into a pane whose shell is
# ALREADY RUNNING — so a dispatched tick never sees a single brokered var. It is a
# silent no-op for all four. Measured 2026-08-04 on marketing-vps:
#
#     running pane's shell : EMPTY
#     tmux session env     : probe_value_12345
#     NEWLY created pane   : probe_value_12345
#
# Ticks worked at all only because this script ssh-fetched FLEET_API_TOKEN from
# zig-computer:~/.secrets — which holds that one and NOT SLACK_BOT_TOKEN,
# SLACK_NEWS_PLANNING_CHANNEL_ID, or SITE_PASSWORD (those live in the project's
# .env.local and stay there; splitting them across two homes is the two-copies
# defect). Hence di-wednesday's research 401s and every failed Slack notice.
#
# So `ensure` reads the brokered session env FIRST and ssh-fetches only what is
# still missing. When everything resolves locally there is NO ssh round-trip at
# all — which also keeps ticks off zig-computer's ufw ssh rate limit. Every var is
# reported with the source it came from, because "where did this come from" is
# exactly what was unanswerable on the morning this broke.
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
#   fleet-creds.sh ensure                 brokered tmux env first, ssh for the rest
#   eval "$(fleet-creds.sh ensure --export)"    ALSO load into THIS shell
#   fleet-creds.sh clear                  unset from the tmux session env
#
# `--export` prints `export VAR=...` lines to stdout — that is the only way into
# an already-running shell, so it necessarily emits the value. Use it only inside
# `eval "$( ... )"`, never bare in a pane whose output gets transcribed. Since a
# send-keys-delivered tick ALWAYS has an already-running shell, `--export` is the
# form a tick wants, even for vars the dispatcher already brokered.
#
# Exit: 0 ok · 1 could not reach zig-computer · 2 a var was missing upstream
#       (missing EVERYWHERE — brokered env and zig-computer both)

set -uo pipefail

# A function, not `sed -n '<line>,<line>p' "$0"` — the old form hardcoded line
# numbers into the header and silently printed the wrong paragraph the moment the
# comment block above it grew.
usage() {
  cat <<'USAGE'
fleet-creds.sh status                 presence + length per var, no values
fleet-creds.sh ensure                 brokered tmux env first, ssh for the rest
eval "$(fleet-creds.sh ensure --export)"    ALSO load into THIS shell
fleet-creds.sh clear                  unset from the tmux session env

  --host <peer>   fetch from <peer> instead of zig-computer

--export prints `export VAR=...` to stdout — the only way into an already-running
shell, so it necessarily emits the value. Use it only inside eval "$( ... )".

Sources, in order: the tmux SESSION env the dispatcher brokered, then
zig-computer:~/.secrets for whatever is still missing. If everything resolves
from the brokered env there is no ssh round-trip at all.

Exit: 0 ok · 1 could not reach the peer · 2 a var was missing everywhere
USAGE
}

PEER=zig-computer
CMD=status
EXPORT=0
VARS=(FLEET_API_TOKEN SLACK_BOT_TOKEN SLACK_NEWS_PLANNING_CHANNEL_ID SITE_PASSWORD)

while [ $# -gt 0 ]; do
  case "$1" in
    status|ensure|clear) CMD=$1; shift ;;
    --export) EXPORT=1; shift ;;
    --host) PEER=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
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

# Read one var out of the tmux SESSION environment — where the dispatcher's
# `tmux setenv` brokering actually lands. Value on stdout; rc 1 when unresolvable.
#
# `tmux show-environment` has THREE answers and conflating them is how a brokered
# var gets read as the literal string "-NAME":
#   NAME=value   set
#   -NAME        explicitly UNSET (a teardown ran) — that is ABSENT, not a value
#   rc != 0      never set at all ("unknown variable" on stderr)
session_env_get() {
  local name=$1 line
  in_tmux || return 1
  line=$(tmux show-environment -t "$(session)" "$name" 2>/dev/null | head -1) || return 1
  case "$line" in
    "$name="?*) printf '%s' "${line#*=}"; return 0 ;;
    *)          return 1 ;;   # "-NAME", "NAME=" (empty), or nothing at all
  esac
}

case "$CMD" in
  status)
    say "credential state (values are never printed):"
    for v in "${VARS[@]}"; do
      cur="${!v:-}"
      [ -n "$cur" ] || cur=$(session_env_get "$v") || cur=""
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
# ensure — two sources, brokered-first
# ---------------------------------------------------------------------------
# 1. the tmux SESSION env the dispatcher already brokered (no network at all)
# 2. zig-computer:~/.secrets, for whatever step 1 could not answer
#
# Step 1 exists because a send-keys-delivered tick runs in an already-started
# shell and therefore never inherits the brokering (see the header). It also
# means the common case does ZERO ssh, keeping ticks off zig-computer's ufw ssh
# rate limit.
declare -A VALUE=()
declare -A SOURCE=()
NEED=()
UNREACHABLE=0

for v in "${VARS[@]}"; do
  if got=$(session_env_get "$v"); then
    VALUE[$v]=$got
    SOURCE[$v]="brokered tmux env"
  else
    NEED+=("$v")
  fi
done
unset got

if [ "${#NEED[@]}" -eq 0 ]; then
  say "all ${#VARS[@]} vars resolved from the brokered tmux session env — no ssh to $PEER needed"
else
  # One ssh round-trip for the remainder; print each var as NAME<TAB>VALUE.
  # Reading ~/.secrets and echoing only the ones still missing keeps the blast
  # radius to those.
  say "resolved ${#VALUE[@]} from the brokered tmux env; fetching ${NEED[*]} from $PEER (memory only, never written to disk here)"
  # `bash -lc`, NOT a bare ssh command: zig-computer's login shell is ZSH, and the
  # indirect expansion ${!v} below is a bash-ism that zsh answers with
  # "bad substitution". Without this the fetch returned nothing, the loop set
  # nothing, and every proxy call kept 401ing while the script claimed success —
  # the same class of silent-wrong-answer the dispatch's own `rsh` uses bash -lc to
  # avoid. Verified 2026-07-28.
  REMOTE_SNIPPET="set -a; . \$HOME/.secrets 2>/dev/null; set +a; for v in ${NEED[*]}; do printf '%s\t%s\n' \"\$v\" \"\${!v:-}\"; done"
  FETCHED=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$PEER" \
    "bash -lc $(printf '%q' "$REMOTE_SNIPPET")" 2>&1)
  RC=$?
  if [ "$RC" -ne 0 ]; then
    say "FAILED to reach $PEER (rc=$RC):"
    printf '%s\n' "$FETCHED" | sed 's/^/    /' >&2
    say "  Check: ssh -o BatchMode=yes $PEER true"
    say "  If this says 'Connection refused', zig-computer's ufw may be rate-limiting ssh"
    say "  (the LIMIT rule REJECTs, and every retry refreshes the window — back off, do not hammer)."
    UNREACHABLE=1
  else
    # Refuse to report success over an unparseable answer. A remote shell that
    # errored still exits 0 through some paths, and "loaded nothing, said fine" is
    # exactly how the 401 above survived a green run. The sentinel is the first var
    # we actually ASKED for — hardcoding FLEET_API_TOKEN here would skip the guard
    # entirely on the (now normal) runs where that one came from the brokered env.
    SENTINEL=${NEED[0]}
    if ! printf '%s' "$FETCHED" | grep -q "^$SENTINEL$(printf '\t')"; then
      say "FAILED: $PEER returned no $SENTINEL line. Raw answer:"
      printf '%s\n' "$FETCHED" | sed 's/^/    /' >&2
      exit 2
    fi
    while IFS=$'\t' read -r name value; do
      [ -z "$name" ] && continue
      [ -z "$value" ] && continue          # reported as MISSING by the emit loop
      VALUE[$name]=$value
      SOURCE[$name]=$PEER
    done <<< "$FETCHED"
  fi
fi

# Emit in declaration order, naming the SOURCE of each — "where did this come
# from" was the unanswerable question the morning this broke.
MISSING=0
for v in "${VARS[@]}"; do
  val=${VALUE[$v]:-}
  if [ -z "$val" ]; then
    if [ "$UNREACHABLE" = 1 ]; then
      say "  $v: UNRESOLVED — not in the brokered tmux env, and $PEER was unreachable"
    else
      say "  $v: MISSING — not in the brokered tmux env, and not set in $PEER:~/.secrets"
    fi
    MISSING=1
    continue
  fi
  # Already in the session env if that is where it came from; only write back
  # what the fetch added.
  if [ "${SOURCE[$v]}" != "brokered tmux env" ] && in_tmux; then
    tmux setenv -t "$(session)" "$v" "$val" 2>/dev/null
  fi
  [ "$EXPORT" = 1 ] && printf 'export %s=%q\n' "$v" "$val"
  say "  $v: loaded from ${SOURCE[$v]} (len=${#val})"
done

if in_tmux; then
  say "tmux session $(session) holds every resolved var — but only NEW panes inherit it."
  say "  A send-keys-delivered tick is an ALREADY-RUNNING shell: it needs --export."
else
  say "not inside tmux — only --export can help a bare shell."
fi
[ "$EXPORT" = 1 ] || say 'to load into THIS shell:  eval "$('"$0"' ensure --export)"'

[ "$UNREACHABLE" = 1 ] && exit 1
[ "$MISSING" = 1 ] && exit 2
exit 0
