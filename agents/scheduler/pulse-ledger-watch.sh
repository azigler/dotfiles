#!/bin/bash
# pulse-ledger-watch.sh — the LOCAL-loop completion watcher (dotfiles-wqby).
#
# ---------------------------------------------------------------------------
# THE HOLE THIS FILLS
# ---------------------------------------------------------------------------
# The retired remote dispatcher surfaced EVERY finished tick — done, quiet,
# blocked alike (step 7, dotfiles-5ts2; Zig 2026-07-31: "there's no such thing as
# a low-value bell"). It could do that only because it OBSERVED completion: step 5
# polled result.json, step 6 wrote the ledger row, step 7 staged the surface.
# It went with marketing-vps (dotfiles-y3u8); this script is now the ONLY thing
# keeping that guarantee alive, which raises the stakes on everything below.
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
#      ExecStart calls pulse-inject.sh AND whose TIMER is enabled. Those are the
#      LOCAL loops. Anything else is skipped — including a unit still naming the
#      retired remote dispatcher, which the catch-all arm handles with no special
#      case (the dispatcher went with marketing-vps, dotfiles-y3u8; while it lived
#      the skip existed so its own surfacing was not double-announced).
#      A unit whose timer is DISABLED is skipped too — see "A DISABLED LOOP IS NOT
#      DRIFT" below.
#   2. Resolve each one's project path + ledger + row from the harnessd manifest
#      (~/harnessd/refs/harness-manifest.json). NOTHING is hardcoded here — the
#      manifest already pins ledger/ledger_row per loop and is already asserted
#      per tick by harness-assert-registration.
#   3. Read that ledger's NEWEST row for that loop and compare its `ts` against a
#      per-loop marker under $LOCAL_ROOT/marks/.
#   4. Newer ⇒ write a surface object and STAGE it via pulse-surface-queue.sh
#      (--origin local, which is what makes the queue's injected command say "the
#      ledger row is already written" instead of the remote form's "land the ledger
#      row" — dotfiles-sxsv), then advance the marker, but ONLY if the queue
#      confirmed `staged`.
#
# The whole run holds an exclusive lock ($LOCAL_ROOT/.watch.lock). The read-marker →
# stage → write-marker window is not atomic and the QUEUE's lock does not cover it:
# two concurrent runs would both read the stale marker and both stage the same row,
# collapsing to pending:1 / superseded:1 — an announcement that claims the tick
# re-ran when it did not.
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
# seen. So the FIRST run for a loop that ALREADY HAS ledger rows records the newest
# ts and stages NOTHING, and says so in the log. The cost is bounded and named: a
# tick that completes in the <=2-minute window between installing this watcher and
# its first run is not announced. Everything after that is.
#
# ⚠️ That was ALSO, until dotfiles-sxsv, the story for a NEWLY REGISTERED loop —
# and there it was wrong and unbounded. A loop with no matching ledger row yet took
# the row-absent error path, wrote no marker, and so the run after its FIRST REAL
# TICK was that row's "first sight": it seeded and announced nothing, and only the
# SECOND tick ever surfaced. Not a 2-minute install window — every new loop, always.
# The fix: the row-absent path writes a FLOOR marker (0000-00-00T00:00:00Z, whose
# ts_key is 0), so a loop that has never ticked is distinguishable from a loop whose
# history predates the watcher, and its first real row surfaces like any other. The
# error stays loud, because the same empty match is also how a drifted ledger_row
# pin presents.
#
# ---------------------------------------------------------------------------
# ERRORS ARE LOUD. "no ledger" IS NOT "nothing new".
# ---------------------------------------------------------------------------
# A local loop with no manifest entry, an unreadable/corrupt ledger, a manifest
# ledger_row that matches no row in its ledger, a newest row whose ts is absent or
# MALFORMED, a marker file that exists but is unreadable garbage, a marks/ directory
# that cannot be written, a systemctl enumeration that FAILED (rather than returned
# nothing), and a lock this run could not take are all DRIFT — each one means a loop
# whose completions can never be announced, or a run that examined nothing. Every
# one is counted into the result token on EVERY run, and printed to stderr; only the
# verbose stderr line is throttled to once per UTC day per (loop, kind) so a
# standing drift does not drown the log it is trying to be visible in.
#
# The rule behind that list: any path that ends in "nothing to do" must be able to
# prove it looked. `mapfile < <(systemctl …)` could not — it discarded the exit
# status, so a dead user bus reported staged:0:seeded:0:errors:0.
#
# ---------------------------------------------------------------------------
# A DISABLED LOOP IS NOT DRIFT — and a false alarm is not free (dotfiles-eh21)
# ---------------------------------------------------------------------------
# The list above is only worth its loudness if every entry is real. This script
# enumerated pulse-*.service without asking whether the loop's TIMER was enabled, so
# five dormant units on zig-computer (pulse-autonoveld-{conceive,mail,voice,write},
# superseded by pulse-daily-ao3; pulse-picod, dormant) were reported as
# `unregistered` — errors:5, every 2 minutes, forever, on a healthy box. A timer that
# never fires cannot finish a tick, so there is no completion to lose and nothing to
# announce: that is not a loop that "can never be surfaced", it is a loop with
# nothing to surface. It is the explore-4x39 failure mode pointed the other way — a
# standing false alarm trains the reader to discount the alarm that will matter.
#
# So a loop whose timer is disabled/masked is SKIPPED. Two things about how:
#
# ⚠️ Keyed on the TIMER's enabled state, NEVER on the service's active state. Every
#    pulse-*.service is `Type=oneshot` and therefore `inactive` between runs BY
#    DESIGN; keying on that would skip every healthy loop and silently switch the
#    whole watcher off — the loudest possible bug wearing the quietest face.
#
# ⚠️ Only an AFFIRMATIVELY disabled timer skips. Anything else — enabled, static,
#    indirect, a timer that does not exist, an is-enabled that failed — is treated as
#    LIVE and takes the normal path, errors included. Assuming "disabled" from an
#    unclear answer would silence a running loop, which is the failure this whole
#    script exists to end; assuming "live" costs at worst one error on a unit that
#    was never going to fire. The regression test pins the direction that matters:
#    an ENABLED timer with no manifest entry still errors loudly.
#
# The skip is logged as a `note` (log only, not stderr, not counted). Silent would be
# indistinguishable from "the unit isn't installed", which is exactly the question
# someone asks when a loop stops surfacing; every other skip in this loop leaves the
# same kind of trace.
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
# PULSE_SURFACE_QUEUE, PULSE_LEDGER_WATCH_LOG, PULSE_LEDGER_WATCH_LOCK_WAIT.
#
# Bead: dotfiles-wqby (and dotfiles-sxsv for the origin-aware staging)

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
    -h|--help) sed -n '2,171p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_fail "unknown arg $1" ;;
  esac
