#!/bin/bash
# Shared lexicon mapping: hook event -> semantic state TOKEN -> display glyph.
# Source via:  . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/lexicon-map.sh"
#
# This is the single source of truth for the tmux lexicon that was, until
# 2026-07-03, inlined in tmux-status.sh and thrown away after the window
# rename. Extracting it lets every surface (the tmux window name, the
# statusline, a future menu-bar/robot/page renderer) share ONE event->glyph
# mapping instead of re-deriving the hard-won false-🔔 guards.
#
# The lexicon — exactly four glyphs plus a bare "idle" state:
#   🧠  working     (UserPromptSubmit, PostToolUse)
#   ✅  ready       (Stop — agent finished its turn)
#   🔔  blocked     (permission prompt, AskUserQuestion, plan approval)
#   🌀  compacting  (PreCompact — manual or auto)
#   (no glyph) idle (SessionStart / SessionEnd — fresh context waiting
#                    for its first prompt; carries no glyph)
#
# The subtle guards (moved here VERBATIM from tmux-status.sh — do NOT relax):
# - Notification fires for BOTH "needs your permission to use X" and the
#   ~60s-idle "Claude is waiting for your input". The idle one is true of
#   every finished window, so mapping it to 🔔 falsely flips done windows.
#   We map ONLY permission-type messages to 🔔 (blocked) and treat idle
#   notifications as a NO-OP (leave state alone; Stop's ✅ already covers
#   "done"). Tightened 2026-06-09 after the di/prod false-🔔.
# - PreToolUse on AskUserQuestion / ExitPlanMode -> 🔔 (blocked): the agent
#   is mid-turn but literally asking Andrew something. Any OTHER PreToolUse
#   tool is a NO-OP.
# - PostToolUse (any tool) -> 🧠 (working): work is visibly happening. This
#   also self-heals a stale 🔔 right after a permission is granted, since
#   the approved tool's PostToolUse fires immediately.
#
# Glyph choice (2026-06-09): 🤖 renders as plain ASCII in Andrew's terminal
# font and 🦾 reads too dark next to ✅/🔔 — settled on 🧠. 🌀 added
# 2026-06-10 (VS-free, no ASCII-fallback risk). If the lexicon ever grows,
# add the glyph in lexicon_glyph AND in LEXICON_STRIP_RE below.

# Anchored strip regex for the four managed glyphs (emoji + optional space).
# Keep in sync with lexicon_glyph. Used by any surface that prepends a glyph
# to a manually-named window and must strip the old one first.
# shellcheck disable=SC2034  # consumed by sourcing callers (e.g. tmux-status.sh)
LEXICON_STRIP_RE='^(🧠|✅|🔔|🌀) ?'

# lexicon_glyph <token>
#   Echo the display glyph (with its trailing space, i.e. prefix form) for a
#   semantic state token. Empty for `idle` and any unknown token — a bare
#   window/statusline is the correct render for "waiting for first prompt".
lexicon_glyph() {
  case "$1" in
    working)    printf '🧠 ' ;;
    ready)      printf '✅ ' ;;
    blocked)    printf '🔔 ' ;;
    compacting) printf '🌀 ' ;;
    *)          printf '' ;;
  esac
}

# lexicon_resolve <event> <message> <tool>
#   Map a hook event to a semantic state. On a mapped event, sets the globals
#   LEXICON_TOKEN (working|ready|blocked|compacting|idle) and LEXICON_GLYPH
#   (its prefix glyph) and returns 0. On an event that must NOT change state
#   (idle notification, an ordinary PreToolUse tool, an unknown event),
#   returns 1 and leaves the globals empty — callers should treat this as
#   "leave the current state alone" (the old inline `exit 0` no-op paths).
#
#   <message> is only consulted for Notification, <tool> only for PreToolUse;
#   pass empty strings when not applicable.
lexicon_resolve() {
  local event=$1 msg=$2 tool=$3
  LEXICON_TOKEN=""
  LEXICON_GLYPH=""
  case "$event" in
    UserPromptSubmit|PostToolUse) LEXICON_TOKEN="working" ;;
    Stop)                         LEXICON_TOKEN="ready" ;;
    PreCompact)                   LEXICON_TOKEN="compacting" ;;
    Notification)
      # Only permission-type notifications mean "blocked on Andrew".
      # The ~60s-idle "waiting for your input" notification fires for every
      # finished window — ignore it (Stop's ✅ already covers it).
      echo "$msg" | grep -qi 'permission' || return 1
      LEXICON_TOKEN="blocked"
      ;;
    PreToolUse)
      # The agent is mid-turn but explicitly asking Andrew something.
      case "$tool" in
        AskUserQuestion|ExitPlanMode) LEXICON_TOKEN="blocked" ;;
        *) return 1 ;;
      esac
      ;;
    SessionStart|SessionEnd) LEXICON_TOKEN="idle" ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2034  # consumed by sourcing callers alongside LEXICON_TOKEN
  LEXICON_GLYPH="$(lexicon_glyph "$LEXICON_TOKEN")"
  return 0
}
