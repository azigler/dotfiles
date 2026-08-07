#!/bin/bash
# pulse-ledger-watch.sh — the LOCAL-loop completion watcher (dotfiles-wqby).
#
# ---------------------------------------------------------------------------
# THE HOLE THIS FILLS
# ---------------------------------------------------------------------------
# pulse-dispatch-remote.sh surfaces EVERY finished tick — done, quiet, blocked
# alike (step 7, dotfiles-5ts2; Zig 2026-07-31: "there's no such thing as a
# low-value bell"). It can do that only because it OBSERVES completion: step 5
# polls result.json, step 6 writes the ledger row, step 7 stages the surface.
#
# pulse-inject.sh — the LOCAL path — observes nothing. It returns the moment it
# has typed the command into the pane; at that instant the tick has not run. So a
# loop moved from the dispatcher to a local timer silently loses the
# always-surface guarantee, /pulse's "a tick never raises AskUserQuestion" rule
# then stops the tick from standing in, and the pane shows ✅ over a finished
# deliverable that is waiting on Zig. Nothing errors.
#
# Measured on pulse-weekly-report, 2026-08-07: report published clean, tick
# logged `done`, PushNotification returned "Remote Control inactive" (i.e. did
# NOT deliver), and Zig found out by asking.
#
# ⚠️ TEACHING pulse-inject.sh TO STAGE CANNOT WORK, and that was this bead's
# first framing. Its verdict contract is about whether INJECTION succeeded
# (injected / bounced / failed), and it exits before the tick has done anything.
# A surface staged there would announce a tick that has not happened.
#
# ---------------------------------------------------------------------------
# WHAT THIS DOES INSTEAD — watch the LEDGER, ride the existing timer
# ---------------------------------------------------------------------------
# A local tick's durable completion record is its LEDGER ROW, appended at wrap
# (/pulse tick procedure step 5) for done/quiet/blocked alike — exactly the set
# the dispatcher surfaces. So:
#
#   1. Enumerate the pulse-*.service units installed HERE and keep the ones whose
#      ExecStart calls pulse-inject.sh. Those are the LOCAL loops. A unit that
#      calls pulse-dispatch-remote.sh is skipped: the dispatcher already surfaces
#      it, and surfacing again would double-announce.
#   2. Resolve each one's project path + ledger + row from the harnessd manifest
#      (~/harnessd/refs/harness-manifest.json). NOTHING is hardcoded here — the
#      manifest already pins ledger/ledger_row per loop and is already asserted
#      per tick by harness-assert-registration.
#   3. Read that ledger's NEWEST row for that loop and compare its `ts` against a
#      per-loop marker under $LOCAL_ROOT/marks/.
#   4. Newer ⇒ write a surface object and STAGE it via pulse-surface-queue.sh,
#      then advance the marker — but ONLY if the queue confirmed `staged`.
#
# It is invoked from pulse-retry.sh, BEFORE that script's drain, so a surface
# staged on this run is delivered on this run. No new systemd unit: pulse-retry
# already fires every 2 minutes and already exists for this exact shape of
# problem ("the deferred thing is ready — deliver it").
#
# ---------------------------------------------------------------------------
# EXACTLY ONCE PER LEDGER ROW — and why the marker advances on STAGE, not on
# DELIVERY
# ---------------------------------------------------------------------------
# The queue owns delivery. Staging is durable (one file per row, collapse-newest-
# wins, delivery by move into delivered/, no expiry), so once an entry is staged
# it is delivered eventually — on the drain that pulse-retry runs two lines later,
# or on a later one once the 🔔 clears. Advancing the marker on a successful STAGE
# is therefore exactly-once: the row is announced once, and a bounced drain leaves
# the entry PENDING (never dropped, never re-staged, never duplicated).
#
# Advancing on DELIVERY instead would be the bug: the drain is asynchronous and
# bounces are the NORMAL state whenever Zig is away, so the same row would be
# re-staged every 2 minutes until the bell cleared. Collapse would hide the
# duplication in the queue and the marker would still be wrong.
#
# ---------------------------------------------------------------------------
# FIRST SIGHT SEEDS, IT DOES NOT ANNOUNCE (a decision this script makes)
# ---------------------------------------------------------------------------
# With no marker at all there is no honest answer to "newer than what". Every
# existing row would be "new", so a fresh install — or a loop just moved from the
# dispatcher to a local timer — would announce a backlog of ticks Zig has already
# seen. So the FIRST run for a loop records the newest ts and stages NOTHING, and
# says so in the log. The cost is bounded and named: a tick that completes in the
# <=2-minute window between installing this watcher and its first run is not
# announced. Everything after that is.
#
# ---------------------------------------------------------------------------
# ERRORS ARE LOUD. "no ledger" IS NOT "nothing new".
# ---------------------------------------------------------------------------
# A local loop with no manifest entry, an unreadable/corrupt ledger, or a manifest
# ledger_row that matches no row in its ledger are all DRIFT — each one means a
# loop whose completions can never be announced. Every one of them is counted into
# the result token on EVERY run, and printed to stderr; only the verbose stderr
# line is throttled to once per UTC day per (loop, kind) so a standing drift does
# not drown the log it is trying to be visible in.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   pulse-ledger-watch.sh [--loop <id>] [--dry-run]
#     --loop     only consider this loop id (the unit/timer stem, e.g.
#                pulse-weekly-report). Default: every local loop.
#     --dry-run  report what WOULD be staged; stage nothing, advance no marker,
#                seed no marker.
#
# OUTCOME CONTRACT — PULSE_LEDGER_WATCH_RESULT. Exactly ONE machine-readable
# line, LAST on stdout, and ALWAYS the same shape so a caller can parse it
# without a case ladder:
#
#   PULSE_LEDGER_WATCH_RESULT=staged:<n>:seeded:<m>:errors:<e>
#   PULSE_LEDGER_WATCH_RESULT=failed-usage           bad/missing args (64)
#
# TEST SEAMS (unset in production): HARNESS_MANIFEST, PULSE_LEDGER_WATCH_STATE,
# PULSE_SURFACE_QUEUE, PULSE_LEDGER_WATCH_LOG.
#
# Bead: dotfiles-wqby

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

