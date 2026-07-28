#!/bin/bash
# pulse-inject.sh — the tmux-injection scheduler primitive (/pulse OQ-1).
#
# Fired by a systemd user timer (or anything else). Ensures the
# dedicated scheduler window exists in Andrew's tmux, ensures an
# INTERACTIVE Claude Code session is running there, then types the
# kick-off command into it via send-keys.
#
# Why injection instead of `claude -p`: headless -p draws from the
# separate monthly Agent SDK credit pool (docs, 2026-06-15 policy) and
# is invisible — Andrew can't watch or steer. An interactive session in
# a tmux window uses the normal subscription, is observable by both
# Andrew and the agent, persists between ticks, and inherits the
# 🧠/✅/🔔/🌀 window lexicon (tmux-status.sh).
#
# Usage:
#   pulse-inject.sh --dir <project-path> --cmd "<prompt or /skill>" \
#                   [--session work] [--window pulse] [--launch claude] [--loop <id>]
#
#   --dir      project directory the Claude session anchors in (required)
#   --cmd      the text typed into the session, submitted with Enter (required)
#   --session  tmux session name (default: work — created detached if absent,
#              so timers still work after a reboot before Andrew attaches)
#   --window   dedicated window name (default: pulse). Matching strips any
#              leading lexicon glyph (🧠/✅/🔔/🌀) so the status hook's renames
#              don't break window discovery.
#   --launch   program to start when the window has no live session
#              (default: claude). Tests override with something inert.
#   --loop     the loop id (= the manifest timer / harness-state loop id, e.g.
#              pulse-daily-digest). Units pass `--loop %p` (systemd expands %p to
#              the unit prefix). On a 🔔-defer, the loop id is recorded to
#              ~/.local/state/harness/pulse-bounces.jsonl so the state bus renders
#              the tick as 'bounced' instead of a false 'tick in flight'
#              (harnessd-gf6). Optional + backward-compatible: omit it and defer
#              behaves exactly as before (logs, no bounce record). That log is
#              RETENTION-BOUNDED — see BOUNCE_MAX_LINES / PULSE_BOUNCE_MAX_LINES
#              below for the cap and exactly what it discards (explore-foda).
#   --fresh    OPT-IN (default OFF): warm process, COLD CONTEXT. When the pane
#              already runs the launcher, send `/clear` + Enter and settle before
#              typing the tick command, so the tick starts near the onboard floor
#              instead of re-creating the session's whole accumulated prefix.
#              Rationale (dotfiles-6ycc, ~/explore/refs/warm-session-collapse.md):
#              the prompt cache TTL is ~1h and pulse cadences are hours apart, so
#              a "warm" session buys ZERO cached tokens and pays full
#              cache-creation on everything it has accumulated. Measured on the
#              explore slug since 2026-07-01: warm resumes after a >=3h gap
#              re-create a 442,914-token median (84% of them re-create >=99% of
#              their context) against a 78,270 first-turn floor — 5.7x, and it
#              grows with session age. This decouples process liveness (keep it:
#              no relaunch race, no SessionStart re-run, scrollback survives)
#              from context accumulation (drop it). On a COLD launch --fresh is a
#              no-op: the context is already fresh and /clear would only cost a
#              round trip. /clear re-reads CLAUDE.md + the memory tier from disk
#              (verified end-to-end), so a --fresh loop cannot act on a stale
#              always-loaded snapshot.
#              PULSE_FRESH_SETTLE (default 2) = seconds to settle after /clear.
#
# Behavior contract (tested in test-pulse-inject.sh):
#   1. No tmux server / no session  -> created detached.
#   2. No window named <window>     -> created with cwd <dir>.
#   3. Window exists, launch absent -> launch started, waited for, cmd sent.
#   4. Window exists, launch alive  -> cmd sent directly.
#   5. The window name match is lexicon-aware (✅ pulse == pulse).
#   6. --fresh + warm pane -> /clear sent BEFORE the cmd, same window.
#   7. --fresh + cold launch -> no /clear (already fresh).
#   8. --fresh never runs on a 🔔-deferred tick (the guard wins).
#   9. Readiness gate times out -> BOUNCE (record + exit 0), never a blind
#      inject into a composer that isn't there (dotfiles-mrta).
#
# OUTCOME CONTRACT — PULSE_INJECT_RESULT (dotfiles-q0qi).
#
#   THE EXIT CODE CANNOT ANSWER "DID ANYTHING GET TYPED?". This script exits 0
#   on three structurally different outcomes: it really injected; it BOUNCED
#   because the composer never reported input-ready; it DEFERRED because the
#   window is 🔔-blocked on Andrew. All three are correct for /pulse (whose
#   contract is "the next timer retries") and all three are indistinguishable to
#   a caller reading only `$?` — which is exactly the fleet's #1 defect shape
#   (dotfiles-cxle, "the reporter keeps saying success"). A ONE-SHOT consumer —
#   picod's ha-portal 🛎️ button, any daemon with no next timer — has no retry to
#   paper over the difference: a deferred press is a silently dropped request.
#
#   So EVERY terminal path prints exactly ONE machine-readable line, and it is
#   the LAST line of STDOUT:
#
#     PULSE_INJECT_RESULT=injected                    the cmd was typed + Enter sent
#     PULSE_INJECT_RESULT=bounced-not-ready           readiness gate timed out; typed NOTHING
#     PULSE_INJECT_RESULT=deferred-blocked-on-human   window is 🔔-blocked; typed NOTHING
#     PULSE_INJECT_RESULT=failed-usage                bad/missing args (exit 64)
#     PULSE_INJECT_RESULT=failed-no-dir               --dir does not exist (exit 66)
#     PULSE_INJECT_RESULT=failed-no-tmux              tmux binary not found (exit 69)
#     PULSE_INJECT_RESULT=failed-no-session           could not create the tmux session (exit 70)
#     PULSE_INJECT_RESULT=failed                      any other non-zero exit (crash/EXIT trap)
#
#   STREAM: STDOUT, always. note() writes only to $LOG (/tmp/pulse-inject.log) and
#   the argument guards write their prose to STDERR — neither is the verdict. A
#   consumer must capture stdout (`OUT="$(pulse-inject.sh … )"`, or `2>&1` if it
#   also wants the guard prose) and read the marker from it.
#
#   PARSING: match the literal `PULSE_INJECT_RESULT=<verdict>`; take the LAST such
#   line if you see more than one (there is exactly one per run by construction).
#   Every hard-failure verdict starts with `failed`, so `case "$v" in failed*)` is
#   a stable "this run errored" test that survives new failure verdicts.
#
#   FAIL CLOSED: exit 0 with NO marker means an OLDER injector, or a path that
#   forgot to report — treat it as NOT injected, never as success. Only
#   `injected` may set a caller's "delivered" flag. Never `pulse-inject.sh &&
#   DELIVERED=true`: that is the same defect one layer down.
#
#   EXIT CODES ARE UNCHANGED by this contract — it is purely additive, because
#   every /pulse systemd unit on the box calls this script. Consumer shape:
#   readme_push_verdict() in ~/andrewzigler3/scripts/daily-build.sh; template in
#   ~/dotfiles/agents/skills/daemon/reference/templates/verdict-contract.sh.
#
# Logs to /tmp/pulse-inject.log, one line per event, appended under an
# exclusive flock and tagged with this run's pid so simultaneous ticks
# (pulse-explore — pulse-dive after the rename flip — and pulse-di-thursday
# both fire at 13:00 UTC) stay
# attributable instead of braiding into an unreadable record — see note().
# Exit non-zero on hard failures so the systemd unit records them
# (journalctl --user -u pulse-*).