done

mkdir -p "$MARK_DIR" "$SURF_DIR" "$WARN_DIR" \
  || { echo "pulse-ledger-watch: cannot create state under $LOCAL_ROOT" >&2; ERRORS=1; finish; }

# Digits-only sort key for an ISO-8601-Z timestamp (2026-08-07T16:19:23Z →
# 20260807161923). Same helper, same reason, as pulse-retry.sh: locale-independent
# numeric comparison rather than string collation.
ts_key() { printf '%s' "$1" | tr -cd '0-9'; }

# The floor marker: a well-formed ISO-8601-Z stamp whose ts_key is 0, so every real
# ledger ts sorts strictly above it. Written for a loop that is registered but has
# not yet produced a matching ledger row, so that its FIRST real row surfaces
# instead of being swallowed as "first sight". See the row-absent branch.
TS_FLOOR="0000-00-00T00:00:00Z"

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

# --- ONE watcher at a time --------------------------------------------------
# The read-marker → stage → write-marker window is NOT atomic, and the queue's own
# lock does not cover it: that lock guards the queue FILE, so two concurrent
# watchers both read the same stale marker, both stage the same row, and the second
# staging collapses onto the first — pending:1 with superseded:1, which makes the
# announcement claim the tick re-ran when it did not. Measured with two parallel
# runs against one new row.
#
# pulse-retry.timer fires every 2 minutes and a healthy run is sub-second, so
# contention means a previous run is wedged, not that this is normal. Wait for it
# (the loser then reads the ADVANCED marker and correctly stages nothing); give up
# loudly rather than proceeding lock-free, because proceeding is the double-stage
# this lock exists to prevent.
WATCH_LOCK="$LOCAL_ROOT/.watch.lock"
exec 7>>"$WATCH_LOCK"
if ! flock -w "${PULSE_LEDGER_WATCH_LOCK_WAIT:-30}" 7; then
  err_loud "lock" "another pulse-ledger-watch run has held $WATCH_LOCK for over ${PULSE_LEDGER_WATCH_LOCK_WAIT:-30}s. Refusing to run concurrently — two watchers double-stage the same ledger row. Nothing was examined this run; this is NOT 'nothing new'."
  finish
