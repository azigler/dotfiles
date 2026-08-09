#!/bin/bash
# demesne-freeze.sh — freeze/unfreeze runbook for the ~/.claude symlink
# retarget cutover (dotfiles-ocm7, the Scrutiny-L E3/E5 hardening pass on the
# retarget chain: dotfiles-retarget-claude-symlinks-860z ->
# dotfiles-agent-brain-split-ezeu).
#
# WHY THIS EXISTS
# The retarget chain (symlinks -> sync/shell -> systemd units) rewires paths
# that ~30 systemd timers, and several durable pulse sessions (desk, dream —
# hold for DAYS on a snapshotted tier), resolve at runtime. A timer firing
# mid-flip hits half-retargeted paths; a durable session keeps acting on
# rules that moved out from under it. This script IS the freeze window: stop
# the affected timers, snapshot exactly what was running BEFORE touching
# anything, flip, then restore exactly that snapshot.
#
# THE FREEZE SET IS DERIVED, NEVER PREFIX-MATCHED (Scrutiny-L E3)
# A naive "stop every pulse-*.timer" freeze misses non-pulse units that also
# reference retargeted paths — two of them hourly writers
# (claude-vault-sync.timer, lb-granola-commit.timer). So the set is derived
# LIVE, every run:
#   grep -rl -e 'dotfiles/agents' -e '\.agents/agents' \
#        $SYSTEMD_UNIT_DIR/*.service $SYSTEMD_UNIT_DIR/*.timer
#   -> each hit mapped to its OWN .timer unit (a .service with no sibling
#      .timer — e.g. an OnFailure=-only unit — contributes nothing to the
#      freeze; there is nothing to stop)
#   -> PLUS restart-loop-check.timer explicitly, belt-and-suspenders against
#      the grep ever drifting off it (it currently also matches via grep).
#
# BOTH PATH FORMS, AND THE DOT IS ESCAPED (dotfiles-ypbc)
# The kvrl retarget moved the fleet's units from %h/dotfiles/agents to
# %h/.agents/agents. A single-form grep for 'dotfiles/agents' therefore went
# blind to almost the whole fleet — measured 2026-08-09 at the cutover
# unfreeze, 4 raw matches where 31 had been found the day before. Unfreeze was
# unaffected (it restores from the recorded snapshot FILE and never
# re-derives), but the NEXT freeze would have left ~28 timers running through
# a flip window. Both forms are matched now; the old one stays for stragglers
# (two units still reference it). The `\.` is escaped deliberately — an
# unescaped dot is grep's any-char and would also match e.g. 'xagents/agents'.
# Verified 2026-08-09 against the live fleet, post-kvrl and post-fix: 38 raw
# file matches -> 32 distinct .timer units (`status` prints both every run),
# and that 32 is byte-identical to the derived-set FILE recorded by the last
# pre-kvrl freeze — i.e. the fix restores exactly the set that was frozen,
# nothing added, nothing lost. (Pre-kvrl, 2026-08-08, the same derivation read
# 31 raw -> 28; broken post-kvrl, 2026-08-09, it read 4 raw -> 2.)
#
# E5 — THE ORCHESTRATOR RUNNING THIS IS ITSELF PRE-FLIP
# The session invoking `freeze` / the flip / `unfreeze` is loaded from the
# CURRENT (pre-flip) ~/.claude symlink tier — CLAUDE.md, skills, hooks — the
# same "snapshot with no invalidation" staleness agents/AGENTS.md documents
# for its own always-loaded tier. It will not see the flip either. The
# runbook is:
#   1. demesne-freeze.sh freeze
#   2. run the retarget (860z's symlink flip + n3b6's sync/shell re-point)
#   3. /clear the orchestrator's OWN session — and any durable window (desk,
#      dream, …) whose stale-snapshot lag is not explicitly accepted in
#      writing — so it reloads the POST-flip tier before acting on it again
#   4. demesne-freeze.sh unfreeze
#   5. demesne-freeze.sh status  — confirm the restored set matches the
#      snapshot before calling the window closed
#
# VERBS
#   freeze [--force]   Stop the derived set. Snapshots
#                       `systemctl --user list-unit-files --type=timer`
#                       to a state file BEFORE stopping anything. Refuses
#                       (blocked-inflight) if any ~/*/refs/*ledger*.jsonl
#                       looks younger than the quiescence window — a tick
#                       may be mid-flight — unless --force.
#   unfreeze            Restores EXACTLY the recorded snapshot's enabled-set
#                       — read from the FILE, never recomputed, never from
#                       memory or prose — and re-starts what was running.
#   status               Read-only. Frozen-or-not, plus the (freshly
#                       re-derived) affected set vs the last recorded
#                       snapshot.
#
# Every terminal path prints exactly one DEMESNE_FREEZE_RESULT=<verdict> as
# the LAST stdout line (daemon-skill verdict discipline — a caller greps the
# last line, never parses prose):
#   freeze:   frozen | blocked-inflight | failed-<reason>
#   unfreeze: unfrozen | failed-<reason>
#   status:   status-frozen | status-unfrozen
#
# TEST SEAMS (mirrors test-pulse-retry.sh / test-pulse-ledger-watch.sh — a
# PATH-prepended fake `systemctl`, plus HARNESS_STATE_DIR):
#   SYSTEMD_UNIT_DIR          — override for ~/.config/systemd/user
#   HARNESS_STATE_DIR         — override for ~/.local/state/harness (the
#                               snapshot + derived-set + marker files live
#                               under here)
#   DEMESNE_LEDGER_ROOT       — override for the ~/*/refs/*ledger*.jsonl glob
#                               root (default $HOME)
#   DEMESNE_QUIESCENT_SECONDS — override the "a few minutes" quiescence
#                               window (default 300)
#   PATH-prepended fake `systemctl` — SYSTEMCTL_BIN resolves via
#                               `command -v systemctl`, so a fixture bin dir
#                               ahead of it on PATH replaces the real binary.
#                               No real timer is ever touched by the tests.

