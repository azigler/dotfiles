#!/usr/bin/env bash
# api-stall-recover — the keep wakes the seats a dead upstream killed.
#
# WHY THIS EXISTS. 2026-08-09 (dotfiles-kviw): the agentgateway relay went away
# for two and a half hours, and four sessions — seneschal, digest, hevyd,
# dotfiles — each took an `API Error: Unable to connect to API
# (ConnectionRefused)` mid-turn and then sat at an idle prompt until a human
# noticed. Claude Code does NOT resume a turn killed that way: the turn is gone,
# the composer comes back empty, and the tmux glyph stays 🧠 — so there was no
# bell, no retry, and no signal of any kind. The work simply stopped. Ground
# truth for all four pane tails is ~/.local/state/harness/api-error-captures.jsonl
# (the 2026-08-09T15:1x rows), and two of them are verbatim fixtures in the suite.
#
# The recovery for a killed turn is a NEW turn, which is the established
# pulse-inject mechanism: send-keys the text, pause, send-keys Enter. This guard
# does exactly that and nothing else.
#
# THE ORDER OF THE PAIR IS LOAD-BEARING. gateway-health.sh restores the upstream
# on the EVEN minutes; this runs on the ODD ones. Nudging a session into a
# gateway that is still down just re-errors it, burns the cooldown, and leaves
# the pane exactly as stuck — so step one here is the SAME probe gateway-health
# uses, and a probe that does not answer ends the run without touching a single
# pane. That is why neither timer carries RandomizedDelaySec.
#
# OUTCOME CONTRACT. The last line is always
#
#     API_STALL_RESULT=<ok:nudged:N:skipped:M|upstream-down|no-panes>
#
# Exit codes: 0 nothing needed (including upstream-down and no-panes) · 10 at
# least one session had to be revived · anything else, THIS CHECKER is broken.
# The unit does not list 10 in SuccessExitStatus, so a nudge lands in
# `systemctl --user --failed` — same posture as pico-health, same reasoning as
# gateway-health's `restored`: a seat that had to be resuscitated by a timer is
# news. `upstream-down` is deliberately NOT a finding here: gateway-health owns
# that fact and is already failing loudly about it, and two units alarming on
# one outage is how alarm fatigue starts.
#
# ⚠️ IDENTITY BEFORE CONTENT — THE PANE MUST BE RUNNING CLAUDE CODE.
# Everything below this line is a judgement about TEXT ON A SCREEN, and text is
# not identity. A plain zsh pane that merely DISPLAYS an error — someone `cat`s
# api-error-captures.jsonl, greps a log, opens this repo's own test fixtures,
# `git show`s this commit — presents a connection-shaped "API Error:" and, under
# Zig's p10k prompt, an `❯` right after it. Every content rule below then passes
# and the guard types a paragraph of English into a raw shell, which runs it.
# (Caught in adversarial review, 2026-08-09, demonstrated against this script.)
#
# So the FIRST gate is `#{pane_current_command}`, and it is an ALLOW-list, not a
# shell denylist — a denylist is wrong by construction here, because the set of
# things that are not a claude pane is open-ended (vim, less, ssh, python, a new
# shell nobody has heard of) while the set that IS one is small and knowable.
# Measured on this fleet, 2026-08-09, `tmux list-panes -a -F
# '#{pane_current_command}'` over all 8 live seats:
#
#   claude  ×7   the ordinary seat
#   bwrap   ×1   the digest seat — it runs claude inside the tick-jail sandbox,
#                so bwrap is what tmux sees. digest was one of the FOUR seats
#                that stalled on 2026-08-09, so excluding bwrap would leave a
#                victim of the founding incident unprotected.
#   node         NOT observed here, allowed anyway: Claude Code is a node
#                program and a pane launched without the wrapper presents as
#                `node`. Belt and braces, and cheap — a node pane still has to
#                pass every content rule below.
#
# Extend with ASR_PANE_CMDS if the fleet grows a new launcher; do not "fix" a
# missed nudge by deleting this gate.
#
# WHAT COUNTS AS STALLED — conservatively, because a false nudge types into a
# live session. All of:
#   · the tail's LAST `API Error:` block is CONNECTION-shaped ("Unable to
#     connect to API", "Connection refused", "ConnectionRefused");
#   · it is NOT a 3-digit HTTP error ("API Error: 529 Overloaded", "API Error:
#     400 ..."). Those are harnessd's bell, and a settled 4xx/5xx may be
#     something a human must answer — re-running the turn could repeat a
#     rejected request or an overload;
#   · no live retry tail ("Retrying", "attempt N/M") — the client is already
#     handling it;
#   · no in-flight turn ("esc to interrupt") — something IS running;
#   · a composer marker after the error ("❯", "new task?") — the session really
#     is back at an idle prompt.
# Only the LAST error block is read, so an old 529 higher in the scrollback
# cannot veto a fresh connection failure below it.
#
# AND THREE THINGS IT WILL NOT TOUCH:
#   · a 🔔 window — blocked on Zig, sitting in a modal dialog, where send-keys
#     feeds the DIALOG and the Enter answers his open question with the default
#     (pulse-inject.sh §3.5, and pulse-retry.sh's same refusal). Never inject
#     into a bell;
#   · a pane nudged within ASR_COOLDOWN_MIN — one nudge per outage per pane, not
#     one every two minutes;
#   · its own pane, if it somehow has one.
#
# THE UPSTREAM PROBE IS gateway-health's, RC-BRANCHING INCLUDED. `000` is not
# one fact: refused (rc 7) and timed-out (rc 28) print the same body, and a
# gateway that ACCEPTED the connection and is merely slow is alive. Only a
# CLEANLY up probe (rc 0, a real HTTP status — 401 is the healthy signature of
# the transparent passthrough) may lead to a nudge. Down and degraded both end
# the run untouched under the `upstream-down` marker, which the contract fixes
# at three values; the log line carries which of the two it was. Nudging into a
# gateway that is not cleanly up re-errors the session AND burns its 15-minute
# cooldown, so the whole recovery is spent for nothing.
#
# Knobs (all env, all with defaults, each one a test seam):
#   ASR_TMUX          the tmux binary                (tmux)
#   ASR_CURL          the probe binary               (curl)
#   ASR_PROBE_URL     the upstream door              (http://100.72.47.4:17017/claude/v1/models)
#   ASR_PROBE_CONNECT curl --connect-timeout         (5)
#   ASR_PROBE_MAX_TIME curl -m, total budget         (20)
#   ASR_PANE_CMDS     pane_current_command allow-list (claude bwrap node)
#   HARNESS_STATE_DIR state + log directory          (~/.local/state/harness)
#   ASR_LOG           the action log                 (<state-dir>/api-stall-recover.log)
#   ASR_COOLDOWN_MIN  minutes between nudges/pane    (15)
#   ASR_TAIL_LINES    pane tail examined             (40)
#   ASR_SEND_SETTLE   pause between text and Enter   (0.3)
#   ASR_VERBOSE       log every per-pane skip reason (0 — see the log policy)
#
# LOG POLICY, because a 2-minute timer writes forever. Nudges, errors and the
# run's verdict are logged ALWAYS. Per-pane SKIP reasons are buffered and only
# flushed when something was actually nudged this run (that is when you want to
# know what else was on the screen) or when ASR_VERBOSE=1. At ~30 panes × 720
# runs a day, logging every skip would be ~20k lines a day, forever, to say
# "nothing happened" — and a log nobody can read is a log nobody reads.

