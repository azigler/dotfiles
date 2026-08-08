#!/bin/bash
# PostToolUse (PushNotification): fall back to AskUserQuestion when a mobile
# push did NOT deliver.
#
# A PushNotification whose result says "Remote Control inactive" never reached
# Zig — the phone push silently no-ops. The reliable attention channel is an
# AskUserQuestion: the harness app notification + the tmux 🔔 fire on it,
# independent of Remote Control. So on the failed-delivery marker we inject
# guidance telling the session to raise an AskUserQuestion carrying whatever the
# push was for. (Zig's standing rule, 2026-07-17.)
#
# INJECT-only: emits additionalContext on a match, nothing otherwise. Never
# blocks — the push tool already ran; this only redirects the follow-up.

INPUT=$(cat)

# tostring so a string OR object tool_response both match; // "" guards null.
RESP=$(printf '%s' "$INPUT" | jq -r '(.tool_response // "") | tostring' 2>/dev/null || true)

printf '%s' "$RESP" | grep -qF 'Remote Control inactive' || exit 0

# --- durable record (dotfiles-dpml) ----------------------------------------
# So the seneschal can later report "I tried to reach you N times today."
# Append-only, best-effort: an unwritable log must NOT change this hook's
# behavior or exit code, and any failure is reported on the hook's OWN
# stderr only — stdout below is the hookSpecificOutput JSON and must stay
# clean.
{
  RESOLVE_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/tmux-pane-resolve.sh"
  # shellcheck source=../lib/tmux-pane-resolve.sh
  [ -f "$RESOLVE_LIB" ] && . "$RESOLVE_LIB"

  SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  WINDOW=""
  if command -v tmux_resolve_window >/dev/null 2>&1; then
    WINDOW=$(tmux_resolve_window "$SESSION" 2>/dev/null) || WINDOW=""
  fi
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  LOG="${CLAUDE_PUSH_FAILURE_LOG:-$HOME/.claude/push-failures.jsonl}"
  LINE=$(jq -nc \
    --arg ts "$TS" --arg session "$SESSION" --arg window "$WINDOW" \
    '{ts: $ts,
      session: (if ($session|length) > 0 then $session else null end),
      window: (if ($window|length) > 0 then $window else null end),
      reason: "remote-control-inactive"}' 2>/dev/null)

  if [ -n "$LINE" ]; then
    mkdir -p "$(dirname "$LOG")" 2>/dev/null \
      && printf '%s\n' "$LINE" >> "$LOG" 2>/dev/null \
      || echo "post-push-fallback.sh: could not append to $LOG (best-effort, non-fatal)" >&2
  fi
} 1>&2

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "⚠️ That PushNotification did NOT reach Zig — its result says \"Remote Control inactive\", so the mobile push silently did not deliver. Do not treat the notification as delivered or assume he saw it. Fall back to the reliable channel: raise an AskUserQuestion now (the harness app + tmux 🔔 fire on it regardless of Remote Control), carrying whatever the push was for — the decision, the review, or the heads-up plus the obvious next choice. Only skip inside an autonomous loop/tick that must not block on input; there, file a P1 human: bead instead."
  }
}'
exit 0
