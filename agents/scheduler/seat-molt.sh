#!/bin/bash
# seat-molt.sh — THE MOLT: a mechanical offboard -> /clear|/compact -> /onboard
# cycle, so a long-running seat never stalls at the context ceiling
# (dotfiles-it06).
#
# The manual bracket (agent says "I'm full", human /clear's it, agent /onboard's)
# cannot serve a marshal running all night or a seneschal working a sprint.
# stop-context-guard.sh used to fire at 85% and tell the agent to SURFACE TO
# ANDREW — that blocks autonomy by design. This script is the self-service half:
# the guard now names it, and a seat can cycle its own context with no human.
#
#   seat-molt.sh --target <session> <window> --mode molt|compact|auto [--in-flight yes|no]
#   seat-molt.sh --self --mode auto --in-flight yes|no
#
# TWO MODES, chosen by IN-FLIGHT STATE — and the agent is the only thing that
# knows its own state, so `auto` does not sniff for it, it is TOLD (--in-flight):
#
#   MOLT    (/clear then /onboard) — at a work-item boundary with nothing in
#           flight. Cheapest and cleanest: the durable anchor (handoff note +
#           beads) IS the memory. The default, and the steady-state choice.
#   COMPACT (/compact then /onboard) — mid-arc with in-flight background tasks
#           or an unfinishable arc. Measured 2026-08-09 in session 2cc9586e:
#           three background builder handles ALL survived compaction and their
#           notifications landed post-compact; a /clear would have orphaned
#           them. That asymmetry is the whole mode-choice rule.
#
# WHY COMPACT ALSO DEMANDS A FRESH OFFBOARD. The tempting deviation is "compact
# preserves context, so it needs no handoff". It is exactly backwards:
# compaction is LOSSY and silent about what it dropped, so the handoff note is
# the only durable record of the detail it eats — and the post-compact session
# re-onboards from that note. A compact without a fresh offboard destroys detail
# with no anchor to recover it from, which is the same defect as an unoffboarded
# /clear with a slower fuse. Both modes therefore refuse.
#
# ---------------------------------------------------------------------------
# THE SOCKET RULE (read before touching any tmux call in this file)
# ---------------------------------------------------------------------------
# EVERY tmux invocation here goes through TM(), which is:
#
#     env -u TMUX -u TMUX_TMPDIR "$TMUX_BIN" -S "$SOCKET" …
#
# and $SOCKET is an ABSOLUTE path resolved once, up front. That single idiom is
# correct in production AND in the fixture-socket suite, and it is deliberate:
#
#  * `-S <abs path>` names the server outright. $TMUX only supplies the DEFAULT
#    socket (so -S overrides it) and $TMUX_TMPDIR only resolves `-L <name>` into
#    a path (so it cannot touch -S at all). Stripping both is therefore SAFE
#    here precisely BECAUSE the socket is explicit — the 2026-08-09 incident
#    (dotfiles-2v8h) was env precedence deciding which server a call reached,
#    and an explicit -S is the only thing that takes that decision away from the
#    environment. Stripping the env while relying on ambient resolution would be
#    the incident again; this file never does the second half.
#  * `-L <name>` is NOT used anywhere, not even in tests: -L is resolved through
#    TMUX_TMPDIR, i.e. through the environment, which is the thing we are
#    refusing to trust. The suite passes the fixture socket's PATH.
#
# --self AND THE DETACHED CHILD. `--self` runs INSIDE the live server, from a
# Claude Code Bash tool whose $TMUX/$TMUX_PANE MAY OR MAY NOT be propagated —
# a background-forked session gets neither (lib/tmux-pane-resolve.sh), while a
# normal in-pane one does (measured 2026-08-09 from a worktree agent's Bash tool:
# TMUX=/tmp/tmux-1000/default,…, ancestry socket_path the same, session
# zig-computer, window dotfiles). So it is resolved BOTH ways in the FOREGROUND
# invocation — $TMUX first, then the ancestry walk, which works because this
# process is still a genuine descendant of the pane's shell — and then passed
# EXPLICITLY to the detached child as `--socket`. After setsid the child is
# reparented to init: its own ancestry walk would fail and any ambient-env
# resolution would be a guess against an unknown server. THE CHILD NEVER
# RE-RESOLVES. If no socket can be resolved, this script refuses
# (failed-no-socket) rather than falling through to an ambient-default call.
#
# --self ALSO stamps its own t0 in the foreground, for the same reason it
# resolves the socket there: `date +%s` before the detach is a real read of
# "when this invocation started", and the child (reparented, no ancestry to
# lean on) never re-derives it — it is handed `--t0 <epoch>` explicitly and
# treats it as authoritative. See rail 1 below (dotfiles-ygf8).
#
# R13 (seat address spec, dotfiles-seat-address-spec-uikg): session and window
# are SEPARATE fields and an address is NEVER handed to `tmux -t`. tmux matches
# targets by prefix/fnmatch, so `session:window` can silently bind the wrong
# session. Here: windows are enumerated with `-t "=$SESSION"` (exact-match form),
# compared glyph-stripped, and the pane target is `<window_id>.0` — a window id,
# never a name. Same idiom as pulse-inject.sh.
#
# ---------------------------------------------------------------------------
# SAFETY RAILS — every one of them refuses rather than degrades
# ---------------------------------------------------------------------------
#   1. IDLE-WAIT.  Never type into a pane mid-turn.
#        --target: idle = the window carries no 🧠/🌀 lexicon glyph AND the
#        composer's input-ready marker is on screen, observed on
#        MOLT_IDLE_STABLE consecutive polls. Timeout -> abort, type nothing.
#        --self: pane-TEXT stability is the wrong signal here — a background
#        builder's spinner/token-counter redraws every second, so a pane with
#        real work in flight can STRUCTURALLY never read as stable, which is
#        exactly the case that most needs molting (FINDING 3, live 2026-08-09:
#        the first --self run sat blind until killed). --self instead waits
#        for stop-context-guard.sh's turn-end stamp
#        ($HARNESS_STATE_DIR/turn-end/<session_id>) to carry an mtime NEWER
#        than this invocation's own t0 — a signal from OUTSIDE the pane, since
#        that hook runs on every single Stop regardless of what the pane is
#        rendering. Timeout -> abort, type nothing, same as --target.
#   2. MODAL ABORT. A 🔔 window (or a dialog matched in the pane) is blocked on
#      Andrew: send-keys there feeds the DIALOG, not the composer, and the
#      trailing Enter answers his open question with the default
#      (pulse-inject.sh:692-727 owns this lesson). Abort, type nothing — and the
#      check is repeated in every wait loop, not just once at the start.
#   3. OFFBOARD FRESHNESS. Refuse to /clear or /compact unless the pane's
#      project carries a FRESH .claude/last-offboard-session (mtime inside
#      MOLT_OFFBOARD_FRESH_SECS; content matching --session-id when one is
#      known). Reuses stop-context-guard.sh's logic INCLUDING its portable-mtime
#      lesson (dotfiles-5vz2): an unreadable mtime FAILS CLOSED — no release, and
#      it says so — because `stat -c` is GNU-only and the old `|| echo 0` made
#      every file 56 years old on a Mac.
#   4. RATE LIMIT. Refuse if this window molted inside the last
#      MOLT_RATE_LIMIT_MIN minutes. Molt-loop protection: a seat that molts, is
#      re-onboarded into a full window, and molts again would burn a subscription
#      in a loop with every mechanical signal green.
#   5. ORDERING. Rate limit first (cheap, no waiting), then idle-wait, then the
#      modal re-check, then offboard freshness LAST — immediately before the
#      destructive keystroke. Freshness is time-sensitive: a marker that was
#      fresh when a five-minute idle-wait started can be stale when it ends, and
#      the check that matters is the one nearest the act.
#
# OUTCOME CONTRACT (same shape as pulse-inject's PULSE_INJECT_RESULT, and for
# the same reason — the exit code cannot answer "did anything get typed?"):
# every terminal path prints exactly ONE machine-readable line, LAST on STDOUT.
#
#   SEAT_MOLT_RESULT=molted                    /clear + /onboard sent
#   SEAT_MOLT_RESULT=compacted                 /compact + /onboard sent
#   SEAT_MOLT_RESULT=compacted-onboard-skipped /compact sent; compaction never
#                                              reported done, so /onboard was NOT
#                                              sent (the session is compacted but
#                                              un-onboarded — say so, don't lie)
#   SEAT_MOLT_RESULT=detached                  --self handed off to a child; the
#                                              child writes its own verdict to
#                                              $MOLT_LOG
#   SEAT_MOLT_RESULT=aborted-modal             🔔/dialog; typed NOTHING
#   SEAT_MOLT_RESULT=aborted-not-idle          idle-wait timed out; typed NOTHING
#   SEAT_MOLT_RESULT=refused-not-offboarded    no FRESH offboard; typed NOTHING
#   SEAT_MOLT_RESULT=refused-rate-limited      molted too recently; typed NOTHING
#   SEAT_MOLT_RESULT=failed-usage              bad/missing args (exit 64)
#   SEAT_MOLT_RESULT=failed-no-tmux            no tmux binary (exit 69)
#   SEAT_MOLT_RESULT=failed-no-socket          no socket could be resolved (69)
#   SEAT_MOLT_RESULT=failed-no-window          session/window not on that socket (70)
#   SEAT_MOLT_RESULT=failed                    any other non-zero exit
#
# Exit codes: 0 on molted/compacted/compacted-onboard-skipped/detached, 3 on
# every deliberate refusal or abort, 64/69/70 on hard failures. FAIL CLOSED: an
# exit 0 with NO marker means an older copy or a path that forgot to report —
# treat it as NOT molted.
#
# LEDGER — one row per run (refusals included; that is the audit value) at
# ~/.local/state/harness/molt-ledger.jsonl:
#   {"ts","epoch","session","window","mode","pct","result"}
# `epoch` is additive to the spec'd fields on purpose: the rate limit reads this
# file, and re-parsing an ISO timestamp in portable shell is exactly the kind of
# thing that fails open. Only rows whose result is a REAL molt count against the
# rate limit — a refusal must never lock the window out of a later legitimate one.
#
# Environment seams (all optional; tests use them, production uses defaults):
#   MOLT_LEDGER, HARNESS_STATE_DIR   ledger path / its dir
#   MOLT_RATE_LIMIT_MIN     30    minutes between molts of one window
#   MOLT_OFFBOARD_FRESH_SECS 1800 offboard freshness window
#   MOLT_IDLE_TIMEOUT       300   --target idle-wait ceiling (seconds)
#   MOLT_SELF_IDLE_TIMEOUT  900   --self child's ceiling (the invoker must end
#                                 its turn; if it never does, log + exit, no
#                                 injection) — also the turn-end poll ceiling
#   MOLT_IDLE_STABLE        2     consecutive idle polls required (--target only)
#   MOLT_POLL               2     seconds between polls
#   MOLT_READY_MARKER             ERE for the composer footer; empty DISABLES
#   MOLT_MODAL_MARKER             ERE for an in-pane dialog; empty DISABLES.
#                                 The AUTHORITATIVE modal signal is the 🔔 glyph
#                                 (set by the hook fleet); this is a backstop for
#                                 a window whose glyph is not maintained.
#   MOLT_CLEAR_SETTLE       3     seconds between /clear and /onboard
#   MOLT_COMPACT_GRACE      10    seconds before compaction is polled as done
#   MOLT_COMPACT_TIMEOUT    900   ceiling on waiting for compaction
#   MOLT_DETACH             1     0 = --self runs its child INLINE (test seam)
#   MOLT_LOG                      /tmp/seat-molt.log
#   MOLT_TMUX_BIN                 tmux binary (test seam)

