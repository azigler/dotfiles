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
#        d.5 A BOUNCE IS A CLAIM ABOUT THE PAST — re-verify it against the PRESENT
#           before acting on it (dotfiles-t5fj). Two independent staleness signals;
#           EITHER one ⇒ the bounce is RESOLVED ⇒ skip and mark ACTED.
#        e. Still live → `systemctl --user start <loop>.service` and mark last-acted.
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
# STALENESS: RE-VERIFY THE BOUNCE BEFORE RE-FIRING (dotfiles-t5fj, step 3d.5)
# ---------------------------------------------------------------------------
# The dedup above answers "have I acted on this bounce?" — it does NOT answer "is
# this bounce still worth acting on?". Measured 2026-08-09, 15:50:55Z: two
# blocked_on_andrew bounces for pulse-marshal (15:47:16, 15:48:32) were sitting
# unacted; a supervising session cleared the blockage and injected the tick BY HAND
# at 15:50:51; four seconds later this watcher saw a cleared 🔔 and re-fired the
# unit anyway. The re-fired pulse-inject typed `/clear` + `/marshal night` into the
# now-🧠 composer of the LIVE run, where it QUEUED — a delayed wipe of the running
# drain's context, armed to fire at whatever turn boundary came next.
#
# So a bounce older than the present is checked against the present, two ways.
# EITHER signal resolves it:
#
#   (i)  DELIVERY — pulse-inject.sh writes one row per delivered injection to
#        $STATE_DIR/pulse-injections.jsonl (dotfiles-t5fj). A row for this loop
#        NEWER than the bounce means somebody already delivered this tick — by
#        hand, by an earlier retry, by the natural timer — so the bounce is spent.
#        And a row naming THIS session+window while that window is mid-turn
#        (🧠/🌀) AND YOUNGER THAN PULSE_SAME_LOOP_TTL means the tick is running
#        RIGHT NOW: re-firing would queue behind it, which is the incident above.
#        That third clause is not decoration — this is the ONE branch here that
#        compares nothing against the bounce, so without a TTL a weeks-old row
#        (the file retains ~1000) plus a lying 🧠 would keep a genuine bounce
#        acted forever. The knob is pulse-inject.sh's, shared rather than
#        duplicated: same proposition, one TTL.
#   (ii) LEDGER — a completion row newer than the bounce. Where the loop is
#        registered in the harnessd manifest (~/harnessd/refs/harness-manifest.json),
#        that manifest already pins its ledger + ledger_row per loop; the lookup and
#        the jq query here are REPLICATED from pulse-ledger-watch.sh so there is one
#        discovery mechanism on this box, not a third. A loop with no manifest entry
#        simply has no ledger signal, and the log says so rather than implying a
#        check that never ran.
#
# Resolved ⇒ SKIP, and mark ACTED (unlike the 🔔 skip, which stays unacted on
# purpose): the bounce is spent, so re-checking it every two minutes until its next
# scheduled fire would be pure noise.
#
# ⚠️ AND THE LOG SAYS ONLY WHAT WAS OBSERVED. The incident's own re-fire line read
# "window cleared 🔔" — this script did not clear it; the supervisor's verified
# rename did, and the engine merely outlived it. Every line below names the
# OBSERVATION (a ledger row's ts, a delivery row's ts, a window's current glyph),
# never a causal claim it cannot support. Same rule as pulse-escalate.sh's "AND THE
# LOG SAYS ONLY WHAT THIS SCRIPT DID".
#
# COUNTERPART: pulse-escalate.sh's "SINGLE OWNERSHIP OF THE RE-FIRE DECISION" block.
# That script clears a lying 🔔 and STOPS — it never re-fires, precisely so this
# watcher stays the only re-fire path. This section is the other half of that pair:
# the single owner re-fires only after proving the bounce is still live.
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
#   HARNESS_MANIFEST    — the harnessd loop manifest the staleness check resolves
#                         ledgers through (same seam name pulse-ledger-watch.sh uses).
#   PULSE_SAME_LOOP_TTL — seconds a delivery row may still be read as "that turn is
#                         this loop's tick" (default 86400). SHARED with
#                         pulse-inject.sh's guard — same claim, one knob.

