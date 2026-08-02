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
# DEFERRAL IS NOT FAILURE (dotfiles-tqjk) ----------------------------------- #
# Both push functions return 3 (DEFERRED) when they lose the `flock -w 10` race —
# i.e. a CONCURRENT run holds the lock and is doing this tier's work right now.
# That is a benign no-op, not a human-blocking condition, and it happens by
# construction: the hourly timer and the pulse-dispatch local-push step are both
# scheduled on the hour. Until this bead, a deferral was classified DEGRADED /
# exit 10 / ledger `blocked`, and harnessd's newest-row tie-break (which prefers
# `blocked` over `done` at an identical ts) rendered the loop "parked on you"
# while the winning run had just pushed everything. A backup alarm that cries
# wolf is how the next REAL outage gets ignored — so the alarm is RE-AIMED here,
# not weakened:
#   deferred + FRESH success stamp (< N hours)  -> exit 0, verdict "OK (deferred)",
#       ledger outcome "quiet". The summary still reads `<tier>=deferred`, so the
#       log never claims a push that did not happen.
#   deferred + stamp >= N hours old             -> unchanged: STALE, exit 2x,
#       outcome "blocked". This backstop is what makes the above safe — a
#       permanently wedged lock still reddens the unit within N hours.
#   deferred + NO stamp at all (never succeeded here) -> DEGRADED, exit 1x,
#       outcome "blocked" (conservative; matches the no-stamp rule below).
# FAILED (1) and BLOCKED (2) are untouched by all of this.
#
# EXIT CODES ---------------------------------------------------------------- #
#   0   healthy — every bootstrapped tier reached the remote, had nothing to do,
#       or deferred to a concurrent run while its success stamp is still fresh
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
# The coreutils-flavour shim (dotfiles-5vz2) — `stat -c %Y` below is GNU-only.
if [ -r "$HERE/../hooks/lib/portable.sh" ]; then
  # shellcheck source=/dev/null
  . "$HERE/../hooks/lib/portable.sh"
fi
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

# SCRUB-AND-CONTINUE VISIBILITY (dotfiles-t6sd) ------------------------------ #
# The Layer-1 secret gate no longer halts the push: a secret in vault-bound
# content is redacted in place and the run continues (scrub-continue.sh). That
# makes a redaction a NORMAL event — and it means the gate is no longer the thing
# that tells anyone a credential reached disk. The only remaining signal is what
# this script emits, so it emits three, at three different distances:
#   - the REDACTION LEDGER ($VAULT_REDACTION_LEDGER) — one durable JSONL row per
#     event, naming tier / action / path / pattern names + counts (never the
#     secret). This is the forensic record.
#   - the VERDICT LINE — a `scrub=<action counts>` term, so the log line and the
#     `systemctl status` line for a run that redacted something do not read
#     identically to a clean run.
#   - the JOURNAL PRIORITY — a healthy run that redacted is logged at NOTICE
#     rather than INFO, so `journalctl -p notice -t vault-sync` lists exactly the
#     runs where a credential was scrubbed. It stays exit 0 and the unit stays
#     green, because by policy that run behaved correctly.
REDACTION_LEDGER="${VAULT_REDACTION_LEDGER:-$HOME/.claude/vault-redactions.jsonl}"
export VAULT_REDACTION_LEDGER="$REDACTION_LEDGER"
# `[ -f ]` guard rather than 2>/dev/null: the "No such file" here would come from
# the SHELL's redirection, which 2>/dev/null on wc does not suppress anyway.
redl_lines() { [ -f "$REDACTION_LEDGER" ] && wc -l < "$REDACTION_LEDGER" || echo 0; }
redl_before=$(redl_lines)

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

# 1a. Secondary boxes only: make the freshly-pulled content actually USABLE.
#     Both steps below exist because a git checkout is not a faithful mirror —
#     it reproduces content but not identity or time.
if [ -f "$VDIR/.peer" ]; then
  # (i) ALIAS every canonical slug into this box's local naming.
  #
  #     Claude Code looks up a project's history by a slug derived from $PWD, so
  #     on a box whose unix user is not the primary's it looks for
  #     -home-<user>-foo while the vault holds -home-ubuntu-foo. session-start.sh
  #     creates that symlink, but only for the project a session is STARTING in —
  #     which is too late to browse history you have not opened yet, and useless
  #     for the far more common "is my old work here?" question. Measured
  #     2026-07-28: 91 canonical slugs, 13 aliases, so 78 projects were fully
  #     present on disk and completely invisible (Zig hit this on
  #     ~/linearb/pipeline-website). Doing it here, after every pull, means a slug
  #     the primary invents shows up on its own.
  _canon_prefix="-home-ubuntu"
  _local_prefix="$(printf '%s' "$HOME" | sed 's#/#-#g')"
  if [ "$_local_prefix" != "$_canon_prefix" ]; then
    _aliased=0
    for _d in "$WT/$_canon_prefix" "$WT/$_canon_prefix"-*; do
      [ -d "$_d" ] || continue
      _b=$(basename "$_d"); _a="$WT/$_local_prefix${_b#$_canon_prefix}"
      # Never replace a real directory: that would be un-synced local history.
      [ -e "$_a" ] || [ -L "$_a" ] || { ln -s "./$_b" "$_a" && _aliased=$((_aliased+1)); }
    done
    [ "$_aliased" -gt 0 ] && echo "  aliased $_aliased new slug(s) into $_local_prefix-*"
  fi
  unset _canon_prefix _local_prefix _aliased _d _b _a

  # (ii) RESTORE mtimes. git does not carry them, so every pulled transcript is
  #      stamped "now" and the whole back catalogue collapses to "1 day ago",
  #      destroying recency order. The real time is inside the file. --since
  #      bounds the work to what this pull just touched; the initial backfill is
  #      a manual full run.
  if [ -x "$HERE/restore-mtimes.py" ]; then
    "$HERE/restore-mtimes.py" --since 180 --quiet || true
  fi
