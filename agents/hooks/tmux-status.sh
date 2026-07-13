#!/bin/bash
# Multi-event hook: surface this Claude session's state in its tmux window
# name (reader #1) AND persist it to a per-session state file (the SSoT) so
# other surfaces — the statusline, a future menu-bar/robot/page renderer —
# can read the same hard-won event->glyph mapping without re-deriving it.
#
# The event->state/glyph mapping (and its false-🔔 guards) lives in the
# shared lib agents/hooks/lib/lexicon-map.sh; this hook is the place that
# COMPUTES state (via lexicon_resolve), then does three things with it:
#   1. writes the semantic token to /tmp/claude-lexicon/<session_id>  (SSoT)
#   2. on a state CHANGE, appends a transition line to
#      ~/.claude/lexicon-log/<YYYY-MM-DD>.jsonl                       (log)
#   3. renames the tmux window token->glyph                       (reader #1)
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
# The semantics of the mapping (permission-only 🔔, AskUserQuestion/
# ExitPlanMode special-case, idle-notification suppression, PostToolUse
# self-heal of a stale 🔔) now live — with their full rationale — in
# lib/lexicon-map.sh. See there before touching the mapping.
#
# Design notes:
# - STATELESS window name: we never store the "original" name. On every
#   event we read the current window name, strip any leading lexicon emoji,
#   and prepend the new one. Manual renames at any time are preserved —
#   only the prefix changes. (Andrew names windows by hand: fast-lane,
#   weeklies, imc-, ... — those names must survive.)
# - Per-session state IS stored (the SSoT the readers consume), keyed by
#   session_id under $CLAUDE_LEXICON_STATE_DIR, cleaned on SessionEnd by
#   session-end.sh (mirrors statusline's /tmp/claude-context-pct file).
# - Targets the window containing this session's pane, so split panes (bead
#   viewer next to the agent) are unaffected. The pane is $TMUX_PANE when set,
#   else recovered from process ancestry via lib/tmux-pane-resolve.sh — a
#   background-forked session (`bg-pty-host --fork-session`, CC 2.x) has no
#   $TMUX_PANE even though it lives in a pane (root-caused 2026-07-13).
# - Wired to main-session events only (SessionStart, UserPromptSubmit,
#   Stop, Notification, PreCompact, SessionEnd) — NOT SubagentStart/
#   SubagentStop, so background subagents don't flicker the window.
# - `tmux` is resolved via command -v with a /usr/bin fallback: the
#   interactive zsh aliases tmux to a plugin function that doesn't
#   exist in non-interactive shells (observed 2026-06-09).
# - Always exits 0; a missing tmux or dead pane must never break a
#   session. The SSoT write is best-effort and only happens when the
#   payload carries a session_id (it always does for main-session events).

INPUT=$(cat 2>/dev/null || echo '{}')

# Shared event->state/glyph mapping (single source of truth). If the lib is
# somehow absent, degrade to a no-op rather than break the session.
LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/lexicon-map.sh"
# shellcheck source=lib/lexicon-map.sh
[ -f "$LIB" ] && . "$LIB"
command -v lexicon_resolve >/dev/null 2>&1 || exit 0

# Shared pane resolver — recovers our tmux pane from process ancestry when
# $TMUX_PANE is absent (a background-forked session: `claude bg-pty-host
# --fork-session`, CC 2.x, has no $TMUX_PANE even though it lives in a pane).
# Best-effort: if the lib is missing we simply fall back to $TMUX_PANE below.
RESOLVE_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/tmux-pane-resolve.sh"
# shellcheck source=../lib/tmux-pane-resolve.sh
[ -f "$RESOLVE_LIB" ] && . "$RESOLVE_LIB"

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$EVENT" ] && exit 0

MSG=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Compute the semantic state. A non-zero return means "this event does not
# map — leave state alone" (idle notification, ordinary PreToolUse tool,
# unknown event), exactly the old inline `exit 0` no-op paths.
lexicon_resolve "$EVENT" "$MSG" "$TOOL" || exit 0
TOKEN="$LEXICON_TOKEN"
PREFIX="$LEXICON_GLYPH"

# Resolve tmux + the current window name once. CURRENT stays empty when we
# are not in a usable tmux pane — the window rename below then no-ops
# exactly as the original did, while the SSoT write still happens.
TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "$TMUX_BIN" ] || TMUX_BIN=/usr/bin/tmux

# Resolve THIS session's pane. $TMUX_PANE is the fast path; a background-forked
# session (`claude bg-pty-host --fork-session`, CC 2.x) has no $TMUX_PANE even
# though it lives in a pane, so recover it from process ancestry via the shared
# resolver — otherwise the glyph never tracks state (root-caused 2026-07-13).
PANE="${TMUX_PANE:-}"
if [ -z "$PANE" ] && command -v tmux_resolve_pane >/dev/null 2>&1; then
  PANE=$(tmux_resolve_pane)
fi

CURRENT=""
if [ -n "$PANE" ] && [ -x "$TMUX_BIN" ]; then
  CURRENT=$("$TMUX_BIN" display-message -p -t "$PANE" '#W' 2>/dev/null)
fi

# Strip any existing lexicon prefix to recover the manual base name.
BASE=""
if [ -n "$CURRENT" ]; then
  BASE=$(printf '%s' "$CURRENT" | sed -E "s/${LEXICON_STRIP_RE}//")
  [ -z "$BASE" ] && BASE="claude"
fi

# --- The SSoT: per-session state token + transition log ---------------------
# Only when the payload carries a session_id (main-session events always do).
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
  STATE_DIR="${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}"
  mkdir -p "$STATE_DIR" 2>/dev/null
  STATE_FILE="$STATE_DIR/$SESSION_ID"

  # The state file itself carries the prior token — read it before we
  # overwrite, so we can detect (and log) a genuine state transition.
  PREV=""
  [ -f "$STATE_FILE" ] && PREV=$(cat "$STATE_FILE" 2>/dev/null)

  if [ "$PREV" != "$TOKEN" ]; then
    # Raw exhaust stream: one JSON line per transition. A DuckDB view over
    # this is a follow-on (depends on the `est` bead) — this only writes
    # the log. jq builds the object so window names with quotes/unicode
    # can't corrupt the JSONL.
    LOG_DIR="${CLAUDE_LEXICON_LOG_DIR:-$HOME/.claude/lexicon-log}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    LOG_FILE="$LOG_DIR/$(date -u +%F).jsonl"
    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn \
      --arg ts "$TS" \
      --arg session "$SESSION_ID" \
      --arg window "$BASE" \
      --arg from "$PREV" \
      --arg to "$TOKEN" \
      '{ts:$ts, session:$session, window:$window, from_state:$from, to_state:$to}' \
      >> "$LOG_FILE" 2>/dev/null
  fi

  printf '%s\n' "$TOKEN" > "$STATE_FILE" 2>/dev/null
fi

# --- Reader #1: the tmux window name (behavior IDENTICAL to pre-SSoT) --------
[ -n "$CURRENT" ] || exit 0
NEW="${PREFIX}${BASE}"
[ "$NEW" = "$CURRENT" ] && exit 0

"$TMUX_BIN" rename-window -t "$PANE" "$NEW" 2>/dev/null

exit 0
