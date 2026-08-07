#!/bin/bash
# pulse-retry.sh — the bounced-tick early-retry watcher (harnessd-dbp).
#
# A pulse tick BOUNCES when pulse-inject.sh finds the target tmux window blocked
# on Andrew (name starts with 🔔): it records {"ts","loop","reason":"blocked_on_andrew"}
# to ~/.local/state/harness/pulse-bounces.jsonl and exits WITHOUT injecting. Left to
# itself, that tick only retries on the loop's NEXT scheduled fire — which can be a
# DAY away. This watcher delivers it EARLY: the moment the 🔔 clears, it re-fires the
# loop's systemd unit (which re-invokes pulse-inject, re-checking the 🔔 and delivering).
#
# Fleet-wide: ONE instance (a 2-min timer), not one per loop. Each run:
#   1. Read pulse-bounces.jsonl → latest bounce `ts` per `loop`.
#   2. Read pulse-retry-state.jsonl → last-acted `ts` per loop.
#   3. For each loop whose latest bounce is NEWER than its last-acted ts:
#        a. next_fire = systemctl --user show <loop>.timer -p NextElapseUSecRealtime
#           --value. Empty / 0 (no schedule) → SKIP (unbounded; don't retry).
#        b. now >= next_fire → SKIP (the natural timer is about to take over).
#        c. Resolve the target window from the unit's ExecStart (--session/--window,
#           defaults work/pulse) and read its CURRENT tmux name (lexicon-aware).
#        d. Window STILL starts with 🔔 → SKIP, leave UNACTED (poll again next run).
#           KEY: never re-fire into a 🔔 window — that just re-bounces and grows the
#           bounce log unboundedly while Andrew is away.
#        e. 🔔 CLEARED → `systemctl --user start <loop>.service` and mark last-acted.
#   4. Write retry-state atomically.
#
# Idempotency: the last-acted dedup ⇒ one re-fire per bounce (after a delivered
# re-fire with no new bounce, latest == last-acted ⇒ no double-inject). next_fire is
# the hard TTL ⇒ no runaway when Andrew is away for days.
#
# Best-effort per loop: a failing systemctl / tmux for ONE loop must not abort the
# rest. Hence `set -uo pipefail` (no -e — matching pulse-inject.sh, which chose the
# same for the same reason); each loop iteration tolerates its own failures.
#
# ---------------------------------------------------------------------------
# IT ALSO DRAINS DEFERRED SURFACES (dotfiles-5ts2) — and that is a DIFFERENT verb.
# ---------------------------------------------------------------------------
# Everything above re-fires a tick that never ran. A deferred SURFACE is the
# opposite case: the tick already RAN, on marketing-vps, and finished — only its
# announcement bounced off a 🔔 window. Re-firing that loop would redo completed work
# and burn the row's cap, so this watcher must never do that for a surface. It calls
# pulse-surface-queue.sh drain instead, which retries the ANNOUNCEMENT ONLY.
#
# It lives here rather than in a new timer on purpose: this is already the
# "the 🔔 cleared, deliver what was deferred" watcher, it already runs every 2
# minutes, and a surface has exactly the same trigger condition. A second unit would
# have been a second thing to install, monitor and forget.
#
# It runs FIRST, before the no-bounces early exit below — a queued surface is
# independent of whether any tick bounced, and would otherwise never be drained on
# the common path where the bounce log is empty.
#
# ---------------------------------------------------------------------------
# AND IT WATCHES LOCAL LOOPS' LEDGERS (dotfiles-wqby) — a THIRD verb.
# ---------------------------------------------------------------------------
# The drain above retries an announcement that was already STAGED. For a LOCAL
# loop nothing ever stages one: pulse-inject.sh returns the instant it has typed
# the command, so it never observes the tick's outcome, and a local tick therefore
# finished in total silence (measured on pulse-weekly-report, 2026-08-07).
#
# pulse-ledger-watch.sh closes that: it reads each local loop's newest LEDGER row —
# the tick's durable completion record — and stages a surface for anything newer
# than that loop's marker. It runs BEFORE the drain, so a completion noticed on
# this run is delivered on this run rather than waiting another 2 minutes.
#
# Same reuse argument as the drain, one step further: a third trigger condition
# that fires on the same 2-minute clock is a third reason not to add a unit.
#
# Overrides (for the hermetic test-harness):
#   HARNESS_STATE_DIR   — where pulse-bounces.jsonl / pulse-retry-state.jsonl live.
#   PULSE_RETRY_LOG     — the note() log file (default <state-dir>/pulse-retry.log).
#   PULSE_SURFACE_DRAIN — path to pulse-surface-queue.sh (a non-existent path
#                         disables the drain; tests point it at a recorder stub).
#   PULSE_LEDGER_WATCH  — path to pulse-ledger-watch.sh (a non-existent path
#                         disables the watch; tests point it at a recorder stub).

