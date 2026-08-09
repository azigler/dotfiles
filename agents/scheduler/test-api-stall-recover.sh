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
#   $ASRT_FAKE/panes        — `list-panes -a -F` output
#                             (pane<TAB>session<TAB>window<TAB>current_command)
#   $ASRT_FAKE/tails/<pane> — what `capture-pane -p -t <pane>` prints
#   $ASRT_FAKE/sendkeys     — every send-keys invocation, one per line, IN ORDER
#   $ASRT_FAKE/captures     — every capture-pane target, one per line
#   $ASRT_FAKE/codes        — one probe outcome per curl call: `<code>` alone
#                             (000 ⇒ rc 7, i.e. refused) or the explicit triple
#                             `<code> <rc> <time_connect>`. The three real shapes,
#                             measured with curl on 2026-08-09:
#                               refused             000 7  0.000000
#                               connect timeout     000 28 0.000000
#                               connected-then-slow 000 28 0.000278

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
line=$(sed -n "${n}p" "$ASRT_FAKE/codes")
[ -n "$line" ] || line=$(tail -n 1 "$ASRT_FAKE/codes")
set -- $line
code="$1"; rc="${2:-}"; tconn="${3:-}"
if [ -z "$rc" ]; then
  if [ "$code" = "000" ]; then rc=7; tconn=0.000000; else rc=0; tconn=0.001234; fi
fi
printf '%s %s' "$code" "$tconn"
exit "$rc"
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

# pane <id> <session> <window> <tail-text> [pane_current_command]
# The command defaults to `claude` — the ordinary seat. Pass `zsh` (or anything
# else) to build a pane that is NOT a Claude Code session.
pane() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${5:-claude}" >>"$ASRT_FAKE/panes"
  printf '%s\n' "$4" >"$ASRT_FAKE/tails/$1"
}
log_skips() { # how many per-pane skip reasons reached the log file
  local f="$HARNESS_STATE_DIR/api-stall-recover.log"
  [ -f "$f" ] && grep -c ' skip %' "$f" | tr -d ' ' || echo 0
}
log_verdicts() {
  local f="$HARNESS_STATE_DIR/api-stall-recover.log"
  [ -f "$f" ] && grep -c 'API_STALL_RESULT\|ok:nudged:' "$f" | tr -d ' ' || echo 0
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
# Case 13: IDENTITY BEFORE CONTENT — the reviewer's demonstration, 2026-08-09.
#   A plain zsh pane that is merely DISPLAYING captured error text (someone
#   `cat`s api-error-captures.jsonl, or opens this suite's own fixtures) plus
#   Zig's p10k `❯` prompt satisfies every content rule. Without the identity
#   gate the guard types a paragraph of English into a raw shell, which RUNS it.
setup_case
pane '%1' work shell "$FIX_SENESCHAL" zsh
run_asr
if [ "$(sendkeys_count)" = "0" ] && [ "$LAST" = "API_STALL_RESULT=ok:nudged:0:skipped:1" ]; then
  ok
else
  bad "a zsh pane displaying error text is NOT a claude pane ⇒ skipped (got '$LAST' keys=$(sendkeys_count))"
fi
if [ "$(grep -c . "$ASRT_FAKE/captures")" = "0" ]; then
  ok
else
  bad "a non-claude pane is refused BEFORE capture-pane — its scrollback is none of the guard's business"
fi
# The paired control: byte-identical content, `claude` in the foreground ⇒ nudged.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL" claude
run_asr
if [ "$(sendkeys_count)" = "2" ]; then ok; else bad "control: the SAME content on a claude pane IS nudged"; fi
# bwrap is the digest seat's launcher (the tick-jail) and digest was one of the
# four seats that stalled on 2026-08-09 — excluding it would leave a victim of
# the founding incident unprotected.
setup_case
pane '%1' work digest "$FIX_SENESCHAL" bwrap
run_asr
if [ "$(sendkeys_count)" = "2" ]; then ok; else bad "bwrap (the tick-jail launcher, digest's seat) counts as a claude pane"; fi
# ...and the allow-list is a knob, not a hardcode.
setup_case
pane '%1' work weird "$FIX_SENESCHAL" mystery-launcher
ASR_PANE_CMDS='claude mystery-launcher' run_asr
if [ "$(sendkeys_count)" = "2" ]; then ok; else bad "ASR_PANE_CMDS extends the allow-list"; fi

# ---------------------------------------------------------------------------
# Case 14: SLOW IS NOT UP. curl prints 000 for a timeout as well as a refusal;
#   a gateway that accepted the connection and then stalled is not somewhere to
#   send four sessions — they would re-error and burn their cooldowns.
setup_case '000 28 0.000278'
pane '%1' work seneschal "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=upstream-down" ] && [ "$(sendkeys_count)" = "0" ] && [ "$(grep -c . "$ASRT_FAKE/captures")" = "0" ]; then
  ok