set -uo pipefail

# --- libs: all OPTIONAL, each with a documented degrade ---------------------
# A copy of this script with no libs beside it must still RUN and still REFUSE
# (that is a test case). portable.sh gives _p_mtime; handoff-path.sh gives
# last_offboard_path (per-window offboard-marker scoping); tmux-pane-resolve.sh
# (sourced by handoff-path.sh) gives the ancestry walk --self needs.
_MOLT_SELF_PATH="${BASH_SOURCE[0]:-$0}"
_MOLT_DIR="$(cd "$(dirname -- "$_MOLT_SELF_PATH")" 2>/dev/null && pwd)"
# ABSOLUTE from here on. --self re-execs this file in a setsid'd child, and a
# relative $0 would resolve against whatever cwd that child inherits — the class
# of bug that only shows up when someone invokes the script from somewhere new.
[ -n "$_MOLT_DIR" ] && _MOLT_SELF_PATH="$_MOLT_DIR/$(basename -- "$_MOLT_SELF_PATH")"
[ -n "$_MOLT_DIR" ] && [ -r "$_MOLT_DIR/../hooks/lib/portable.sh" ] && . "$_MOLT_DIR/../hooks/lib/portable.sh"
[ -n "$_MOLT_DIR" ] && [ -r "$_MOLT_DIR/../lib/handoff-path.sh" ] && . "$_MOLT_DIR/../lib/handoff-path.sh"