set -uo pipefail

STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LOG="${PULSE_RETRY_LOG:-$STATE_DIR/pulse-retry.log}"
BOUNCES="$STATE_DIR/pulse-bounces.jsonl"
RETRY_STATE="$STATE_DIR/pulse-retry-state.jsonl"

TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null)
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl

note() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# --- Helpers -----------------------------------------------------------------

# Extract a "field":"value" from a flat JSON line (the bounce/retry-state format
# is written by us + pulse-inject.sh, so a fixed-shape sed is safe + dependency-free).
json_field() { printf '%s' "$1" | sed -n -E "s/.*\"$2\":\"([^\"]*)\".*/\1/p"; }

# Digits-only sort key for an ISO-8601-Z timestamp (2026-07-09T05:00:00Z →
# 20260709050000). Locale-independent numeric comparison — avoids any collation
# surprise from comparing the raw strings.
ts_key() { printf '%s' "$1" | tr -cd '0-9'; }

# Lexicon-aware window-name strip (replicated verbatim from pulse-inject.sh, NOT
# sourced: it is ~1 line, and replication keeps pulse-inject's proven behavior
# untouched rather than coupling both scripts to a shared helper).
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀) ?//'; }

# Pull the token following a flag out of a `systemctl show -p ExecStart` line.
# e.g. execstart_flag "$es" --session → "work". Empty if the flag is absent.
execstart_flag() { printf '%s' "$1" | grep -oE -- "$2 [^ ]+" | head -1 | awk '{print $2}'; }

# Normalize a `systemctl show -p NextElapseUSecRealtime --value` reading into epoch SECONDS.
# systemd renders this property in DIFFERENT forms across versions / timer kinds:
#   - raw microseconds since the epoch (systemd ≤256): all-digit, e.g. 1783969200000000
#   - a formatted realtime timestamp (systemd 257+):   "Mon 2026-07-13 19:00:00 UTC"
#   - empty / "0" / "n/a" / "infinity":                no bounded realtime schedule (unbounded)
# Echoes epoch seconds when there IS a bounded next fire; echoes NOTHING (empty) otherwise — so the
# caller treats "no output" as unbounded and skips (the original intent), while a real schedule in
# EITHER the numeric OR the human form now resolves correctly.
#   HISTORY (harnessd-95w): the caller previously kept only an all-digit guard and treated ANY
#   non-digit reading as "unbounded" — so the systemd 257 upgrade (which switched this property to a
#   human timestamp) silently turned pulse-retry into a no-op for EVERY OnCalendar loop. This helper
#   is the format-agnostic replacement.
next_fire_epoch() {
  local raw="$1" secs
  case "$raw" in
    ''|0|n/a|infinity) return 0 ;;                        # no bounded realtime schedule
    *[!0-9]*)                                             # non-digit → a formatted timestamp
      secs=$(date -d "$raw" +%s 2>/dev/null) || return 0 # GNU date (Linux, where the timers run)
      [ -n "$secs" ] && printf '%s' "$secs"
      ;;
    *) printf '%s' $(( raw / 1000000 )) ;;               # all-digit → microseconds → seconds
  esac
}

# --- 0a. Watch LOCAL loops' ledgers and STAGE anything newly finished ---------
#
# Runs before the drain so this run delivers what this run notices. Best-effort in
# both directions, exactly like the drain: the watcher's own errors are its own,
# and they must not stop a bounced tick from being retried below. Its verdict is
# always `staged:<n>:seeded:<m>:errors:<e>`; the all-zero form is the quiet normal
# case and is not worth a log line, and a non-zero ERROR count carries the
# watcher's full output into this log because that output names the drift.