set -uo pipefail

LOG=/tmp/pulse-inject.log
# PULSE_TMUX_BIN is a TEST SEAM (same idiom as HARNESS_STATE_DIR below): it lets
# the suite point at an absent binary (exit 69) or a stub that fails (exit 70) so
# those terminal paths — and their verdict markers — are actually exercised.
# Unset (production, always) the resolution below is byte-for-byte what it was.
TMUX_BIN=${PULSE_TMUX_BIN:-}
if [ -z "$TMUX_BIN" ]; then
  TMUX_BIN=$(command -v tmux 2>/dev/null)
  [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
fi

SESSION="work"
WINDOW="pulse"
LAUNCH="claude"
# Process name to expect in the pane once the launcher is live (liveness/reuse
# detection). Empty => default to basename of --launch (today's behavior). A
# jailed launcher (tick-jailed.sh) execs `bwrap`, so its pane_current_command
# reads 'bwrap' not 'tick-jailed.sh' — those loops pass --launch-detect bwrap.
LAUNCH_DETECT=""
DIR=""
CMD=""
LOOP=""
FRESH=0
# Retention bound for the bounce log (explore-foda). It was append-only and read IN FULL
# on every harnessd state generation, so a loop bouncing on every tick while Andrew is
# away grew it without limit. Same idiom + same trim shape as the vault-sync ledger's
# VAULT_SYNC_LEDGER_MAX_LINES: over the cap, keep the newest HALF via an atomic rename,
# so a concurrent harnessd read always sees a complete file.
#
# WHAT THE BOUND DISCARDS, stated plainly: the OLDEST lines, once there are more than
# 2000. Both consumers only ever want the NEWEST record per loop — harnessd's
# _newest_bounce_by_loop / newestBounceByLoop reduce to it, and pulse-retry.sh takes the
# latest bounce ts per loop — so the only reachable loss is a loop whose newest bounce has
# been pushed out by 1000+ NEWER bounces from other loops. At the ~11 loops on this box
# that takes ~90 bounces per loop, and such a bounce is long past its own next scheduled
# fire, which is the hard TTL pulse-retry.sh already refuses to retry past. Nothing else
# reads this file: it is not history, it is a latest-state signal with a log's shape.
BOUNCE_MAX_LINES="${PULSE_BOUNCE_MAX_LINES:-2000}"   # ~160 KB; trims to the newest 1000

# emit_result <verdict> — the outcome contract (see the header). ONE line, on
# STDOUT, on every terminal path.
#
# Defined BEFORE argument parsing on purpose: the very first thing that can end
# this script is `unknown arg` (exit 64), and a path that exits before the
# emitter exists is a path with no verdict — the exact hole this closes.
#
# Idempotent by design. The EXIT trap is a backstop for the paths nobody wrote
# (an unbound variable under `set -u`, a kill, a future edit that adds an exit
# and forgets the marker): it emits `failed` only when the run is ending
# non-zero AND nothing has reported yet. The guard is what keeps "exactly one
# marker per run" true rather than aspirational — without it the success path
# would print `injected` and the trap would happily print again.
INJECT_RESULT_SENT=0
emit_result() {
  [ "$INJECT_RESULT_SENT" -eq 1 ] && return 0
  INJECT_RESULT_SENT=1
  printf 'PULSE_INJECT_RESULT=%s\n' "$1"
}
# shellcheck disable=SC2317  # invoked indirectly, via `trap _on_exit EXIT` below.
_on_exit() {
  local rc=$?
  [ "$rc" -ne 0 ] && emit_result failed
  exit "$rc"
}
trap _on_exit EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR=$2; shift 2 ;;
    --cmd)     CMD=$2; shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --window)  WINDOW=$2; shift 2 ;;
    --launch)  LAUNCH=$2; shift 2 ;;
    --launch-detect) LAUNCH_DETECT=$2; shift 2 ;;
    --loop)    LOOP=$2; shift 2 ;;
    --fresh)   FRESH=1; shift ;;
    *) echo "pulse-inject: unknown arg $1" >&2; emit_result failed-usage; exit 64 ;;
  esac
