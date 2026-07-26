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
SESSION4="pulse-notready-$$"
SESSION5="pulse-hatch-$$"
SESSION6="pulse-deadline-$$"
SESSION7="pulse-verdict-$$"
SESSION8="pulse-verdictnr-$$"
# Every session here is a throwaway running an INERT stub (cat / a bash loop) —
# this suite must never start a real `claude`. Interactive Claude sessions live
# only in the `work` and `zig-computer` tmux sessions.
trap '"$TMUX_BIN" kill-session -t "=$SESSION" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION2" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION3" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION4" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION5" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION6" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION7" 2>/dev/null; "$TMUX_BIN" kill-session -t "=$SESSION8" 2>/dev/null; rm -rf "$DIR"' EXIT

# The inert launch (`cat`) is NOT a TUI, so the default input-ready marker never
# appears. Since dotfiles-mrta a readiness timeout BOUNCES instead of injecting,
# so a non-TUI launcher must DISABLE the gate rather than time out through it —
# which is exactly what the empty marker is documented to do. Cases 8 and 10
# override both per-invocation to exercise the gate itself.
export PULSE_READY_MARKER=''
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

# 13. Readiness TIMEOUT bounces instead of injecting blind (dotfiles-mrta).
#
#     Observed 2026-07-25: a cold boot took ~60s to paint its composer, the gate
#     timed out at its 60s ceiling, typed into an empty composer, and the tick
#     was EATEN — 0% context, no work, no ledger row. "Inject anyway" is not
#     "try late" when there is nothing to type into; it is a silent loss, and a
#     concrete mechanism for the "fired but no ledger row" class.
#
#     Stub launcher, never a real claude session: a program that is alive and
#     holds the pane but NEVER prints the marker — which is exactly the shape of
#     a TUI that hasn't finished painting.
NEVERTUI="$DIR/nevertui.sh"
cat > "$NEVERTUI" <<'EOS'
# alive, holds the pane, and never prints the readiness marker
while IFS= read -r line; do printf '%s\n' "$line"; done
EOS
NR_BOUNCE=$(mktemp -d)
HARNESS_STATE_DIR="$NR_BOUNCE" PULSE_READY_MARKER='NEVER-APPEARS-MARKER-QQQ' PULSE_READY_TIMEOUT=3 \
  "$INJECT" --session "$SESSION4" --window pulse --dir "$DIR" \
  --launch "bash $NEVERTUI" --cmd "must-not-be-injected-13" --loop pulse-notready-loop >/dev/null 2>&1
NR_RC=$?
sleep 1
PANE4=$("$TMUX_BIN" list-panes -t "=$SESSION4" -a -F '#{window_name} #{pane_id}' 2>/dev/null | awk '$1=="pulse"{print $2; exit}')

# a. the tick is NOT typed into the unready pane
if "$TMUX_BIN" capture-pane -p -t "$PANE4" 2>/dev/null | grep -q "must-not-be-injected-13"; then
  bad "readiness timeout must NOT inject into an unready composer"
else
  ok
fi
# b. …and the bounce is RECORDED, so a tick that produced no work is
#    distinguishable from one that never fired (the whole point of the bead).
if grep -q '"reason":"not_ready"' "$NR_BOUNCE/pulse-bounces.jsonl" 2>/dev/null \
   && grep -q '"loop":"pulse-notready-loop"' "$NR_BOUNCE/pulse-bounces.jsonl" 2>/dev/null; then
  ok
else
  bad "readiness timeout writes a not_ready bounce record"
fi
# c. …and it exits 0 — a bounce is a deferral, not a unit failure. Exiting
#    non-zero would paint the timer red on a condition that resolves itself.
if [ "$NR_RC" -eq 0 ]; then ok; else bad "readiness-timeout bounce exits 0 (got $NR_RC)"; fi
"$TMUX_BIN" kill-session -t "=$SESSION4" 2>/dev/null

# 14. The escape hatch restores the old behavior verbatim. It exists for one
#     failure mode — Claude Code changing its footer text, which would make the
#     marker never match and bounce EVERY tick — and a guard that cannot be
#     turned off in an incident is one people rip out instead.
NR_BOUNCE2=$(mktemp -d)
HARNESS_STATE_DIR="$NR_BOUNCE2" PULSE_READY_MARKER='NEVER-APPEARS-MARKER-QQQ' PULSE_READY_TIMEOUT=3 \
  PULSE_READY_ON_TIMEOUT=inject \
  "$INJECT" --session "$SESSION5" --window pulse --dir "$DIR" \
  --launch "bash $NEVERTUI" --cmd "hatch-injected-14" --loop pulse-hatch-loop >/dev/null 2>&1