# ⚠️ DISABLED 2026-08-07, same day it shipped — adversarial review (dotfiles-wqby)
# found this staging into a queue whose injected command is hardcoded for the REMOTE
# dispatcher. The text typed into the pane says, verbatim, "...and land the ledger row
# at <proj>/refs/pulse-ledger.jsonl". For a REMOTE tick that is correct: the box ran the
# tick, the local session lands the row. For a LOCAL tick the row ALREADY EXISTS — the
# tick wrote it at wrap — so the announcement instructs the session to write a SECOND
# row. That row carries a fresh ts, the next 2-minute run reads it as new, stages again,
# and types the same instruction. A self-sustaining announcement loop that also corrupts
# the very ledger this mechanism reads, on the happy path.
#
# Kept wired-but-off rather than reverted: the watcher, its 42-case suite, and the
# marker state are all sound in isolation (verified 42/42, 24/24, and case 14 does drive
# the real queue). The defect is in the QUEUE's remote-only prose, which is dotfiles-sxsv
# — filed as "cosmetic" and that assessment was WRONG. Re-enable only when sxsv makes the
# injected command origin-aware; PULSE_LEDGER_WATCH_ENABLE=1 forces it on for testing.
#
# Anything relying on this for surfacing is back to the ATTENDED prose path until then.
LEDGER_WATCH="${PULSE_LEDGER_WATCH:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pulse-ledger-watch.sh}"
if [ "${PULSE_LEDGER_WATCH_ENABLE:-0}" = 1 ] && [ -x "$LEDGER_WATCH" ]; then
  lw_out=$("$LEDGER_WATCH" 2>&1)
  lw_verdict=$(printf '%s\n' "$lw_out" | grep -o 'PULSE_LEDGER_WATCH_RESULT=[a-z0-9:-]*' | tail -1 | cut -d= -f2-)
  case "${lw_verdict:-}" in
    ''|staged:0:seeded:0:errors:0) : ;;
    *:errors:0)                    note "ledger-watch: $lw_verdict" ;;
    *)
      note "ledger-watch: $lw_verdict"
      # Everything EXCEPT the result marker, which the line above already carries.
      while IFS= read -r _l; do
        case "$_l" in ''|PULSE_LEDGER_WATCH_RESULT=*) continue ;; esac
        note "ledger-watch| $_l"
      done <<< "$lw_out"
      ;;
  esac
else
  note "ledger-watch: skipped (no executable at $LEDGER_WATCH)"
fi

# --- 0. Drain deferred SURFACES (announcement-only retry; never re-fires a tick) --
#
# Best-effort and non-fatal in every direction: a queue that cannot be drained must
# not stop the bounced-tick retries below, and vice versa. `drain` is a no-op that
# emits PULSE_SURFACE_RESULT=empty when nothing is pending, which is the normal case.

SURFACE_DRAIN="${PULSE_SURFACE_DRAIN:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pulse-surface-queue.sh}"
if [ -x "$SURFACE_DRAIN" ]; then
  drain_out=$("$SURFACE_DRAIN" drain 2>&1)
  drain_verdict=$(printf '%s\n' "$drain_out" | grep -o 'PULSE_SURFACE_RESULT=[a-z0-9:-]*' | tail -1 | cut -d= -f2-)
  case "${drain_verdict:-}" in
    ''|empty) : ;;   # nothing pending — the normal case, not worth a log line
    *)        note "surface-drain: $drain_verdict" ;;
  esac
else
  note "surface-drain: skipped (no executable at $SURFACE_DRAIN)"
fi

# --- 1. No bounces → no-op --------------------------------------------------

if [ ! -s "$BOUNCES" ]; then
  note "no bounces file (or empty) at $BOUNCES — nothing to retry"
  exit 0
fi

# --- 1a. Latest bounce ts per loop ------------------------------------------

declare -A LATEST_BOUNCE
while IFS= read -r line; do
  [ -n "$line" ] || continue
  bloop=$(json_field "$line" loop)
  bts=$(json_field "$line" ts)
  if [ -z "$bloop" ] || [ -z "$bts" ]; then continue; fi
  cur="${LATEST_BOUNCE[$bloop]:-}"
  if [ -z "$cur" ]; then
    LATEST_BOUNCE[$bloop]="$bts"
  else
    bkey=$(ts_key "$bts"); ckey=$(ts_key "$cur")
    [ "${bkey:-0}" -gt "${ckey:-0}" ] && LATEST_BOUNCE[$bloop]="$bts"
  fi
done < "$BOUNCES"

# --- 2. Last-acted ts per loop (retry-state; absent ⇒ empty) ----------------

