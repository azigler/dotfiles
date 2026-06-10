#!/bin/bash
# Multi-event hook: surface this Claude session's state in its tmux
# window name, so Andrew can see at a glance which windows are waiting
# for him without rotating through all of them.
#
# Lexicon (prefix on the window name) — exactly four glyphs:
#   🧠  working          (UserPromptSubmit, PostToolUse)
#   ✅  ready for review (Stop — agent finished its turn)
#   🔔  needs YOU to continue (permission prompt, AskUserQuestion,
#                              plan approval — blocked on Andrew)
#   🌀  compacting       (PreCompact — manual or auto)
#   (no prefix)          fresh context waiting for its first prompt
#                        (SessionStart — any source: startup, resume,
#                        clear, compact — and SessionEnd both strip)
#
# The cycle (2026-06-10, Andrew's read): bare → 🧠 on the first prompt
# → ✅/🔔 → 🌀 while compacting → bare again. A just-started or
# just-compacted session isn't thinking — it's waiting — so it carries
# no glyph, same as a window where claude hasn't run yet.
#
# Semantics (tightened 2026-06-09 after the di/prod false-🔔):
# - Notification fires for BOTH "needs your permission to use X" and
#   the ~60s-idle "Claude is waiting for your input". The idle one is
#   true of every finished window, so mapping it to 🔔 falsely flips
#   done windows. We map ONLY permission-type messages to 🔔 and
#   ignore idle notifications (Stop's ✅ already covers "done").
# - PreToolUse on AskUserQuestion / ExitPlanMode -> 🔔: the agent is
#   mid-turn but literally asking Andrew something. This closes the
#   "has a checkmark but is actually waiting for an answer" gap for
#   structured questions. (A free-text question at end-of-turn still
#   reads ✅ — undetectable deterministically; agents should prefer
#   AskUserQuestion for blocking questions partly for this reason.)
# - PostToolUse (any tool) -> 🧠: work is visibly happening. This also
#   self-heals a stale 🔔 right after a permission is granted, since
#   the approved tool's PostToolUse fires immediately.
#
# (Glyph choice 2026-06-09: 🤖 renders as plain ASCII in Andrew's
# terminal font and 🦾 reads too dark next to ✅/🔔 — settled on 🧠.
# All live windows were relabeled in the same pass, so the strip
# regex handles ONLY the current set; add a glyph here AND in the
# strip regex if the lexicon ever grows. 🌀 added 2026-06-10 —
# VS-free, so no 🤖-style ASCII-fallback risk.)
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
#   Stop, Notification, PreCompact, SessionEnd) — NOT SubagentStart/
#   SubagentStop, so background subagents don't flicker the window.
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
  UserPromptSubmit|PostToolUse) PREFIX="🧠 " ;;
  Stop)                         PREFIX="✅ " ;;
  PreCompact)                   PREFIX="🌀 " ;;
  Notification)
    # Only permission-type notifications mean "blocked on Andrew".
    # The ~60s-idle "waiting for your input" notification fires for
    # every finished window — ignore it (Stop's ✅ already covers it).
    MSG=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
    echo "$MSG" | grep -qi 'permission' || exit 0
    PREFIX="🔔 "
    ;;
  PreToolUse)
    # The agent is mid-turn but explicitly asking Andrew something.
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    case "$TOOL" in
      AskUserQuestion|ExitPlanMode) PREFIX="🔔 " ;;
      *) exit 0 ;;
    esac
    ;;
  SessionStart|SessionEnd) PREFIX="" ;;
  *) exit 0 ;;
esac

CURRENT=$("$TMUX_BIN" display-message -p -t "$TMUX_PANE" '#W' 2>/dev/null)
[ -z "$CURRENT" ] && exit 0

# Strip any existing lexicon prefix (emoji + optional space).
BASE=$(printf '%s' "$CURRENT" | sed -E 's/^(🧠|✅|🔔|🌀) ?//')
[ -z "$BASE" ] && BASE="claude"

NEW="${PREFIX}${BASE}"
[ "$NEW" = "$CURRENT" ] && exit 0

"$TMUX_BIN" rename-window -t "$TMUX_PANE" "$NEW" 2>/dev/null

exit 0
