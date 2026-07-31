#!/bin/bash
# pulse-surface-queue.sh — the deferred-surface QUEUE and its DRAIN (dotfiles-5ts2).
#
# Zig, 2026-07-31:
#
#     "I don't think there's such a thing as a low-value bell. ... you need to be
#      in charge of making sure I see their actions and I know when they're ready
#      so I can pick them up and publish them."
#
# Which makes every finished pulse tick something he must SEE — not only the ones
# carrying a decision. pulse-dispatch-remote.sh now surfaces on EVERY completion.
# That policy alone would have made things WORSE, and this script is why.
#
# ---------------------------------------------------------------------------
# THE HOLE THIS FILLS
# ---------------------------------------------------------------------------
# pulse-inject.sh REFUSES to type into a window whose name starts with 🔔 — the
# text would land in the modal dialog instead of the composer, and the trailing
# Enter would answer Zig's open question with the wrong option. So it records a
# bounce, returns PULSE_INJECT_RESULT=deferred-blocked-on-human, and types nothing.
#
# Before this script, the dispatcher warned, left a surface_request JSON in its own
# per-run state dir, and moved on. NOTHING EVER REDELIVERED IT. (pulse-retry.sh
# re-fires bounced *ticks* — a whole `systemctl start <loop>.service`, which for an
# already-completed tick is the wrong verb entirely: it redoes the work and burns
# the cap. The ANNOUNCEMENT is what needs retrying, not the tick.)
#
# Under always-bell, an open 🔔 is the NORMAL state whenever Zig is away. So the
# always-surface half without this half would swallow exactly the notifications it
# exists to guarantee. Both halves ship together or neither does.
#
# ---------------------------------------------------------------------------
# THE MODEL
# ---------------------------------------------------------------------------
# One file per ROW under ~/.local/state/pulse-dispatch-surfaces/pending/. That is not
# an incidental layout choice — it IS the collapse rule: staging a second surface for a row that
# already has one pending OVERWRITES it, so a row that re-ran while Zig was away
# announces its NEWEST state and never a stale one. The count of collapsed stagings
# is kept (`superseded`) so the announcement can say so out loud.
#
# Ordering is by `first_staged_at`, preserved across collapse: the row that has been
# waiting longest is announced first, even if it has since re-run.
#
# Delivery is a MOVE into ../delivered/ — atomic within the queue root, so an entry
# is either pending or delivered, never both. That is the whole
# "nothing announces twice" guarantee.
#
# NO EXPIRY, deliberately. The queue is bounded by construction (one file per row,
# ~20 rows fleet-wide), so there is nothing to reclaim — and an expiry would drop the
# very announcement this exists to guarantee, silently, exactly when Zig has been
# away longest.
#
# ---------------------------------------------------------------------------
# WHAT TRIGGERS A DRAIN
# ---------------------------------------------------------------------------
#   1. Every surface attempt. pulse-dispatch-remote.sh stages THEN drains, so a
#      later tick's injection carries the earlier tick's held announcements with it.
#   2. pulse-retry.sh, every 2 minutes (pulse-retry.timer). That watcher already
#      exists for precisely this shape of problem — "the 🔔 cleared, deliver what
#      was deferred" — and reusing it means no new unit and no polling daemon. It
#      is also what makes delivery independent of a NEW DISPATCH ever happening:
#      answering the bell is enough.
#
# Both call the same `drain`, so there is one implementation of "what does the
# announcement say", not two to drift.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   pulse-surface-queue.sh stage --row <row> --file <surface.json> [options]
#       --run <run-id>      the dispatch run id (provenance in the announcement)
#       --session <name>    LOCAL tmux session   (default work)
#       --window  <name>    LOCAL tmux window    (default di)
#       --dir <project>     the LOCAL project dir (ledger lives at <dir>/refs/…)
#       --reason <text>     why this surfaced (surface-request / completed:done / …)
#       --summary <text>    one line: what landed
#
#   pulse-surface-queue.sh drain [--session <n>] [--window <n>] [--loop <id>]
#       Deliver every pending surface, oldest first, ONE injection per
#       session:window. With no filter, drains every group.
#
#   pulse-surface-queue.sh list [--session <n>] [--window <n>]
#       Print pending entries as JSON, oldest first (+ ._path). Read-only.
#
# ---------------------------------------------------------------------------
# OUTCOME CONTRACT — PULSE_SURFACE_RESULT (same discipline as the other two)
# ---------------------------------------------------------------------------
# Exactly ONE machine-readable line, LAST on stdout:
#
#   PULSE_SURFACE_RESULT=staged              stage: written (collapsing any older one)
#   PULSE_SURFACE_RESULT=empty               drain/list: nothing was pending
#   PULSE_SURFACE_RESULT=pending:<n>         list: <n> pending (read-only; nothing sent)
#   PULSE_SURFACE_RESULT=delivered:<n>       drain: <n> announcements injected + marked
#   PULSE_SURFACE_RESULT=deferred:<n>        drain: <n> still pending (window 🔔-blocked
#                                            or not input-ready); NOTHING was lost
#   PULSE_SURFACE_RESULT=partial:<n>:<m>     drain: <n> delivered, <m> still pending
#                                            (different session:window groups)
#   PULSE_SURFACE_RESULT=failed-usage        bad/missing args (64)
#   PULSE_SURFACE_RESULT=failed              anything else (1)
#
# FAIL CLOSED: no marker means an older copy of this script or a path that forgot to
# report — treat it as NOT delivered. Only `delivered:` may clear a surface.
#
# TEST SEAMS (unset in production): PULSE_SURFACE_STATE (the queue root; defaults to
# a sibling of PULSE_DISPATCH_STATE), PULSE_DISPATCH_STATE, PULSE_DISPATCH_INJECT,
# PULSE_SURFACE_LOG, PULSE_SURFACE_DONE_KEEP.
#
# Bead: dotfiles-5ts2

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

