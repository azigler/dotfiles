#!/bin/bash
# Test for handoff-path.sh — per-window scoping of the offboard/onboard
# artifacts. Uses a throwaway tmux window with a known name (and a lexicon
# glyph) to exercise the key resolution. Convention: non-zero exit = failure,
# PASS/FAIL summary on the last line.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/handoff-path.sh"

PASS=0; FAIL=0; FAILED=()
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); }

TMUX_BIN=$(command -v tmux 2>/dev/null); [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
DIR=$(mktemp -d)
mkdir -p "$DIR/refs" "$DIR/.claude"
trap 'rm -rf "$DIR"; [ -n "${SES:-}" ] && "$TMUX_BIN" kill-session -t "=$SES" 2>/dev/null' EXIT

# --- 1. No marker -> legacy single-file paths regardless of tmux state. ---
unset TMUX_PANE
if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff.md" ]; then ok; else bad "no-marker handoff legacy"; fi
if [ "$(offboard_pending_path "$DIR")" = "$DIR/.offboard-pending" ]; then ok; else bad "no-marker pending legacy"; fi
if [ "$(last_offboard_path "$DIR")" = "$DIR/.claude/last-offboard-session" ]; then ok; else bad "no-marker last-offboard legacy"; fi

# --- 2. Marker present but NOT in tmux (no pane) -> still legacy (safe fallback). ---
touch "$DIR/refs/.handoff-per-window"
unset TMUX_PANE
if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff.md" ]; then ok; else bad "marker-no-tmux falls back to legacy"; fi

# --- 3. Marker + a real tmux window named "🧠 wintest" -> scoped, glyph stripped. ---
if [ -x "$TMUX_BIN" ]; then
  SES="handoff-test-$$"
  "$TMUX_BIN" new-session -d -s "$SES" -n "wintest" -c "$DIR" 2>/dev/null
  PANE=$("$TMUX_BIN" list-panes -t "=$SES" -F '#{pane_id}' 2>/dev/null | head -1)
  "$TMUX_BIN" rename-window -t "$PANE" "🧠 wintest" 2>/dev/null
  export TMUX_PANE="$PANE"

  if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff--wintest.md" ]; then ok; else bad "scoped handoff (got $(handoff_path "$DIR"))"; fi
  if [ "$(offboard_pending_path "$DIR")" = "$DIR/.offboard-pending--wintest" ]; then ok; else bad "scoped pending"; fi
  if [ "$(last_offboard_path "$DIR")" = "$DIR/.claude/last-offboard-session--wintest" ]; then ok; else bad "scoped last-offboard"; fi

  # 4. handoff_read_path: scoped file absent -> legacy; present -> scoped.
  if [ "$(handoff_read_path "$DIR")" = "$DIR/refs/session-handoff.md" ]; then ok; else bad "read falls back to legacy when scoped absent"; fi
  touch "$DIR/refs/session-handoff--wintest.md"
  if [ "$(handoff_read_path "$DIR")" = "$DIR/refs/session-handoff--wintest.md" ]; then ok; else bad "read prefers scoped when present"; fi

  # 5. A different window name -> a different key (no cross-session collision).
  "$TMUX_BIN" rename-window -t "$PANE" "✅ elevate" 2>/dev/null
  if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff--elevate.md" ]; then ok; else bad "distinct window -> distinct key"; fi
else
  echo "PASS: $PASS/$PASS (tmux missing — scoped cases skipped)"; exit 0
fi

TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS/$TOTAL test cases"; exit 0; fi
echo "FAIL: $FAIL/$TOTAL test cases failed"; for n in "${FAILED[@]}"; do echo "  - $n"; done; exit 1
