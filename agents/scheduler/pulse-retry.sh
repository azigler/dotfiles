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
# Overrides (for the hermetic test-harness):
#   HARNESS_STATE_DIR — where pulse-bounces.jsonl / pulse-retry-state.jsonl live.
#   PULSE_RETRY_LOG   — the note() log file (default <state-dir>/pulse-retry.log).

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
