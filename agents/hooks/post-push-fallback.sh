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

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "⚠️ That PushNotification did NOT reach Zig — its result says \"Remote Control inactive\", so the mobile push silently did not deliver. Do not treat the notification as delivered or assume he saw it. Fall back to the reliable channel: raise an AskUserQuestion now (the harness app + tmux 🔔 fire on it regardless of Remote Control), carrying whatever the push was for — the decision, the review, or the heads-up plus the obvious next choice. Only skip inside an autonomous loop/tick that must not block on input; there, file a P1 human: bead instead."
  }
}'
exit 0