set -uo pipefail

# FAIL-CLOSED, AND THE ORDER HERE IS THE MECHANISM. The verdict starts at
# `checker-broken` and the EXIT trap is armed BEFORE anything that can fail —
# before the config block, which is itself a live hazard: every default below is
# a `${X:-...}` expansion under `set -u`, so an unset HOME (or any later
# unbound reference, anywhere in the loop) aborts the shell mid-flight. Armed
# late, that abort produces NO result line and exit 0-or-1 by accident; armed
# here, it produces `API_STALL_RESULT=checker-broken` and exit 1, which is a
# failed unit. Only the deliberate paths below may set a green verdict.
RESULT="checker-broken"
NUDGED=0
SKIPPED=0
CHECKER_BROKEN=0

# shellcheck disable=SC2317  # invoked via the EXIT trap
finish() {
  rc=$?
  if [ "$RESULT" = "checker-broken" ]; then
    printf 'api-stall-recover: THIS CHECKER did not reach a verdict — it aborted\n' >&2
    printf '                   before deciding anything. No pane was nudged.\n' >&2
  fi
  printf 'API_STALL_RESULT=%s\n' "$RESULT"
  [ "$CHECKER_BROKEN" -ne 0 ] && exit 1
  case "$RESULT" in
  upstream-down | no-panes) exit 0 ;;
  ok:*) if [ "$NUDGED" -gt 0 ]; then exit 10; else exit 0; fi ;;
  *) exit "$((rc == 0 ? 1 : rc))" ;; # checker-broken, or the checker lost the plot
  esac
}
trap finish EXIT

