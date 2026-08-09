#!/bin/bash
# pulse-escalate.sh — the keep-the-marshal-moving ladder (dotfiles-9z3o).
#
# THE PROBLEM. A scheduled seat has no human in the room. When its tick bounces
# because the window is blocked on a human (pulse-inject records
# reason=blocked_on_andrew and returns deferred-blocked-on-human) or because the
# composer never came up (reason=not_ready), NOTHING escalates: pulse-retry.sh —
# the only existing consumer of the bounce log — re-fires a loop ONLY after the 🔔
# has cleared, and skips not_ready entirely. So a persistent block escalates to
# nobody and the loop silently eats every fire until someone happens to look.
# Live evidence: maiden marshal night 2026-08-09 — a post-molt AskUserQuestion
# froze the seat, pulse-inject deferred twice, and the Esc recovery exposed the
# stale-🔔 defect (dotfiles-jisc).
#
# THE LADDER (Zig via the Master of Works, 2026-08-09), in order, no gaps:
#
#   0. GRACE   — for grace_minutes after the episode's FIRST bounce this script
#                does nothing at all. Zig's rung 2 ("a supervising session
#                nudges") is satisfied by standing still while someone else acts.
#   1. TRUTH   — the jisc reconciler. PROVE the block before escalating it:
#                capture-pane the seat window; a 🔔 NAME with no dialog chrome in
#                the pane is the stale-🔔 divergence, not a block, so clear the
#                glyph with a VERIFIED rename — and STOP there. Name-only trust is
#                removed on this, the consumer, side (jisc AC). This rung does NOT
#                re-fire the loop: see SINGLE OWNERSHIP below.
#   2. NUDGE   — modal chrome present => genuinely blocked => the front desk's
#                business. A SPECIFIC nudge naming the blocked seat, injected into
#                the seneschal window via pulse-inject --cmd (a real user turn).
#   3. RAISE   — no seneschal window, or it is itself 🔔: `systemctl --user start
#                <seneschal_unit>.service`, with the nudge carried in
#                $STATE_DIR/pulse-escalate-nudge.md so the raised brief has the
#                specifics rather than the daily default.
#   4. FLOOR   — still bouncing after the ladder + a cooldown: a P1 `human:` bead
#                AND a push. Always reached; the ladder never dead-ends.
#
# SINGLE OWNERSHIP OF THE RE-FIRE DECISION (dotfiles-t5fj, measured 2026-08-09).
# pulse-retry.sh already decides whether a bounced tick gets re-fired, and re-fires
# on exactly the condition rung 1 creates: a window whose 🔔 has cleared. Tonight it
# beat a manual recovery by TWO SECONDS and queued a stale '/clear + /marshal night'
# pair into a LIVE run's composer. Two owners of one decision is that race. So this
# script NEVER runs `systemctl --user start <blocked-loop>.service` — it clears the
# lying glyph and stops, and the existing 2-minute watcher takes it from there under
# its own dedup and next-fire rules. (Rung 3 starting the SENESCHAL's unit is not an
# exception: that is a different loop's injection, not a re-fire of the blocked one.)
#
# AND THE LOG SAYS ONLY WHAT THIS SCRIPT DID. The same review caught pulse-retry
# claiming credit for clearing a 🔔 it merely outlived. An outcome owned by another
# mechanism never appears in these lines — renamed, nudged, raised, filed; never
# "re-fired", "unblocked" or "recovered".
#
# THE PUSH PATH IS REAL, AND THIS IS WHAT IT WIRES TO (investigated 2026-08-09).
# harnessd exposes POST /act/push/test (internal/daemon/push.go →
# push.Manager.SendTest → every subscribed device in
# ~/.local/state/harness/push-subs.json). It is behind actionGate: an
# `X-Harnessd-Action: 1` header, an allowlisted Origin, and a Tailscale whois of
# the peer. Measured from a plain shell ON zig-computer, against the daemon's
# tailnet bind (100.98.174.21:14174):
#
#   POST /act/push/unsubscribe {"endpoint":""}  + header + Origin -> 400 "missing endpoint"
#   POST /act/push/test        NOT-JSON         + header + Origin -> 400 "malformed JSON body"
#   POST /act/push/test        {}               no header         -> 403 "forbidden"
#
# The two 400s are the proof: the gate PASSED (403 is the gate's own answer) and
# the handler got past its `s.push == nil` check (that path is a 503), i.e. push
# is configured and the route is shell-callable with curl. So the floor is a P1
# `human:` bead AND a real push — not the bead alone.
#
# GAPS THIS BUILD DOES NOT CLOSE, stated rather than hidden:
#   * The raise rung's nudge FILE has no reader yet. `human:`-prefixed P1 beads
#     ARE read by seneschal-gather.py (it filters on exactly that prefix), so the
#     FLOOR rung is guaranteed-surfaced; the raise rung's extra specificity is
#     best-effort until /seneschal reads pulse-escalate-nudge.md.
#   * The modal-chrome ERE is a UI fingerprint. A Claude Code that changed its
#     dialog footer would make every 🔔 read as "chrome absent" — which is why an
#     UNVERIFIABLE pane (empty capture, or an EMPTY marker) is treated as
#     GENUINELY BLOCKED. The reconciler fails SAFE: it can miss a stale 🔔; it can
#     never rename a live modal out from under Zig.
#
# OUTCOME CONTRACT. The LAST line of stdout is always
#
#   PULSE_ESCALATE_RESULT=checked:<n>:grace:<n>:reconciled:<n>:nudged:<n>:raised:<n>:floored:<n>:skipped:<n>:errors:<n>
#   PULSE_ESCALATE_RESULT=failed-config     (exit 78 — conf unreadable / not key=value)
#
# Exit 0 on every other path: a best-effort watcher, where one loop's failure must
# never abort the rest (`set -uo pipefail`, no -e — pulse-retry.sh's posture, for
# pulse-retry.sh's reason).
#
# IDEMPOTENCY. State is per loop+EPISODE in $STATE_DIR/pulse-escalate-state.jsonl:
# {"loop","episode","rung","acted_ts"}. An EPISODE is the contiguous run of
# escalate-worthy bounces for one loop whose neighbours are within
# episode_gap_minutes, keyed by its FIRST bounce. One rung-action per run, at most
# one of each rung per episode, cooldown_minutes between rungs — and a rung only
# advances when the loop has bounced AGAIN since our action (newest bounce ts >
# acted_ts), so a rung that WORKED closes the episode and one that did not is
# followed by the next rung.
#
# NEVER: re-fire the blocked loop (single ownership, above); inject into any 🔔
# window (pulse-retry's precedent — the text would land in the modal and its Enter
# would answer it); act while the loop's own tick is in flight (`is-active`); write
# to the bounce log (read-only here).
#
# Test seams (env; production sets none of them). tmux / systemctl resolve through
# PATH, so a hermetic suite shims them:
#   HARNESS_STATE_DIR  · PULSE_ESCALATE_CONF · PULSE_ESCALATE_LOG
#   PULSE_ESCALATE_INJECT (pulse-inject.sh path) · PULSE_ESCALATE_BR · PULSE_ESCALATE_CURL
#   PULSE_ESCALATE_MODAL_MARKER — the dialog-chrome ERE; EMPTY disables the
#   reconciler, in the safe direction (every 🔔 then reads as genuinely blocked).