fi

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
  # NOT `stat -c %Y` (dotfiles-5vz2): BSD stat has no -c, so on macOS this
  # returned 1 for a stamp that EXISTS — "no stamp, never succeeded here" —
  # which is exactly the branch that suppresses the STALE escalation. The
  # staleness backstop was inert on this machine.
  mtime=$(_p_mtime "$f") || return 1
  now=$(date +%s)
  echo $(( (now - mtime) / 3600 ))
}

# Does this tier's status count AGAINST the run? (see "DEFERRAL IS NOT FAILURE")
# $1 = tier name, $2 = status code. Exit 0 = bad, 1 = fine.
tier_is_bad() {
  local tier="$1" rc="$2" age
  tier_counts "$rc" || return 1                # INERT: nothing to back up here
  [ "$rc" -eq 0 ] && return 1                  # OK
  if [ "$rc" -eq 3 ]; then
    # DEFERRED — another run holds the lock and is pushing this tier as we speak.
    # Benign ONLY while this tier has a recent recorded success; a stamp that is
    # missing or >= STALE_HOURS old means the deferral is not clearing, and the
    # normal escalation below (which re-reads the same stamp) must still fire.
    age=$(stamp_age_hours "$tier") && [ "$age" -lt "$STALE_HOURS" ] && return 1
  fi
  return 0
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
tier_is_bad memory      "$mem_rc" && mem_bad=1
tier_is_bad transcripts "$tra_rc" && tra_bad=1

# A deferral that did NOT count as bad still has to be visible: it changes the
# verdict word and the ledger outcome, so a benign-looking green run is never
# mistaken for "both tiers pushed".
any_deferred=0
{ [ "$mem_rc" -eq 3 ] || [ "$tra_rc" -eq 3 ]; } && any_deferred=1

any_stale=0
for pair in "memory:$mem_bad" "transcripts:$tra_bad"; do
  tier="${pair%%:*}"; bad="${pair##*:}"
  [ "$bad" -eq 1 ] || continue
  if age=$(stamp_age_hours "$tier") && [ "$age" -ge "$STALE_HOURS" ]; then
    any_stale=1
    stale_detail="$stale_detail no successful $tier push in ${age}h (>=${STALE_HOURS}h);"
  fi
done

# 3b. Scrub activity this run = the rows scrub-continue.sh appended while the two
#     pushes ran. Summarised by action ("redacted=2 deferred-live=1") so the term
#     says WHAT happened, not just that something did.
redl_after=$(redl_lines)
scrub_new=$(( redl_after - redl_before ))
[ "$scrub_new" -lt 0 ] && scrub_new=0          # ledger was trimmed mid-run
scrub_term=""
if [ "$scrub_new" -gt 0 ]; then
  scrub_detail=$(tail -n "$scrub_new" "$REDACTION_LEDGER" 2>/dev/null | python3 -c '
import collections, json, sys
c = collections.Counter()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        c[json.loads(line).get("action", "?")] += 1
    except Exception:
        c["unparseable"] += 1
print(" ".join(f"{k}={v}" for k, v in sorted(c.items())))
' 2>/dev/null)
  scrub_term=" scrub=[${scrub_detail:-$scrub_new events}]"
fi

summary="memory=$(status_word "$mem_rc") transcripts=$(status_word "$tra_rc")$scrub_term"
if [ "$mem_bad" -eq 0 ] && [ "$tra_bad" -eq 0 ]; then
  exit_code=0
  if [ "$any_deferred" -eq 1 ]; then
    # "quiet" (an ALLOWED_OUTCOMES value in pulse-ledger-lint) — this run did no
    # work because a concurrent one was doing it. Green, but not "done".
    verdict="OK (deferred — concurrent run holds the lock)"; outcome="quiet"
  else
    verdict="OK"; outcome="done"
  fi
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
  # `scrub` is a plain integer count of this run's redaction-ledger rows — an
  # extra key harnessd's loopHealth projection ignores, but which makes a
  # redacting run mechanically greppable in the sync ledger too.
  printf '{"ts":"%s","row":"%s","outcome":"%s","scrub":%d,"note":"%s (exit %d)"}\n' \
    "$(date -u +%FT%TZ)" "$LEDGER_ROW" "$outcome" "$scrub_new" "$summary" "$exit_code" \
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
  if [ "$exit_code" -ne 0 ]; then
    printf '%s\n' "$final" | systemd-cat -t vault-sync -p err
  elif [ "$scrub_new" -gt 0 ]; then
    # healthy, but a credential was scrubbed out on the way through. NOTICE, not
    # ERR: the unit stays green because the run did the right thing — but
    # `journalctl -p notice -t vault-sync` lists exactly these runs, so the event
    # is never invisible just because it stopped being fatal.
    printf '%s\n' "$final" | systemd-cat -t vault-sync -p notice
  else
    printf '%s\n' "$final" | systemd-cat -t vault-sync -p info
  fi
fi
exit "$exit_code"
