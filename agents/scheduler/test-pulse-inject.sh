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
SESSION2="pulse-ready-$$"
SESSION3="pulse-fresh-$$"
DIR=$(mktemp -d)
trap '"$TMUX_BIN" kill-session -t "=$SESSION" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION2" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION3" 2>/dev/null; rm -rf "$DIR"' EXIT

# The inert launch (`cat`) is NOT a TUI, so the default input-ready marker never
# appears; cap the readiness-poll ceiling so cold-start cases fall back fast
# instead of waiting the production default. Case 8 overrides this per-invocation.
export PULSE_READY_TIMEOUT=2

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

# 8. Input-readiness gate (the ha-portal cold-boot fix): on a cold launch the
#    injector waits for PULSE_READY_MARKER — the "TUI is ready for input" signal
#    (Claude Code's composer footer in prod) — BEFORE typing, so keystrokes are
#    not eaten by a still-initializing TUI. Simulate a slow TUI: a launch that
#    prints the marker only after a delay, then reads stdin (echoing it, like a
#    composer). Assert (a) the cmd lands, and (b) the injector actually WAITED for
#    the delayed marker (elapsed covers the delay) rather than injecting blindly.
SLOWTUI="$DIR/slowtui.sh"
cat > "$SLOWTUI" <<'EOS'
sleep 4
echo "TUI-INPUT-READY-MARKER-XYZ"
while IFS= read -r line; do printf '%s\n' "$line"; done
EOS
_t0=$(date +%s)
PULSE_READY_MARKER='TUI-INPUT-READY-MARKER-XYZ' PULSE_READY_TIMEOUT=20 \
  "$INJECT" --session "$SESSION2" --window pulse --dir "$DIR" \
  --launch "bash $SLOWTUI" --cmd "ready-gated-tick" >/dev/null 2>&1
_elapsed=$(( $(date +%s) - _t0 ))
PANE2=$("$TMUX_BIN" list-panes -t "=$SESSION2" -a -F '#{window_name} #{pane_id}' 2>/dev/null | awk '$1=="pulse"{print $2; exit}')
if "$TMUX_BIN" capture-pane -p -t "$PANE2" 2>/dev/null | grep -q "ready-gated-tick"; then
  ok
else
  bad "cmd injected once the readiness marker appeared"
fi
if [ "$_elapsed" -ge 3 ]; then
  ok
else
  bad "injector waited for the delayed readiness marker (elapsed=${_elapsed}s)"
fi
"$TMUX_BIN" kill-session -t "=$SESSION2" 2>/dev/null

# 9. note() is atomic under concurrent writers (dotfiles-0lm3). Two ticks
#     firing in the same second (pulse-explore + pulse-di-thursday both fire at
#     13:00 UTC) must not braid into an unparseable record. Assert: every line
#     matches `<utc-ts> [pid] <text>`, and each writer's lines are recoverable
#     as a contiguous group by pid — the property a bare flock does NOT give.
CONC_LOG=$(mktemp -d)/pulse-inject.log
CONC_SRC=$(mktemp -d)/note.sh
{
  echo 'set -uo pipefail'
  echo "LOG=$CONC_LOG"
  # extract the real note() implementation from the injector — test the shipped
  # code, not a copy that can drift.
  awk '/^note\(\) \{/,/^\}/' "$INJECT"
  echo 'for i in $(seq 1 200); do note "tick: session=work window=$1 dir=/x cmd=/pulse tick padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-padding-$i"; done'
} > "$CONC_SRC"
bash "$CONC_SRC" alpha &
_p1=$!
bash "$CONC_SRC" bravo &
_p2=$!
wait "$_p1" "$_p2"
CONC_TOTAL=$(wc -l < "$CONC_LOG")
CONC_GOOD=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \[[0-9]+\] tick: session=work window=(alpha|bravo) .*-[0-9]+$' "$CONC_LOG")
if [ "$CONC_TOTAL" -eq 400 ] && [ "$CONC_GOOD" -eq 400 ]; then
  ok
else
  bad "concurrent note(): every line parses (total=$CONC_TOTAL parsed=$CONC_GOOD, expected 400/400)"
fi
# each writer's 200 lines are individually recoverable by its pid tag
CONC_PIDS=$(sed -E 's/^[^ ]+ \[([0-9]+)\].*/\1/' "$CONC_LOG" | sort -u | wc -l)
CONC_PERPID=$(sed -E 's/^[^ ]+ \[([0-9]+)\].*/\1/' "$CONC_LOG" | sort | uniq -c | awk '{print $1}' | sort -u)
if [ "$CONC_PIDS" -eq 2 ] && [ "$CONC_PERPID" = "200" ]; then
  ok
else
  bad "concurrent note(): records stay attributable per writer (pids=$CONC_PIDS counts=$CONC_PERPID)"
fi
rm -rf "$(dirname "$CONC_LOG")" "$(dirname "$CONC_SRC")"