set -uo pipefail
export LC_ALL=C

STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
mkdir -p "$STATE_DIR" || true
LOG="${PULSE_ESCALATE_LOG:-$STATE_DIR/pulse-escalate.log}"
BOUNCES="$STATE_DIR/pulse-bounces.jsonl"
ESC_STATE="$STATE_DIR/pulse-escalate-state.jsonl"
NUDGE_FILE="$STATE_DIR/pulse-escalate-nudge.md"
_ME_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${PULSE_ESCALATE_CONF:-$_ME_DIR/escalate.conf}"
INJECT="${PULSE_ESCALATE_INJECT:-$_ME_DIR/pulse-inject.sh}"
BR_BIN="${PULSE_ESCALATE_BR:-br}"
CURL_BIN="${PULSE_ESCALATE_CURL:-curl}"

# The AskUserQuestion / permission-prompt chrome, as pulse-inject's 3.5 guard
# WISHES it knew it. Derived from a live capture of a blocked pane (zig-computer,
# 2026-08-09): the dialog paints a numbered option list with a ❯ caret and closes
# with "Enter to select · Tab/Arrow keys to navigate · Esc to cancel". The footer
# wraps, so each phrase is matched independently. The idle composer footer
# ("? for shortcuts", "shift+tab to cycle") matches NONE of these — that is the
# whole discrimination.
MODAL_MARKER="${PULSE_ESCALATE_MODAL_MARKER-Enter to select|Tab/Arrow keys to navigate|Esc to cancel|Do you want to (proceed|make this edit)|❯ [0-9]+\. }"