TMUX_BIN="${ASR_TMUX:-tmux}"
CURL_BIN="${ASR_CURL:-curl}"
PROBE_URL="${ASR_PROBE_URL:-http://100.72.47.4:17017/claude/v1/models}"
PROBE_CONNECT="${ASR_PROBE_CONNECT:-5}"
PROBE_MAX_TIME="${ASR_PROBE_MAX_TIME:-20}"
PANE_CMDS="${ASR_PANE_CMDS:-claude bwrap node}"
STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
LOG="${ASR_LOG:-$STATE_DIR/api-stall-recover.log}"
STATE="$STATE_DIR/api-stall-recover-state.jsonl"
COOLDOWN_MIN="${ASR_COOLDOWN_MIN:-15}"
TAIL_LINES="${ASR_TAIL_LINES:-40}"
SEND_SETTLE="${ASR_SEND_SETTLE:-0.3}"
VERBOSE="${ASR_VERBOSE:-0}"

NUDGE='api-connectivity-guard: your previous turn died with a connection error to the API (upstream outage, since restored and verified). Resume the interrupted work — if the dead turn was an injected command/tick, re-run that command; do not invent new work.'

note() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  printf '  %s\n' "$*"
}

# The state directory is a PRECONDITION, not a nicety: without the cooldown file
# this guard has no memory of whom it nudged, and it would nudge the same panes
# again every two minutes forever. So this is a hard stop, before any pane is
# read — a broken checker that touches nothing.
mkdir -p "$STATE_DIR" || {
  printf 'api-stall-recover: cannot create the state directory %s — refusing to\n' "$STATE_DIR" >&2
  printf '                   nudge anything without a cooldown to remember it by.\n' >&2
  CHECKER_BROKEN=1
  exit 1
}

# --- 1. Is the upstream CLEANLY back? ---------------------------------------
# gateway-health.sh's probe, verbatim in its reasoning: ANY HTTP status means
# the relay is listening (401 is the healthy signature of the transparent
# passthrough), but `000` is three different facts and only the exit code tells
# them apart — rc 7 refused, rc 28 with time_connect 0 a connect-phase timeout,
# rc 28 with a non-zero time_connect a gateway that ACCEPTED the connection and
# is merely slow. Only a CLEANLY up probe earns a nudge; the other two both end
# the run untouched. No `2>/dev/null` — curl is output-bearing here and a
# suppressed failure would read as an outage (repo rule 3).
PROBE_OUT=$("$CURL_BIN" -s -o /dev/null --connect-timeout "$PROBE_CONNECT" -m "$PROBE_MAX_TIME" \
  -w '%{http_code} %{time_connect}' "$PROBE_URL")