STATE_ROOT="${PULSE_DISPATCH_STATE:-$HOME/.local/state/pulse-dispatch}"
# A SIBLING of the dispatch state root, not a child of it. The dispatcher's root
# holds one directory PER RUN and several readers enumerate it that way (`ls -dt
# <root>/*/ | head -1` is the idiom for "the newest run"), so a queue directory
# living inside it would silently become "the newest run" the moment anything was
# staged. A sibling cannot be mistaken for a run, and stays just as visible.
QUEUE_ROOT="${PULSE_SURFACE_STATE:-${STATE_ROOT%/}-surfaces}"
QUEUE_DIR="$QUEUE_ROOT/pending"
DONE_DIR="$QUEUE_ROOT/delivered"
INJECT="${PULSE_DISPATCH_INJECT:-$HERE/pulse-inject.sh}"
LOG="${PULSE_SURFACE_LOG:-/tmp/pulse-surface-queue.log}"
# The delivered/ dir is an audit trail, not state anything reads. Trim it so a
# long-lived box does not accumulate one file per announcement forever.
DONE_KEEP="${PULSE_SURFACE_DONE_KEEP:-200}"

RESULT_SENT=0
emit_result() {
  [ "$RESULT_SENT" -eq 1 ] && return 0
  RESULT_SENT=1
  printf 'PULSE_SURFACE_RESULT=%s\n' "$1"
}

note() {
  { flock -w 5 9 || true
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${BASHPID:-$$}" "$*" >&9
  } 9>>"$LOG" 2>/dev/null || true
}
say()  { printf '%s\n' "$*"; note "$*"; }
warn() { printf 'pulse-surface-queue: %s\n' "$*" >&2; note "WARN $*"; }

usage_fail() { echo "pulse-surface-queue: $*" >&2; emit_result failed-usage; exit 64; }

command -v jq >/dev/null 2>&1 || usage_fail "jq required"

# The queue is shared between concurrent dispatchers (di-tuesday 07:00 and
# weekly-report 09:00 can overlap on an hour-long poll timeout), so stage and drain
# both take the same exclusive lock. Without it a drain can read a half-written
# entry, or two drains can both claim the same pending file and double-announce.
LOCK="$QUEUE_ROOT/.queue.lock"

CMD="${1:-}"
[ -n "$CMD" ] || usage_fail "a subcommand is required (stage | drain | list)"
shift || true