TMUX_BIN=$(command -v tmux 2>>"$LOG")
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
SYSTEMCTL_BIN=$(command -v systemctl 2>>"$LOG")
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl

note() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# --- Helpers (json_field / ts_key / strip_lexicon are pulse-retry.sh's, verbatim
# --- and for its stated reason: one line each, replication keeps the proven
# --- behaviour of both scripts independent).
json_field() { printf '%s' "$1" | sed -n -E "s/.*\"$2\":\"([^\"]*)\".*/\1/p"; }
ts_key() { printf '%s' "$1" | tr -cd '0-9'; }
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀) ?//'; }
iso_epoch() { date -u -d "$1" +%s 2>>"$LOG"; }

# CONFIG — key=value only, and the parser REFUSES anything else (marshal.conf's
# parser, same argument: a config file that can execute is a config file that can
# be an incident, and this one is read by an unattended 5-minute loop).
declare -A CFG=()
CONF_ERROR=""
conf_load() {
  local file=$1 line key value n=0
  [ -r "$file" ] || { CONF_ERROR="config not readable: $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    if ! printf '%s' "$line" | grep -qE '^[a-z][a-z0-9_]*=[A-Za-z0-9_:,./~+-]*$'; then
      CONF_ERROR="config line $n is not a plain key=value: $line"
      return 1
    fi
    key=${line%%=*}; value=${line#*=}
    CFG[$key]=$value
  done < "$file"
  return 0
}
cfg() {
  local k=$1 d=${2:-}
  if [ -n "${CFG[$k]+set}" ] && [ -n "${CFG[$k]}" ]; then printf '%s' "${CFG[$k]}"; else printf '%s' "$d"; fi
}

CHECKED=0; GRACED=0; RECONCILED=0; NUDGED=0; RAISED=0; FLOORED=0; SKIPPED=0; ERRORS=0
emit_result() {
  printf 'PULSE_ESCALATE_RESULT=checked:%s:grace:%s:reconciled:%s:nudged:%s:raised:%s:floored:%s:skipped:%s:errors:%s\n' \
    "$CHECKED" "$GRACED" "$RECONCILED" "$NUDGED" "$RAISED" "$FLOORED" "$SKIPPED" "$ERRORS"
}

conf_load "$CONF" || {
  note "FAIL: $CONF_ERROR"
  echo "pulse-escalate: $CONF_ERROR" >&2
  echo "PULSE_ESCALATE_RESULT=failed-config"
  exit 78
}

GRACE_S=$(( $(cfg grace_minutes 10) * 60 ))
COOLDOWN_S=$(( $(cfg cooldown_minutes 15) * 60 ))
GAP_S=$(( $(cfg episode_gap_minutes 45) * 60 ))
SEN_UNIT=$(cfg seneschal_unit pulse-seneschal)
SEN_WINDOW=$(cfg seneschal_window seneschal)
SEN_SESSION=$(cfg seneschal_session zig-computer)
SEN_DIR=$(cfg seneschal_dir "$HOME/dotfiles")
BEAD_REPO=$(cfg bead_repo "$HOME/dotfiles")
PUSH_URL=$(cfg push_url)
PUSH_ORIGIN=$(cfg push_origin)

# win_lookup <session> <window> — prints "<index> <live-name>" for the window whose
# LEXICON-STRIPPED name is <window>; empty output means absent. The index is what
# every later tmux call targets: a name carrying a 🔔 and a space is not a target
# anyone should be re-quoting.
win_lookup() {
  local session=$1 want=$2 line idx name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    idx=${line%% *}; name=${line#* }
    [ "$(strip_lexicon "$name")" = "$want" ] || continue
    printf '%s %s' "$idx" "$name"; return 0
  done < <("$TMUX_BIN" list-windows -t "=$session" -F '#{window_index} #{window_name}' 2>>"$LOG")
  return 1
}

# pane_modal <session> <index> -> 0 present · 1 absent · 2 UNVERIFIABLE.
# 2 is the fail-safe outcome (empty capture, or MODAL_MARKER disabled) and every
# caller treats it exactly like "present": the reconciler may miss a stale 🔔, it
# may never rename a live dialog away.
pane_modal() {
  local session=$1 idx=$2 pane
  [ -n "$MODAL_MARKER" ] || return 2
  pane=$("$TMUX_BIN" capture-pane -p -t "=$session:$idx" 2>>"$LOG")
  [ -n "$pane" ] || return 2
  printf '%s\n' "$pane" | grep -Eq "$MODAL_MARKER" && return 0
  return 1
}

# --- Read the bounce log (READ-ONLY to this script) ---------------------------
declare -A BTS=() BREASON=()
if [ -s "$BOUNCES" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    l=$(json_field "$line" loop); t=$(json_field "$line" ts); r=$(json_field "$line" reason)
    if [ -z "$l" ] || [ -z "$t" ]; then continue; fi
    case "$r" in blocked_on_andrew|deferred-blocked-on-human|not_ready) ;; *) continue ;; esac
    BTS[$l]="${BTS[$l]:-}$t"$'\n'
    BREASON[$l]="$r"
  done < "$BOUNCES"
fi

# --- Existing state -----------------------------------------------------------
declare -A S_EPISODE=() S_RUNG=() S_ACTED=()
if [ -s "$ESC_STATE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    l=$(json_field "$line" loop); [ -n "$l" ] || continue
    S_EPISODE[$l]=$(json_field "$line" episode)
    S_RUNG[$l]=$(json_field "$line" rung)
    S_ACTED[$l]=$(json_field "$line" acted_ts)
  done < "$ESC_STATE"
fi

now=$(date +%s)
now_iso=$(date -u +%FT%TZ)
changed=0

# record <loop> <episode> <rung> — remember the rung we just acted on.
record() { S_EPISODE[$1]=$2; S_RUNG[$1]=$3; S_ACTED[$1]=$now_iso; changed=1; }

# --- The ladder, per CONFIGURED loop (seats opt in; `loops` is the whole gate) --
IFS=, read -r -a LOOP_ROWS <<< "$(cfg loops)"
for row in "${LOOP_ROWS[@]:-}"; do
  [ -n "$row" ] || continue
  loop=${row%%:*}; rest=${row#*:}; window=${rest%%:*}; session=${rest#*:}
  if [ -z "$loop" ] || [ -z "$window" ] || [ -z "$session" ]; then
    note "skip malformed loops entry '$row'"; ERRORS=$((ERRORS + 1)); continue
  fi

  bl="${BTS[$loop]:-}"
  [ -n "$bl" ] || continue
  CHECKED=$((CHECKED + 1))

  mapfile -t tss < <(printf '%s' "$bl" | sort)
  n=${#tss[@]}
  newest=${tss[n-1]}
  newest_ep=$(iso_epoch "$newest")
  [ -n "$newest_ep" ] || { note "skip $loop: unparseable bounce ts '$newest'"; ERRORS=$((ERRORS + 1)); continue; }

  # An episode whose newest bounce is older than the gap is OVER — the loop
  # recovered on its own and nothing here has any business acting.
  if [ $((now - newest_ep)) -gt "$GAP_S" ]; then SKIPPED=$((SKIPPED + 1)); continue; fi

  ep_start=$newest; prev=$newest_ep
  for ((i = n - 2; i >= 0; i--)); do
    e=$(iso_epoch "${tss[i]}") || break
    [ -n "$e" ] || break
    [ $((prev - e)) -le "$GAP_S" ] || break
    ep_start=${tss[i]}; prev=$e
  done
  ep_start_ep=$(iso_epoch "$ep_start")
  age_min=$(( (now - ep_start_ep) / 60 ))
  reason="${BREASON[$loop]:-unknown}"

  # Never act while the loop's own tick is genuinely in flight.
  st=$("$SYSTEMCTL_BIN" --user is-active "$loop.service" 2>>"$LOG")
  case "$st" in
    active|activating|reloading)
      note "skip $loop: its tick is in flight (is-active=$st)"; SKIPPED=$((SKIPPED + 1)); continue ;;
  esac

  # RUNG 0 — GRACE. A supervising session moves first.
  if [ $((now - ep_start_ep)) -lt "$GRACE_S" ]; then
    note "grace $loop: episode $ep_start is ${age_min}m old (< $((GRACE_S / 60))m) — leaving the first move to a supervisor"
    GRACED=$((GRACED + 1)); continue
  fi

  same_episode=0
  [ "${S_EPISODE[$loop]:-}" = "$ep_start" ] && same_episode=1
  rung=""; acted=""
  if [ "$same_episode" = 1 ]; then rung="${S_RUNG[$loop]:-}"; acted="${S_ACTED[$loop]:-}"; fi

  # A rung that WORKED closes the episode: nothing has bounced since we acted.
  # (`floored` is terminal either way — the floor never fires twice per episode.)
  if [ -n "$rung" ]; then
    if [ "$rung" = floored ]; then SKIPPED=$((SKIPPED + 1)); continue; fi
    nk=$(ts_key "$newest"); ak=$(ts_key "$acted")
    if [ "${nk:-0}" -le "${ak:-0}" ]; then
      SKIPPED=$((SKIPPED + 1)); continue
    fi
    acted_ep=$(iso_epoch "$acted")
    if [ -n "$acted_ep" ] && [ $((now - acted_ep)) -lt "$COOLDOWN_S" ]; then
      SKIPPED=$((SKIPPED + 1)); continue
    fi
  fi

  # RUNG 1 — TRUTH. The jisc reconciler: capture-pane before believing the glyph.
  # ⚠️ THE RENAME IS THE WHOLE RUNG — no re-fire (SINGLE OWNERSHIP, in the header).
  if wl=$(win_lookup "$session" "$window"); then
    widx=${wl%% *}; wname=${wl#* }
    if [ "$wname" != "${wname#🔔}" ]; then
      pane_modal "$session" "$widx"; pm=$?
      if [ "$pm" = 1 ]; then
        stripped=$(strip_lexicon "$wname")
        "$TMUX_BIN" rename-window -t "=$session:$widx" "$stripped" 2>>"$LOG"
        after=$("$TMUX_BIN" list-windows -t "=$session" -F '#{window_index} #{window_name}' 2>>"$LOG" \
                | sed -n -E "s/^$widx //p" | head -1)
        if [ -n "$after" ] && [ "$after" = "${after#🔔}" ]; then
          # States ONLY what this script did — see the header's log clause.
          note "RENAMED $loop: window $widx '$wname' carried 🔔 with NO dialog chrome in the pane (stale-🔔, dotfiles-jisc); renamed to '$after' after verifying the rename took. No re-fire issued here — pulse-retry owns that decision."
          record "$loop" "$ep_start" reconciled
          RECONCILED=$((RECONCILED + 1)); continue
        fi
        note "WARN: $loop: rename of window $widx did not clear 🔔 (now '${after:-<gone>}')"
        ERRORS=$((ERRORS + 1)); continue
      fi
      [ "$pm" = 2 ] && note "$loop: pane $widx UNVERIFIABLE (empty capture or marker disabled) — treating as genuinely blocked"
    fi
  fi

  # The nudge, carried by rungs 2 and 3 alike.
  nudge="Escalation from pulse-escalate — the '$window' seat (loop $loop, session $session) has been blocked for ${age_min}m: its tick bounced $n time(s), newest reason '$reason', and a capture-pane confirms the block is real. You are the front desk: read that window, answer or reroute the question so the loop's next tick can land. If it genuinely needs Zig, file the P1 human: bead and say so."

  # RUNG 2 — SENESCHAL DUTY. Never into a 🔔 window, and only a DELIVERED
  # injection counts (pulse-inject's own verdict is the evidence, not its exit code).
  if [ "$rung" != nudged ] && [ "$rung" != raised ]; then
    if sl=$(win_lookup "$SEN_SESSION" "$SEN_WINDOW"); then
      sname=${sl#* }
      if [ "$sname" != "${sname#🔔}" ]; then
        note "$loop: seneschal window '$sname' is itself 🔔 — not injecting; raising instead"
      elif [ -x "$INJECT" ]; then
        out=$("$INJECT" --dir "$SEN_DIR" --session "$SEN_SESSION" --window "$SEN_WINDOW" --cmd "$nudge" 2>&1)
        v=$(printf '%s\n' "$out" | grep -o 'PULSE_INJECT_RESULT=[a-z-]*' | tail -1 | cut -d= -f2-)
        if [ "$v" = injected ]; then
          note "NUDGED $loop: specific nudge delivered to $SEN_SESSION:$SEN_WINDOW (episode $ep_start, ${age_min}m)"
          record "$loop" "$ep_start" nudged
          NUDGED=$((NUDGED + 1)); continue
        fi
        note "$loop: seneschal nudge did NOT deliver (PULSE_INJECT_RESULT=${v:-<none>}) — raising instead"
      else
        note "$loop: no executable injector at $INJECT — raising instead"
      fi
    else
      note "$loop: no '$SEN_WINDOW' window in $SEN_SESSION — raising instead"
    fi
  fi

  # RUNG 3 — RAISE the seneschal, with the nudge carried.
  if [ "$rung" != raised ]; then
    { printf '# pulse-escalate nudge — %s\n\n%s\n' "$now_iso" "$nudge" > "$NUDGE_FILE"; } \
      || note "WARN: could not write $NUDGE_FILE (raising anyway)"
    if "$SYSTEMCTL_BIN" --user start "$SEN_UNIT.service" >>"$LOG" 2>&1; then
      note "RAISED $loop: started $SEN_UNIT.service; nudge carried in $NUDGE_FILE (episode $ep_start, ${age_min}m)"
      record "$loop" "$ep_start" raised
      RAISED=$((RAISED + 1)); continue
    fi
    note "WARN: $loop: 'systemctl --user start $SEN_UNIT.service' failed — falling through to the floor"
    ERRORS=$((ERRORS + 1))
  fi

  # RUNG 4 — THE FLOOR. P1 `human:` bead (seneschal-gather.py filters on exactly
  # that prefix, so this rung is the one that is GUARANTEED to surface) + push.
  title="human: $window seat blocked ${age_min}m — pulse-escalate ladder exhausted for $loop"
  desc="## Context
pulse-escalate.sh walked its whole ladder for loop '$loop' (seat window
'$window' in session '$session') and the loop is STILL bouncing: $n bounce(s)
in this episode, first at $ep_start, newest at $newest, reason '$reason'.
Grace, the stale-🔔 reconciler, the seneschal nudge and the seneschal raise have
all been tried. This is the floor rung: the loop needs a human.

## Task
Look at $session:$window, answer or dismiss whatever is holding it, and confirm
the loop's next tick lands.

## Acceptance Criteria
- [ ] The blocking modal in $session:$window is resolved
- [ ] $loop.service produces a delivered tick (no new bounce record)"
  if ( cd "$BEAD_REPO" && "$BR_BIN" create -t bug -p 1 -d "$desc" "$title" ) >>"$LOG" 2>&1; then
    note "FLOOR $loop: filed P1 human: bead in $BEAD_REPO"
  else
    note "WARN: $loop: 'br create' failed in $BEAD_REPO — the push below is the only floor left"
    ERRORS=$((ERRORS + 1))
  fi
  if [ -n "$PUSH_URL" ]; then
    body=$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"body":sys.argv[2],"all":True,"urgency":"high"}))' \
             "$window seat is stuck" "$title" 2>>"$LOG")
    code=$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' -X POST "$PUSH_URL" \
             -H 'X-Harnessd-Action: 1' -H "Origin: $PUSH_ORIGIN" \
             -H 'Content-Type: application/json' -d "$body" 2>>"$LOG")
    case "$code" in
      2*) note "FLOOR $loop: push delivered (HTTP $code)" ;;
      *)  note "WARN: $loop: push to $PUSH_URL returned HTTP ${code:-<none>}"; ERRORS=$((ERRORS + 1)) ;;
    esac
  else
    note "WARN: $loop: no push_url configured — the bead is the only floor"
  fi
  record "$loop" "$ep_start" floored
  FLOORED=$((FLOORED + 1))
done

# --- Write state atomically (only when something changed) ---------------------
if [ "$changed" = 1 ]; then
  tmp="$ESC_STATE.tmp.$$"
  : > "$tmp" || { note "FAIL: cannot write escalate-state tmp $tmp"; emit_result; exit 0; }
  for l in "${!S_EPISODE[@]}"; do
    printf '{"loop":"%s","episode":"%s","rung":"%s","acted_ts":"%s"}\n' \
      "$l" "${S_EPISODE[$l]}" "${S_RUNG[$l]:-}" "${S_ACTED[$l]:-}" >> "$tmp"
  done
  mv -f "$tmp" "$ESC_STATE" || { note "FAIL: cannot install escalate-state $ESC_STATE"; rm -f "$tmp"; }
fi

emit_result
exit 0