set -uo pipefail

STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LOG="${PULSE_RETRY_LOG:-$STATE_DIR/pulse-retry.log}"
BOUNCES="$STATE_DIR/pulse-bounces.jsonl"
RETRY_STATE="$STATE_DIR/pulse-retry-state.jsonl"
# Written by pulse-inject.sh on every DELIVERED injection (dotfiles-t5fj) — the
# staleness check's first signal. Absent file ⇒ no delivery has ever been recorded
# ⇒ the signal is simply unavailable, never "nothing was delivered".
INJECTIONS="$STATE_DIR/pulse-injections.jsonl"
# The loop → ledger mapping. Same file, same seam name, same query as
# pulse-ledger-watch.sh (which this script already invokes): ONE discovery
# mechanism for "where does this loop record its completions".
MANIFEST="${HARNESS_MANIFEST:-$HOME/harnessd/refs/harness-manifest.json}"
# ONE knob, shared with pulse-inject.sh's same-loop guard, deliberately: both
# scripts use it to bound the SAME claim — "the turn running in that pane is this
# loop's tick" — and two independently-drifting TTLs for one proposition is the
# two-copies defect. Default and name are pulse-inject.sh's; see step 3d.5.
SAME_LOOP_TTL="${PULSE_SAME_LOOP_TTL:-86400}"

TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null)
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl
# jq is only needed by the staleness check's LEDGER signal. Its absence disables
# that one signal (and says so at the decision point); everything else — including
# the DELIVERY signal, which is a plain grep — is unaffected.
JQ_BIN=$(command -v jq 2>/dev/null)
[ -x "${JQ_BIN:-}" ] || JQ_BIN=""

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

# --- Staleness helpers (dotfiles-t5fj; see the header block) -----------------

# newest_injection <loop> — the newest delivery row pulse-inject.sh recorded for
# this loop, or empty. Append-only file ⇒ the LAST matching line is the newest,
# the same assumption pulse-ledger-watch.sh makes about a ledger.
newest_injection() {
  # The readability guard above is what makes an unsuppressed grep safe here: an
  # absent file is answered before grep runs, so any stderr grep DOES produce is a
  # real error and belongs in the log rather than in /dev/null.
  [ -r "$INJECTIONS" ] || return 0
  grep -F "\"loop\":\"$1\"" "$INJECTIONS" 2>>"$LOG" | tail -n1
}

# injection_age <ts> — age in SECONDS of a delivery row's timestamp. Echoes 0 for
# an absent or malformed stamp, which is the SAFE answer here: 0 keeps the row
# inside the TTL, so an unreadable marker reads as "that turn may still be ours"
# and the re-fire is skipped. A re-fire skipped in error costs one cycle (the
# natural timer still fires); a re-fire made in error queues /clear into a live
# run. Same asymmetry, and the same direction, as pulse-inject.sh's guard.
#
# The shape is checked BEFORE date(1) so an unusable stamp is a DECISION this
# function makes rather than an error it swallows.
injection_age() {
  local _ts=$1 _epoch
  case "$_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) note "  delivery row ts '${_ts:-<none>}' is not YYYY-MM-DDTHH:MM:SSZ — treating it as age 0 (inside the TTL), because an unreadable marker must never read as 'nothing is running'"
       printf '0'; return 0 ;;
  esac
  _epoch=$(date -u -d "$_ts" +%s)
  printf '%s' "$(( $(date +%s) - _epoch ))"
}

# turn_in_flight <window-name> — does the lexicon say a turn is running there?
# 🧠 mid-turn, 🌀 compacting. ✅ / a bare name mean idle; 🔔 has its own earlier
# guard and never reaches here.
turn_in_flight() {
  [ "$1" != "${1#🧠}" ] && return 0
  [ "$1" != "${1#🌀}" ] && return 0
  return 1
}

