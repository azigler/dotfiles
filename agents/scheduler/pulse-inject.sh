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
#              behaves exactly as before (logs, no bounce record).
#
# Behavior contract (tested in test-pulse-inject.sh):
#   1. No tmux server / no session  -> created detached.
#   2. No window named <window>     -> created with cwd <dir>.
#   3. Window exists, launch absent -> launch started, waited for, cmd sent.
#   4. Window exists, launch alive  -> cmd sent directly.
#   5. The window name match is lexicon-aware (✅ pulse == pulse).
#
# Logs to /tmp/pulse-inject.log. Exit non-zero on hard failures so the
# systemd unit records them (journalctl --user -u pulse-*).

set -uo pipefail

LOG=/tmp/pulse-inject.log
TMUX_BIN=$(command -v tmux 2>/dev/null)
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux

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

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR=$2; shift 2 ;;
    --cmd)     CMD=$2; shift 2 ;;
    --session) SESSION=$2; shift 2 ;;
    --window)  WINDOW=$2; shift 2 ;;
    --launch)  LAUNCH=$2; shift 2 ;;
    --launch-detect) LAUNCH_DETECT=$2; shift 2 ;;
    --loop)    LOOP=$2; shift 2 ;;
    *) echo "pulse-inject: unknown arg $1" >&2; exit 64 ;;
  esac
done

note() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

[ -n "$DIR" ] && [ -n "$CMD" ] || { echo "pulse-inject: --dir and --cmd are required" >&2; exit 64; }
[ -d "$DIR" ] || { echo "pulse-inject: --dir $DIR does not exist" >&2; note "FAIL: dir missing: $DIR"; exit 66; }
[ -x "$TMUX_BIN" ] || { echo "pulse-inject: tmux not found" >&2; exit 69; }

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
  "$TMUX_BIN" new-session -d -s "$SESSION" -c "$DIR" || { note "FAIL: cannot create session"; exit 70; }
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
  # (Claude Code's composer footer) before typing, then a small settle. Bounded;
  # on timeout inject anyway, so a marker miss degrades to "try late" (the old
  # behavior) rather than "never".
  #   PULSE_READY_MARKER  — ERE matched against capture-pane. Empty DISABLES the
  #                         gate (non-TUI launches / tests). Default = CC footer.
  #   PULSE_READY_TIMEOUT — max seconds to wait for the marker (default 60). The
  #                         first match returns immediately; this is only a ceiling.
  READY_MARKER=${PULSE_READY_MARKER-'shift\+tab to cycle|\? for shortcuts|for agents|bypass permissions|accept edits on|plan mode on'}
  READY_TIMEOUT=${PULSE_READY_TIMEOUT:-60}
  if [ -n "$READY_MARKER" ]; then
    _ready=""
    for _ in $(seq 1 "$READY_TIMEOUT"); do
      if "$TMUX_BIN" capture-pane -p -t "$PANE" 2>/dev/null | grep -Eq "$READY_MARKER"; then
        _ready=1; break
      fi
      sleep 1
    done
    if [ -n "$_ready" ]; then
      note "input-ready marker seen; settling before inject"
      sleep 2
    else
      note "WARN: input-ready marker not seen after ${READY_TIMEOUT}s — injecting anyway"
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
  # Best-effort + loop-scoped (only when --loop is passed by the unit as `--loop %p`);
  # confined to this defer path (normal injection below is untouched) and must NEVER
  # fail the exit 0. The loop id must equal the manifest timer / bus loop id.
  if [ -n "$LOOP" ]; then
    _bdir="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"   # override for tests
    { mkdir -p "$_bdir" 2>/dev/null \
      && printf '{"ts":"%s","loop":"%s","reason":"blocked_on_andrew"}\n' \
           "$(date -u +%FT%TZ)" "$LOOP" >> "$_bdir/pulse-bounces.jsonl" 2>/dev/null ; } \
      || note "bounce-record failed for loop '$LOOP' (non-fatal)"
  fi
  exit 0
fi

# 4. Inject the command. Text first, Enter separately — some TUIs
#    mis-handle a combined burst.
"$TMUX_BIN" send-keys -t "$PANE" -- "$CMD"
sleep 0.3
"$TMUX_BIN" send-keys -t "$PANE" Enter
note "injected into $PANE"

exit 0