sleep 1
PANE5=$("$TMUX_BIN" list-panes -t "=$SESSION5" -a -F '#{window_name} #{pane_id}' 2>/dev/null | awk '$1=="pulse"{print $2; exit}')
if "$TMUX_BIN" capture-pane -p -t "$PANE5" 2>/dev/null | grep -q "hatch-injected-14"; then
  ok
else
  bad "PULSE_READY_ON_TIMEOUT=inject restores the pre-mrta blind inject"
fi
if [ -f "$NR_BOUNCE2/pulse-bounces.jsonl" ]; then
  bad "the escape hatch injected, so it must NOT also record a bounce"
else
  ok
fi
"$TMUX_BIN" kill-session -t "=$SESSION5" 2>/dev/null

# 15. The gate honors its advertised ceiling. It used to be `seq 1 $N` + `sleep
#     1`, but each iteration also pays for a capture-pane and a grep, so the
#     loop overshot: the 2026-07-25 incident logged "not seen after 60s" a
#     measured 63 seconds after launch. That drift matters now that the same
#     number decides whether to bounce, so the poll runs to a wall-clock
#     deadline. 3s ceiling must not become 5s+ of real waiting.
_d0=$(date +%s)
PULSE_READY_MARKER='NEVER-APPEARS-MARKER-QQQ' PULSE_READY_TIMEOUT=3 \
  "$INJECT" --session "$SESSION6" --window pulse --dir "$DIR" \
  --launch "bash $NEVERTUI" --cmd "deadline-probe-15" >/dev/null 2>&1
_dwait=$(( $(date +%s) - _d0 ))
# Budget: up to 30s liveness poll (the stub is bash, so it flips fast) + the 3s
# readiness ceiling. Assert the READINESS part did not blow past its ceiling.
if [ "$_dwait" -le 12 ]; then ok; else bad "readiness poll honors its ceiling (total wait ${_dwait}s for a 3s ceiling)"; fi
"$TMUX_BIN" kill-session -t "=$SESSION6" 2>/dev/null
rm -rf "$NR_BOUNCE" "$NR_BOUNCE2"

# 16. THE OUTCOME CONTRACT (dotfiles-q0qi). Exit code ≠ effect: this injector
#     exits 0 when it injected, when it BOUNCED (composer never ready), and when
#     it DEFERRED (🔔 window) — three different outcomes, one exit code. So every
#     terminal path must print exactly one `PULSE_INJECT_RESULT=<verdict>` line,
#     as the LAST line of STDOUT, and the exit codes must be UNCHANGED.
#
#     Each assertion below checks all three properties together (verdict + "last
#     line" + "exactly one"), plus the exit code, because a contract that holds
#     for the value but not the position is one a consumer still has to guess at.
#     Every run captures stdout ONLY (stderr to /dev/null) — that is the stream
#     the header promises, so if a marker ever moved to stderr these go red.
verdict_last() { printf '%s\n' "$1" | tail -n 1; }
verdict_count() { printf '%s\n' "$1" | grep -c '^PULSE_INJECT_RESULT='; }
# assert_verdict <label> <expected-verdict> <expected-rc> <actual-rc> <stdout>
assert_verdict() {
  local label=$1 want=$2 want_rc=$3 got_rc=$4 out=$5
  local last count
  last=$(verdict_last "$out")
  count=$(verdict_count "$out")
  if [ "$last" = "PULSE_INJECT_RESULT=$want" ]; then ok; else bad "$label: marker is the LAST stdout line and reads '$want' (got '$last')"; fi
  if [ "$count" -eq 1 ]; then ok; else bad "$label: exactly ONE marker line (got $count)"; fi
  if [ "$got_rc" -eq "$want_rc" ]; then ok; else bad "$label: exit code UNCHANGED at $want_rc (got $got_rc)"; fi
}

# a. success path -> injected, exit 0 (cold start into its own throwaway session)
V_OUT=$("$INJECT" --session "$SESSION7" --window pulse --dir "$DIR" --launch cat --cmd "verdict-tick-16a" 2>/dev/null)
V_RC=$?
assert_verdict "injected" injected 0 "$V_RC" "$V_OUT"
sleep 1
# Session-scoped on PURPOSE: `list-panes -a` lists the whole SERVER and ignores
# -t, so the older `awk '$1=="pulse"'` idiom above returns whichever session
# happens to sort first — which by now is $SESSION, not this one. Match the
# session name explicitly so the assertions below can't be about another pane.
PANE7=$("$TMUX_BIN" list-panes -a -F '#{session_name} #{window_name} #{pane_id}' 2>/dev/null \
  | awk -v s="$SESSION7" '$1==s && $2=="pulse"{print $3; exit}')
