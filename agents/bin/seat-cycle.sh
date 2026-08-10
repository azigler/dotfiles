#!/bin/bash
# seat-cycle.sh — gracefully cycle a Claude seat's PROCESS in its tmux pane:
# /exit (with dialog confirm) -> wait for death -> relaunch -> readiness gate
# -> inject the opening prompt. The three failures this tool exists to close,
# all measured live 2026-08-10 (dotfiles-2xvq's cutover night):
#
#   1. A C-c C-c exit needs sub-second spacing and keeps missing (Zig: "/exit
#      is more reliable"). /exit opens a confirm dialog — the confirm Enter is
#      part of the verb.
#   2. A bare `claude` relaunch never trips the wrapper's Fable leg —
#      _ciw_fable_launch reads ARGV, and the fable_ceiling consult only fires
#      for a launch that NAMES a fable model. Relaunch with the canonical
#      literal (model-canon.sh owns the table) or the seat silently stays on
#      its config-dir pool.
#   3. A relaunched TUI sits idle forever unless something SUBMITS an opening
#      prompt — the consul's own restarter exited+relaunched and then nobody
#      typed (measured: fresh context, empty composer, zero work). The
#      readiness gate + injected command are the fix; the composer-footer
#      marker set matches pulse-inject's READY_MARKER / escalate's
#      IDLE_MARKER.
#
# Usage:
#   seat-cycle.sh --pane %N [--relaunch "<cmd>"] [--cmd "<opening prompt>"]
#                 [--no-exit]
#
#   --pane      tmux pane id (%N form). REQUIRED — explicit, never derived,
#               so an empty variable cannot retarget the live server (the
#               2026-08-10 caution: variables in paths/targets that could be
#               empty).
#   --relaunch  command typed at the shell after death. Default:
#                 claude --model 'claude-fable-5[1m]'
#   --cmd       opening prompt typed into the fresh composer after the
#               readiness gate. Optional — but a cycle without one is only
#               half a cycle for a fresh (non-resume) context.
#   --no-exit   skip the exit phase (pane already at a shell).
#
# Verdict contract (last stdout line, pulse-inject convention):
#   SEAT_CYCLE_RESULT=cycled | cycled-no-cmd | failed-no-pane |
#     failed-exit-refused | failed-not-ready | failed-no-claude-pid-skip-exit
set -uo pipefail

TMUX_BIN=/usr/bin/tmux
PANE=""
RELAUNCH="claude --model 'claude-fable-5[1m]'"
CMD=""
DO_EXIT=1
READY_MARKER='shift\+tab to cycle|\? for shortcuts|bypass permissions on|accept edits on|plan mode on|manual mode on'
READY_TIMEOUT="${SEAT_CYCLE_READY_TIMEOUT:-90}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pane)     PANE="${2:?--pane needs a value}"; shift 2 ;;
    --relaunch) RELAUNCH="${2:?--relaunch needs a value}"; shift 2 ;;
    --cmd)      CMD="${2:?--cmd needs a value}"; shift 2 ;;
    --no-exit)  DO_EXIT=0; shift ;;
    *) echo "seat-cycle: unknown arg '$1'" >&2; echo "SEAT_CYCLE_RESULT=failed-usage"; exit 2 ;;
  esac
done

case "$PANE" in
  %[0-9]*) : ;;
  *) echo "seat-cycle: --pane must be an explicit %N pane id (got '${PANE}')" >&2
     echo "SEAT_CYCLE_RESULT=failed-usage"; exit 2 ;;
esac

"$TMUX_BIN" has-session 2>/dev/null || { echo "SEAT_CYCLE_RESULT=failed-no-pane"; exit 1; }
PANE_PID=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || {
  echo "seat-cycle: pane $PANE not found" >&2
  echo "SEAT_CYCLE_RESULT=failed-no-pane"; exit 1
}

# The claude process is a descendant of the pane shell. pgrep -P finds direct
# children; claude is launched directly by the shell (wrapper is a function,
# not a wrapper process).
claude_pid() { pgrep -P "$PANE_PID" -x claude 2>/dev/null | head -1; }

if [ "$DO_EXIT" -eq 1 ]; then
  CPID=$(claude_pid)
  if [ -z "$CPID" ]; then
    echo "seat-cycle: no claude child under pane shell $PANE_PID — skipping exit phase" >&2
    echo "SEAT_CYCLE_RESULT_NOTE=failed-no-claude-pid-skip-exit"
  else
    "$TMUX_BIN" send-keys -t "$PANE" "/exit" Enter
    sleep 3
    "$TMUX_BIN" send-keys -t "$PANE" Enter          # confirm dialog
    for _ in $(seq 1 30); do kill -0 "$CPID" 2>/dev/null || break; sleep 2; done
    if kill -0 "$CPID" 2>/dev/null; then            # retry once, composer may hold text
      "$TMUX_BIN" send-keys -t "$PANE" Escape
      sleep 1
      "$TMUX_BIN" send-keys -t "$PANE" "/exit" Enter
      sleep 3
      "$TMUX_BIN" send-keys -t "$PANE" Enter
      for _ in $(seq 1 30); do kill -0 "$CPID" 2>/dev/null || break; sleep 2; done
    fi
    if kill -0 "$CPID" 2>/dev/null; then
      echo "seat-cycle: claude pid $CPID never exited" >&2
      echo "SEAT_CYCLE_RESULT=failed-exit-refused"; exit 1
    fi
  fi
  sleep 3                                            # let the shell prompt paint
fi

# RE-SOURCE THE WRAPPER FIRST — failure #4 of this class (2026-08-10 02:14Z,
# measured on the dotfiles cycle): the wrapper is a shell FUNCTION captured at
# shell start, and durable pane shells are DAYS old. A relaunch through a
# stale function gets stale attribution epochs and NO tap consult — the
# 02:14:31Z row attributed epoch-1 (group=zig-computer) with no rollover.
# pulse-inject.sh:896 is the precedent idiom; ~/.agents first, dotfiles
# fallback, matching agents-root resolution.
"$TMUX_BIN" send-keys -t "$PANE" \
  '[ -f "$HOME/.agents/agents/lib/claude-identity-wrapper.sh" ] && . "$HOME/.agents/agents/lib/claude-identity-wrapper.sh" || . "$HOME/dotfiles/agents/lib/claude-identity-wrapper.sh"' Enter
sleep 1
"$TMUX_BIN" send-keys -t "$PANE" "$RELAUNCH" Enter

# Readiness gate: the composer footer is the "TUI accepts input" signal.
ready=0
for _ in $(seq 1 "$READY_TIMEOUT"); do
  if "$TMUX_BIN" capture-pane -pJ -t "$PANE" 2>/dev/null | grep -qE "$READY_MARKER"; then
    ready=1; break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "seat-cycle: relaunch never showed the composer footer within ${READY_TIMEOUT}s" >&2
  echo "SEAT_CYCLE_RESULT=failed-not-ready"; exit 1
fi

if [ -n "$CMD" ]; then
  sleep 2                                            # settle past first paint
  "$TMUX_BIN" send-keys -t "$PANE" "$CMD"
  sleep 1
  "$TMUX_BIN" send-keys -t "$PANE" Enter
  echo "SEAT_CYCLE_RESULT=cycled"
else
  echo "SEAT_CYCLE_RESULT=cycled-no-cmd"
fi