PROBE_RC=$?
CODE="${PROBE_OUT%% *}"
TCONN="${PROBE_OUT##* }"
if [ "$PROBE_RC" -ge 126 ] && [ "$PROBE_RC" -le 127 ]; then
  note "CHECKER BROKEN: cannot execute the probe binary '$CURL_BIN' (rc=$PROBE_RC)"
  CHECKER_BROKEN=1
  exit 1
fi
if [ "$PROBE_RC" -ne 0 ] || [ "${CODE:-000}" = "000" ]; then
  if [ -n "$(printf '%s' "$TCONN" | tr -d '0.')" ]; then
    why="it accepted the connection and then did not answer (slow, not dead)"
  else
    why="the connection never completed"
  fi
  note "upstream ${PROBE_URL} is not CLEANLY up — ${why} (curl rc=${PROBE_RC}, http=${CODE:-000}, time_connect=${TCONN}s). Touching no panes: a nudge into this re-errors the session and burns its cooldown."
  RESULT="upstream-down"
  exit 0
fi

# --- 2. Every pane on the box, WITH ITS FOREGROUND COMMAND -------------------
# pane_current_command is the identity gate (see the header): content alone
# cannot tell a stalled claude seat from a shell displaying a log that mentions
# one.
PANES=$("$TMUX_BIN" list-panes -a -F '#{pane_id}	#{session_name}	#{window_name}	#{pane_current_command}' 2>&1)
LIST_RC=$?
if [ "$LIST_RC" -ne 0 ] || [ -z "$PANES" ]; then
  note "no panes to examine (tmux said: ${PANES:-<nothing>})"
  RESULT="no-panes"
  exit 0
fi