# 10. --fresh (dotfiles-6ycc): warm process, cold context. On a WARM pane the
#    injector sends /clear before the tick command, into the SAME window, and
#    the command still lands after it. Order matters — /clear must precede.
"$TMUX_BIN" rename-window -t "$PANE" "pulse"
"$TMUX_BIN" send-keys -t "$PANE" "FENCE9-fresh-marker" Enter   # scrollback fence
sleep 0.5
PULSE_FRESH_SETTLE=1 "$INJECT" --session "$SESSION" --window pulse --dir "$DIR" \
  --launch cat --cmd "fresh-tick-9" --fresh >/dev/null 2>&1
sleep 1
FRESH_TAIL=$("$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | sed -n '/FENCE9-fresh-marker/,$p')
if printf '%s\n' "$FRESH_TAIL" | grep -q '/clear'; then ok; else bad "--fresh sends /clear on a warm pane"; fi
if printf '%s\n' "$FRESH_TAIL" | grep -q 'fresh-tick-9'; then ok; else bad "--fresh still injects the tick command"; fi
_clear_ln=$(printf '%s\n' "$FRESH_TAIL" | grep -n '/clear' | head -1 | cut -d: -f1)
_cmd_ln=$(printf '%s\n' "$FRESH_TAIL" | grep -n 'fresh-tick-9' | head -1 | cut -d: -f1)
if [ -n "$_clear_ln" ] && [ -n "$_cmd_ln" ] && [ "$_clear_ln" -lt "$_cmd_ln" ]; then
  ok
else
  bad "--fresh sends /clear BEFORE the tick command (clear=$_clear_ln cmd=$_cmd_ln)"
fi
# …and the window was not duplicated / relaunched.
WIN_COUNT9=$("$TMUX_BIN" list-windows -t "=$SESSION" -F '#{window_name}' | sed -E 's/^(🧠|✅|🔔|🌀) ?//' | grep -cx "pulse")
if [ "$WIN_COUNT9" -eq 1 ]; then ok; else bad "--fresh lands in the same durable window (count=$WIN_COUNT9)"; fi

# 11. --fresh is OPT-IN: without the flag, no /clear is ever sent (default
#     behavior byte-for-byte unchanged for every loop that doesn't ask).
"$TMUX_BIN" send-keys -t "$PANE" "FENCE10-nofresh-marker" Enter
sleep 0.5
"$INJECT" --session "$SESSION" --window pulse --dir "$DIR" --launch cat --cmd "plain-tick-10" >/dev/null 2>&1
sleep 1
NOFRESH_TAIL=$("$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | sed -n '/FENCE10-nofresh-marker/,$p')
if printf '%s\n' "$NOFRESH_TAIL" | grep -q '/clear'; then
  bad "no --fresh => no /clear (opt-in, default off)"
else
  ok
fi
if printf '%s\n' "$NOFRESH_TAIL" | grep -q 'plain-tick-10'; then ok; else bad "default path still injects"; fi

# 12. --fresh is a NO-OP on a cold launch (the context is already fresh) and
#     must NOT fire on a 🔔-deferred tick (the modal guard wins — clearing
#     there would feed the dialog and wipe a session blocked on Andrew).
PULSE_READY_MARKER='' PULSE_FRESH_SETTLE=1 "$INJECT" --session "$SESSION3" --window pulse \
  --dir "$DIR" --launch cat --cmd "cold-fresh-tick-11" --fresh >/dev/null 2>&1
sleep 1
PANE3=$("$TMUX_BIN" list-panes -t "=$SESSION3" -a -F '#{window_name} #{pane_id}' 2>/dev/null | awk '$1=="pulse"{print $2; exit}')
if "$TMUX_BIN" capture-pane -p -t "$PANE3" 2>/dev/null | grep -q '/clear'; then
  bad "--fresh is a no-op on a cold launch (no /clear)"
else
  ok
fi
if "$TMUX_BIN" capture-pane -p -t "$PANE3" 2>/dev/null | grep -q "cold-fresh-tick-11"; then ok; else bad "--fresh cold launch still injects"; fi
"$TMUX_BIN" rename-window -t "$PANE3" "🔔 pulse"
PULSE_FRESH_SETTLE=1 "$INJECT" --session "$SESSION3" --window pulse --dir "$DIR" \
  --launch cat --cmd "should-not-appear-tick-11" --fresh >/dev/null 2>&1
sleep 1
if "$TMUX_BIN" capture-pane -p -t "$PANE3" 2>/dev/null | grep -q '/clear'; then
  bad "🔔 defer beats --fresh (no /clear into a modal dialog)"
else
  ok
fi
if "$TMUX_BIN" capture-pane -p -t "$PANE3" 2>/dev/null | grep -q "should-not-appear-tick-11"; then
  bad "🔔 defer beats --fresh (no injection)"
else
  ok
fi
"$TMUX_BIN" kill-session -t "=$SESSION3" 2>/dev/null

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