fi

# --- Enumerate the units installed HERE -------------------------------------
# The rc is CHECKED. `mapfile < <(systemctl …)` cannot fail: with no user bus (a
# non-session context, a stopped user manager) systemctl writes to stderr, exits
# non-zero, prints nothing — and the old code read that as zero units and reported
# staged:0:seeded:0:errors:0. Total blindness dressed as a clean run, which is the
# exact silence this script exists to end.
#
# stderr is captured to a FILE rather than folded into stdout with 2>&1: a warning
# on a SUCCESSFUL call would otherwise be parsed as a unit name by the awk below.
scerr=$(mktemp) || scerr=/dev/null
units_raw=$("$SYSTEMCTL_BIN" --user list-unit-files 'pulse-*.service' --no-legend 2>"$scerr"); sc_rc=$?
sc_msg=""
[ -s "$scerr" ] && sc_msg=$(tr '\n' ' ' < "$scerr" | cut -c1-300)
[ "$scerr" = /dev/null ] || rm -f "$scerr"
if [ "$sc_rc" -ne 0 ]; then
  err_loud "systemctl" "'$SYSTEMCTL_BIN --user list-unit-files pulse-*.service' failed (rc=$sc_rc: ${sc_msg:-no message}). No unit could be enumerated, so NOTHING is being watched — this is drift, not 'nothing new'."
  finish
fi
mapfile -t UNITS < <(printf '%s\n' "$units_raw" | awk 'NF {print $1}')
if [ "${#UNITS[@]}" -eq 0 ]; then
  # Not a normal state on a box that runs this: pulse-retry.service is itself a
  # pulse-*.service, so a working enumeration always returns at least one unit.
  err_loud "no-units" "the systemctl enumeration succeeded but matched NO pulse-*.service units. On a box where this watcher runs at all, pulse-retry.service alone should match — an empty match means the units are gone or the wrong user manager was queried, and every local loop's completions are going unannounced."
  finish
fi