MANIFEST="${HARNESS_MANIFEST:-$HOME/harnessd/refs/harness-manifest.json}"
# A SIBLING of the queue root (~/.local/state/pulse-dispatch-surfaces), for the
# same reason that root is a sibling of the dispatch state root: the queue owns
# pending/ + delivered/ and readers enumerate them, so this watcher's own
# bookkeeping must not live inside it.
LOCAL_ROOT="${PULSE_LEDGER_WATCH_STATE:-$HOME/.local/state/pulse-local-surfaces}"
MARK_DIR="$LOCAL_ROOT/marks"
SURF_DIR="$LOCAL_ROOT/surfaces"
WARN_DIR="$LOCAL_ROOT/warned"
QUEUE="${PULSE_SURFACE_QUEUE:-$HERE/pulse-surface-queue.sh}"
LOG="${PULSE_LEDGER_WATCH_LOG:-$LOCAL_ROOT/pulse-ledger-watch.log}"

SYSTEMCTL_BIN=$(command -v systemctl) || SYSTEMCTL_BIN=/usr/bin/systemctl
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl

RESULT_SENT=0
STAGED=0; SEEDED=0; ERRORS=0

emit_result() {
  [ "$RESULT_SENT" -eq 1 ] && return 0
  RESULT_SENT=1
  printf 'PULSE_LEDGER_WATCH_RESULT=%s\n' "$1"
}
finish() { emit_result "staged:$STAGED:seeded:$SEEDED:errors:$ERRORS"; exit 0; }