ROW=""; RUN=""; SESSION=""; WINDOW=""; DIR=""; FILE=""; REASON=""; SUMMARY=""; LOOP=""
F_SESSION=""; F_WINDOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --row)     ROW=$2; shift 2 ;;
    --run)     RUN=$2; shift 2 ;;
    --session) SESSION=$2; F_SESSION=$2; shift 2 ;;
    --window)  WINDOW=$2; F_WINDOW=$2; shift 2 ;;
    --dir)     DIR=$2; shift 2 ;;
    --file)    FILE=$2; shift 2 ;;
    --reason)  REASON=$2; shift 2 ;;
    --summary) SUMMARY=$2; shift 2 ;;
    --loop)    LOOP=$2; shift 2 ;;
    -h|--help) sed -n '2,95p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) usage_fail "unknown arg $1" ;;
  esac
done

mkdir -p "$QUEUE_DIR" "$DONE_DIR" 2>/dev/null \
  || { echo "pulse-surface-queue: cannot create $QUEUE_DIR" >&2; emit_result failed; exit 1; }

# A row name is a filename here, so it is sanitized rather than trusted. The slug is
# also the collapse key: same row -> same file -> newest wins.
slug_of() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# ---------------------------------------------------------------------------
# stage
# ---------------------------------------------------------------------------
if [ "$CMD" = stage ]; then
  [ -n "$ROW" ]  || usage_fail "stage: --row is required"
  [ -n "$FILE" ] || usage_fail "stage: --file is required"
  SESSION=${SESSION:-work}
  WINDOW=${WINDOW:-di}
  target="$QUEUE_DIR/$(slug_of "$ROW").json"
  now=$(date -u +%FT%TZ)

  exec 8>>"$LOCK"
  flock -w 10 8 || warn "stage: could not take the queue lock in 10s — proceeding (a lost collapse is better than a lost surface)"

  first="$now"; sup=0
  if [ -f "$target" ]; then
    _f=$(jq -r '.first_staged_at // .staged_at // empty' "$target" 2>/dev/null)
    [ -n "$_f" ] && first="$_f"
    _s=$(jq -r '.superseded // 0' "$target" 2>/dev/null)
    case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
    sup=$(( _s + 1 ))
  fi

  tmp="$target.tmp.$$"
  if ! jq -n \
      --arg row "$ROW" --arg run "$RUN" --arg session "$SESSION" --arg window "$WINDOW" \
      --arg dir "$DIR" --arg file "$FILE" --arg reason "$REASON" --arg summary "$SUMMARY" \
      --arg staged "$now" --arg first "$first" --argjson sup "$sup" \
      '{row:$row, run:$run, session:$session, window:$window, dir:$dir, file:$file,
        reason:$reason, summary:$summary, staged_at:$staged, first_staged_at:$first,
        superseded:$sup}' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; flock -u 8
    warn "stage: could not write $tmp"
    emit_result failed; exit 1
  fi
  mv -f "$tmp" "$target" || { rm -f "$tmp"; flock -u 8; warn "stage: could not install $target"; emit_result failed; exit 1; }
  flock -u 8

  if [ "$sup" -gt 0 ]; then
    say "surface staged for row=$ROW (collapsed onto $sup older staging(s) — the newest wins): $target"
  else
    say "surface staged for row=$ROW: $target"
  fi
  emit_result staged
  exit 0
fi