MOLT_LOG_FILE="${MOLT_LOG:-/tmp/seat-molt.log}"
# Same flock+pid idiom as pulse-inject's note(): two seats molting at once must
# stay attributable instead of braiding into an unreadable record.
note() {
  { flock -w 5 9 2>/dev/null
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$MOLT_LOG_FILE"
}

# --- the outcome contract ---------------------------------------------------
MOLT_RESULT_SENT=0
emit_result() {
  [ "$MOLT_RESULT_SENT" -eq 1 ] && return 0
  MOLT_RESULT_SENT=1
  printf 'SEAT_MOLT_RESULT=%s\n' "$1"
}
# shellcheck disable=SC2317  # invoked indirectly via `trap _on_exit EXIT`
_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then emit_result failed; else emit_result exited-unlogged; fi
  exit "$rc"
}
trap _on_exit EXIT

usage() {
  cat >&2 <<'EOF'
usage:
  seat-molt.sh --target <session> <window> --mode molt|compact|auto [--in-flight yes|no] [opts]
  seat-molt.sh --self --mode auto --in-flight yes|no [opts]

opts:
  --socket <path>     tmux socket to address (absolute path; see THE SOCKET RULE)
  --dir <path>        project dir holding .claude/last-offboard-session
                      (default: the pane's current path)
  --session-id <id>   Claude session id the offboard marker must name
  --pct <n>           context percentage, recorded in the ledger row
  --wait-idle-first   internal: set on the detached --self child
  --t0 <epoch>        internal: the --self invocation's own start time, so the
                      detached child knows which turn-end stamp is fresh
EOF
}

SESSION=""
WINDOW=""
MODE=""
MODE_ARG=""
IN_FLIGHT=""
SOCKET=""
DIR=""
SESSION_ID=""
PCT=""
SELF=0
WAIT_IDLE_FIRST=0
PANE_ARG=""
T0=""

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ $# -ge 3 ] || { echo "seat-molt: --target needs <session> <window>" >&2; emit_result failed-usage; exit 64; }
      SESSION=$2; WINDOW=$3; shift 3 ;;
    --self)       SELF=1; shift ;;
    --mode)       [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; MODE_ARG=$2; shift 2 ;;
    --in-flight)  [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; IN_FLIGHT=$2; shift 2 ;;
    --socket)     [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; SOCKET=$2; shift 2 ;;
    --dir)        [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; DIR=$2; shift 2 ;;
    --session-id) [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; SESSION_ID=$2; shift 2 ;;
    --pct)        [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; PCT=$2; shift 2 ;;
    --wait-idle-first) WAIT_IDLE_FIRST=1; shift ;;
    --pane)       [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; PANE_ARG=$2; shift 2 ;;
    --t0)         [ $# -ge 2 ] || { usage; emit_result failed-usage; exit 64; }; T0=$2; shift 2 ;;
    -h|--help)    usage; emit_result failed-usage; exit 64 ;;
    *) echo "seat-molt: unknown arg $1" >&2; usage; emit_result failed-usage; exit 64 ;;
  esac