else
  bad "connected-but-slow upstream ⇒ upstream-down, no captures, no nudges (got '$LAST')"
fi
# A connect-phase timeout is likewise not cleanly up.
setup_case '000 28 0.000000'
pane '%1' work seneschal "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=upstream-down" ] && [ "$(sendkeys_count)" = "0" ]; then
  ok
else
  bad "connect-phase timeout ⇒ upstream-down, no nudges (got '$LAST')"
fi
# And the sharp one: a REAL HTTP code with a NON-ZERO curl exit — headers came
# back and then the transfer timed out. The body says 401, which looks exactly
# like health; only the exit code says the gateway is limping. Reading the code
# alone would send every stalled seat into it.
setup_case '401 28 0.001234'
pane '%1' work seneschal "$FIX_SENESCHAL"
run_asr
if [ "$LAST" = "API_STALL_RESULT=upstream-down" ] && [ "$(sendkeys_count)" = "0" ]; then
  ok
else
  bad "a 401 with curl rc 28 is NOT cleanly up ⇒ upstream-down, no nudges (got '$LAST')"
fi

# ---------------------------------------------------------------------------
# Case 15: FAIL-CLOSED ON ITS OWN CRASH. An unset HOME makes the config block's
#   `${HARNESS_STATE_DIR:-$HOME/...}` an unbound expansion under `set -u`, which
#   aborts the shell mid-flight — a real abort, not a simulated one. Because the
#   verdict starts at checker-broken and the trap is armed FIRST, that reads as
#   a failed unit instead of a silent green one.
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
OUT=$(env -u HOME -u HARNESS_STATE_DIR "$ASR" 2>&1)
RC=$?
LAST=$(printf '%s\n' "$OUT" | tail -n 1)
if [ "$RC" = 1 ] && [ "$LAST" = "API_STALL_RESULT=checker-broken" ] && [ "$(sendkeys_count)" = "0" ]; then
  ok
else
  bad "a mid-flight abort ⇒ checker-broken/exit1, nothing typed (rc=$RC last='$LAST')"
fi

# ---------------------------------------------------------------------------
# Case 16: THE LOG IS BOUNDED. ~30 panes × 720 runs/day of per-pane skip lines
#   is ~20k lines a day saying nothing happened. Quiet runs log the verdict and
#   not the skips; a run that nudged logs both; ASR_VERBOSE=1 logs both.
setup_case
pane '%1' work explore "$FIX_HEALTHY"
pane '%2' work shell "$FIX_SENESCHAL" zsh
run_asr
if [ "$(log_skips)" = "0" ] && [ "$(log_verdicts)" -ge 1 ]; then
  ok
else
  bad "a quiet run logs the verdict but no per-pane skips (skips=$(log_skips) verdicts=$(log_verdicts))"
fi
setup_case
pane '%1' work explore "$FIX_HEALTHY"
pane '%2' work shell "$FIX_SENESCHAL" zsh
ASR_VERBOSE=1 run_asr
if [ "$(log_skips)" = "2" ]; then ok; else bad "ASR_VERBOSE=1 logs every skip reason (got $(log_skips))"; fi
setup_case
pane '%1' work seneschal "$FIX_SENESCHAL"
pane '%2' work explore "$FIX_HEALTHY"
run_asr
if [ "$(log_skips)" = "1" ]; then ok; else bad "a run that NUDGED flushes the skips too (got $(log_skips))"; fi

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