done

# Append one log line ATOMICALLY (dotfiles-0lm3). Two guarantees, both needed:
#
#  1. `flock` on the log fd serializes writers, so a line is never torn in half
#     by a simultaneous tick. (The bare `echo >>` this replaces relied on the
#     kernel's O_APPEND write being one syscall — true in practice for short
#     lines, but not a contract, and the `caller:` line carries two 160-char
#     cmdlines.)
#  2. The `[pid]` tag makes a RECORD reconstructable. This is the half a plain
#     flock does NOT fix and the one that actually bit: the observed damage was
#     never torn lines, it was interleaved *whole* lines — `pulse-explore` and
#     `pulse-di-thursday` fire at the same second, so their tick/caller/injected
#     lines braid and a per-tick reader attributes the wrong body to the wrong
#     header. Nine ticks read as "fired, no row" that way, which is exactly the
#     condition the stale-loop detector (harnessd-h14z) alerts on — i.e. the
#     unsynchronized log manufactures false alarms for a detector that has
#     already been silenced once. Grouping by pid de-braids them.
#
# Format stays `<utc-ts> <fields>` with the tag inserted after the timestamp, so
# existing greps (`grep ' tick: '`, `grep 'launched '`) are unaffected.
# If `flock` is unavailable the write still goes to the same O_APPEND fd —
# degraded, never lost.
#
# $BASHPID, not $$: bash does NOT update $$ inside a subshell, so two writers
# forked from one parent would share a tag and re-braid. Production always runs
# this as its own process (where they agree), but the tag must be right in every
# caller shape or the de-braiding is silently a no-op. Fallback for non-bash.
note() {
  { flock -w 5 9 2>/dev/null
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$LOG"
}

# record_bounce <reason>
#   A tick that did NOT get delivered must leave a machine-readable trace, or
#   it is indistinguishable from one that never fired — the "fired but no
#   ledger row" class the stale-loop detector (harnessd-h14z) alerts on.
#   Written where the state bus reads it, so the tick renders 'bounced'
#   instead of a false 'tick in flight' (harnessd-gf6).
#
#   Loop-scoped: only when --loop was passed (units pass `--loop %p`).
#   Best-effort and must NEVER fail the caller's exit 0 — a bounce that can't
#   be recorded is still a bounce, and losing the injector on top of it would
#   be strictly worse. The retention trim inherits that rule: it is appended
#   AFTER the write, guarded, and its failure is silent (see BOUNCE_MAX_LINES).
record_bounce() {
  local reason=$1
  [ -n "$LOOP" ] || return 0
  local _bdir="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"   # override for tests
  local _bfile="$_bdir/pulse-bounces.jsonl"
  { mkdir -p "$_bdir" 2>/dev/null \
    && printf '{"ts":"%s","loop":"%s","reason":"%s"}\n' \
         "$(date -u +%FT%TZ)" "$LOOP" "$reason" >> "$_bfile" 2>/dev/null ; } \
    || note "bounce-record failed for loop '$LOOP' (reason=$reason, non-fatal)"
  # Bounded growth: over the cap, keep the newest half via an atomic rename (mv), so a
  # concurrent harnessd read never observes a truncated file. The trim runs only on a
  # bounce — a rare path — so the wc is free in practice. Runs LAST so a trim failure
  # can never cost the record itself.
  local _lines
  _lines=$(wc -l < "$_bfile" 2>/dev/null || echo 0)
  if [ "${_lines:-0}" -gt "$BOUNCE_MAX_LINES" ] 2>/dev/null; then
    tail -n $((BOUNCE_MAX_LINES / 2)) "$_bfile" > "$_bfile.tmp" 2>/dev/null \
      && mv -f "$_bfile.tmp" "$_bfile" 2>/dev/null \
      && note "bounce log trimmed to the newest $((BOUNCE_MAX_LINES / 2)) lines (was $_lines)"
  fi
}

if [ -z "$DIR" ] || [ -z "$CMD" ]; then
  echo "pulse-inject: --dir and --cmd are required" >&2
  emit_result failed-usage
  exit 64
fi
[ -d "$DIR" ] || { echo "pulse-inject: --dir $DIR does not exist" >&2; note "FAIL: dir missing: $DIR"; emit_result failed-no-dir; exit 66; }
[ -x "$TMUX_BIN" ] || { echo "pulse-inject: tmux not found" >&2; emit_result failed-no-tmux; exit 69; }

# Hand the tick an ABSOLUTE project anchor. A long-lived pulse session's
# shell cwd can drift (a stray `cd` in one tick persists), so a bare
# relative `refs/pulse-ledger.jsonl` in the next tick silently resolves
# against another project — crossing ledgers. Only this injector knows the
# canonical --dir, so append it to every /pulse command; the /pulse skill
# anchors refs/pulse.md + refs/pulse-ledger.jsonl to this absolute path.
ABS_DIR=$(cd "$DIR" 2>/dev/null && pwd -P) || ABS_DIR="$DIR"
case "$CMD" in
  /pulse|/pulse\ *) CMD="$CMD $ABS_DIR" ;;