done

RATE_LIMIT_MIN="${MOLT_RATE_LIMIT_MIN:-30}"
FRESH_SECS="${MOLT_OFFBOARD_FRESH_SECS:-1800}"
IDLE_TIMEOUT="${MOLT_IDLE_TIMEOUT:-300}"
SELF_IDLE_TIMEOUT="${MOLT_SELF_IDLE_TIMEOUT:-900}"
IDLE_STABLE="${MOLT_IDLE_STABLE:-2}"
POLL="${MOLT_POLL:-2}"
CLEAR_SETTLE="${MOLT_CLEAR_SETTLE:-3}"
COMPACT_GRACE="${MOLT_COMPACT_GRACE:-10}"
COMPACT_TIMEOUT="${MOLT_COMPACT_TIMEOUT:-900}"
# Default ready marker is pulse-inject's, verbatim: the same composer footer, and
# a divergence between the two would mean one of them silently stops matching.
READY_MARKER=${MOLT_READY_MARKER-'shift\+tab to cycle|\? for shortcuts|for agents|bypass permissions|accept edits on|plan mode on'}
MODAL_MARKER=${MOLT_MODAL_MARKER-'Do you want to |Would you like to proceed|Select an option'}
LEDGER="${MOLT_LEDGER:-${HARNESS_STATE_DIR:-$HOME/.local/state/harness}/molt-ledger.jsonl}"
# The turn-end signal --self reads instead of pane-text stability (dotfiles-ygf8).
# Same HARNESS_STATE_DIR seam as the ledger above, deliberately: one env var
# points a test's whole isolated state tree, ledger included.
TURN_END_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}/turn-end"

TMUX_BIN=${MOLT_TMUX_BIN:-}
if [ -z "$TMUX_BIN" ]; then
  TMUX_BIN=$(command -v tmux 2>/dev/null)
  [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
fi

# --- mode resolution --------------------------------------------------------
# `auto` does NOT sniff for in-flight work: nothing outside the agent can see
# whether a background task is live, and a wrong guess either orphans a builder
# (/clear when something was in flight) or needlessly degrades context (/compact
# when nothing was). The agent states it; this refuses without it.
case "$MODE_ARG" in
  molt|compact) MODE="$MODE_ARG" ;;
  auto)
    case "$IN_FLIGHT" in
      yes) MODE=compact ;;
      no)  MODE=molt ;;
      *)
        echo "seat-molt: --mode auto requires --in-flight yes|no (the agent knows its own in-flight state; nothing else does)" >&2
        emit_result failed-usage; exit 64 ;;
    esac ;;
  "") echo "seat-molt: --mode is required" >&2; usage; emit_result failed-usage; exit 64 ;;
  *)  echo "seat-molt: --mode must be molt|compact|auto (got '$MODE_ARG')" >&2; emit_result failed-usage; exit 64 ;;
esac

if [ "$SELF" -eq 0 ] && { [ -z "$SESSION" ] || [ -z "$WINDOW" ]; }; then
  echo "seat-molt: --target <session> <window> or --self is required" >&2
  usage; emit_result failed-usage; exit 64
fi
[ -x "$TMUX_BIN" ] || { echo "seat-molt: tmux not found" >&2; emit_result failed-no-tmux; exit 69; }

_json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ledger_row <verdict> — best-effort, never fails the caller. A molt that cannot
# be recorded is still a molt; losing the cycle on top of it would be worse.
ledger_row() {
  local verdict=$1 dir pct
  [ -n "$SESSION" ] && [ -n "$WINDOW" ] || return 0
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || { note "ledger: cannot create $dir (row dropped: $verdict)"; return 0; }
  case "$PCT" in ''|*[!0-9]*) pct=null ;; *) pct="$PCT" ;; esac
  printf '{"ts":"%s","epoch":%s,"session":"%s","window":"%s","mode":"%s","pct":%s,"result":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$(date +%s)" \
    "$(_json_esc "$SESSION")" "$(_json_esc "$WINDOW")" "$MODE" "$pct" "$verdict" \
    >> "$LEDGER" || note "ledger: append to $LEDGER failed (row dropped: $verdict)"
}

# finish <verdict> <exit-code> — the ONLY terminal path: ledger, verdict, exit.
finish() {
  ledger_row "$1"
  note "verdict=$1 session='$SESSION' window='$WINDOW' mode=$MODE"
  emit_result "$1"
  exit "$2"
}

