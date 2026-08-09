#!/bin/bash
# Test for api-stall-recover.sh — the killed-turn revival guard (dotfiles-r3sm).
#
# HERMETIC. Fake `tmux` and `curl` shims on PATH; HARNESS_STATE_DIR in a per-case
# tmpdir. The live tmux server is never contacted, no real pane is ever typed
# into, and the real gateway is never probed. Style mirrors test-pulse-retry.sh.
#
# THE FIXTURES ARE REAL. FIX_SENESCHAL and FIX_DOTFILES are the VERBATIM pane
# tails captured at 2026-08-09T15:11:01Z during the outage this guard exists for
# (~/.local/state/harness/api-error-captures.jsonl, rows `seneschal` and
# `dotfiles`), and FIX_OVERLOADED is a real `API Error: 529` tail from the same
# file. They are two genuinely different shapes: seneschal ends at an empty `❯`
# composer, dotfiles ends in a task-list overlay whose only composer marker is
# the `new task?` hint — a guard that only knew the first shape would have left
# the dotfiles seat stalled for the full 2.5 hours, which is exactly what
# happened.
#
# The shims read $ASRT_FAKE (a per-case control dir):
#   $ASRT_FAKE/panes        — `list-panes -a -F` output (pane<TAB>session<TAB>window)
#   $ASRT_FAKE/tails/<pane> — what `capture-pane -p -t <pane>` prints
#   $ASRT_FAKE/sendkeys     — every send-keys invocation, one per line, IN ORDER
#   $ASRT_FAKE/captures     — every capture-pane target, one per line
#   $ASRT_FAKE/codes        — one HTTP code per curl call (000 = connect failure)

set -u

ASR="$(cd "$(dirname "$0")" && pwd)/api-stall-recover.sh"
# A deliberately broken variant can be dropped in via ASR_UNDER_TEST (that is how
# the mutation demonstrations for repo rule 1 are driven); default is the real one.
ASR="${ASR_UNDER_TEST:-$ASR}"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
}

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# --- The real captured tails -------------------------------------------------
FIX_SENESCHAL=$(
  cat <<'EOF'

 ▐▛███▜▌   Claude Code v2.1.226
▝▜█████▛▘  Fable 5 · Claude Max
  ▘▘ ▝▝    ~/dotfiles


❯ /seneschal brief

● API Error: Unable to connect to API
  (ConnectionRefused)

✻ Worked for 2m 57s



─────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────
  🧠 [Fable 5] 📁 dotfiles | 📮 main ~1 | 🔗 https:…
  [----------] 0% | $0.00 | 🕰️  3m 1s | (me)
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ←…
EOF
)
FIX_DOTFILES=$(
  cat <<'EOF'

● Monitor event: "pico Tahoe upgrade: install
progress + restart cycle"

● Monitor "pico Tahoe upgrade: install progress +
restart cycle" stream ended

● API Error: Unable to connect to API
  (ConnectionRefused)

✻ Brewed for 3m 3s · 1 monitor still running

  7 tasks (4 done, 3 open)
  ◻ Cutover: unfreeze, /clear all windows…
  ◻ Maiden marshal: full harnessd drain
  ◻ Arm the marshal clockwork going forwa…
  ✔ Merge p89v guard after scrutiny
  ✔ Confirm peer design beads landed
   … +2 completed
              new task? /clear to save 492.9k tokens
─────────────────────────────────────────────────────
EOF
)
FIX_OVERLOADED=$(
  cat <<'EOF'

● Previous quiet mail tick committed the digest bump (5f753d1), so I'll follow that convention. Appending the ledger line now (decided last, after the scan resolved).

  Ran 1 shell command

● Both lints clean. Committing the digest bump + ledger together, then asserting registration.

  Ran 2 shell commands

● No bead for a quiet tick; this is pure state bookkeeping (ledger line + last_fetched_at), so the :card_file_box: exemption is the honest label.

  Ran 1 shell command

● API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (100.72.47.4:17017).

✻ Churned for 9m 47s

















─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  🧠 [Opus 5 (1M context)] 📁 autonoveld | 📮 master  | 🔗 https://github.com/azigler/autonoveld
  [#---------] 13% | $1.82 | 🕰️  9m 51s
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
)
# A pane doing perfectly ordinary work — no API Error anywhere in the tail.
FIX_HEALTHY=$(
  cat <<'EOF'
● Reading the manifest now.

  Ran 1 shell command

✻ Working for 12s (esc to interrupt)
EOF
)

# --- Fake binaries on PATH ---------------------------------------------------
BIN="$ROOT/bin"
mkdir -p "$BIN"

cat >"$BIN/fake-tmux" <<'EOTM'
#!/bin/bash
sub="${1:-}"
shift || true
case "$sub" in
  list-panes)
    [ -f "$ASRT_FAKE/panes" ] && cat "$ASRT_FAKE/panes"
    ;;
  capture-pane)
    pane=""
    while [ "$#" -gt 0 ]; do
      [ "$1" = "-t" ] && pane="${2:-}"
      shift
    done
    printf '%s\n' "$pane" >> "$ASRT_FAKE/captures"
    [ -f "$ASRT_FAKE/tails/$pane" ] && cat "$ASRT_FAKE/tails/$pane"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$ASRT_FAKE/sendkeys"
    ;;