esac

note "tick: session=$SESSION window=$WINDOW dir=$DIR cmd=$CMD"
# Caller provenance (diagnostic): who invoked this injector? A systemd unit
# leaves a journal trail; a self-scheduling loop (the /pulse anti-pattern) does
# not, so log the parent + grandparent so a ghost cadence can be traced.
_pcmd() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | cut -c1-160; }
_gpid=$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null)
note "  caller: ppid=$PPID ($(ps -o comm= -p "$PPID" 2>/dev/null)) [$(_pcmd "$PPID")] gpid=${_gpid:-?} ($(ps -o comm= -p "${_gpid:-0}" 2>/dev/null)) [$(_pcmd "${_gpid:-0}")]"

# 1. Ensure the session exists (detached creation survives reboots —
#    the window is there when Andrew attaches).
if ! "$TMUX_BIN" has-session -t "=$SESSION" 2>/dev/null; then
  "$TMUX_BIN" new-session -d -s "$SESSION" -c "$DIR" \
    || { note "FAIL: cannot create session"; emit_result failed-no-session; exit 70; }
  note "created session $SESSION (detached)"
fi

# 2. Find the dedicated window, lexicon-aware: the tmux-status hook
#    prefixes 🧠/✅/🔔/🌀, so "✅ pulse" must match "pulse".
strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀) ?//'; }

