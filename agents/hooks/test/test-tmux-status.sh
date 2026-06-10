#!/bin/bash
# Test for tmux-status.sh — window-name lexicon transitions.
#
# Hook test convention (see test-worktree-guard.sh): executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.
#
# Strategy: spin up a DETACHED throwaway tmux session, point the hook
# at its pane via TMUX/TMUX_PANE env, fire events, assert the window
# name after each. Skips cleanly (exit 0) when tmux isn't available.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/tmux-status.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
if [ ! -x "$TMUX_BIN" ]; then
  echo "PASS: 0/0 test cases (tmux not installed — skipped)"
  exit 0
fi

SESSION="claude-hook-test-$$"
"$TMUX_BIN" new-session -d -s "$SESSION" -x 80 -y 24 2>/dev/null || {
  echo "PASS: 0/0 test cases (cannot create tmux session — skipped)"
  exit 0
}
trap '"$TMUX_BIN" kill-session -t "$SESSION" 2>/dev/null' EXIT

PANE=$("$TMUX_BIN" list-panes -t "$SESSION" -F '#{pane_id}' | head -1)
SOCKET=$("$TMUX_BIN" display-message -p -t "$SESSION" '#{socket_path}')
"$TMUX_BIN" rename-window -t "$PANE" "myproject"

fire() {
  local event=$1
  fire_json "$(printf '{"hook_event_name":"%s"}' "$event")"
}

fire_json() {
  printf '%s' "$1" | TMUX="$SOCKET,0,0" TMUX_PANE="$PANE" "$HOOK"
}

assert_name() {
  local name=$1 want=$2
  local got
  got=$("$TMUX_BIN" display-message -p -t "$PANE" '#W')
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (want '$want', got '$got')")
  fi
}

# 1. SessionStart on a fresh window → bare (a session that just
#    started isn't thinking — it's waiting for its first prompt)
fire SessionStart
assert_name "SessionStart leaves fresh window bare" "myproject"

# 1b. First prompt → 🧠
fire UserPromptSubmit
assert_name "first prompt sets working prefix" "🧠 myproject"

# 2. Stop → ✅ replaces 🧠 (no stacking)
fire Stop
assert_name "Stop swaps to ready prefix" "✅ myproject"

# 3. Permission-type Notification → 🔔 replaces ✅
fire_json '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
assert_name "permission notification swaps to attention prefix" "🔔 myproject"

# 3b. Idle "waiting for your input" Notification → IGNORED (the di/prod
#     false-🔔: every finished window idles; that is what ✅ means)
fire Stop
fire_json '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
assert_name "idle notification does not override ready" "✅ myproject"

# 4. UserPromptSubmit → back to 🧠
fire UserPromptSubmit
assert_name "UserPromptSubmit swaps to working prefix" "🧠 myproject"

# 4b. PreToolUse AskUserQuestion → 🔔 (agent mid-turn, asking Andrew)
fire_json '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
assert_name "AskUserQuestion swaps to attention prefix" "🔔 myproject"

# 4c. PostToolUse (any tool) → 🧠 (work resumed; heals stale 🔔)
fire_json '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
assert_name "PostToolUse heals back to working prefix" "🧠 myproject"

# 4d. PreToolUse on an ordinary tool → no change
fire_json '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert_name "ordinary PreToolUse is a no-op" "🧠 myproject"

# 4e. PreCompact → 🌀 (compaction running — manual or auto)
fire PreCompact
assert_name "PreCompact swaps to compacting prefix" "🌀 myproject"

# 4f. SessionStart (fires with source=compact when compaction ends)
#     strips 🌀 — compacted context is fresh, waiting for a prompt
fire SessionStart
assert_name "SessionStart strips compacting to bare" "myproject"

# 5. Manual rename mid-session survives (only prefix is managed)
"$TMUX_BIN" rename-window -t "$PANE" "renamed-by-hand"
fire Stop
assert_name "manual rename preserved under prefix" "✅ renamed-by-hand"

# 6. SessionEnd → prefix stripped, plain name restored
fire SessionEnd
assert_name "SessionEnd strips prefix" "renamed-by-hand"

# 6b. SessionEnd also strips a compacting prefix
"$TMUX_BIN" rename-window -t "$PANE" "🌀 renamed-by-hand"
fire SessionEnd
assert_name "SessionEnd strips compacting prefix" "renamed-by-hand"

# 7. Unknown event → no-op
fire SubagentStop
assert_name "unknown event is a no-op" "renamed-by-hand"

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