for unit in "${UNITS[@]}"; do
  [ -n "$unit" ] || continue
  loop=${unit%.service}
  [ -z "$ONLY_LOOP" ] || [ "$ONLY_LOOP" = "$loop" ] || continue

  es=$("$SYSTEMCTL_BIN" --user show "$unit" -p ExecStart --value)
  case "$es" in
    *pulse-inject.sh*) : ;;                       # LOCAL — ours
    *)
      # Not a pulse tick at all (pulse-retry, pulse-stall, …) — or a unit still
      # naming the retired remote dispatcher, which lands here too and is skipped
      # identically. Silent by design: these units are named pulse-* but inject
      # nothing, so there is no ledger row to watch and no surface to lose.
      note "skip $loop: ExecStart is not a pulse injection"
      continue ;;
  esac

  # --- Is this loop LIVE? Ask the TIMER, not the service. ---------------------
  # See "A DISABLED LOOP IS NOT DRIFT" in the header. is-enabled prints the state on
  # STDOUT for every state including not-found (verified: `not-found` on stdout,
  # rc=4), so stderr here would only ever carry a bus/permission complaint — captured
  # rather than discarded, and reported on the treat-as-live path where it is the
  # only clue about why the probe was unusable.
  tmerr=$(mktemp) || tmerr=/dev/null
  timer_state=$("$SYSTEMCTL_BIN" --user is-enabled "$loop.timer" 2>"$tmerr" | head -1)
  tm_msg=""
  [ -s "$tmerr" ] && tm_msg=$(tr '\n' ' ' < "$tmerr" | cut -c1-200)
  [ "$tmerr" = /dev/null ] || rm -f "$tmerr"
  case "$timer_state" in
    disabled|masked|masked-runtime)
      note "skip $loop: its timer $loop.timer is $timer_state — it cannot fire, so it cannot finish a tick, so there is nothing to surface. Not drift; enable the timer and this loop is watched again."
      continue ;;
    enabled|enabled-runtime|static|indirect|generated|transient|linked|linked-runtime) : ;;
    *)
      note "$loop: could not read its timer's enabled state ($loop.timer is-enabled said '${timer_state:-<nothing>}'${tm_msg:+; stderr: $tm_msg}). Treating it as LIVE — an unclear answer must never be read as 'disabled', because that would silence a running loop." ;;
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
  mark="$MARK_DIR/$(slug_of "$loop")"
  have_mark=0; prev=""
  if [ -f "$mark" ]; then
    have_mark=1
    prev=$(head -1 "$mark")
  fi

  # write_mark <value> — install a marker value atomically.
  write_mark() {
    local val=$1 tmp="$mark.tmp.$$"
    printf '%s\n' "$val" > "$tmp" 2>/dev/null && mv -f "$tmp" "$mark" 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null
    err_loud "$loop/marker-write" "could not write the last-surfaced marker $mark — the next run would announce this row again."
    return 1
  }

  if [ -z "$newest" ]; then
    # An empty match is TWO different states wearing one face: a pin that is drift
    # (typo, renamed row) and a loop registered before it has ever ticked. Both are
    # worth an error, but only one of them ever resolves — and for that one, doing
    # nothing here is what swallowed its first real tick: with no marker, the run
    # AFTER its first ledger row is that row's "first sight", so the row SEEDS
    # instead of surfacing and only the SECOND tick is ever announced.
    #
    # So seed a FLOOR marker (ts_key -> 0) on the way past. Every real ts sorts
    # above it, so the loop's first real row surfaces like any other, while the
    # error keeps the drift case loud on every run. Not counted as a seed: nothing
    # was learned from a ledger, and SEEDED means "a backlog was deliberately not
    # announced".
    if [ "$have_mark" = 0 ] && [ "$DRY" != 1 ]; then
      write_mark "$TS_FLOOR" \
        && note "$loop: floor marker seeded at $TS_FLOOR — its first real row will SURFACE rather than seed"
    fi
    err_loud "$loop/row-absent" "ledger $ledger contains no row named '${row_pin:-<any>}'. The manifest pins that row for $loop, so either the loop has never written one (its first row WILL surface — a floor marker is now in place) or the pin is drift, in which case nothing can ever surface for it."
    continue
  fi

  n_ts=$(jq -r '.ts // empty' <<<"$newest")
  if [ -z "$n_ts" ]; then
    err_loud "$loop/row-no-ts" "the newest row for '${row_pin:-<any>}' in $ledger has no ts — it cannot be compared against the marker."
    continue
  fi
  # A MALFORMED ts is as fatal to the comparison as an absent one, and used to be
  # the quietest failure in the script: ts_key() strips non-digits, so "yesterday"
  # became "" became 0, which is <= any marker, which logged "no new row" and
  # returned errors:0. There is an explicit error for an ABSENT ts; there must be
  # one for an UNUSABLE ts. The shape is also what makes ts_key comparable at all —
  # a different digit count (date-only, a +00:00 offset) would compare wrongly.
  case "$n_ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *)
      err_loud "$loop/row-ts-unparsable" "the newest row for '${row_pin:-<any>}' in $ledger has ts '$n_ts', which is not the ISO-8601 UTC form YYYY-MM-DDTHH:MM:SSZ. It cannot be compared against the marker, and skipping it quietly would silence this loop for as long as that row stays newest."
      continue ;;
  esac

  # First sight: learn, do not announce. See the header.
  if [ "$have_mark" = 0 ]; then
    if [ "$DRY" = 1 ]; then
      say "would SEED $loop at $n_ts (no marker yet — first sight never announces a backlog)"
    else
      write_mark "$n_ts" && say "seeded $loop at $n_ts (first sight — nothing announced; the NEXT row surfaces)"
    fi
    SEEDED=$(( SEEDED + 1 ))
    continue
  fi

  # A marker file that EXISTS but is empty or garbage is not "no marker" — and the
  # old code could not tell the two apart, so it re-SEEDED: it jumped the marker to
  # the newest ts and lost that announcement permanently. Recovering by ANNOUNCING
  # is the right direction; the worst case is one duplicate announcement (which the
  # queue collapses), against a permanent silence. Loud either way.
  if [ -z "$prev" ] || ! printf '%s' "$prev" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    err_loud "$loop/marker-corrupt" "the marker $mark exists but reads '$prev', which is not a comparable timestamp (truncated write? partial disk?). Re-seeding it would jump past a finished tick and lose that announcement forever, so the newest row is being treated as UNANNOUNCED instead — at worst you see one announcement twice."
    prev=""
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

  # RESERVE the marker write BEFORE staging. "Stage, then advance the marker" reads
  # safe and is not: when the marker write is the thing that fails (an unwritable
  # marks/ — reproduced with chmod 555), every run stages the SAME row again, the
  # queue's superseded counter climbs, and the announcement starts claiming a tick
  # re-ran when it never did. There is no in-band recovery from that after the
  # staging, so the failure has to be detected before it.
  #
  # Creating the temp file proves the directory is writable; the mv that installs it
  # is then the same directory operation, so the residual window is one atomic
  # rename rather than a whole staging round-trip. If the reservation fails, the row
  # is NOT staged at all — a loud, retryable error beats an announcement loop.
  mres="$mark.tmp.$$"
  if ! printf '%s\n' "$n_ts" > "$mres" 2>/dev/null; then
    rm -f "$mres" 2>/dev/null
    err_loud "$loop/marker-unwritable" "cannot write into $MARK_DIR, so the last-surfaced marker for $loop could not be reserved. REFUSING to stage the completion at $n_ts: staging without an advanceable marker re-announces this row on every run, forever. Fix the permissions on $MARK_DIR and it will surface on the next run."
    continue
  fi

  # --origin local is load-bearing, not metadata (dotfiles-sxsv). It selects the
  # wording the queue's drain TYPES into the pane. Without it the session is told to
  # "land the ledger row" — a row this tick already wrote and this watcher just read —
  # so it writes a duplicate with a fresh ts, which this watcher reads as new on the
  # next 2-minute run, stages, and types again. Forever.
  out=$("$QUEUE" stage --row "$qrow" --run "ledger-watch:$loop@$n_ts" \
          --session "$session" --window "$window" --dir "$proj" --file "$sfile" \
          --origin local \
          --reason "completed:$n_out" --summary "$summary" 2>&1)
  case "$out" in
    *PULSE_SURFACE_RESULT=staged*)
      # Marker advances ONLY here. A drain that bounces later leaves the entry
      # pending in the queue — that is the queue's job, not this script's, and
      # re-staging it would be the duplicate this guard exists to prevent.
      if mv -f "$mres" "$mark" 2>/dev/null; then
        STAGED=$(( STAGED + 1 ))
        say "staged surface for $loop (row=$qrow, ts=$n_ts, outcome=$n_out) -> $session:$window"
      else
        rm -f "$mres" 2>/dev/null
        err_loud "$loop/marker-write" "the completion of $loop at $n_ts WAS staged, but installing the marker $mark failed after the reservation succeeded. The next run will announce this row again — check $MARK_DIR."
      fi
      ;;
    *)
      rm -f "$mres" 2>/dev/null
      err_loud "$loop/stage-failed" "pulse-surface-queue stage refused the completion of $loop at $n_ts (said: $(printf '%s' "$out" | tail -1)). Marker NOT advanced — the next run retries it."
      ;;
  esac
done

finish