note() {
  { flock -w 5 9 || true
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$LOG" || true
}
say() { printf '%s\n' "$*"; note "$*"; }

# A drift error. Counted EVERY run (the count rides the result token); the verbose
# line is printed at most once per UTC day per key, so a standing drift stays
# visible without filling the log.
err_loud() {
  local key=$1 msg=$2 today stampf prev
  ERRORS=$(( ERRORS + 1 ))
  note "ERROR $key: $msg"
  today=$(date -u +%F)
  stampf="$WARN_DIR/$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
  prev=""
  [ -f "$stampf" ] && prev=$(cat "$stampf")
  if [ "$prev" != "$today" ]; then
    printf 'pulse-ledger-watch: ERROR %s: %s\n' "$key" "$msg" >&2
    printf '%s\n' "$today" > "$stampf" || true
  fi
}

usage_fail() { echo "pulse-ledger-watch: $*" >&2; emit_result failed-usage; exit 64; }

command -v jq >/dev/null || usage_fail "jq required"

ONLY_LOOP=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --loop)    ONLY_LOOP=${2:-}; [ -n "$ONLY_LOOP" ] || usage_fail "--loop needs a value"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,110p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_fail "unknown arg $1" ;;
  esac
done

mkdir -p "$MARK_DIR" "$SURF_DIR" "$WARN_DIR" \
  || { echo "pulse-ledger-watch: cannot create state under $LOCAL_ROOT" >&2; ERRORS=1; finish; }

# Digits-only sort key for an ISO-8601-Z timestamp (2026-08-07T16:19:23Z →
# 20260807161923). Same helper, same reason, as pulse-retry.sh: locale-independent
# numeric comparison rather than string collation.
ts_key() { printf '%s' "$1" | tr -cd '0-9'; }

slug_of() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Pull the token following a flag out of an ExecStart rendering. Replicated from
# pulse-retry.sh rather than shared: it is one line, and replication keeps both
# scripts' proven behavior independent.
execstart_flag() { printf '%s' "$1" | grep -oE -- "$2 [^ ]+" | head -1 | awk '{print $2}'; }

# --- The manifest is the mapping. No mapping, no watcher. -------------------
if [ ! -r "$MANIFEST" ]; then
  err_loud "manifest" "cannot read $MANIFEST — no loop can be mapped to a ledger, so NOTHING is being watched. This is drift, not 'nothing new'."
  finish
fi
if ! MAN_ERR=$(jq -e 'has("projects")' "$MANIFEST" 2>&1 >/dev/null); then
  err_loud "manifest" "$MANIFEST is not readable as a manifest with a top-level 'projects' key (jq: ${MAN_ERR:-parse failed}) — NOTHING is being watched."
  finish
fi

# --- Enumerate the units installed HERE -------------------------------------
mapfile -t UNITS < <("$SYSTEMCTL_BIN" --user list-unit-files 'pulse-*.service' --no-legend | awk '{print $1}')
if [ "${#UNITS[@]}" -eq 0 ]; then
  note "no pulse-*.service units installed — nothing to watch"
  finish
fi

