#!/usr/bin/env bash
# tmux-fixture-sweep — reap leaked hook-test tmux sockets in /tmp/tmux-<uid>/.
#
# WHY (dotfiles-2v8h). Test fixtures under agents/scheduler/ and
# agents/hooks/test/ spin up private `-L`/`-S` tmux servers (pulseseat-*,
# pulseseatleak-*, fcsuite*, and one-off manual probes). Their EXIT traps
# call `kill-server`, but a killed server does not reliably unlink its own
# socket FILE (measured live, 2026-08-09: two fresh dead sockets appeared
# from a single clean test-pulse-inject.sh run even with a correct trap), and
# a run that gets SIGKILLed by a timeout skips the trap entirely. Both leave
# a dead socket file behind; over enough runs they accumulate (42 found on
# 2026-08-09, the count that motivated this bead).
#
# ⚠️ THE 2026-08-09 INCIDENT THIS SCRIPT EXISTS TO NEVER REPEAT: a prior sweep
# attempt exported TMUX_TMPDIR for a demo dir and ran a BARE `tmux kill-server`.
# TMUX_TMPDIR only shapes the DEFAULT socket path when NO -S/-L is given; the
# INHERITED $TMUX (the sweep agent's own shell was itself a tmux client) takes
# precedence over that default, so the bare command connected to and killed
# the LIVE server — every pane, the orchestrator, two sibling agents. Verified
# empirically (dotfiles-2v8h) that an explicit -S/-L ON THE COMMAND LINE
# overrides an inherited $TMUX regardless of env:
#   TMUX="/tmp/tmux-1000/default,99999,0" tmux -L probetest-verify list-sessions
#   -> "error connecting to /tmp/tmux-1000/probetest-verify (No such file or
#      directory)" — never touched the socket named in $TMUX.
# So every tmux invocation below is `env -u TMUX -u TMUX_TMPDIR tmux -S
# <explicit-path> ...` — belt (explicit -S always wins) AND suspenders (env
# hygiene so nothing here could ever be misread as depending on ambient env).
#
# SAFETY RAILS, absolute:
#   - 'default' is NEVER touched, mutation or not — it is the live server.
#   - a name is only ever passed to `-S`, never bare — no fallback path exists.
#   - a socket is REMOVED only after being proven dead (list-sessions failed)
#     or, if live, only after an explicit-socket kill-server against THAT
#     exact path succeeded.
#   - read-only probes (list-sessions) run unconditionally; only kill-server
#     and rm run against sockets that match a known fixture-name pattern.
#
# Usage:
#   agents/bin/tmux-fixture-sweep.sh [--dry-run] [socket-dir]
#     --dry-run    report what would be killed/removed, touch nothing
#     socket-dir   defaults to /tmp/tmux-$UID
#
# Fixture patterns swept (see dotfiles-2v8h): pulseseat-*, pulseseatleak-*,
# fcsuite*, fctest*, fcx*, probe*, ska5-*, plus a short list of one-off names
# left over from the incident's own manual investigation (romdbench,
# seatcheck, y2od-validate, envprobe, probetest) — none of these map to a
# checked-in fixture script; they are debris from ad hoc exploration and are
# swept on the same "prove dead or explicitly kill, then rm" contract.
#
# Exits 0 on a clean sweep (including "nothing to do"), 1 if any live socket
# refused to die under an explicit-socket kill-server.

set -uo pipefail

DRY_RUN=0
SOCKDIR=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) SOCKDIR="$arg" ;;
  esac
done
SOCKDIR="${SOCKDIR:-/tmp/tmux-$UID}"

TMUX_BIN=$(command -v tmux 2>/dev/null) || TMUX_BIN=/usr/bin/tmux
[ -x "$TMUX_BIN" ] || { echo "tmux-fixture-sweep: no tmux binary found" >&2; exit 1; }

# The explicit-socket, env-hygienic invocation this whole script exists to
# model. NEVER called without a $1 socket path.
tmux_explicit() {
  local sock=$1; shift
  env -u TMUX -u TMUX_TMPDIR "$TMUX_BIN" -S "$sock" "$@"
}

# Fixture name patterns. Extend this list if a new suite mints a new prefix —
# do NOT widen it to match everything in $SOCKDIR; 'default' and any name
# outside this list are left untouched on purpose.
PATTERNS=(
  'pulseseat-*' 'pulseseatleak-*' 'fcsuite*' 'fctest*' 'fcx*' 'probe*'
  'ska5-*' 'probetest*' 'sweep-demo*'
  'romdbench' 'seatcheck' 'y2od-validate' 'envprobe'
)

matches_pattern() {
  local name=$1 pat
  for pat in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2053  -- deliberate glob match, not literal compare
    [[ "$name" == $pat ]] && return 0
  done
  return 1
}

[ -d "$SOCKDIR" ] || { echo "tmux-fixture-sweep: $SOCKDIR does not exist — nothing to sweep"; exit 0; }

BEFORE=$(find "$SOCKDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
KILLED=0
REMOVED=0
SKIPPED_LIVE=0
SKIPPED_UNMATCHED=0

echo "tmux-fixture-sweep: scanning $SOCKDIR (before: $BEFORE entries)"
[ "$DRY_RUN" -eq 1 ] && echo "  (--dry-run: reporting only, touching nothing)"

for path in "$SOCKDIR"/*; do
  [ -e "$path" ] || continue
  name=$(basename "$path")

  if [ "$name" = "default" ]; then
    echo "  SKIP   $name  (the live default server — never touched)"
    continue
  fi

  if ! matches_pattern "$name"; then
    SKIPPED_UNMATCHED=$((SKIPPED_UNMATCHED + 1))
    echo "  SKIP   $name  (does not match a known fixture pattern)"
    continue
  fi

  # Read-only probe first — always allowed bare-socket-argument, never a
  # mutation. A dead socket answers with a nonzero exit and "no server
  # running on <path>" on stderr.
  if tmux_explicit "$path" list-sessions >/dev/null 2>&1; then
    echo "  LIVE   $name  -> explicit-socket kill-server"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "         (dry-run: would kill-server -S $path)"
    elif tmux_explicit "$path" kill-server 2>&1; then
      KILLED=$((KILLED + 1))
    else
      echo "  FAIL   $name  -> kill-server did not report success" >&2
      SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
      continue
    fi
  else
    echo "  DEAD   $name"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "         (dry-run: would rm -f $path)"
  else
    rm -f "$path"
    REMOVED=$((REMOVED + 1))
  fi
done

AFTER=$(find "$SOCKDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
echo
echo "tmux-fixture-sweep: before=$BEFORE after=$AFTER killed=$KILLED removed=$REMOVED skipped_unmatched=$SKIPPED_UNMATCHED skipped_live_refused=$SKIPPED_LIVE"

[ "$SKIPPED_LIVE" -eq 0 ]