# --- socket resolution (see THE SOCKET RULE) --------------------------------
resolve_socket() {
  local s dir n
  if [ -n "$SOCKET" ]; then printf '%s' "$SOCKET"; return 0; fi
  if [ -n "${TMUX:-}" ]; then printf '%s' "${TMUX%%,*}"; return 0; fi
  # Ancestry: this is the ONE call made with ambient env, because its whole job
  # is to discover which server this process's pane belongs to. It is a pure
  # read (list-panes), and it only runs when no socket was passed and $TMUX is
  # absent — i.e. never in the suite, which always passes --socket.
  if command -v _tpr_by_ancestry >/dev/null 2>&1; then
    s=$(_tpr_by_ancestry '#{socket_path}') && [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  fi
  dir="${SEAT_TMUX_SOCKET_DIR:-/tmp/tmux-$(id -u)}"
  if [ -d "$dir" ]; then
    n=$(find "$dir" -maxdepth 1 -type s | wc -l | tr -d ' ')
    if [ "$n" = 1 ]; then
      s=$(find "$dir" -maxdepth 1 -type s)
      note "socket: resolved to the only live socket in $dir ($s)"
      printf '%s' "$s"; return 0
    fi
    note "socket: $n sockets in $dir — refusing to guess"
  fi
  return 1
}

SOCKET=$(resolve_socket) || {
  echo "seat-molt: no tmux socket could be resolved. Pass --socket <absolute path>; this script never falls back to an ambient-default tmux call (see THE SOCKET RULE)." >&2
  emit_result failed-no-socket; exit 69
}

# TM — every tmux call in this file. Explicit socket, hostile to ambient env.
TM() { env -u TMUX -u TMUX_TMPDIR "$TMUX_BIN" -S "$SOCKET" "$@"; }

strip_lexicon() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//'; }

# --- --self: resolve in the FOREGROUND, then hand off -----------------------
if [ "$SELF" -eq 1 ]; then
  # Stamped HERE, before anything else --self does, for the same reason the
  # socket is resolved here: this is the one moment with a genuine "now" for
  # THIS invocation. The detached child is reparented after setsid and must
  # not re-derive it (dotfiles-ygf8).
  SELF_T0=$(date +%s)

  if [ -z "$WINDOW" ]; then
    if command -v tmux_resolve_window >/dev/null 2>&1; then
      WINDOW=$(tmux_resolve_window) || WINDOW=""
    fi
    [ -n "$WINDOW" ] || WINDOW=$(strip_lexicon "${SEAT_WINDOW:-${HANDOFF_WINDOW:-}}")
  fi
  if [ -z "$SESSION" ]; then
    if [ -n "${SEAT_SESSION:-}" ]; then
      SESSION="$SEAT_SESSION"
    elif [ -n "${TMUX_PANE:-}" ]; then
      SESSION=$(TM display-message -p -t "$TMUX_PANE" '#{session_name}') || SESSION=""
    fi
    if [ -z "$SESSION" ] && command -v _tpr_by_ancestry >/dev/null 2>&1; then
      SESSION=$(_tpr_by_ancestry '#{session_name}') || SESSION=""
    fi
  fi
  if [ -z "$WINDOW" ] || [ -z "$SESSION" ]; then
    echo "seat-molt: --self could not resolve this pane's tmux session/window (session='$SESSION' window='$WINDOW'). Pass --target <session> <window> explicitly, or set \$SEAT_SESSION/\$SEAT_WINDOW." >&2
    emit_result failed-no-window; exit 70
  fi
  [ -n "$SESSION_ID" ] || SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  # Best-effort pct for the ledger row — the same per-session file statusline.sh
  # writes and stop-context-guard.sh reads. Absent is fine (recorded as null).
  if [ -z "$PCT" ] && [ -n "$SESSION_ID" ]; then
    _pf="${CONTEXT_GUARD_STATE_DIR:-/tmp/claude-context-pct}/$SESSION_ID"
    [ -f "$_pf" ] && PCT=$(tr -dc '0-9' < "$_pf")
  fi

  # R14 (dotfiles, 2026-08-09): the invoker's own PANE rides to the child. The
  # <window_id>.0 rebuild assumed one pane per window; a split window put the
  # ORIGINAL session at .0 and this session's molt child watched (and would have
  # typed into) the WRONG pane — measured live: the 06:01 child targeted @3.0
  # while the invoker sat in the other pane. Resolve it here (same reasoning as
  # the socket: the foreground still has env/ancestry; the setsid child has
  # neither) and pass it explicitly.
  # R14b (dotfiles, 2026-08-09): a pane id is only meaningful on the server
  # that issued it. Pass the invoker pane to the child ONLY when the invoker's
  # own server socket (the first component of $TMUX) IS the child's target
  # socket — on any other server the id can collide with an unrelated pane
  # (measured: this suite's fake server owns a %3, and a live session whose
  # TMUX_PANE=%3 leaked it in; send-keys then lands in the wrong pane). No
  # $TMUX → no proof of same-server → no passthrough; the child falls back to
  # window-name resolution, the pre-R14 path.
  PANE_SELF=""
  if [ -n "${TMUX:-}" ] && [ "${TMUX%%,*}" = "$SOCKET" ]; then
    if [ -n "${TMUX_PANE:-}" ]; then
      PANE_SELF="$TMUX_PANE"
    elif command -v _tpr_by_ancestry >/dev/null 2>&1; then
      PANE_SELF=$(_tpr_by_ancestry '#{pane_id}') || PANE_SELF=""
    fi
  fi
  CHILD=(--target "$SESSION" "$WINDOW" --mode "$MODE" --socket "$SOCKET" --wait-idle-first --t0 "$SELF_T0")
  [ -n "$PANE_SELF" ] && CHILD+=(--pane "$PANE_SELF")
  [ -n "$DIR" ]        && CHILD+=(--dir "$DIR")
  [ -n "$SESSION_ID" ] && CHILD+=(--session-id "$SESSION_ID")
  [ -n "$PCT" ]        && CHILD+=(--pct "$PCT")

  if [ "${MOLT_DETACH:-1}" = 1 ]; then
    # setsid so the child outlives this Bash tool call AND the agent's turn: the
    # whole point is to cycle the pane AFTER the invoker goes idle. stdin from
    # /dev/null, output to the log — it has no terminal to write to.
    if command -v setsid >/dev/null 2>&1; then
      setsid bash "$_MOLT_SELF_PATH" "${CHILD[@]}" >>"$MOLT_LOG_FILE" 2>&1 </dev/null &
    else
      nohup bash "$_MOLT_SELF_PATH" "${CHILD[@]}" >>"$MOLT_LOG_FILE" 2>&1 </dev/null &
    fi
    note "self: detached child pid $! for session='$SESSION' window='$WINDOW' mode=$MODE (idle ceiling ${SELF_IDLE_TIMEOUT}s)"
    echo "seat-molt: detached. The cycle fires once this pane goes idle; watch $MOLT_LOG_FILE for its verdict." >&2
    emit_result detached
    exit 0
  fi
  # MOLT_DETACH=0 — run the child INLINE (test seam). One code path either way:
  # the child prints the verdict, we forward its stdout and its exit code.
  note "self: MOLT_DETACH=0 — running the child inline"
  bash "$_MOLT_SELF_PATH" "${CHILD[@]}"
  _rc=$?
  MOLT_RESULT_SENT=1     # the child already emitted the one verdict for this run
  exit "$_rc"
fi

# --- from here on: the --target path (and the --self child) -----------------
[ "$WAIT_IDLE_FIRST" -eq 1 ] && IDLE_TIMEOUT="$SELF_IDLE_TIMEOUT"

# R14: an explicitly-passed invoker pane is ground truth — it wins over the
# window-NAME lookup, and the window identity is re-derived from it so the rate
# limit and the idle-watch key on the pane's real window (a shared window name
# across sessions/panes must not couple their molt cycles).
PANE=""
WIN_ID=""
if [ -n "$PANE_ARG" ]; then
  _pw=$(TM display-message -p -t "$PANE_ARG" '#{window_id}' 2>/dev/null) || _pw=""
  if [ -n "$_pw" ]; then
    PANE="$PANE_ARG"
    WIN_ID="$_pw"
    _pwname=$(TM display-message -p -t "$PANE_ARG" '#{window_name}' 2>/dev/null) || _pwname=""
    [ -n "$_pwname" ] && WINDOW=$(strip_lexicon "$_pwname")
    note "pane: using invoker pane $PANE (window $WIN_ID '$WINDOW') — R14 self-pane passthrough"
  else
    note "pane: passed invoker pane '$PANE_ARG' no longer exists — falling back to window-name resolution"
  fi
fi
if [ -z "$PANE" ]; then
  while IFS=$'\t' read -r _id _name; do
    [ -n "$_id" ] || continue
    if [ "$(strip_lexicon "$_name")" = "$WINDOW" ]; then WIN_ID=$_id; break; fi
  done < <(TM list-windows -t "=$SESSION" -F $'#{window_id}\t#{window_name}' 2>/dev/null)

  if [ -z "$WIN_ID" ]; then
    echo "seat-molt: no window '$WINDOW' in session '$SESSION' on socket $SOCKET" >&2
    note "FAIL: no window '$WINDOW' in session '$SESSION' on $SOCKET"
    emit_result failed-no-window; exit 70
  fi
  PANE="$WIN_ID.0"
fi

# The project whose offboard marker governs this pane. pane_current_path is the
# pane shell's cwd, which for a Claude seat is its project anchor; --dir wins
# when a caller knows better (a shell cwd can drift — pulse-inject.sh:450 says
# the same thing about relative ledger paths).
if [ -z "$DIR" ]; then
  DIR=$(TM display-message -p -t "$PANE" '#{pane_current_path}') || DIR=""
  [ -n "$DIR" ] || DIR="$HOME"
fi

note "molt: session='$SESSION' window='$WINDOW' pane=$PANE mode=$MODE dir=$DIR socket=$SOCKET"

# --- rail 4: rate limit (FIRST — cheap, and it needs no waiting) ------------
# Only REAL molts count. A refusal row must never lock the window out of a later
# legitimate cycle.
if [ -f "$LEDGER" ]; then
  _cutoff=$(( $(date +%s) - RATE_LIMIT_MIN * 60 ))
  if grep -F "\"session\":\"$(_json_esc "$SESSION")\"" "$LEDGER" \
     | grep -F "\"window\":\"$(_json_esc "$WINDOW")\"" \
     | grep -E '"result":"(molted|compacted|compacted-onboard-skipped)"' \
     | sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' \
     | awk -v cut="$_cutoff" '$1 > cut { hit = 1 } END { exit !hit }'; then
    echo "seat-molt: window '$WINDOW' (session '$SESSION') already molted within the last ${RATE_LIMIT_MIN} minutes — refusing. Molt-loop protection; raise MOLT_RATE_LIMIT_MIN only if you know why the last cycle did not take." >&2
    note "REFUSED: rate limit (${RATE_LIMIT_MIN}m) for session='$SESSION' window='$WINDOW'"
    finish refused-rate-limited 3
  fi
fi

# --- pane state readers -----------------------------------------------------
win_name()  { TM display-message -p -t "$PANE" '#{window_name}' 2>/dev/null; }
pane_text() { TM capture-pane -p -t "$PANE" 2>/dev/null; }

is_modal() { # <window-name> <pane-text>
  case "$1" in 🔔*) return 0 ;; esac
  [ -n "$MODAL_MARKER" ] || return 1
  printf '%s' "$2" | grep -Eq "$MODAL_MARKER"
}
is_busy() { # <window-name>  — 🧠 mid-turn, 🌀 compacting
  case "$1" in 🧠*|🌀*) return 0 ;; esac
  return 1
}
is_ready() { # <pane-text> — composer up and accepting input
  [ -n "$READY_MARKER" ] || return 0
  printf '%s' "$1" | grep -Eq "$READY_MARKER"
}