esac
exit 0
EOTM

cat >"$BIN/fake-curl" <<'EOCURL'
#!/bin/bash
printf '%s\n' "$*" >> "$ASRT_FAKE/curl-calls"
n=$(wc -l < "$ASRT_FAKE/curl-calls" | tr -d ' ')
code=$(sed -n "${n}p" "$ASRT_FAKE/codes")
[ -n "$code" ] || code=$(tail -n 1 "$ASRT_FAKE/codes")
printf '%s' "$code"
[ "$code" = "000" ] && exit 7
exit 0
EOCURL

chmod +x "$BIN/fake-tmux" "$BIN/fake-curl"
export PATH="$BIN:$PATH"

# setup_case [http-code] — fresh control dir + state dir. Default code 401, the
# healthy signature of the gateway's transparent passthrough.
setup_case() {
  ASRT_FAKE=$(mktemp -d)
  export ASRT_FAKE
  mkdir -p "$ASRT_FAKE/tails"
  : >"$ASRT_FAKE/panes"
  : >"$ASRT_FAKE/sendkeys"
  : >"$ASRT_FAKE/captures"
  : >"$ASRT_FAKE/curl-calls"
  printf '%s\n' "${1:-401}" >"$ASRT_FAKE/codes"
  export HARNESS_STATE_DIR="$ASRT_FAKE/state"
  export ASR_TMUX="$BIN/fake-tmux"
  export ASR_CURL="$BIN/fake-curl"
  export ASR_SEND_SETTLE=0
  export ASR_COOLDOWN_MIN=15
  unset TMUX_PANE
}

# pane <id> <session> <window> <tail-text>
pane() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$ASRT_FAKE/panes"
  printf '%s\n' "$4" >"$ASRT_FAKE/tails/$1"
}

run_asr() {
  OUT=$("$ASR" 2>&1)
  RC=$?
  LAST=$(printf '%s\n' "$OUT" | tail -n 1)
}
sendkeys_count() { grep -c . "$ASRT_FAKE/sendkeys" | tr -d ' '; }

# ---------------------------------------------------------------------------
# Case 1: the REAL seneschal tail — killed turn, idle composer ⇒ nudged.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:1:skipped:0" ] && [ "$RC" = 10 ]; then
  ok
else
  bad "real seneschal tail ⇒ nudged, exit 10 (got '$LAST' rc=$RC)"
fi
# Text first, Enter SEPARATELY — the pulse-inject §4 mechanism, in that order.
# The `! grep ' Enter$'` on the first call is the part that matters: a combined
# burst (text and Enter in one send-keys) is exactly what some TUIs mis-handle,
# and it still produces two recorded calls, so counting alone would not see it.
if [ "$(sendkeys_count)" = "2" ] &&
  head -n 1 "$ASRT_FAKE/sendkeys" | grep -q -- '-t %1 -- api-connectivity-guard:' &&
  ! head -n 1 "$ASRT_FAKE/sendkeys" | grep -q ' Enter$' &&
  [ "$(tail -n 1 "$ASRT_FAKE/sendkeys")" = "-t %1 Enter" ]; then
  ok
else
  bad "nudge = send-keys TEXT then a separate Enter (got: $(tr '\n' '|' <"$ASRT_FAKE/sendkeys"))"
fi
if grep -q '"pane":"%1"' "$HARNESS_STATE_DIR/api-stall-recover-state.jsonl"; then
  ok
else
  bad "a nudge records the pane in the cooldown state"
fi

# ---------------------------------------------------------------------------
# Case 2: the REAL dotfiles tail — a DIFFERENT shape (task-list overlay, the
#   only composer marker is `new task?`) and it must be nudged too.
setup_case
pane '%2' work dotfiles "$FIX_DOTFILES"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:1:skipped:0" ] && [ "$(sendkeys_count)" = "2" ]; then
  ok