declare -A LAST_ACTED
if [ -s "$RETRY_STATE" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rloop=$(json_field "$line" loop)
    rts=$(json_field "$line" acted_ts)
    [ -n "$rloop" ] || continue
    LAST_ACTED[$rloop]="$rts"
  done < "$RETRY_STATE"
fi

# --- 3. Decide + act per loop (best-effort; one loop must not abort others) --

now=$(date +%s)
changed=0

for loop in "${!LATEST_BOUNCE[@]}"; do
  bts="${LATEST_BOUNCE[$loop]}"
  acted="${LAST_ACTED[$loop]:-}"

  # dedup: only a bounce NEWER than the last one we acted on is actionable.
  if [ -n "$acted" ]; then
    bkey=$(ts_key "$bts"); akey=$(ts_key "$acted")
    [ "${bkey:-0}" -gt "${akey:-0}" ] || continue
  fi

  # 3a. next_fire → epoch SECONDS. systemd 257+ renders NextElapseUSecRealtime as a formatted
  #     timestamp ("Mon 2026-07-13 19:00:00 UTC"); older systemd as raw µs; a monotonic-only or
  #     unscheduled timer as empty/0. next_fire_epoch normalizes all three — an EMPTY result ⇒ no
  #     bounded realtime schedule ⇒ unbounded ⇒ skip (don't early-retry a loop with no natural
  #     fallback). (The prior all-digit guard silently broke on the systemd 257 upgrade — harnessd-95w.)
  nf_raw=$("$SYSTEMCTL_BIN" --user show "$loop.timer" -p NextElapseUSecRealtime --value 2>>"$LOG")
  nf_sec=$(next_fire_epoch "$nf_raw")
  if [ -z "$nf_sec" ]; then
    note "skip $loop: no bounded next_fire (raw='$nf_raw') — unbounded, not retrying"
    continue
  fi

  # 3b. next fire already due ⇒ let the natural timer take over.
  if [ "$now" -ge "$nf_sec" ]; then
    note "skip $loop: next_fire ($nf_sec) already due (now=$now) — natural timer takes over"
    continue
  fi

  # 3c. Resolve the target window from the unit's ExecStart (defaults work/pulse).
  es=$("$SYSTEMCTL_BIN" --user show "$loop.service" -p ExecStart 2>>"$LOG")
  session=$(execstart_flag "$es" --session); session=${session:-work}
  window=$(execstart_flag "$es" --window);   window=${window:-pulse}

  target_name=""
  found=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(strip_lexicon "$name")" = "$window" ]; then
      target_name="$name"; found=1; break
    fi
  done < <("$TMUX_BIN" list-windows -t "=$session" -F '#{window_name}' 2>>"$LOG")

  # 3d. Still 🔔 ⇒ still blocked ⇒ skip, leave UNACTED (poll again next run).
  #     KEY: never re-fire into a 🔔 window (it would just re-bounce).
  if [ "$found" = 1 ] && [ "$target_name" != "${target_name#🔔}" ]; then
    note "skip $loop: window '$target_name' ($session) still 🔔 — leaving unacted, will poll again"
    continue
  fi

  # 3e. 🔔 cleared (or window absent ⇒ definitely not blocked) ⇒ re-fire.
  if [ "$found" = 1 ]; then
    where="window '$target_name' ($session) cleared 🔔"
  else
    where="window '$window' ($session) absent"
  fi
  if "$SYSTEMCTL_BIN" --user start "$loop.service" >>"$LOG" 2>&1; then
    note "re-fired $loop.service — $where (bounce $bts)"
    LAST_ACTED[$loop]="$bts"
    changed=1
  else
    note "WARN: 'systemctl --user start $loop.service' failed — leaving unacted for next run"
  fi
done

# --- 4. Write retry-state atomically (only when something changed) ----------

if [ "$changed" = 1 ]; then
  tmp="$RETRY_STATE.tmp.$$"
  : > "$tmp" || { note "FAIL: cannot write retry-state tmp $tmp"; exit 74; }
  for loop in "${!LAST_ACTED[@]}"; do
    printf '{"loop":"%s","acted_ts":"%s"}\n' "$loop" "${LAST_ACTED[$loop]}" >> "$tmp"
  done
  mv -f "$tmp" "$RETRY_STATE" || { note "FAIL: cannot install retry-state $RETRY_STATE"; rm -f "$tmp"; exit 74; }
fi

exit 0