# wait_for_idle <timeout> <grace>
#   0 = idle (stable), 1 = timed out, 2 = MODAL (abort, never type).
# The grace is --self's insurance: for the first <grace> seconds an idle reading
# is not even eligible, so a window whose lexicon glyph is not being maintained
# cannot read as idle while the invoker is still mid-turn.
wait_for_idle() {
  local timeout=$1 grace=${2:-0} t0 deadline eligible stable=0 name text
  t0=$(date +%s)
  deadline=$(( t0 + timeout ))
  eligible=$(( t0 + grace ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    name=$(win_name); text=$(pane_text)
    if is_modal "$name" "$text"; then return 2; fi
    if [ "$(date +%s)" -lt "$eligible" ] || is_busy "$name" || ! is_ready "$text"; then
      stable=0
    else
      stable=$(( stable + 1 ))
      [ "$stable" -ge "$IDLE_STABLE" ] && return 0
    fi
    sleep "$POLL"
  done
  return 1
}

# wait_for_turn_end <timeout> <t0> <session_id>
#   0 = a turn-end stamp NEWER than t0 exists, and the pane was not modal at
#       that moment -- proceed to molt.
#   1 = timed out (no fresh stamp, or the pane stayed modal the whole time).
# --self's idle-wait (dotfiles-ygf8): stop-context-guard.sh touches
# $TURN_END_DIR/<session_id> on EVERY Stop, unconditionally, so its mtime is a
# signal from OUTSIDE the pane -- unlike pane-text stability it cannot be kept
# artificially "unstable" by a background builder's own redraws. A modal at the
# moment the stamp is found is still not eligible: the turn did not end for
# MOLTING purposes, so we keep polling rather than proceeding (or aborting).
wait_for_turn_end() {
  local timeout=$1 t0=$2 sid=$3 stamp_file deadline mtime name text
  stamp_file="$TURN_END_DIR/$sid"
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$stamp_file" ] \
       && mtime=$(_p_mtime "$stamp_file" 2>/dev/null) \
       && [ -n "$mtime" ] && [ "$mtime" -gt "$t0" ] 2>/dev/null; then
      name=$(win_name); text=$(pane_text)
      if is_modal "$name" "$text"; then
        note "turn-end: fresh stamp for session=$sid but pane is modal -- still waiting"
      else
        return 0
      fi
    fi
    sleep "$POLL"
  done
  return 1
}

# --- rail 1 + rail 2: idle-wait, with the modal abort inside the loop -------
# --target waits on pane-text stability, as always -- there is no session_id
# to stamp for an operator-driven target. --self waits on the turn-end signal
# instead (see wait_for_turn_end above); it hard-requires SESSION_ID and T0 --
# no silent fallback to pane-stability, which is the exact bug this replaces.
if [ "$WAIT_IDLE_FIRST" -eq 1 ]; then
  if [ -z "$SESSION_ID" ] || [ -z "$T0" ]; then
    echo "seat-molt: --self's idle-wait needs both --session-id and --t0 (got session-id='$SESSION_ID' t0='$T0') to read the turn-end signal — ABORTING, typed nothing. This should never happen outside a hand-built --wait-idle-first invocation." >&2
    note "ABORTED: --wait-idle-first without session-id/t0 (session-id='$SESSION_ID' t0='$T0')"
    finish aborted-not-idle 3
  fi
  wait_for_turn_end "$IDLE_TIMEOUT" "$T0" "$SESSION_ID"
  case $? in
    1)
      echo "seat-molt: pane $PANE never showed a turn-end stamp newer than $T0 within ${IDLE_TIMEOUT}s — ABORTING, typed nothing." >&2
      note "ABORTED: turn-end wait timed out after ${IDLE_TIMEOUT}s on session='$SESSION' window='$WINDOW' (t0=$T0)"
      finish aborted-not-idle 3 ;;
  esac
else
  wait_for_idle "$IDLE_TIMEOUT" 0
  case $? in
    2)
      echo "seat-molt: pane $PANE is blocked on Andrew (🔔 / open dialog) — ABORTING, typed nothing. send-keys there would answer his open question with the default (pulse-inject.sh:692)." >&2
      note "ABORTED: modal on session='$SESSION' window='$WINDOW'"
      finish aborted-modal 3 ;;
    1)
      echo "seat-molt: pane $PANE never went idle within ${IDLE_TIMEOUT}s — ABORTING, typed nothing." >&2
      note "ABORTED: idle-wait timed out after ${IDLE_TIMEOUT}s on session='$SESSION' window='$WINDOW'"
      finish aborted-not-idle 3 ;;
  esac
