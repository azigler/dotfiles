#!/bin/bash
# pulse-inject.sh — the tmux-injection scheduler primitive (/pulse OQ-1).
#
# Fired by a systemd user timer (or anything else). Ensures the
# dedicated scheduler window exists in Andrew's tmux, ensures an
# INTERACTIVE Claude Code session is running there, then types the
# kick-off command into it via send-keys.
#
# Why injection instead of `claude -p`: headless -p draws from the
# separate monthly Agent SDK credit pool (docs, 2026-06-15 policy) and
# is invisible — Andrew can't watch or steer. An interactive session in
# a tmux window uses the normal subscription, is observable by both
# Andrew and the agent, persists between ticks, and inherits the
# 🧠/✅/🔔 window lexicon (tmux-status.sh).
#
# Usage:
#   pulse-inject.sh --dir <project-path> --cmd "<prompt or /skill>" \
#                   [--session work] [--window pulse] [--launch claude]
#
#   --dir      project directory the Claude session anchors in (required)
#   --cmd      the text typed into the session, submitted with Enter (required)
#   --session  tmux session name (default: work — created detached if absent,
#              so timers still work after a reboot before Andrew attaches)
#   --window   dedicated window name (default: pulse). Matching strips any
#              leading lexicon glyph (🧠/✅/🔔) so the status hook's renames
#              don't break window discovery.
#   --launch   program to start when the window has no live session
#              (default: claude). Tests override with something inert.
#
# Behavior contract (tested in test-pulse-inject.sh):
#   1. No tmux server / no session  -> created detached.
#   2. No window named <window>     -> created with cwd <dir>.
#   3. Window exists, launch absent -> launch started, waited for, cmd sent.
#   4. Window exists, launch alive  -> cmd sent directly.
#   5. The window name match is lexicon-aware (✅ pulse == pulse).
#
# Logs to /tmp/pulse-inject.log. Exit non-zero on hard failures so the
# systemd unit records them (journalctl --user -u pulse-*).

set -uo pipefail

LOG=/tmp/pulse-inject.log
TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux

SESSION="work"
WINDOW="pulse"
LAUNCH="claude"
DIR=""
CMD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR=$2; shift 2 ;;
    --cmd)     CMD=$2; shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --window)  WINDOW=$2; shift 2 ;;
    --launch)  LAUNCH=$2; shift 2 ;;
    *) echo "pulse-inject: unknown arg $1" >&2; exit 64 ;;
  esac
done

note() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

[ -n "$DIR" ] && [ -n "$CMD" ] || { echo "pulse-inject: --dir and --cmd are required" >&2; exit 64; }
[ -d "$DIR" ] || { echo "pulse-inject: --dir $DIR does not exist" >&2; note "FAIL: dir missing: $DIR"; exit 66; }
[ -x "$TMUX_BIN" ] || { echo "pulse-inject: tmux not found" >&2; exit 69; }

note "tick: session=$SESSION window=$WINDOW dir=$DIR cmd=$CMD"

# 1. Ensure the session exists (detached creation survives reboots —
#    the window is there when Andrew attaches).
if ! "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
  "$TMUX_BIN" new-session -d -s "$SESSION" -c "$DIR" || { note "FAIL: cannot create session"; exit 70; }
  note "created session $SESSION (detached)"
fi

# 2. Find the dedicated window, lexicon-aware: the tmux-status hook
#    prefixes 🧠/✅/🔔, so "✅ pulse" must match "pulse".
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔) ?//'; }

WIN_ID=""
while IFS=$'\t' read -r id name; do
  if [ "$(strip_lexicon "$name")" = "$WINDOW" ]; then
    WIN_ID=$id
    break
  fi
done < <("$TMUX_BIN" list-windows -t "=$SESSION" -F $'#{window_id}\t#{window_name}' 2>/dev/null)

if [ -z "$WIN_ID" ]; then
  WIN_ID=$("$TMUX_BIN" new-window -d -P -F '#{window_id}' -t "=$SESSION" -n "$WINDOW" -c "$DIR")
  note "created window $WINDOW ($WIN_ID)"
fi

PANE="$WIN_ID.0"

# 3. Ensure the launch program is running in the pane.
LAUNCH_BASE=$(basename "${LAUNCH%% *}")
CURRENT_CMD=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)

if [ "$CURRENT_CMD" != "$LAUNCH_BASE" ]; then
  # cd first so a recycled shell pane anchors in the right project.
  "$TMUX_BIN" send-keys -t "$PANE" "cd $(printf '%q' "$DIR")" Enter
  sleep 0.5
  "$TMUX_BIN" send-keys -t "$PANE" "$LAUNCH" Enter
  note "launched '$LAUNCH' in $PANE (was: ${CURRENT_CMD:-empty})"
  # Wait for the program to come up (Claude Code TUI takes a few
  # seconds; bounded poll, then proceed regardless and let the log
  # show what happened).
  for _ in $(seq 1 30); do
    sleep 1
    NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
    [ "$NOW" = "$LAUNCH_BASE" ] && break
  done
  NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
  if [ "$NOW" != "$LAUNCH_BASE" ]; then
    note "WARN: '$LAUNCH_BASE' not detected after 30s (pane runs '$NOW') — injecting anyway"
  else
    # Give an interactive TUI a moment to finish booting before typing.
    sleep 3
  fi
fi

# 4. Inject the command. Text first, Enter separately — some TUIs
#    mis-handle a combined burst.
"$TMUX_BIN" send-keys -t "$PANE" -- "$CMD"
sleep 0.3
"$TMUX_BIN" send-keys -t "$PANE" Enter
note "injected into $PANE"

exit 0
