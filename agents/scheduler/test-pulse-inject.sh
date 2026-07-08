#!/bin/bash
# Test for pulse-inject.sh — window discovery (lexicon-aware), creation,
# launch, and command injection, against a throwaway detached tmux
# session with an inert launch program (cat) instead of claude.
#
# Convention matches hooks/test/: executable bash, non-zero exit =
# failure, PASS/FAIL summary on the last line.

set -u

INJECT="$(cd "$(dirname "$0")" && pwd)/pulse-inject.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
if [ ! -x "$TMUX_BIN" ]; then
  echo "PASS: 0/0 test cases (tmux not installed — skipped)"
  exit 0
fi

SESSION="pulse-test-$$"
DIR=$(mktemp -d)
trap '"$TMUX_BIN" kill-session -t "=$SESSION" 2>/dev/null; rm -rf "$DIR"' EXIT

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

# 1. Cold start: no session at all → injector creates session + window,
#    launches `cat`, injects text.
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "hello-tick-1" >/dev/null 2>&1
sleep 1
if "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then ok; else bad "session created"; fi

PANE=$("$TMUX_BIN" list-panes -t "=$SESSION" -a -F '#{window_name} #{pane_id}' 2>/dev/null | awk '$1=="pulse"{print $2; exit}')
if [ -n "$PANE" ]; then ok; else bad "pulse window created"; fi

if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -q "hello-tick-1"; then
  ok
else
  bad "command injected on cold start"
fi

# 2. Warm tick: window + cat alive → injects directly (no relaunch).
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "hello-tick-2" >/dev/null 2>&1
sleep 1
if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -q "hello-tick-2"; then
  ok
else
  bad "command injected on warm tick"
fi

# 3. Lexicon-aware matching: the status hook renamed the window — the
#    injector must still find it, not create a duplicate. (🌀 is the
#    newest glyph; the same strip regex covers 🧠/✅/🔔.)
"$TMUX_BIN" rename-window -t "$PANE" "🌀 pulse"
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "hello-tick-3" >/dev/null 2>&1
sleep 1
WIN_COUNT=$("$TMUX_BIN" list-windows -t "=$SESSION" -F '#{window_name}' | sed -E 's/^(🧠|✅|🔔|🌀) ?//' | grep -cx "pulse")
if [ "$WIN_COUNT" -eq 1 ]; then ok; else bad "no duplicate window under lexicon prefix (count=$WIN_COUNT)"; fi
if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -q "hello-tick-3"; then
  ok
else
  bad "command injected under lexicon prefix"
fi

# 4. Missing --dir → hard failure, nothing created elsewhere.
if "$INJECT" --session "$SESSION" --window pulse --cmd "x" >/dev/null 2>&1; then
  bad "missing --dir should fail"
else
  ok
fi

# 5. /pulse commands get the absolute project dir appended, so a tick
#    anchors its ledger absolutely and never crosses ledgers on cwd drift.
#    (Non-/pulse cmds in cases 1-3 are deliberately left untouched.)
ABS_DIR=$(cd "$DIR" 2>/dev/null && pwd -P)
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "/pulse tick" >/dev/null 2>&1
sleep 1
if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -qF "/pulse tick $ABS_DIR"; then
  ok
else
  bad "/pulse cmd gets absolute dir appended"
fi

# 6. Modal-safety guard: a window blocked on Andrew (🔔, set by the status
#    hook on AskUserQuestion / permission prompts) must NOT receive the
#    command — injecting would feed the modal dialog and the Enter would
#    mis-answer it. The window is still FOUND (lexicon-aware), just not
#    injected into. (Case 3 proves a NON-🔔 glyph 🌀 still injects, so this
#    confirms the guard is 🔔-specific, not a blanket "any prefix" skip.)
"$TMUX_BIN" rename-window -t "$PANE" "🔔 pulse"
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "should-not-appear-tick-6" >/dev/null 2>&1
sleep 1
if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -q "should-not-appear-tick-6"; then
  bad "injection skipped when window is 🔔 (blocked on Andrew)"
else
  ok
fi
# …and the window was not duplicated by the deferred run.
WIN_COUNT6=$("$TMUX_BIN" list-windows -t "=$SESSION" -F '#{window_name}' | sed -E 's/^(🧠|✅|🔔|🌀) ?//' | grep -cx "pulse")
if [ "$WIN_COUNT6" -eq 1 ]; then ok; else bad "no duplicate window on deferred 🔔 run (count=$WIN_COUNT6)"; fi

# 7. Bounce record (harnessd-gf6): a 🔔-deferred tick invoked WITH --loop appends a
#    bounce record to the harness state dir (HARNESS_STATE_DIR override) so the state
#    bus renders 'bounced' instead of a false 'tick in flight'. Window is still 🔔.
BOUNCE_DIR=$(mktemp -d)
HARNESS_STATE_DIR="$BOUNCE_DIR" "$INJECT" --session "$SESSION" --window pulse --dir "$DIR" \
  --launch cat --cmd "should-not-appear-tick-7" --loop pulse-test-loop >/dev/null 2>&1
if grep -q '"loop":"pulse-test-loop"' "$BOUNCE_DIR/pulse-bounces.jsonl" 2>/dev/null \
   && grep -q '"reason":"blocked_on_andrew"' "$BOUNCE_DIR/pulse-bounces.jsonl" 2>/dev/null; then
  ok
else
  bad "bounce record written on 🔔 defer with --loop"
fi
# …and the tick is still NOT injected (defer still holds with --loop present).
if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -q "should-not-appear-tick-7"; then
  bad "injection still skipped on 🔔 defer when --loop is passed"
else
  ok
fi
# …and WITHOUT --loop, a 🔔 defer writes NO bounce file (backward compat).
BOUNCE_DIR2=$(mktemp -d)
HARNESS_STATE_DIR="$BOUNCE_DIR2" "$INJECT" --session "$SESSION" --window pulse --dir "$DIR" \
  --launch cat --cmd "should-not-appear-tick-7b" >/dev/null 2>&1
if [ -f "$BOUNCE_DIR2/pulse-bounces.jsonl" ]; then
  bad "no bounce file written without --loop (backward compat)"
else
  ok
fi
rm -rf "$BOUNCE_DIR" "$BOUNCE_DIR2"

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