# --- 3. Cooldown state (pane -> epoch of its last nudge) --------------------
declare -A LAST_NUDGE
if [ -s "$STATE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p=$(printf '%s' "$line" | sed -n -E 's/.*"pane":"([^"]*)".*/\1/p')
    e=$(printf '%s' "$line" | sed -n -E 's/.*"epoch":([0-9]+).*/\1/p')
    [ -n "$p" ] && [ -n "$e" ] && LAST_NUDGE["$p"]="$e"
  done <"$STATE"
fi

NOW=$(date +%s)
COOLDOWN_S=$((COOLDOWN_MIN * 60))
CHANGED=0

# Skips are BUFFERED, not logged as they happen (see the header's log policy):
# ~30 panes × 720 runs a day is ~20k lines a day of "nothing happened". They are
# flushed at the end only if this run nudged something — the case where you want
# to know what else was on the screen — or under ASR_VERBOSE=1.
SKIP_BUF=()
skip() { # skip <pane> <window> <reason>
  SKIPPED=$((SKIPPED + 1))
  SKIP_BUF+=("skip $1 ($2): $3")
}

# The LAST `API Error:` block — that line and everything after it. An older
# error further up the scrollback must not decide the verdict.
last_error_block() {
  printf '%s\n' "$1" | awk '
    /API Error:/ { n = NR }
    { l[NR] = $0 }
    END { if (!n) exit 1; for (i = n; i <= NR; i++) print l[i] }'
}

# Is this pane's foreground process one that can BE a Claude Code session? An
# allow-list, matched whole-word against ASR_PANE_CMDS — never a shell denylist
# (the header says why).
is_claude_pane() {
  local c
  for c in $PANE_CMDS; do
    [ "$1" = "$c" ] && return 0
  done
  return 1
}

while IFS=$'\t' read -r pane session window pcmd; do
  [ -n "$pane" ] || continue
  # Own pane first: if this guard is ever run from inside tmux, it must not type
  # into itself — and TMUX_PANE is the only identity it has of its own.
  if [ -n "${TMUX_PANE:-}" ] && [ "$pane" = "$TMUX_PANE" ]; then
    skip "$pane" "$window" "this guard's own pane"
    continue
  fi
  # IDENTITY BEFORE CONTENT. Refuse before even capturing: a shell pane's
  # scrollback is none of this guard's business, and a pane showing a log full
  # of captured API errors would otherwise pass every content rule below and be
  # sent a paragraph of English to execute.
  if ! is_claude_pane "$pcmd"; then
    skip "$pane" "$window" "foreground command '${pcmd:-<none>}' is not a Claude Code pane (allowed: ${PANE_CMDS})"
    continue
  fi

  tail_text=$("$TMUX_BIN" capture-pane -p -t "$pane" | tail -n "$TAIL_LINES")
  block=$(last_error_block "$tail_text") || {
    skip "$pane" "$window" "no API Error in the last ${TAIL_LINES} lines"
    continue
  }

  if printf '%s\n' "$block" | grep -qE 'API Error: *[0-9]{3}'; then
    skip "$pane" "$window" "a settled HTTP error (harnessd's bell owns it; re-running the turn may repeat a rejected or overloading request)"
    continue
  fi
  if ! printf '%s\n' "$block" | grep -qiE 'Unable to connect to API|Connection refused|ConnectionRefused'; then
    skip "$pane" "$window" "an API Error this guard does not recognise as connection-shaped"
    continue
  fi
  if printf '%s\n' "$block" | grep -qiE 'Retrying|attempt [0-9]+/[0-9]+'; then
    skip "$pane" "$window" "the client is already retrying"
    continue
  fi
  if printf '%s\n' "$block" | grep -qF 'esc to interrupt'; then
    skip "$pane" "$window" "a turn is in flight"
    continue
  fi
  if ! printf '%s\n' "$block" | grep -qE '❯|new task\?'; then
    skip "$pane" "$window" "no idle composer after the error — the session has moved on"
    continue
  fi
  if [ "$window" != "${window#🔔}" ]; then
    skip "$pane" "$window" "blocked on Zig (🔔) — send-keys would answer his open dialog, not the composer"
    continue
  fi
  last="${LAST_NUDGE[$pane]:-}"
  if [ -n "$last" ] && [ "$((NOW - last))" -lt "$COOLDOWN_S" ]; then
    skip "$pane" "$window" "nudged $(((NOW - last) / 60))m ago, inside the ${COOLDOWN_MIN}m cooldown"
    continue
  fi

  # Text first, Enter separately — some TUIs mis-handle a combined burst
  # (pulse-inject.sh §4, the mechanism this mirrors).
  "$TMUX_BIN" send-keys -t "$pane" -- "$NUDGE"
  sleep "$SEND_SETTLE"
  "$TMUX_BIN" send-keys -t "$pane" Enter
  NUDGED=$((NUDGED + 1))
  LAST_NUDGE["$pane"]="$NOW"
  CHANGED=1
  note "NUDGED $pane ($session:$window) — its turn died on a connection error and the upstream is back (HTTP $CODE)"
done <<<"$PANES"

# --- 4. Persist the cooldown state atomically -------------------------------
if [ "$CHANGED" = 1 ]; then
  tmp="$STATE.tmp.$$"
  : >"$tmp" || {
    note "CHECKER BROKEN: cannot write the cooldown state $tmp"
    CHECKER_BROKEN=1
  }
  if [ "$CHECKER_BROKEN" -eq 0 ]; then
    for p in "${!LAST_NUDGE[@]}"; do
      printf '{"pane":"%s","ts":"%s","epoch":%s}\n' \
        "$p" "$(date -u -d "@${LAST_NUDGE[$p]}" +%FT%TZ)" "${LAST_NUDGE[$p]}" >>"$tmp"
    done
    mv -f "$tmp" "$STATE" || {
      note "CHECKER BROKEN: cannot install the cooldown state $STATE"
      CHECKER_BROKEN=1
    }
  fi
fi

# --- 5. Flush the buffered skip reasons, under the log policy ---------------
if [ "$NUDGED" -gt 0 ] || [ "$VERBOSE" = "1" ]; then
  for s in ${SKIP_BUF+"${SKIP_BUF[@]}"}; do note "$s"; done
fi

# The verdict line is logged ALWAYS — it is one line per run, it is what a
# reader scans for, and it is the only thing that says the guard ran at all.
RESULT="ok:nudged:${NUDGED}:skipped:${SKIPPED}"
note "$RESULT"
exit 0