# ---------------------------------------------------------------------------
# Shared reader: pending entries, oldest first, optionally filtered.
# Prints "<first_staged_at>\t<path>" lines; the sort key is an ISO-8601-Z stamp, so
# lexicographic sort IS chronological sort.
# ---------------------------------------------------------------------------
pending_lines() {
  local f k s w
  for f in "$QUEUE_DIR"/*.json; do
    [ -f "$f" ] || continue
    s=$(jq -r '.session // "work"' "$f" 2>/dev/null) || continue
    w=$(jq -r '.window  // "di"'   "$f" 2>/dev/null) || continue
    [ -n "$F_SESSION" ] && [ "$F_SESSION" != "$s" ] && continue
    [ -n "$F_WINDOW"  ] && [ "$F_WINDOW"  != "$w" ] && continue
    k=$(jq -r '.first_staged_at // .staged_at // "0"' "$f" 2>/dev/null)
    printf '%s\t%s\n' "${k:-0}" "$f"
  done | sort
}

# ---------------------------------------------------------------------------
# list — read-only, for evidence and for a human looking at a stuck queue.
# ---------------------------------------------------------------------------
if [ "$CMD" = list ]; then
  n=0
  while IFS=$'\t' read -r _k f; do
    [ -n "${f:-}" ] || continue
    jq -c --arg p "$f" '. + {_path:$p}' "$f" 2>/dev/null && n=$((n+1))
  done < <(pending_lines)
  if [ "$n" -eq 0 ]; then emit_result empty; else emit_result "pending:$n"; fi
  exit 0
fi

[ "$CMD" = drain ] || usage_fail "unknown subcommand '$CMD' (stage | drain | list)"

# ---------------------------------------------------------------------------
# drain
# ---------------------------------------------------------------------------
exec 8>>"$LOCK"
flock -w 10 8 || { warn "drain: could not take the queue lock in 10s — another drain is running; leaving the queue alone"; emit_result "deferred:0"; exit 0; }

mapfile -t PENDING < <(pending_lines | cut -f2)
if [ "${#PENDING[@]}" -eq 0 ]; then
  flock -u 8
  note "drain: nothing pending"
  emit_result empty
  exit 0
fi

# Group by session|window: the bell is a property of a WINDOW, so all the surfaces
# aimed at one window collapse into ONE injection — a window that gets six separate
# "go look at this" messages is a window Zig learns to ignore.
# NOT named GROUPS: that is a bash BUILT-IN indexed array (the caller's unix groups),
# and `declare -A` on it dies with "cannot convert indexed to associative array" —
# then every read of it is an unbound-variable error under `set -u`. And NOT
# `declare -A X=()` either: an empty compound assignment makes bash treat it as
# indexed. Declare with a distinct name, then fill.
declare -A BY_TARGET
for f in "${PENDING[@]}"; do
  s=$(jq -r '.session // "work"' "$f" 2>/dev/null); w=$(jq -r '.window // "di"' "$f" 2>/dev/null)
  key="${s}|${w}"
  BY_TARGET["$key"]="${BY_TARGET[$key]:-}${f}"$'\n'
done

DELIVERED=0
STILL=0

for key in "${!BY_TARGET[@]}"; do
  s="${key%%|*}"; w="${key##*|}"
  mapfile -t GF < <(printf '%s' "${BY_TARGET[$key]}" | grep -v '^$')
  n=${#GF[@]}
  [ "$n" -gt 0 ] || continue

  # Per-entry facts, oldest first. The FIRST entry's fields are kept separately
  # because the single-surface wording below is not a truncation of the multi one —
  # it is a different sentence, and it still has to carry the collapse note.
  files=""; rows=""; dir=""
  one_row=""; one_run=""; one_rsn=""; one_sum=""; one_sf=""; one_sup=0
  i=0
  for f in "${GF[@]}"; do
    i=$((i+1))
    _row=$(jq -r '.row // "?"' "$f" 2>/dev/null)
    _run=$(jq -r '.run // "?"' "$f" 2>/dev/null)
    _rsn=$(jq -r '.reason // "?"' "$f" 2>/dev/null)
    _sum=$(jq -r '.summary // ""' "$f" 2>/dev/null)
    _sf=$(jq -r '.file // ""' "$f" 2>/dev/null)
    _dir=$(jq -r '.dir // ""' "$f" 2>/dev/null)
    _sup=$(jq -r '.superseded // 0' "$f" 2>/dev/null)
    _at=$(jq -r '.first_staged_at // .staged_at // ""' "$f" 2>/dev/null)
    [ -n "$dir" ] || dir="$_dir"
    _extra=""
    [ "${_sup:-0}" != 0 ] && _extra=" [it re-ran ${_sup}x while held — this is the NEWEST]"
    rows="${rows}${rows:+ | }($i) $_row · $_rsn · staged $_at${_sum:+ · $_sum}${_extra} · surface: $_sf${_dir:+ · ledger: $_dir/refs/pulse-ledger.jsonl}"
    files="${files}${files:+, }$_sf"
    if [ "$i" -eq 1 ]; then
      one_row="$_row"; one_run="$_run"; one_rsn="$_rsn"; one_sum="$_sum"; one_sf="$_sf"; one_sup="${_sup:-0}"
    fi
  done

  # ONE line. A newline inside send-keys -l submits the composer, so everything the
  # local session needs has to ride on a single line.
  if [ "$n" -eq 1 ]; then
    _collapse=""
    [ "$one_sup" != 0 ] && _collapse=" This row re-ran ${one_sup}x while the announcement was held — what follows is the NEWEST run; the superseded ones are not announced."
    cmd="REMOTE PULSE SURFACE (row=$one_row, run=$one_run, reason=$one_rsn): a pulse tick that ran on marketing-vps has FINISHED and Zig has to see it.${one_sum:+ What landed: $one_sum.}$_collapse Read $one_sf and raise the AskUserQuestion it describes (this is the 🔔 the remote box cannot ring) — say what landed, WHERE it is, and the obvious next step, even if nothing needs a decision. File any bead it names that the remote side did not already file and push, and land the ledger row at ${dir:-<project>}/refs/pulse-ledger.jsonl. Do NOT re-run the tick."
  else
    cmd="REMOTE PULSE SURFACE ($n PENDING, oldest first): $n pulse ticks finished while this window was blocked on you, and their announcements were HELD — none of them was re-run, only the announcement was retried. Oldest first: $rows. Read those surface files in that order and raise ONE AskUserQuestion covering all $n (this is the 🔔 the remote box cannot ring) — for each: what landed, WHERE it is, and the obvious next step, even where nothing needs a decision. File any bead they name that the remote side did not already file and push, and land any ledger rows at ${dir:-<project>}/refs/pulse-ledger.jsonl. Do NOT re-run any tick."
  fi

  if [ ! -x "$INJECT" ]; then
    warn "drain: $INJECT is not executable — $n surface(s) for $s:$w stay pending"
    STILL=$(( STILL + n )); continue
  fi

  out=$("$INJECT" ${dir:+--dir "$dir"} --session "$s" --window "$w" \
        ${LOOP:+--loop "$LOOP"} --cmd "$cmd" 2>&1)
  printf '%s\n' "$out" | sed 's/^/    inject: /'
  verdict=$(printf '%s\n' "$out" | grep -o 'PULSE_INJECT_RESULT=[a-z-]*' | tail -1 | cut -d= -f2)

  if [ "${verdict:-}" = injected ]; then
    # Mark delivered only AFTER the injector confirms. The move is what makes
    # "nothing announces twice" true; it happens per entry so a partial failure
    # leaves the rest pending rather than losing them.
    for f in "${GF[@]}"; do
      dest="$DONE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$f")"
      if jq -c --arg at "$(date -u +%FT%TZ)" '. + {delivered_at:$at}' "$f" > "$dest.tmp" 2>/dev/null; then
        mv -f "$dest.tmp" "$dest" 2>/dev/null
        rm -f "$f"
      else
        rm -f "$dest.tmp"
        mv -f "$f" "$dest" 2>/dev/null || rm -f "$f"
      fi
    done
    DELIVERED=$(( DELIVERED + n ))
    say "surfaced: $n pending announcement(s) delivered to $s:$w"
  else
    STILL=$(( STILL + n ))
    warn "surface NOT delivered: PULSE_INJECT_RESULT=${verdict:-<none>}. $n announcement(s) for $s:$w stay PENDING in $QUEUE_DIR \
and will be redelivered on the next drain (pulse-retry.timer, every 2 min, or the next surface into that window). \
The tick is NOT re-run — only the announcement is retried."
  fi
done

# Trim the audit trail. Newest kept; oldest dropped. Best-effort — a failed trim
# must never look like a failed delivery.
_dn=$(find "$DONE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "${_dn:-0}" -gt "$DONE_KEEP" ]; then
  find "$DONE_DIR" -maxdepth 1 -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | head -n "$(( _dn - DONE_KEEP ))" | cut -d' ' -f2- \
    | while IFS= read -r old; do rm -f "$old"; done
  note "delivered-surfaces trimmed to the newest $DONE_KEEP (was $_dn)"
fi

flock -u 8

if   [ "$DELIVERED" -gt 0 ] && [ "$STILL" -gt 0 ]; then emit_result "partial:$DELIVERED:$STILL"
elif [ "$DELIVERED" -gt 0 ];                       then emit_result "delivered:$DELIVERED"
elif [ "$STILL"     -gt 0 ];                       then emit_result "deferred:$STILL"
else                                                    emit_result empty
fi
exit 0