# …and the verdict is not a lie: the command really did land in the pane.
if "$TMUX_BIN" capture-pane -p -t "$PANE7" 2>/dev/null | grep -q "verdict-tick-16a"; then
  ok
else
  bad "the 'injected' verdict corresponds to a command that actually landed"
fi

# b. 🔔 defer -> deferred-blocked-on-human, still exit 0. THE live instance: a
#    homeowner button press into a 🔔-blocked operator window used to be
#    indistinguishable from a delivered one.
"$TMUX_BIN" rename-window -t "$PANE7" "🔔 pulse"
V_OUT=$("$INJECT" --session "$SESSION7" --window pulse --dir "$DIR" --launch cat --cmd "must-not-appear-16b" 2>/dev/null)
V_RC=$?
assert_verdict "deferred" deferred-blocked-on-human 0 "$V_RC" "$V_OUT"
if "$TMUX_BIN" capture-pane -p -t "$PANE7" 2>/dev/null | grep -q "must-not-appear-16b"; then
  bad "the 'deferred' verdict corresponds to a command that was NOT typed"
else
  ok
fi
"$TMUX_BIN" kill-session -t "=$SESSION7" 2>/dev/null

# c. readiness timeout -> bounced-not-ready, still exit 0 (NEVERTUI from case 13:
#    alive, holds the pane, never prints the marker).
V_BOUNCE=$(mktemp -d)
V_OUT=$(HARNESS_STATE_DIR="$V_BOUNCE" PULSE_READY_MARKER='NEVER-APPEARS-MARKER-QQQ' PULSE_READY_TIMEOUT=3 \
  "$INJECT" --session "$SESSION8" --window pulse --dir "$DIR" \
  --launch "bash $NEVERTUI" --cmd "must-not-appear-16c" 2>/dev/null)
V_RC=$?
assert_verdict "bounced" bounced-not-ready 0 "$V_RC" "$V_OUT"
"$TMUX_BIN" kill-session -t "=$SESSION8" 2>/dev/null
rm -rf "$V_BOUNCE"

# d. the argument + environment guards. These already exited non-zero, so the
#    marker is redundant for a caller reading `$?` — but a consumer that parses
#    ONLY the marker (the shape the header prescribes) must never hit a run with
#    no marker at all, or it cannot tell "failed" from "old injector".
V_OUT=$("$INJECT" --session "$SESSION" --window pulse --cmd "x" 2>/dev/null); V_RC=$?
assert_verdict "missing --dir" failed-usage 64 "$V_RC" "$V_OUT"

V_OUT=$("$INJECT" --bogus-flag 2>/dev/null); V_RC=$?
assert_verdict "unknown arg" failed-usage 64 "$V_RC" "$V_OUT"

V_OUT=$("$INJECT" --dir "$DIR/definitely-not-here" --cmd "x" 2>/dev/null); V_RC=$?
assert_verdict "--dir missing" failed-no-dir 66 "$V_RC" "$V_OUT"

# PULSE_TMUX_BIN is the test seam that makes the last two terminal paths
# reachable at all: an absent binary (69) and a tmux that refuses to create the
# session (70). Without it those two exits could only ever be reasoned about.
V_OUT=$(PULSE_TMUX_BIN="$DIR/no-such-tmux" "$INJECT" --dir "$DIR" --cmd "x" 2>/dev/null); V_RC=$?
assert_verdict "tmux absent" failed-no-tmux 69 "$V_RC" "$V_OUT"

FAKETMUX="$DIR/faketmux.sh"
cat > "$FAKETMUX" <<'EOS'
#!/bin/bash
# a tmux that is present and executable but fails every subcommand
exit 1
EOS
chmod +x "$FAKETMUX"
V_OUT=$(PULSE_TMUX_BIN="$FAKETMUX" "$INJECT" --session "pulse-nope-$$" --dir "$DIR" --cmd "x" 2>/dev/null); V_RC=$?
assert_verdict "session create fails" failed-no-session 70 "$V_RC" "$V_OUT"

# 17. The verdict marker goes to STDOUT, not stderr — the stream the header
#     promises and the only one a `OUT="$(pulse-inject.sh …)"` consumer reads.
#     Asserted head-on: with stdout discarded, stderr must carry NO marker.
V_ERR=$("$INJECT" --bogus-flag 2>&1 >/dev/null)
if printf '%s\n' "$V_ERR" | grep -q '^PULSE_INJECT_RESULT='; then
  bad "the verdict marker is on stdout, never stderr"
else
  ok
fi

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