fi

# Re-read immediately before the destructive keystroke. The wait returned on a
# snapshot; a dialog can open in the seconds since.
_name=$(win_name); _text=$(pane_text)
if is_modal "$_name" "$_text"; then
  echo "seat-molt: a dialog opened while we were settling — ABORTING, typed nothing." >&2
  note "ABORTED: modal appeared post-idle on session='$SESSION' window='$WINDOW'"
  finish aborted-modal 3
fi

# --- rail 3: offboard freshness (LAST, nearest the act) ---------------------
# _molt_offboard_path <dir> <window> — the marker path for THAT window's seat.
# Reuses handoff-path.sh's per-window scoping when the lib is present; the
# degraded fallback reproduces the same two shapes so a lib-less copy still
# looks in the right place instead of silently checking a file that never exists.
_molt_offboard_path() {
  local d=$1 w=$2
  if command -v last_offboard_path >/dev/null 2>&1; then
    ( export HANDOFF_WINDOW="$w"; last_offboard_path "$d" )
    return 0
  fi
  if [ -f "$d/refs/.handoff-per-window" ]; then
    printf '%s/.claude/last-offboard-session--%s' "$d" "$w"
  else
    printf '%s/.claude/last-offboard-session' "$d"
  fi
}

OFFBOARD_FILE=$(_molt_offboard_path "$DIR" "$WINDOW")
REFUSE=""
if [ ! -f "$OFFBOARD_FILE" ]; then
  REFUSE="there is no offboard marker at $OFFBOARD_FILE"