else
  bad "real dotfiles tail (task-list overlay) ⇒ nudged (got '$LAST', $(sendkeys_count) send-keys)"
fi

# ---------------------------------------------------------------------------
# Case 3: a live retry tail ⇒ hands off, the client is already handling it.
setup_case
pane '%3' work seneschal "$FIX_SENESCHAL
  Retrying... (attempt 2/10)"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ] && [ "$(sendkeys_count)" = "0" ] && [ "$RC" = 0 ]; then
  ok
else
  bad "retry tail ⇒ skipped, zero send-keys, exit 0 (got '$LAST' rc=$RC keys=$(sendkeys_count))"
fi

# ---------------------------------------------------------------------------
# Case 4: a 🔔 window ⇒ never. send-keys there feeds Zig's open modal dialog and
#   the Enter answers it with the default (pulse-inject §3.5).
setup_case
pane '%4' work '🔔 seneschal' "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ] && [ "$(sendkeys_count)" = "0" ]; then
  ok
else
  bad "🔔 window ⇒ skipped, zero send-keys (got '$LAST' keys=$(sendkeys_count))"
fi

# ---------------------------------------------------------------------------
# Case 5: an ordinary working pane ⇒ skipped.
setup_case
pane '%5' work explore "$FIX_HEALTHY"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ] && [ "$(sendkeys_count)" = "0" ] && [ "$RC" = 0 ]; then
  ok
else
  bad "healthy pane ⇒ skipped, zero send-keys, exit 0 (got '$LAST' rc=$RC)"
fi

# Case 5b: a connection error with a turn back IN FLIGHT ⇒ skipped.
setup_case
pane '%6' work seneschal "$FIX_SENESCHAL
✻ Reticulating… (14s · esc to interrupt)"
run_asr
if [ "$(sendkeys_count)" = "0" ]; then ok; else bad "in-flight turn ('esc to interrupt') ⇒ skipped"; fi

# Case 5c: a connection error the session has already moved PAST — no composer
#   marker after it at all ⇒ skipped. Typing into a pane that is not at an idle
#   prompt is the failure mode this requirement exists for.
setup_case
pane '%6' work seneschal "● API Error: Unable to connect to API
  (ConnectionRefused)
● Picking the thread back up on my own.
  Ran 1 shell command"
run_asr
if [ "$(sendkeys_count)" = "0" ]; then ok; else bad "no idle composer after the error ⇒ skipped"; fi

# ---------------------------------------------------------------------------
# Case 6: THE UPSTREAM IS STILL DOWN ⇒ not one pane is touched. Nudging into a
#   dead gateway just re-errors the session and burns its cooldown.
setup_case 000
pane '%7' work seneschal "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=upstream-down" ] && [ "$RC" = 0 ]; then ok; else bad "upstream down ⇒ upstream-down/exit0 (got '$LAST' rc=$RC)"; fi
if [ "$(sendkeys_count)" = "0" ] && [ "$(grep -c . "$ASRT_FAKE/captures")" = "0" ]; then
  ok
else
  bad "upstream down ⇒ zero send-keys AND zero pane captures (keys=$(sendkeys_count) caps=$(grep -c . "$ASRT_FAKE/captures"))"
fi

# ---------------------------------------------------------------------------
# Case 7: a real `API Error: 529 Overloaded` tail ⇒ NOT nudged. That is
#   harnessd's bell, and a settled 4xx/5xx may need a human.
setup_case
pane '%8' work digest "$FIX_OVERLOADED"
run_asr
if [ "$(sendkeys_count)" = "0" ] && [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ]; then
  ok
else
  bad "3-digit API Error (529) ⇒ skipped (got '$LAST' keys=$(sendkeys_count))"
fi
# Case 7a: PRECEDENCE — an error carrying BOTH a 3-digit code AND connection
#   words. Constructed, not captured (the real 529 tail has no connection words,
#   so it is skipped by the whitelist and proves nothing about this rule): a
#   proxy 503 that mentions connecting upstream is the shape where the two rules
#   disagree, and the code rule must win. A settled HTTP status is harnessd's
#   bell and may need a human; only a client-side connect failure is ours.
setup_case
pane '%8' work digest "● API Error: 503 Unable to connect to API (upstream connect error)

─────────────────────────────────────────────────────
❯ "
run_asr
if [ "$(sendkeys_count)" = "0" ]; then ok; else bad "a 3-digit code WINS over connection words in the same error ⇒ skipped"; fi

