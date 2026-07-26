#!/usr/bin/env bash
# vault-sync.sh — bidirectional sync for BOTH claude vaults (the hourly timer's
# entrypoint on both machines). PULLS latest for each vault FIRST — even when the
# machine is idle with no local changes — so a quiet box still receives the other
# machine's updates (the gap the daily push-only timer left). Then pushes local
# changes via the tested, guarded push functions (which also pull-before-push).
# Bounded by timeouts; never clobbers (merge=union on MEMORY.md, delete-guard on
# the peer). spec lin-i2d.1 (P5).
#
# FAILURE PROPAGATION (dotfiles-t6sd) --------------------------------------- #
# This script used to end `vault_push_memory || true; vault_push_transcripts ||
# true` and exit 0 unconditionally. Between 2026-07-21 and 2026-07-26 the
# transcripts push was blocked by the Layer-1 secret gate on 120 CONSECUTIVE
# runs — correctly, there were real secrets staged — and every one of those runs
# reported `status=0/SUCCESS`. Transcript backups were dead for five days and
# `systemctl status` said everything was fine; a human reading the log found it.
# harnessd calls this class of bug the "exit-0 lie".
#
# The fix is three layers, deliberately independent so no single one is the
# whole alarm:
#   1. EXIT STATUS — the unit goes RED when a tier fails, with a code that names
#      WHICH tier, so a memory-only success is never conflated with a
#      both-tiers success. Both tiers are still ATTEMPTED every run; one tier's
#      failure never short-circuits the other. (`set -e` is deliberately NOT
#      used: it would abort the second tier on the first tier's failure — the
#      opposite of what this needs — and turn benign conditions fatal.)
#   2. LEDGER ROW — one JSONL row per run at $VAULT_SYNC_LEDGER, in the shape
#      harnessd's loop-health generator already reads (ts / row / outcome). An
#      outcome of "blocked" renders amber "parked on you" on the dashboard.
#   3. SUCCESS STAMP + STALENESS — per-tier stamp files touched only on a real
#      push. A tier that has not succeeded in >= VAULT_SYNC_STALE_HOURS
#      escalates from "degraded" to "STALE", which is the self-contained
#      backstop if harnessd is down or this loop is missing from its manifest.
#
# EXIT CODES ---------------------------------------------------------------- #
#   0   healthy — every bootstrapped tier reached the remote (or had nothing to do)
#   1x  DEGRADED — at least one tier failed this run
#   2x  STALE    — at least one failing tier has not succeeded in >= N hours
# ...where the units digit names the affected tier(s):
#   x0  transcripts only     x1  memory only     x2  both tiers
# So: 10 = transcripts degraded / memory fine.  21 = memory stale / transcripts
# fine.  A one-line English verdict is printed to the log AND (under systemd)
# logged to the journal, so `systemctl status` shows the reason without anyone
# opening the log file.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VDIR="${VAULT_DIR:-$HOME/.claude/vaults}"
WT="$HOME/.claude/projects"
LEDGER="${VAULT_SYNC_LEDGER:-$HOME/.claude/vault-sync-ledger.jsonl}"
LEDGER_ROW="${VAULT_SYNC_LEDGER_ROW:-vault-sync}"
LEDGER_MAX_LINES="${VAULT_SYNC_LEDGER_MAX_LINES:-10000}"   # ~14 months at hourly

# N — the staleness threshold, in hours. The sync is HOURLY, so N is "how many
# consecutive missed pushes before this stops being a blip and becomes an
# outage." 6 is chosen from both ends:
#   - floor: every plausible transient clears well inside 6 hours — a network
#     blip, a GitHub 5xx, a `gh` token refresh, flock contention with a
#     concurrent session-end push, or a reboot. N=1..3 would fire on those and
#     become an alarm nobody reads, which is how the next outage gets missed.
#   - ceiling: the incident this fixes ran 120 hours undetected. N=6 catches the
#     same failure the same morning; N=24 would still mean a full day of dead
#     backups per incident, i.e. this exact bug at a longer timescale.
# 6h also means Zig sees it within one working session, since sessions are daily.
STALE_HOURS="${VAULT_SYNC_STALE_HOURS:-6}"

echo "== vault-sync $(date -u +%FT%TZ) on $(hostname -s) =="

# 0. Peer only: materialize any slugs newly registered by the dynamic-slug hook.
if [ -f "$VDIR/.peer" ]; then
  for v in memory transcripts; do
    [ -d "$VDIR/$v.git" ] || continue
    timeout 60 git --git-dir="$VDIR/$v.git" --work-tree="$WT" sparse-checkout reapply >/dev/null 2>&1 || true
  done
fi

# 1. Unconditional PULL per vault — an idle machine still syncs DOWN the latest.
#    merge=union (info/attributes) resolves MEMORY.md; a genuine conflict defers
#    (loud) rather than clobbering. A pull failure is NOT a sync failure: the
#    push functions each pull-before-push, so this is an optimization, and an
#    offline pull must not by itself redden the unit.
for v in memory transcripts; do
  gd="$VDIR/$v.git"; [ -d "$gd" ] || continue
  if timeout 120 git --git-dir="$gd" --work-tree="$WT" pull --rebase --autostash -q origin main >/dev/null 2>&1; then
    echo "  $v: pulled latest"
  else
    echo "  $v: pull deferred (offline / conflict — NOT clobbered, resolve manually)"
  fi
done