WIN_ID=""
while IFS=$'\t' read -r id name; do
  if [ "$(strip_lexicon "$name")" = "$WINDOW" ]; then
    WIN_ID=$id
    break
  fi
done < <("$TMUX_BIN" list-windows -t "=$SESSION" -F $'#{window_id}\t#{window_name}' 2>/dev/null)

if [ -z "$WIN_ID" ]; then
  WIN_ID=$("$TMUX_BIN" new-window -d -P -F '#{window_id}' -t "=$SESSION" -n "$WINDOW" -c "$DIR")
  note "created window $WINDOW ($WIN_ID)"
fi

PANE="$WIN_ID.0"

# 3. Ensure the launch program is running in the pane.
LAUNCH_BASE=$(basename "${LAUNCH%% *}")
# EXPECT = the process name that means "the launcher is live in this pane".
# Defaults to the launcher basename; jailed loops override via --launch-detect
# (pane_current_command reads 'bwrap' under tick-jailed.sh, so without this a
# warm jailed session is never recognized and every tick re-types junk).
EXPECT="${LAUNCH_DETECT:-$LAUNCH_BASE}"
CURRENT_CMD=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)

# Was the launcher ALREADY live when this tick arrived? (i.e. did we take the
# warm fall-through rather than the cold-launch branch). --fresh keys off this:
# a session we just launched is already at the onboard floor.
WAS_WARM=0
[ "$CURRENT_CMD" = "$EXPECT" ] && WAS_WARM=1

