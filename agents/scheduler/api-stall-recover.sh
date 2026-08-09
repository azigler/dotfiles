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
# Knobs (all env, all with defaults, each one a test seam):
#   ASR_TMUX          the tmux binary                (tmux)
#   ASR_CURL          the probe binary               (curl)
#   ASR_PROBE_URL     the upstream door              (http://100.72.47.4:17017/claude/v1/models)
#   HARNESS_STATE_DIR state + log directory          (~/.local/state/harness)
#   ASR_LOG           the action log                 (<state-dir>/api-stall-recover.log)
#   ASR_COOLDOWN_MIN  minutes between nudges/pane    (15)
#   ASR_TAIL_LINES    pane tail examined             (40)
#   ASR_SEND_SETTLE   pause between text and Enter   (0.3)

set -uo pipefail

TMUX_BIN="${ASR_TMUX:-tmux}"
CURL_BIN="${ASR_CURL:-curl}"
PROBE_URL="${ASR_PROBE_URL:-http://100.72.47.4:17017/claude/v1/models}"
STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
LOG="${ASR_LOG:-$STATE_DIR/api-stall-recover.log}"
STATE="$STATE_DIR/api-stall-recover-state.jsonl"
COOLDOWN_MIN="${ASR_COOLDOWN_MIN:-15}"
TAIL_LINES="${ASR_TAIL_LINES:-40}"
SEND_SETTLE="${ASR_SEND_SETTLE:-0.3}"

NUDGE='api-connectivity-guard: your previous turn died with a connection error to the API (upstream outage, since restored and verified). Resume the interrupted work — if the dead turn was an injected command/tick, re-run that command; do not invent new work.'

RESULT="no-panes" # fail-closed: nothing has been examined yet
NUDGED=0
SKIPPED=0
CHECKER_BROKEN=0

note() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
  printf '  %s\n' "$*"
}

# shellcheck disable=SC2317  # invoked via the EXIT trap
finish() {
  rc=$?
  printf 'API_STALL_RESULT=%s\n' "$RESULT"
  [ "$CHECKER_BROKEN" -ne 0 ] && exit 1
  case "$RESULT" in
  upstream-down | no-panes) exit 0 ;;
  ok:*) if [ "$NUDGED" -gt 0 ]; then exit 10; else exit 0; fi ;;
  *) exit "$((rc == 0 ? 1 : rc))" ;; # the checker itself lost the plot
  esac
}
trap finish EXIT

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

# --- 1. Is the upstream actually back? --------------------------------------
# The same probe, and the same reading of it, as gateway-health.sh: ANY HTTP
# status means the relay is listening (401 is the healthy signature of a
# transparent passthrough); only a connect failure means down. No
# `2>/dev/null` — curl is output-bearing here and a suppressed failure would
# read as an outage (repo rule 3).
CODE=$("$CURL_BIN" -s -o /dev/null -m 8 -w '%{http_code}' "$PROBE_URL")
PROBE_RC=$?
if [ "$PROBE_RC" -ge 126 ] && [ "$PROBE_RC" -le 127 ]; then
  note "CHECKER BROKEN: cannot execute the probe binary '$CURL_BIN' (rc=$PROBE_RC)"
  CHECKER_BROKEN=1
  exit 1
fi
if [ "${CODE:-000}" = "000" ]; then
  note "upstream ${PROBE_URL} is not answering — touching no panes (nudging into a dead upstream just re-errors)"
  RESULT="upstream-down"
  exit 0
fi

# --- 2. Every pane on the box ------------------------------------------------
PANES=$("$TMUX_BIN" list-panes -a -F '#{pane_id}	#{session_name}	#{window_name}' 2>&1)
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

skip() { # skip <pane> <window> <reason>
  SKIPPED=$((SKIPPED + 1))
  note "skip $1 ($2): $3"
}

# The LAST `API Error:` block — that line and everything after it. An older
# error further up the scrollback must not decide the verdict.
last_error_block() {
  printf '%s\n' "$1" | awk '
    /API Error:/ { n = NR }
    { l[NR] = $0 }
    END { if (!n) exit 1; for (i = n; i <= NR; i++) print l[i] }'
}

while IFS=$'\t' read -r pane session window; do
  [ -n "$pane" ] || continue
  if [ "$pane" = "${TMUX_PANE:-}" ]; then
    skip "$pane" "$window" "this guard's own pane"
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

RESULT="ok:nudged:${NUDGED}:skipped:${SKIPPED}"
[ "$NUDGED" -gt 0 ] && note "$RESULT"
exit 0