# loop_ledger <loop> — echo "<absolute-ledger-path>\t<row-pin>" for a loop that
# the manifest registers, or nothing. row-pin empty means "match any row" (the
# manifest's documented `ledger_row: null`).
#
# The jq expression is copied from pulse-ledger-watch.sh rather than re-derived:
# the mapping question is identical, and two spellings of one query is how the two
# scripts would eventually disagree about where a loop's completions live.
loop_ledger() {
  local _loop=$1 _entry _proj _rel _row _path
  [ -n "$JQ_BIN" ] || return 1
  [ -r "$MANIFEST" ] || return 1
  _entry=$("$JQ_BIN" -c --arg t "$_loop" '
      [ .projects[]? | . as $p | (.loops[]? | select(.timer == $t)
        | {path: $p.path, ledger: .ledger, row: .ledger_row}) ] | first // empty' \
    "$MANIFEST" 2>>"$LOG") || return 1
  [ -n "$_entry" ] || return 1
  _proj=$(printf '%s' "$_entry" | "$JQ_BIN" -r '.path // empty' 2>>"$LOG")
  _rel=$(printf '%s' "$_entry" | "$JQ_BIN" -r '.ledger // empty' 2>>"$LOG")
  _row=$(printf '%s' "$_entry" | "$JQ_BIN" -r 'if .row == null then "" else .row end' 2>>"$LOG")
  [ -n "$_proj" ] && [ -n "$_rel" ] || return 1
  case "$_rel" in
    /*) _path="$_rel" ;;
    *)  _path="${_proj%/}/$_rel" ;;
  esac
  printf '%s\t%s' "$_path" "$_row"
}

# ledger_newest_ts <ledger> <row-pin> — the newest matching row's ts, or empty.
# Same jq shape as pulse-ledger-watch.sh's newest-row read, for the same reason.
ledger_newest_ts() {
  local _ledger=$1 _row=$2 _out
  [ -n "$JQ_BIN" ] || return 1
  [ -r "$_ledger" ] || return 1
  _out=$("$JQ_BIN" -sr --arg r "$_row" '
      [ .[] | select(type == "object") | select(has("ts"))
            | select($r == "" or ((.row // "") == $r)) ] | last // empty | .ts // empty' \
    "$_ledger" 2>>"$LOG") || return 1
  printf '%s' "$_out"
}

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

# HISTORY: this was gated OFF behind PULSE_LEDGER_WATCH_ENABLE for a few hours on
# 2026-08-07, the day it shipped. Adversarial review found it staging into a queue
# whose injected command was hardcoded for the REMOTE dispatcher — it told the
# receiving session to "land the ledger row", which a LOCAL tick has ALREADY written,
# so the session wrote a duplicate row with a fresh ts, which this watcher then read
# as new two minutes later: a self-sustaining announcement loop that corrupted the
# ledger the whole mechanism reads. dotfiles-sxsv made the injected command
# ORIGIN-AWARE (pulse-surface-queue.sh `--origin local|remote`), the local wording no
# longer instructs any ledger write, and the gate is gone. The kill switch is not
# retained: a wiring that can be silently off is a second way to lose the bell, which
# is the failure this whole mechanism exists to end.
LEDGER_WATCH="${PULSE_LEDGER_WATCH:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pulse-ledger-watch.sh}"
if [ -x "$LEDGER_WATCH" ]; then
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

  # 3d.5 IS THE BOUNCE STILL LIVE? (dotfiles-t5fj — see the header block.)
  #      Two independent signals; EITHER resolves the bounce. Resolved ⇒ skip AND
  #      mark acted: a spent bounce re-checked every 2 minutes is pure noise.
  #      Every message below states what was OBSERVED, never a cause.
  resolved=""
  inj_line=$(newest_injection "$loop")
  if [ -n "$inj_line" ]; then
    its=$(json_field "$inj_line" ts)
    isess=$(json_field "$inj_line" session)
    iwin=$(json_field "$inj_line" window)
    ikey=$(ts_key "$its"); bkey_s=$(ts_key "$bts")
    iage=$(injection_age "$its")
    if [ "$found" = 1 ] && [ "$isess" = "$session" ] && [ "$iwin" = "$window" ] \
       && turn_in_flight "$target_name" && [ "$iage" -le "$SAME_LOOP_TTL" ]; then
      # The incident's own shape: a tick of THIS loop is running in the very pane
      # a re-fire would inject into. Re-firing queues /clear behind a live run.
      #
      # ⚠️ THE TTL IS LOAD-BEARING HERE AND NOWHERE ELSE IN THIS STEP. The other
      # two signals compare a timestamp AGAINST THE BOUNCE, so they are
      # self-bounding — a row older than the bounce simply does not resolve it.
      # This branch compares against nothing: it reads a delivery row plus a
      # GLYPH, and a glyph can lie (a session that died mid-turn leaves 🧠
      # standing). Unbounded, one ancient row in a file that retains ~1000 of
      # them plus one stale 🧠 would mark a genuine bounce acted FOREVER, and it
      # would outlive even the injector's own 24h bound on the same claim. Same
      # knob as pulse-inject.sh's guard by design (PULSE_SAME_LOOP_TTL): the two
      # scripts are asserting the SAME proposition — "that turn is this loop's
      # tick" — and two independently-drifting TTLs for one claim is the
      # two-copies defect. (dotfiles-t5fj, adversarial review.)
      resolved="tick already running: window '$target_name' ($session) is mid-turn and pulse-inject last delivered '$loop' to $isess:$iwin at $its (${iage}s ago, within the ${SAME_LOOP_TTL}s TTL)"
    elif [ "${ikey:-0}" -gt "${bkey_s:-0}" ]; then
      resolved="already delivered at $its (pulse-inject recorded a delivery of '$loop' NEWER than the bounce $bts)"
    fi
  fi
  if [ -z "$resolved" ]; then
    if lref=$(loop_ledger "$loop"); then
      ledger_path=${lref%%$'\t'*}
      ledger_row=${lref#*$'\t'}
      lts=$(ledger_newest_ts "$ledger_path" "$ledger_row")
      lkey=$(ts_key "${lts:-}"); bkey_s=$(ts_key "$bts")
      if [ -n "$lts" ] && [ "${lkey:-0}" -gt "${bkey_s:-0}" ]; then
        resolved="resolved by ledger row $lts (row '${ledger_row:-<any>}' in $ledger_path is newer than the bounce $bts)"
      fi
    else
      # NOT "no completions" — "no way to look". Said out loud at the decision
      # point, because a signal that silently never fires is indistinguishable
      # from one that fired negative. The three reasons are kept apart because
      # they need different fixes (install jq / place the manifest / register
      # the loop).
      if [ -z "$JQ_BIN" ]; then
        why="jq is not installed"
      elif [ ! -r "$MANIFEST" ]; then
        why="$MANIFEST is unreadable"
      else
        why="$loop has no loops[] entry in $MANIFEST"
      fi
      note "note $loop: LEDGER signal unavailable ($why) — this decision rests on the delivery signal alone, not on a ledger that reported nothing"
    fi
  fi
  if [ -n "$resolved" ]; then
    note "skip $loop: bounce $bts is RESOLVED — $resolved. NOT re-firing (re-firing a spent bounce queues into a live run); marking acted."
    LAST_ACTED[$loop]="$bts"
    changed=1
    continue
  fi

  # 3e. Still live ⇒ re-fire. The wording is deliberately OBSERVATIONAL: this
  #     script did not clear the 🔔, it only found none — the 2026-08-09 log line
  #     that claimed the clearing was the credit-for-another-mechanism defect this
  #     bead also names.
  if [ "$found" = 1 ]; then
    where="window '$target_name' ($session) shows no 🔔"
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