if [ "$CURRENT_CMD" != "$EXPECT" ]; then
  # cd first so a recycled shell pane anchors in the right project.
  "$TMUX_BIN" send-keys -t "$PANE" "cd $(printf '%q' "$DIR")" Enter
  sleep 0.5
  "$TMUX_BIN" send-keys -t "$PANE" "$LAUNCH" Enter
  note "launched '$LAUNCH' in $PANE (was: ${CURRENT_CMD:-empty})"
  # Wait for the launch PROCESS to come up — this is LIVENESS, not readiness
  # (bounded poll, then proceed). Claude Code's pane_current_command flips to
  # 'claude' within a second or two of exec.
  for _ in $(seq 1 30); do
    sleep 1
    NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
    [ "$NOW" = "$EXPECT" ] && break
  done
  NOW=$("$TMUX_BIN" display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
  [ "$NOW" = "$EXPECT" ] \
    || note "WARN: '$EXPECT' not detected after 30s (pane runs '$NOW')"

  # Liveness (the process exists) is NOT readiness (the TUI can accept typed
  # input). pane_current_command flips to 'claude' within ~1-4s of exec, but the
  # interactive TUI needs longer to draw its composer; typing before then drops
  # the keystrokes SILENTLY. The old cold-boot path detected the process, slept a
  # fixed 3s, then injected — an UNGUARDED timing race that never checked whether
  # the composer was actually up. Whether the 3s lands after-ready varies with
  # boot load, session weight, and attachment, so the SAME injector wins some cold
  # boots and loses others. Evidence (pulse-inject.log): weekly-report cold-boots
  # a fresh window + fresh claude every week (it does NOT reuse a warm session)
  # into the DETACHED, lighter `work` session and injected at +4s/+5s — after
  # ready. The ha-portal button cold-boots into the ATTACHED, heavier ~/explore
  # session (bigger CLAUDE.md + SessionStart) and injected at +5s/+6s/+7s — the
  # +7s run landed BEFORE ready, so '/ha-serve' was eaten and the homeowner queue
  # never drained (a later press into the now-warm session worked). Note the
  # FAILING boot waited LONGER than the winners — so a bigger fixed sleep is not
  # the fix, and the on-demand button (no next-tick retry to paper over a miss) is
  # just what surfaced the race. FIX: poll the pane for an input-READY marker
  # (Claude Code's composer footer) before typing, then a small settle.
  #
  # ON TIMEOUT WE NOW BOUNCE, NOT INJECT (dotfiles-mrta). The original gate fell
  # back to "inject anyway", reasoning that a marker miss should degrade to "try
  # late" rather than "never". Observed 2026-07-25 on a cold boot: the composer
  # took ~60s to paint, the gate timed out at its 60s ceiling, typed into an
  # empty composer, and the tick was EATEN — 0% context, no work, no ledger row.
  # "Inject anyway" is not "try late": there is nothing to type into, so it is a
  # SILENT loss, and it is a concrete mechanism for the "fired but no ledger row"
  # class (harnessd-h14z; the two explore ticks that vanished over 16 days).
  # Bouncing costs nothing by comparison — pulse-retry.timer fires every 2 min
  # and the pane is warm by then — and it leaves a record, which is the whole
  # difference between a tick that produced no work and a tick that never fired.
  #   PULSE_READY_MARKER     — ERE matched against capture-pane. Empty DISABLES
  #                            the gate (non-TUI launches / tests). Default = CC
  #                            composer footer.
  #   PULSE_READY_TIMEOUT    — ceiling in seconds (default 90; see below). The
  #                            first match returns immediately.
  #   PULSE_READY_ON_TIMEOUT — bounce (default) | inject. `inject` restores the
  #                            pre-mrta behavior. It exists as an escape hatch
  #                            for exactly one failure mode: Claude Code changing
  #                            its footer text, which would make the marker never
  #                            match and bounce EVERY tick. Reach for it to
  #                            unblock, then fix the marker — do not leave it on.
  #
  # THE 60 -> 90 DEFAULT, and what it is (and is not) based on. The honest
  # answer is that the ceiling is no longer load-bearing: once a timeout bounces
  # instead of injecting blind, being wrong costs one retry cycle rather than a
  # lost tick. 90 is chosen as: comfortably past the single observed failure
  # (~60s, a first-run-in-a-new-project cold boot — the slowest possible case),
  # while keeping the injector's worst case inside the 120s TimeoutStartSec on
  # pulse-retry.service, which invokes loop units with a BLOCKING
  # `systemctl --user start`. It is NOT a measured percentile: /tmp/pulse-inject.log
  # holds only 3 gated claude cold boots since the gate shipped (two at +2s, one
  # timing out at 60s), and the remaining 23 `launched 'claude'` entries predate
  # the gate entirely. Rather than guess harder, the success path below now logs
  # the OBSERVED seconds, so the distribution accumulates for free and the next
  # person to touch this number can set it from data.
  READY_MARKER=${PULSE_READY_MARKER-'shift\+tab to cycle|\? for shortcuts|for agents|bypass permissions|accept edits on|plan mode on'}
  READY_TIMEOUT=${PULSE_READY_TIMEOUT:-90}
  READY_ON_TIMEOUT=${PULSE_READY_ON_TIMEOUT:-bounce}
  if [ -n "$READY_MARKER" ]; then
    # Deadline, not `seq 1 $N` + `sleep 1`: each iteration also pays for a
    # capture-pane and a grep, so the counting loop overshot its own advertised
    # ceiling — the 2026-07-25 incident logged "not seen after 60s" 63 seconds
    # after launch. A wall-clock deadline makes the number in the message true,
    # which matters now that the same number decides whether to bounce.
    _ready_t0=$(date +%s)
    _ready_deadline=$(( _ready_t0 + READY_TIMEOUT ))
    _ready=""
    while [ "$(date +%s)" -lt "$_ready_deadline" ]; do
      if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -Eq "$READY_MARKER"; then
        _ready=1; break
      fi
      sleep 1
    done
    _ready_elapsed=$(( $(date +%s) - _ready_t0 ))
    if [ -n "$_ready" ]; then
      # The elapsed seconds are the measurement PULSE_READY_TIMEOUT should be
      # set from; log them so the sample grows without anyone instrumenting.
      note "input-ready marker seen after ${_ready_elapsed}s (ceiling ${READY_TIMEOUT}s); settling before inject"
      sleep 2
    elif [ "$READY_ON_TIMEOUT" = "inject" ]; then
      note "WARN: input-ready marker not seen after ${_ready_elapsed}s — injecting anyway (PULSE_READY_ON_TIMEOUT=inject)"
    else
      note "BOUNCED: input-ready marker not seen after ${_ready_elapsed}s — NOT injecting '$CMD'; next timer retries"
      record_bounce "not_ready"
      # Exit 0 is deliberate (a bounce is a deferral, not a unit failure — see
      # test case 13), so the VERDICT is the only thing that tells a caller
      # nothing was typed. record_bounce() is loop-scoped and best-effort; this
      # marker is unconditional and in-band.
      emit_result bounced-not-ready
      exit 0
    fi
  else
    sleep 3
  fi
fi

# 3.5 Modal-safety guard. Do NOT inject into a window that's blocked on
#    Andrew. The tmux-status hook prefixes "🔔 " when the session is
#    waiting on an AskUserQuestion / ExitPlanMode / permission prompt
#    (PreToolUse + permission Notification), and clears it only when work
#    resumes (PostToolUse -> 🧠 / Stop -> ✅) — so "🔔 " is present for
#    exactly the blocked-modal duration. send-keys here would feed the
#    command into the MODAL DIALOG (not the message composer): the text is
#    eaten and the trailing Enter resolves the dialog with the wrong/default
#    answer — losing the tick AND mis-answering Andrew's open question. The
#    text is NOT queued (queuing only happens at the composer). So defer:
#    log and exit 0; the next timer retries once Andrew has answered. This
#    is 🔔-specific — 🧠 (mid-turn, the composer cleanly queues), ✅, 🌀, and
#    a bare/fresh window all still inject.
WIN_NAME=$("$TMUX_BIN" display-message -p -t "$PANE" '#{window_name}' 2>/dev/null)
if [ "$WIN_NAME" != "${WIN_NAME#🔔}" ]; then
  note "deferred: window '$WIN_NAME' is blocked on Andrew (🔔) — not injecting '$CMD'; next timer retries"
  # Record the bounce where the state bus can read it (harnessd-gf6). A deferred
  # tick never ran, so the bus must render 'bounced' — not a false 'tick in flight'.
  # The writer is shared with the not_ready bounce above (dotfiles-mrta): both are
  # "the tick did not get delivered", and one implementation means the two paths
  # cannot drift into different record shapes.
  record_bounce "blocked_on_andrew"
  # Same reasoning as the not_ready bounce above: exit 0 is right for /pulse and
  # useless to a one-shot caller, so the verdict carries the outcome. This is the
  # path that silently ate picod's homeowner button press (dotfiles-q0qi).
  emit_result deferred-blocked-on-human
  exit 0
fi

# 3.75 --fresh: warm process, COLD CONTEXT (dotfiles-6ycc).
#
#   ORDERING IS LOAD-BEARING — this MUST come after the 🔔 guard above, not
#   before it (the decision brief's §6 sketch put it before, at the old line
#   ~199; that is wrong). A 🔔 window is sitting in a modal dialog: send-keys
#   there feeds the DIALOG, not the composer, and the trailing Enter resolves it
#   with the default answer. Clearing before the guard would therefore
#   mis-answer Andrew's open question AND wipe the context of the session that
#   was waiting on him — strictly worse than the tick we were already deferring.
#   Deferred ticks must leave the pane untouched, /clear included.
#
#   Only fires on a WARM pane: a cold launch is already at the onboard floor.
#   Sent exactly like the tick command below (text, pause, Enter) — the same
#   path that delivers `/pulse tick` in production, so the slash-command palette
#   behaves identically. Nothing about the window changes: same pane, same
#   scrollback, same process; only the model's context resets.
if [ "$FRESH" = 1 ] && [ "$WAS_WARM" = 1 ]; then
  "$TMUX_BIN" send-keys -t "$PANE" -- "/clear"
  sleep 0.3
  "$TMUX_BIN" send-keys -t "$PANE" Enter
  note "fresh: sent /clear to $PANE (warm session -> cold context)"
  # NOT covered by the readiness gate above, and it cannot be: that gate polls
  # for the composer FOOTER, and the footer never disappears during a /clear
  # repaint — the marker matches instantly and proves nothing. So this settle is
  # still a fixed sleep, i.e. the same unguarded timing race the cold-boot path
  # had before dotfiles-6ycc. Raise PULSE_FRESH_SETTLE if a --fresh loop starts
  # losing ticks; closing it properly needs a post-/clear marker that is
  # distinguishable from the pre-/clear one (dotfiles-mrta, unresolved).
  sleep "${PULSE_FRESH_SETTLE:-2}"
elif [ "$FRESH" = 1 ]; then
  note "fresh: skipped /clear (cold launch — context already fresh)"
fi

# 4. Inject the command. Text first, Enter separately — some TUIs
#    mis-handle a combined burst.
"$TMUX_BIN" send-keys -t "$PANE" -- "$CMD"
sleep 0.3
"$TMUX_BIN" send-keys -t "$PANE" Enter
note "injected into $PANE"

emit_result injected
exit 0