# Case 7b: an API Error that is neither a code nor connection-shaped ⇒ skipped.
#   The match list is a whitelist, not a fallback.
setup_case
pane '%8' work digest "● API Error: Cannot read properties of undefined (reading 'stream')

─────────────────────────────────────────────────────
❯ "
run_asr
if [ "$(sendkeys_count)" = "0" ]; then ok; else bad "an unrecognised API Error shape ⇒ skipped (whitelist, not fallback)"; fi

# ...and an OLD 529 further up the scrollback must not veto a fresh connection
# failure below it: only the LAST error block decides. ASR_TAIL_LINES is raised
# because the two real tails are 40 + 22 lines and the default 40-line window
# would simply truncate the 529 away — a case that passes because the thing it
# is about fell off the top proves nothing.
setup_case
pane '%9' work digest "$FIX_OVERLOADED
$FIX_SENESCHAL"
ASR_TAIL_LINES=200 run_asr
if [ "$(sendkeys_count)" = "2" ]; then ok; else bad "a stale 529 above a fresh ConnectionRefused must not veto the nudge"; fi

# ---------------------------------------------------------------------------
# Case 8: COOLDOWN across two consecutive runs — one nudge per outage per pane,
#   not one every two minutes.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
run_asr
run_asr
if [ "$(sendkeys_count)" = "2" ] && [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ]; then
  ok
else
  bad "cooldown: two runs, one nudge (got $(sendkeys_count) send-keys, second run '$LAST')"
fi
# With the cooldown expired, the same pane is eligible again.
ASR_COOLDOWN_MIN=0 run_asr
if [ "$(sendkeys_count)" = "4" ]; then ok; else bad "cooldown expired ⇒ eligible again (got $(sendkeys_count) send-keys)"; fi

# ---------------------------------------------------------------------------
# Case 9: a fleet — one stalled, one bell, one healthy, one retrying. Exactly
#   one nudge, and the counts add up.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
pane '%2' work '🔔 dotfiles' "$FIX_DOTFILES"
pane '%3' work explore "$FIX_HEALTHY"
pane '%4' work hevyd "$FIX_SENESCHAL
  Retrying... (attempt 3/10)"
run_asr
if [ "$LAST" = "API_STALL_RESULT=ok:nudged:1:skipped:3" ] && [ "$RC" = 10 ]; then
  ok
else
  bad "mixed fleet ⇒ ok:nudged:1:skipped:3 / exit 10 (got '$LAST' rc=$RC)"
fi
if [ "$(grep -c -- '-t %1' "$ASRT_FAKE/sendkeys")" = "2" ] && [ "$(sendkeys_count)" = "2" ]; then
  ok
else
  bad "mixed fleet ⇒ only the stalled pane is typed into"
fi

# ---------------------------------------------------------------------------
# Case 10: no tmux server at all ⇒ no-panes, exit 0, nothing typed.
setup_case
run_asr
if [ "$LAST" = "API_STALL_RESULT=no-panes" ] && [ "$RC" = 0 ] && [ "$(sendkeys_count)" = "0" ]; then
  ok
else
  bad "no panes ⇒ no-panes/exit0 (got '$LAST' rc=$RC)"
fi

# ---------------------------------------------------------------------------
# Case 11: the guard never types into its OWN pane.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
TMUX_PANE='%1' run_asr
if [ "$(sendkeys_count)" = "0" ] && [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ]; then
  ok
else
  bad "the guard's own pane is skipped (got '$LAST' keys=$(sendkeys_count))"
fi

# ---------------------------------------------------------------------------
# Case 12: no cooldown state can be kept ⇒ CHECKER BROKEN (exit 1) and NOT ONE
#   pane is touched. A guard with no memory of whom it nudged would nudge the
#   same panes again every two minutes forever.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
mkdir -p "$ASRT_FAKE/nowrite"
chmod 500 "$ASRT_FAKE/nowrite"
HARNESS_STATE_DIR="$ASRT_FAKE/nowrite/state" run_asr
chmod 700 "$ASRT_FAKE/nowrite"
if [ "$RC" = 1 ] && [ "$(sendkeys_count)" = "0" ] && [ "$(grep -c . "$ASRT_FAKE/captures")" = "0" ]; then
  ok
else
  bad "unwritable state dir ⇒ exit 1, nothing typed, nothing captured (rc=$RC keys=$(sendkeys_count))"
fi
if printf '%s\n' "$LAST" | grep -q '^API_STALL_RESULT='; then
  ok
else
  bad "even a broken checker ends with the result marker (got '$LAST')"
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