set -uo pipefail

UNIT_DIR="${SYSTEMD_UNIT_DIR:-$HOME/.config/systemd/user}"
STATE_DIR="${HARNESS_STATE_DIR:-$HOME/.local/state/harness}"
LEDGER_ROOT="${DEMESNE_LEDGER_ROOT:-$HOME}"
QUIESCENT_SECONDS="${DEMESNE_QUIESCENT_SECONDS:-300}"

SNAPSHOT_FILE="$STATE_DIR/demesne-freeze-snapshot.txt"
DERIVED_FILE="$STATE_DIR/demesne-freeze-derived.txt"
MARKER_FILE="$STATE_DIR/demesne-freeze-active"

SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null)
[ -x "${SYSTEMCTL_BIN:-}" ] || SYSTEMCTL_BIN=/usr/bin/systemctl

info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- derivation --------------------------------------------------------

# derive_set UNIT_DIR — prints the freeze-target .timer units, one per line,
# sorted + deduped. NEVER prefix-matched: grep for the retargeted path
# reference, map each hit to its sibling .timer (a .service with no sibling
# .timer contributes nothing — there is no timer to stop), plus the explicit
# restart-loop-check.timer floor.
derive_set() {
  local dir="$1"
  local -A timers=()
  local f base timer
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base=$(basename -- "$f")
      case "$base" in
        *.timer) timer="$base" ;;
        *.service) timer="${base%.service}.timer" ;;
        *) continue ;;
      esac
      [ -e "$dir/$timer" ] && timers["$timer"]=1
    done < <(grep -rl -e 'dotfiles/agents' -e '\.agents/agents' "$dir"/*.service "$dir"/*.timer 2>/dev/null)
    [ -e "$dir/restart-loop-check.timer" ] && timers["restart-loop-check.timer"]=1
  fi
  if [ "${#timers[@]}" -gt 0 ]; then
    printf '%s\n' "${!timers[@]}" | sort
  fi
  return 0
}

# raw_match_count UNIT_DIR — informational only (NOT the freeze target
# itself): the number of .service/.timer files the grep matched, for the
# ~31-unit sanity number `status` prints alongside the derived set.
raw_match_count() {
  local dir="$1" n
  if [ -d "$dir" ]; then
    n=$(grep -rl -e 'dotfiles/agents' -e '\.agents/agents' "$dir"/*.service "$dir"/*.timer 2>/dev/null | wc -l)
  else
    n=0
  fi
  printf '%s' "${n// /}"
  return 0
}

# --- ledger quiescence ---------------------------------------------------

# ledger_inflight_report ROOT SECONDS — prints "<file> <age>s" for every
# ~/*/refs/*ledger*.jsonl newer than SECONDS old. Empty output = quiescent.
ledger_inflight_report() {
  local root="$1" threshold="$2"
  local now f mtime age
  now=$(date +%s)
  shopt -s nullglob
  local files=("$root"/*/refs/*ledger*.jsonl)
  shopt -u nullglob
  for f in "${files[@]}"; do
    mtime=$(stat -c '%Y' "$f" 2>/dev/null) || continue
    age=$((now - mtime))
    if [ "$age" -lt "$threshold" ]; then
      printf '%s %ss\n' "$f" "$age"
    fi
  done
  return 0
}

# --- freeze --------------------------------------------------------------

cmd_freeze() {
  local force=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *)
        warn "ERROR: unknown freeze option: $a"
        info "DEMESNE_FREEZE_RESULT=failed-badarg"
        return 1
        ;;
    esac
  done

  if ! mkdir -p "$STATE_DIR"; then
    warn "ERROR: cannot create state dir $STATE_DIR"
    info "DEMESNE_FREEZE_RESULT=failed-statedir"
    return 1
  fi

  local derived count
  derived=$(derive_set "$UNIT_DIR")
  if [ -z "$derived" ]; then
    warn "ERROR: derived freeze set is EMPTY — refusing (is SYSTEMD_UNIT_DIR right? $UNIT_DIR)"
    info "DEMESNE_FREEZE_RESULT=failed-empty-derivation"
    return 1
  fi
  count=$(printf '%s\n' "$derived" | grep -c .)
  info "derived freeze set: $count timer unit(s) under $UNIT_DIR"
  info "$derived"

  local inflight
  inflight=$(ledger_inflight_report "$LEDGER_ROOT" "$QUIESCENT_SECONDS")
  if [ -n "$inflight" ] && [ "$force" -ne 1 ]; then
    warn "BLOCKED: pulse ledger(s) look mid-tick (younger than ${QUIESCENT_SECONDS}s) — pass --force to override:"
    warn "$inflight"
    info "DEMESNE_FREEZE_RESULT=blocked-inflight"
    return 1
  fi
  if [ -n "$inflight" ]; then
    warn "WARNING: --force set; proceeding despite in-flight ledger(s):"
    warn "$inflight"
  fi

  # Snapshot BEFORE stopping anything — atomic write, refuse to freeze if
  # the snapshot itself is not trustworthy.
  local snap_tmp
  snap_tmp="$SNAPSHOT_FILE.tmp.$$"
  if ! "$SYSTEMCTL_BIN" --user list-unit-files --type=timer --no-legend > "$snap_tmp"; then
    rm -f "$snap_tmp"
    warn "ERROR: systemctl list-unit-files failed — refusing to freeze without a snapshot"
    info "DEMESNE_FREEZE_RESULT=failed-snapshot"
    return 1
  fi
  if [ ! -s "$snap_tmp" ]; then
    rm -f "$snap_tmp"
    warn "ERROR: snapshot came back empty — refusing to freeze"
    info "DEMESNE_FREEZE_RESULT=failed-snapshot"
    return 1
  fi
  mv -f "$snap_tmp" "$SNAPSHOT_FILE"
  printf '%s\n' "$derived" > "$DERIVED_FILE"

  local failed=() u st
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if ! "$SYSTEMCTL_BIN" --user stop "$u"; then
      failed+=("$u")
    fi
  done <<< "$derived"

  # Verify: every derived unit must actually be inactive now — a `stop`
  # exit code of 0 is not proof (silent-success is exactly the failure mode
  # this repo's guidance warns about).
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    st=$("$SYSTEMCTL_BIN" --user is-active "$u" 2>/dev/null)
    if [ "$st" = "active" ]; then
      failed+=("$u")
    fi
  done <<< "$derived"

  if [ "${#failed[@]}" -gt 0 ]; then
    local joined
    joined=$(printf '%s,' "${failed[@]}")
    joined="${joined%,}"
    warn "ERROR: failed to stop/verify: ${failed[*]}"
    info "DEMESNE_FREEZE_RESULT=failed-stop:$joined"
    return 1
  fi

  date -u +%FT%TZ > "$MARKER_FILE"
  info "froze $count timer unit(s); snapshot recorded at $SNAPSHOT_FILE"
  info "DEMESNE_FREEZE_RESULT=frozen"
  return 0
}

# --- unfreeze --------------------------------------------------------------

cmd_unfreeze() {
  if [ ! -f "$SNAPSHOT_FILE" ] || [ ! -f "$DERIVED_FILE" ]; then
    warn "ERROR: no snapshot found ($SNAPSHOT_FILE / $DERIVED_FILE) — nothing to restore"
    info "DEMESNE_FREEZE_RESULT=failed-no-snapshot"
    return 1
  fi

  local derived
  derived=$(cat "$DERIVED_FILE")
  if [ -z "$derived" ]; then
    warn "ERROR: recorded derived set ($DERIVED_FILE) is empty"
    info "DEMESNE_FREEZE_RESULT=failed-empty-derived-file"
    return 1
  fi

  local missing=() failed=() u state
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    state=$(awk -v unit="$u" '$1==unit{print $2; exit}' "$SNAPSHOT_FILE")
    if [ -z "$state" ]; then
      missing+=("$u")
      continue
    fi
    if [ "$state" = "enabled" ]; then
      if ! "$SYSTEMCTL_BIN" --user start "$u"; then
        failed+=("$u")
      fi
    fi
  done <<< "$derived"

  if [ "${#missing[@]}" -gt 0 ]; then
    local mjoined
    mjoined=$(printf '%s,' "${missing[@]}")
    mjoined="${mjoined%,}"
    warn "ERROR: derived-set unit(s) with NO snapshot entry — cannot restore EXACTLY, refusing to guess: ${missing[*]}"
    info "DEMESNE_FREEZE_RESULT=failed-missing-snapshot-entry:$mjoined"
    return 1
  fi

  # Verify: every unit recorded 'enabled' at snapshot time is active now;
  # a `start` exit code of 0 is not proof.
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    state=$(awk -v unit="$u" '$1==unit{print $2; exit}' "$SNAPSHOT_FILE")
    local now_active
    now_active=$("$SYSTEMCTL_BIN" --user is-active "$u" 2>/dev/null)
    if [ "$state" = "enabled" ] && [ "$now_active" != "active" ]; then
      failed+=("$u")
    fi
  done <<< "$derived"

  if [ "${#failed[@]}" -gt 0 ]; then
    local fjoined
    fjoined=$(printf '%s,' "${failed[@]}")
    fjoined="${fjoined%,}"
    warn "ERROR: failed to restore/verify: ${failed[*]}"
    info "DEMESNE_FREEZE_RESULT=failed-restore:$fjoined"
    return 1
  fi

  rm -f "$MARKER_FILE"
  info "restored $(printf '%s\n' "$derived" | grep -c .) timer unit(s) from $SNAPSHOT_FILE"
  info "DEMESNE_FREEZE_RESULT=unfrozen"
  return 0
}

# --- status --------------------------------------------------------------

cmd_status() {
  local derived raw dcount
  derived=$(derive_set "$UNIT_DIR")
  raw=$(raw_match_count "$UNIT_DIR")
  dcount=0
  [ -n "$derived" ] && dcount=$(printf '%s\n' "$derived" | grep -c .)

  info "unit dir:           $UNIT_DIR"
  info "raw grep matches:   $raw file(s)"
  info "derived timer set:  $dcount unit(s)"
  if [ -n "$derived" ]; then
    info "$derived"
  fi

  local frozen=0
  [ -f "$MARKER_FILE" ] && frozen=1
  if [ "$frozen" -eq 1 ]; then
    info "frozen: yes (since $(cat "$MARKER_FILE" 2>/dev/null))"
  else
    info "frozen: no"
  fi

  if [ -f "$DERIVED_FILE" ]; then
    info "--- vs last snapshot ($SNAPSHOT_FILE) ---"
    local added removed
    added=$(comm -23 <(printf '%s\n' "$derived") <(sort "$DERIVED_FILE"))
    removed=$(comm -13 <(printf '%s\n' "$derived") <(sort "$DERIVED_FILE"))
    if [ -n "$added" ]; then
      info "added since snapshot:"
      info "$added"
    fi
    if [ -n "$removed" ]; then
      info "removed since snapshot (were frozen, no longer derived):"
      info "$removed"
    fi
    if [ -z "$added" ] && [ -z "$removed" ]; then
      info "derived set matches the last recorded snapshot exactly"
    fi
  else
    info "no snapshot on record yet"
  fi

  if [ "$frozen" -eq 1 ]; then
    info "DEMESNE_FREEZE_RESULT=status-frozen"
  else
    info "DEMESNE_FREEZE_RESULT=status-unfrozen"
  fi
  return 0
}

# --- main --------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage: demesne-freeze.sh <freeze|unfreeze|status> [--force]

  freeze [--force]   stop the derived set (snapshotting first); refuses if
                     a pulse ledger looks mid-tick unless --force
  unfreeze            restore exactly the recorded snapshot's enabled-set
  status               read-only: frozen-or-not + derived set vs snapshot
EOF
}

main() {
  local verb="${1:-}"
  case "$verb" in
    freeze) shift; cmd_freeze "$@" ;;
    unfreeze) shift; cmd_unfreeze "$@" ;;
    status) shift; cmd_status "$@" ;;
    -h|--help) usage; return 0 ;;
    "") usage; return 1 ;;
    *)
      warn "ERROR: unknown verb: $verb"
      usage
      return 1
      ;;
  esac
}

main "$@"
exit $?