for unit in "${UNITS[@]}"; do
  [ -n "$unit" ] || continue
  loop=${unit%.service}
  [ -z "$ONLY_LOOP" ] || [ "$ONLY_LOOP" = "$loop" ] || continue

  es=$("$SYSTEMCTL_BIN" --user show "$unit" -p ExecStart --value)
  case "$es" in
    *pulse-inject.sh*) : ;;                       # LOCAL — ours
    *pulse-dispatch-remote.sh*)
      note "skip $loop: dispatched remotely — pulse-dispatch-remote.sh surfaces it itself"
      continue ;;
    *)
      # Not a pulse tick at all (pulse-retry, pulse-stall, …). Silent by design:
      # these units are named pulse-* but inject nothing, so there is no ledger
      # row to watch and no surface to lose.
      note "skip $loop: ExecStart is not a pulse injection"
      continue ;;
  esac

  entry=$(jq -c --arg t "$loop" '
      [ .projects[]? | . as $p | (.loops[]? | select(.timer == $t)
        | {path: $p.path, key: $p.key, ledger: .ledger, row: .ledger_row}) ] | first // empty' \
    "$MANIFEST")
  if [ -z "$entry" ]; then
    err_loud "$loop/unregistered" "$loop is a LOCAL pulse loop (ExecStart calls pulse-inject.sh) with NO entry in $MANIFEST. Its ledger and row cannot be resolved, so every tick it finishes goes unannounced. Add a loops[] entry for it under the owning project."
    continue
  fi

  proj=$(jq -r '.path // empty' <<<"$entry")
  ledger_rel=$(jq -r '.ledger // empty' <<<"$entry")
  row_pin=$(jq -r 'if .row == null then "" else .row end' <<<"$entry")
  if [ -z "$proj" ] || [ -z "$ledger_rel" ]; then
    err_loud "$loop/manifest-incomplete" "manifest entry for $loop has no path and/or no ledger — cannot resolve where its completions are recorded."
    continue
  fi
  case "$ledger_rel" in
    /*) ledger="$ledger_rel" ;;
    *)  ledger="${proj%/}/$ledger_rel" ;;
  esac

  if [ ! -r "$ledger" ]; then
    err_loud "$loop/ledger-missing" "ledger $ledger is missing or unreadable. A local loop with no readable ledger cannot be observed at all — this is NOT 'no new rows'."
    continue
  fi

  jqerr=$(mktemp) || jqerr=/dev/null
  newest=$(jq -sc --arg r "$row_pin" '
      [ .[] | select(type == "object") | select(has("ts"))
            | select($r == "" or ((.row // "") == $r)) ] | last // empty' \
    "$ledger" 2>"$jqerr")
  jqrc=$?
  jqmsg=""
  [ -s "$jqerr" ] && jqmsg=$(tr '\n' ' ' < "$jqerr")
  [ "$jqerr" = /dev/null ] || rm -f "$jqerr"
  if [ "$jqrc" -ne 0 ]; then
    err_loud "$loop/ledger-unparsable" "could not parse $ledger as JSONL (jq: ${jqmsg:-rc=$jqrc}). Treating a corrupt ledger as 'nothing new' would silence this loop permanently."
    continue
  fi
  if [ -z "$newest" ]; then
    err_loud "$loop/row-absent" "ledger $ledger contains no row named '${row_pin:-<any>}'. The manifest pins that row for $loop, so either the loop has never written one or the pin is drift — either way nothing can ever surface for it."
    continue
  fi

  n_ts=$(jq -r '.ts // empty' <<<"$newest")
  if [ -z "$n_ts" ]; then
    err_loud "$loop/row-no-ts" "the newest row for '${row_pin:-<any>}' in $ledger has no ts — it cannot be compared against the marker."
    continue
  fi

  mark="$MARK_DIR/$(slug_of "$loop")"
  prev=""
  [ -f "$mark" ] && prev=$(head -1 "$mark")

  write_mark() {
    local tmp="$mark.tmp.$$"
    printf '%s\n' "$n_ts" > "$tmp" && mv -f "$tmp" "$mark" && return 0
    rm -f "$tmp"
    err_loud "$loop/marker-write" "could not write the last-surfaced marker $mark — the next run would announce this row again."
    return 1
  }

  # First sight: learn, do not announce. See the header.
  if [ -z "$prev" ]; then
    if [ "$DRY" = 1 ]; then
      say "would SEED $loop at $n_ts (no marker yet — first sight never announces a backlog)"
    else
      write_mark && say "seeded $loop at $n_ts (first sight — nothing announced; the NEXT row surfaces)"
    fi
    SEEDED=$(( SEEDED + 1 ))
    continue
  fi

  nk=$(ts_key "$n_ts"); pk=$(ts_key "$prev")
  if [ "${nk:-0}" -le "${pk:-0}" ]; then
    note "no new row for $loop (newest $n_ts <= last surfaced $prev)"
    continue
  fi

  n_out=$(jq -r '.outcome // "?"' <<<"$newest")
  n_bead=$(jq -r '.bead // empty' <<<"$newest")
  n_note=$(jq -r '(.note // "") | gsub("\\s+"; " ") | .[0:600]' <<<"$newest")
  qrow=${row_pin:-$loop}

  # Where the announcement goes: the loop's OWN session:window, taken from its
  # ExecStart. That is deliberate and it is what makes this compose with the
  # ATTENDED prose fix (weekly-reporting-skd) with no special casing — if the tick
  # already raised its own dialog, that window's name starts with 🔔, pulse-inject
  # refuses to type into it, and this surface simply stays queued until the bell
  # clears. It is also the pane holding the tick's context.
  session=$(execstart_flag "$es" --session); session=${session:-work}
  window=$(execstart_flag "$es" --window);   window=${window:-pulse}

  sfile="$SURF_DIR/$(slug_of "$loop").json"
  if ! jq -n --arg row "$qrow" --arg loop "$loop" --arg out "$n_out" --arg note "$n_note" \
        --arg bead "$n_bead" --arg ledger "$ledger" --arg ts "$n_ts" --arg proj "$proj" \
        '{reason: "a LOCAL pulse tick FINISHED — Zig has to see it, whether or not it needs a decision",
          question: ("The " + $row + " tick finished HERE on zig-computer (outcome: " + $out + ")"
                     + (if $note == "" then "" else " — " + ($note[0:200]) end)
                     + ". Its output is landed and waiting for you. Pick it up now, or park it?"),
          options: ["Show me what landed", "I will pick it up", "Nothing needed — noted"],
          detail: ("row=" + $row + "  ·  loop=" + $loop + "  ·  outcome=" + $out
                   + "  ·  ran LOCALLY (not on marketing-vps)"
                   + (if $bead == "" then "" else "  ·  bead: " + $bead end)
                   + "  ·  ledger row ALREADY WRITTEN at " + $ledger + " (ts " + $ts
                   + ") — do NOT write another, and do NOT re-run the tick"
                   + "  ·  project: " + $proj
                   + (if $note == "" then "" else "  ·  note: " + $note end)
                   + ".  Nothing here necessarily needs a decision — the point is that you SEE it, know where it is, and can pick it up."),
          _loop: $loop, _ledger: $ledger, _ledger_ts: $ts, _outcome: $out,
          _bead: (if $bead == "" then null else $bead end),
          _source: "pulse-ledger-watch"}' > "$sfile.tmp.$$"; then
    rm -f "$sfile.tmp.$$"
    err_loud "$loop/surface-write" "could not write the surface object $sfile — the row is NOT announced and the marker is NOT advanced, so the next run retries it."
    continue
  fi
  mv -f "$sfile.tmp.$$" "$sfile" || {
    rm -f "$sfile.tmp.$$"
    err_loud "$loop/surface-install" "could not install $sfile — the row is NOT announced and the marker stays put."
    continue
  }

  summary="LOCAL tick on zig-computer · row=$qrow outcome=$n_out${n_bead:+ · bead $n_bead}${n_note:+ · ${n_note:0:200}}"

  if [ "$DRY" = 1 ]; then
    say "would STAGE $loop row=$qrow ts=$n_ts outcome=$n_out -> $session:$window (marker stays at ${prev:-<none>})"
    STAGED=$(( STAGED + 1 ))
    continue
  fi

  if [ ! -x "$QUEUE" ]; then
    err_loud "$loop/queue-missing" "$QUEUE is not executable — the completion of $loop at $n_ts cannot be staged. The marker is NOT advanced, so it is retried next run."
    continue
  fi

  out=$("$QUEUE" stage --row "$qrow" --run "ledger-watch:$loop@$n_ts" \
          --session "$session" --window "$window" --dir "$proj" --file "$sfile" \
          --reason "completed:$n_out" --summary "$summary" 2>&1)
  case "$out" in
    *PULSE_SURFACE_RESULT=staged*)
      # Marker advances ONLY here. A drain that bounces later leaves the entry
      # pending in the queue — that is the queue's job, not this script's, and
      # re-staging it would be the duplicate this guard exists to prevent.
      if write_mark; then
        STAGED=$(( STAGED + 1 ))
        say "staged surface for $loop (row=$qrow, ts=$n_ts, outcome=$n_out) -> $session:$window"
      fi
      ;;
    *)
      err_loud "$loop/stage-failed" "pulse-surface-queue stage refused the completion of $loop at $n_ts (said: $(printf '%s' "$out" | tail -1)). Marker NOT advanced — the next run retries it."
      ;;
  esac
done

finish