# --- tier-status helpers ---------------------------------------------------- #
# Codes are the shared contract documented in vault-lib.sh / transcripts-lib.sh:
#   0 OK | 1 FAILED | 2 BLOCKED | 3 DEFERRED | 4 SKIPPED | 9 INERT
status_word() {
  case "$1" in
    0) echo ok ;;
    1) echo failed ;;
    2) echo blocked ;;
    3) echo deferred ;;
    4) echo skipped ;;
    9) echo inert ;;
    *) echo "unknown($1)" ;;
  esac
}

# A tier counts toward the verdict unless it is INERT (vault not bootstrapped on
# this machine — nothing to back up, so nothing to alarm about).
tier_counts() { [ "$1" -ne 9 ]; }

# Age of a tier's success stamp in hours, or empty if there is no stamp. No
# stamp => this tier has never had a recorded success on this machine, so we
# report DEGRADED but never STALE — a fresh install must not scream.
stamp_age_hours() {
  local f="$VDIR/.last-success-$1" mtime now
  [ -f "$f" ] || return 1
  mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
  now=$(date +%s)
  echo $(( (now - mtime) / 3600 ))
}

# 2. PUSH local changes via the tested guarded functions (each pulls-before-push).
#    BOTH tiers are attempted unconditionally — a failure in one must never skip
#    or mask the other. Statuses are captured, not swallowed.
mem_rc=9; tra_rc=9
if [ -f "$HERE/vault-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/vault-lib.sh"
  vault_push_memory
  mem_rc=$?
fi
if [ -f "$HERE/transcripts-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/transcripts-lib.sh"
  vault_push_transcripts
  tra_rc=$?
fi

# 3. Success stamps — touched ONLY on a real push (status 0). A blocked or
#    deferred tier leaves its stamp untouched, which is what ages into STALE.
mkdir -p "$VDIR" 2>/dev/null
for pair in "memory:$mem_rc" "transcripts:$tra_rc"; do
  tier="${pair%%:*}"; rc="${pair##*:}"
  [ "$rc" -eq 0 ] && date -u +%FT%TZ > "$VDIR/.last-success-$tier" 2>/dev/null
done

# 4. Verdict — severity + which tier(s), as documented in the header.
mem_bad=0; tra_bad=0; stale_detail=""
tier_counts "$mem_rc" && [ "$mem_rc" -ne 0 ] && mem_bad=1
tier_counts "$tra_rc" && [ "$tra_rc" -ne 0 ] && tra_bad=1

any_stale=0
for pair in "memory:$mem_bad" "transcripts:$tra_bad"; do
  tier="${pair%%:*}"; bad="${pair##*:}"
  [ "$bad" -eq 1 ] || continue
  if age=$(stamp_age_hours "$tier") && [ "$age" -ge "$STALE_HOURS" ]; then
    any_stale=1
    stale_detail="$stale_detail no successful $tier push in ${age}h (>=${STALE_HOURS}h);"
  fi
done

summary="memory=$(status_word "$mem_rc") transcripts=$(status_word "$tra_rc")"
if [ "$mem_bad" -eq 0 ] && [ "$tra_bad" -eq 0 ]; then
  exit_code=0; verdict="OK"; outcome="done"
else
  # units digit: 0 = transcripts only, 1 = memory only, 2 = both.
  if   [ "$mem_bad" -eq 1 ] && [ "$tra_bad" -eq 1 ]; then unit=2
  elif [ "$mem_bad" -eq 1 ];                          then unit=1
  else                                                     unit=0
  fi
  if [ "$any_stale" -eq 1 ]; then
    exit_code=$((20 + unit)); verdict="STALE —${stale_detail%;}"
  else
    exit_code=$((10 + unit)); verdict="DEGRADED"
  fi
  outcome="blocked"     # harnessd renders "blocked" amber: parked on a human
fi

# 5. Ledger row for harnessd's loop-health generator (ts / row / outcome — the
#    same shape as the pulse ledgers). `note` is human-facing only; harnessd's
#    loopHealth never copies note/bead, so nothing confidential can leak.
if [ -n "$LEDGER" ]; then
  mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
  printf '{"ts":"%s","row":"%s","outcome":"%s","note":"%s (exit %d)"}\n' \
    "$(date -u +%FT%TZ)" "$LEDGER_ROW" "$outcome" "$summary" "$exit_code" \
    >> "$LEDGER" 2>/dev/null
  # bounded growth: trim to the newest half via an atomic rename, so a concurrent
  # harnessd read always sees a complete file.
  lines=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$LEDGER_MAX_LINES" ]; then
    tail -n $((LEDGER_MAX_LINES / 2)) "$LEDGER" > "$LEDGER.tmp" 2>/dev/null \
      && mv -f "$LEDGER.tmp" "$LEDGER" 2>/dev/null
  fi
fi

# 6. The one-line verdict. It goes to stdout (→ the log file) AND, under systemd,
#    to the JOURNAL — because the unit redirects stdout/stderr to a file, so
#    without this `systemctl status` would show a bare exit code and no reason.
#    Only the verdict is journalled: the WARN bodies (which include the secret
#    scanner's per-file report) stay in the log file.
final="== vault-sync $verdict — $summary (exit $exit_code) =="
echo "$final"
if [ -n "${INVOCATION_ID:-}" ] && command -v systemd-cat >/dev/null 2>&1; then
  if [ "$exit_code" -eq 0 ]; then
    printf '%s\n' "$final" | systemd-cat -t vault-sync -p info
  else
    printf '%s\n' "$final" | systemd-cat -t vault-sync -p err
  fi
fi
exit "$exit_code"
