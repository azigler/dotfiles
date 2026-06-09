#!/bin/bash
# Multi-event hook: surface this Claude session's state in its tmux
# window name, so Andrew can see at a glance which windows are waiting
# for him without rotating through all of them.
#
# Lexicon (prefix on the window name):
#   🦾  working          (SessionStart, UserPromptSubmit — agent is busy)
#   ✅  ready for review (Stop — agent finished its turn)
#   🔔  needs attention  (Notification — permission prompt / waiting on input)
#   (no prefix)          (SessionEnd — emoji stripped, name restored)
# (🦾 not 🤖 — the robot emoji renders as a plain ASCII glyph in
# Andrew's terminal font; the mechanical arm renders correctly.)
#
# Design notes:
# - STATELESS: we never store the "original" name. On every event we
#   read the current window name, strip any leading lexicon emoji, and
#   prepend the new one. Manual renames at any time are preserved —
#   only the prefix changes. (Andrew names windows by hand: fast-lane,
#   weeklies, imc-, ... — those names must survive.)
# - Targets the window containing $TMUX_PANE, so split panes (bead
#   viewer next to the agent) are unaffected.
# - Wired to main-session events only (SessionStart, UserPromptSubmit,
#   Stop, Notification, SessionEnd) — NOT SubagentStart/SubagentStop,
#   so background subagents don't flicker the window.
# - `tmux` is resolved via command -v with a /usr/bin fallback: the
#   interactive zsh aliases tmux to a plugin function that doesn't
#   exist in non-interactive shells (observed 2026-06-09).
# - Always exits 0; a missing tmux or dead pane must never break a
#   session.

INPUT=$(cat 2>/dev/null || echo '{}')

# Only act inside tmux with a known pane.
[ -n "$TMUX" ] && [ -n "$TMUX_PANE" ] || exit 0

TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "$TMUX_BIN" ] || TMUX_BIN=/usr/bin/tmux
[ -x "$TMUX_BIN" ] || exit 0

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$EVENT" ] && exit 0

case "$EVENT" in
  SessionStart|UserPromptSubmit) PREFIX="🦾 " ;;
  Stop)                          PREFIX="✅ " ;;
  Notification)                  PREFIX="🔔 " ;;
  SessionEnd)                    PREFIX="" ;;
  *) exit 0 ;;
esac

CURRENT=$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#W' 2>/dev/null)
[ -z "$CURRENT" ] && exit 0

# Strip any existing lexicon prefix (emoji + optional space).
BASE=$(printf '%s' "$CURRENT" | sed -E 's/^(🦾|🤖|✅|🔔) ?//')
[ -z "$BASE" ] && BASE="claude"

NEW="${PREFIX}${BASE}"
[ "$NEW" = "$CURRENT" ] && exit 0

"$TMUX_BIN" rename-window -t "$TMUX_PANE" "$NEW" 2>/dev/null

exit 0