elif [ -n "$SESSION_ID" ] && ! grep -q "$SESSION_ID" "$OFFBOARD_FILE"; then
  REFUSE="$OFFBOARD_FILE does not name session $SESSION_ID — that offboard belongs to a different session"
elif ! command -v _p_mtime >/dev/null 2>&1; then
  # FAIL CLOSED + ANNOUNCE, exactly as stop-context-guard.sh does (dotfiles-5vz2):
  # without an mtime there is no freshness answer, and release is the permissive
  # branch, so we do not take it.
  REFUSE="could not read the mtime of $OFFBOARD_FILE (lib/portable.sh unavailable) — treating the offboard as NOT fresh"
elif ! OFFBOARD_MTIME=$(_p_mtime "$OFFBOARD_FILE"); then
  REFUSE="could not read the mtime of $OFFBOARD_FILE — treating the offboard as NOT fresh (see hooks/lib/portable.sh)"
else
  OFFBOARD_AGE=$(( $(date +%s) - OFFBOARD_MTIME ))
  [ "$OFFBOARD_AGE" -lt "$FRESH_SECS" ] \
    || REFUSE="$OFFBOARD_FILE is ${OFFBOARD_AGE}s old (freshness window ${FRESH_SECS}s) — that session kept working past its offboard"
fi

if [ -n "$REFUSE" ]; then
  echo "seat-molt: REFUSING to $MODE session '$SESSION' window '$WINDOW' — $REFUSE." >&2
  echo "           Run /offboard in that pane first (handoff note + commit + push). Un-offboarded context is not recoverable from a /clear, and /compact eats the detail the note exists to hold." >&2
  note "REFUSED: not offboarded ($REFUSE)"
  finish refused-not-offboarded 3
fi

# --- the cycle --------------------------------------------------------------
# Text first, Enter separately, exactly as pulse-inject.sh:754 does — some TUIs
# mis-handle a combined burst, and the slash-command palette needs the pause.
send_line() {
  TM send-keys -t "$PANE" -- "$1"
  sleep 0.3
  TM send-keys -t "$PANE" Enter
}

if [ "$MODE" = molt ]; then
  send_line "/clear"
  note "sent /clear to $PANE"
  # Fixed settle, and honestly so: the ready marker is the composer FOOTER,
  # which never disappears during a /clear repaint, so polling for it proves
  # nothing (pulse-inject.sh:742 documents the same unresolved gap). Raise
  # MOLT_CLEAR_SETTLE if a seat starts losing its /onboard.
  sleep "$CLEAR_SETTLE"
  send_line "/onboard"
  note "sent /onboard to $PANE — molt complete"
  finish molted 0
fi

# COMPACT. /compact is asynchronous and can run for minutes; the pre-compact
# path leaves the session needing an /onboard afterwards, so we wait for
# compaction to finish before sending it.
send_line "/compact"
note "sent /compact to $PANE; waiting up to ${COMPACT_TIMEOUT}s for it to finish"
sleep "$COMPACT_GRACE"
wait_for_idle "$COMPACT_TIMEOUT" 0
case $? in
  0)
    send_line "/onboard"
    note "sent /onboard to $PANE — compact cycle complete"
    finish compacted 0 ;;
  2)
    echo "seat-molt: a dialog opened during compaction — /compact was sent, /onboard was NOT. The session is compacted and un-onboarded." >&2
    note "compact: modal during compaction; /onboard NOT sent"
    finish compacted-onboard-skipped 0 ;;
  *)
    echo "seat-molt: compaction did not report done within ${COMPACT_TIMEOUT}s — /compact was sent, /onboard was NOT. The session is compacted and un-onboarded; onboard it by hand." >&2
    note "compact: never reported done within ${COMPACT_TIMEOUT}s; /onboard NOT sent"
    finish compacted-onboard-skipped 0 ;;
esac
