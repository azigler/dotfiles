#!/usr/bin/env bash
# pico-health — the keep tends the works. An LLM-FREE, fail-closed watcher that
# reads pico (the works) from zig-computer (the keep) every 30 minutes.
#
# WHY THIS EXISTS. The works audit of 2026-08-09
# (~/demesne/audits/works-audit-2026-08-09.md) found three `com.zig.*` launchd
# jobs that had failed nightly/weekly for ~two months with ZERO visibility —
# clean exits in a column nobody reads, no crash reports, one of them with a
# zero-byte log — while a KeepAlive PWA on :10000 served a state.json frozen for
# 7 days, indistinguishable from a healthy one. Nothing on the keep read pico's
# launchd exits, its disk, its patch level, its port set or its state freshness.
# **The silence was the defect**, exactly as it was for the postgres backup a
# fortnight earlier (vs14d-jms).
#
# So this is the second copy of that fix's second half, and it is a DELIBERATE
# CLONE of vs14d/bin/backup-health.sh — same outcome contract, same exit codes,
# same unit posture. Read that script before changing this one.
#
# OUTCOME CONTRACT. The last line is always
#
#     PICO_HEALTH_RESULT=<ok|degraded|unreachable|stale>
#
# Exit codes: 0 healthy · 10 a real finding · anything else, THIS CHECKER is
# broken. The unit deliberately does NOT list 10 in SuccessExitStatus, so a
# finding lands in `systemctl --user --failed`, a surface the fleet already
# reads, instead of scrolling past in a journal nobody opens.
#
# The vocabulary stays four-valued, so a broken checker reports `unreachable`
# — "the works cannot be verified", which is what a missing manifest or an empty
# probe actually means — and distinguishes itself by EXIT CODE (1, not 10)
# rather than by inventing a fifth verdict that no consumer parses. Whose fault
# it is lives in the exit code; what is known about pico lives in the verdict.
#
# VERDICT PRECEDENCE: unreachable > degraded > stale > ok. `stale` is reserved
# for "the ONLY thing wrong is that pico's published state has stopped moving" —
# the frozen-PWA shape — so it stays legible instead of being swallowed by every
# other finding. Anything else that is wrong is `degraded`.
#
# DURABILITY. The keep's user journal holds ~6h, so a verdict that lives only in
# the journal is a verdict that rotates away unseen — which buys nothing. Every
# run therefore appends one JSON object to $PICO_HEALTH_LEDGER (default
# ~/.local/share/fleet-health/pico.jsonl) AND prints to stdout (→ the journal).
# If the ledger cannot be written, that is a BROKEN CHECKER, not a healthy host:
# the result line is still printed and the exit code becomes 1, never 0.
#
# READ-ONLY ON PICO, ALWAYS. Every remote command here is a read (`date`, `df`,
# `launchctl list`, `lsof`, `curl`, `softwareupdate -l`). Nothing writes, nothing
# uses sudo. That also bounds what it can SEE: a non-privileged `lsof` shows only
# uid-501 listeners, so root-owned ones (sshd :2222, Screen Sharing, kdc,
# multipassd, tailscaled's serve proxy) are invisible here and are out of the
# manifest's scope by construction. Every `com.zig.*` service runs in the user
# domain, which is the set this is written to watch.
#
# LLM-FREE, like vs14d/bin/backup-health.sh and vs14d/bin/groundskeep-scan.sh.
# Reading five things over one ssh connection needs no model; an agent is
# summoned by the finding, not by the schedule. Deliberately NOT a /pulse row.
#
# Knobs (all env, all with defaults):
#   PICO_HOST              ssh target                        (pico)
#   PICO_SSH               the ssh binary — THE TEST SEAM     (ssh)
#   PICO_CONNECT_TIMEOUT   ssh ConnectTimeout, seconds       (15)
#   PICO_STATE_URL         the published state document      (:10000/data/state.json)
#   PICO_STATE_MAX_AGE_H   freshness budget for it, hours    (24)
#   PICO_DISK_MAX_PCT      root filesystem use ceiling       (85)
#   PICO_UPDATES_MAX       tolerated pending Recommended OS updates (0)
#   PICO_PORTS_MANIFEST    expected-listener manifest        (beside this script)
#   PICO_HEALTH_LEDGER     durable verdict ledger            (~/.local/share/fleet-health/pico.jsonl)
#   PICO_SU_CACHE          softwareupdate cache              (beside the ledger)
#   PICO_SU_MAX_AGE_H      how often to re-ask softwareupdate (20)

set -uo pipefail
export LC_ALL=C # `comm` requires its inputs sorted in the SAME collation it uses

HOST="${PICO_HOST:-pico}"
SSH_BIN="${PICO_SSH:-ssh}"
CONNECT_TIMEOUT="${PICO_CONNECT_TIMEOUT:-15}"
STATE_URL="${PICO_STATE_URL:-http://100.72.47.4:10000/data/state.json}"
STATE_MAX_AGE_H="${PICO_STATE_MAX_AGE_H:-24}"
DISK_MAX_PCT="${PICO_DISK_MAX_PCT:-85}"
UPDATES_MAX="${PICO_UPDATES_MAX:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_MANIFEST="${PICO_PORTS_MANIFEST:-$HERE/pico-ports.manifest}"
LEDGER="${PICO_HEALTH_LEDGER:-$HOME/.local/share/fleet-health/pico.jsonl}"
SU_CACHE="${PICO_SU_CACHE:-$(dirname "$LEDGER")/pico-softwareupdate.cache}"
SU_MAX_AGE_H="${PICO_SU_MAX_AGE_H:-20}"

VERDICT="unreachable" # fail-closed: nothing has been proven yet
CHECKER_BROKEN=0
DEGRADED=0
STALE=0
FINDINGS=()

# Metrics for the ledger. Empty means "not measured" and serialises to null — an
# unreachable host must not record a disk of 0 or a failing-job count of 0.
M_DISK_PCT=""
M_JOBS_FAILING=""
M_STATE_AGE_H=""
M_UPDATES=""
M_PORTS_UNEXPECTED=""
M_PORTS_MISSING=""

say() { printf '%s\n' "$*"; }
note() { printf '  note: %s\n' "$*"; }

# A finding is named on stdout AND carried into the ledger. `degrade` is the
# ordinary class; `stale_finding` is the one condition that gets its own verdict;
# `broken` is this checker admitting the fault is its own.
degrade() {
  printf '  FINDING: %s\n' "$*"
  FINDINGS+=("$*")
  DEGRADED=1
}
stale_finding() {
  printf '  FINDING: %s\n' "$*"
  FINDINGS+=("$*")
  STALE=1
}
broken() {
  printf '  CHECKER BROKEN: %s\n' "$*"
  FINDINGS+=("checker broken: $*")
  CHECKER_BROKEN=1
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
num_or_null() { if [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }

ledger_append() {
  local dir line f first=1
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" || {
    broken "cannot create the ledger directory $dir"
    return
  }
  line='{"ts":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"'
  line="$line"',"host":"'"$(json_escape "$HOST")"'"'
  line="$line"',"verdict":"'"$VERDICT"'"'
  line="$line"',"disk_pct":'"$(num_or_null "$M_DISK_PCT")"
  line="$line"',"jobs_failing":'"$(num_or_null "$M_JOBS_FAILING")"
  line="$line"',"state_age_h":'"$(num_or_null "$M_STATE_AGE_H")"
  line="$line"',"updates_pending":'"$(num_or_null "$M_UPDATES")"
  line="$line"',"ports_unexpected":'"$(num_or_null "$M_PORTS_UNEXPECTED")"
  line="$line"',"ports_missing":'"$(num_or_null "$M_PORTS_MISSING")"
  line="$line"',"findings":['
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$first" -eq 1 ] || line="$line,"
    first=0
    line="$line"'"'"$(json_escape "$f")"'"'
  done
  line="$line"']}'
  printf '%s\n' "$line" >>"$LEDGER" || broken "cannot append to the ledger $LEDGER"
}

finish() {
  rc=$?
  ledger_append
  # The diagnostic goes BEFORE the result line, not after: the contract is that
  # the LAST line is always PICO_HEALTH_RESULT=, and a consumer reading `tail -1`
  # of the merged stream must not get a sentence instead.
  if [ "$CHECKER_BROKEN" -ne 0 ]; then
    printf 'pico-health: THIS CHECKER is broken (see CHECKER BROKEN above). The\n' >&2
    printf '             verdict below is what is KNOWN about %s, not a judgement.\n' "$HOST" >&2
  fi
  printf 'PICO_HEALTH_RESULT=%s\n' "$VERDICT"
  [ "$CHECKER_BROKEN" -ne 0 ] && exit 1
  case "$VERDICT" in
  ok) exit 0 ;;
  degraded | stale | unreachable) exit 10 ;;
  *) exit "$((rc == 0 ? 1 : rc))" ;; # the checker itself lost the plot
  esac
}
trap finish EXIT

# --- is the softwareupdate probe due? --------------------------------------
# `softwareupdate -l` costs ~7s and hits Apple's servers; at 48 runs a day that
# is neither kind nor informative. Ask once per SU_MAX_AGE_H and cache.
SU_DUE=1
NOW_LOCAL=$(date +%s)
if [ -f "$SU_CACHE" ]; then
  SU_CACHED_AT=$(sed -n 's/^# generated_at=//p' "$SU_CACHE" | head -1)
  if [ -n "$SU_CACHED_AT" ] && [ "$(((NOW_LOCAL - SU_CACHED_AT) / 3600))" -lt "$SU_MAX_AGE_H" ]; then
    SU_DUE=0
  fi
fi

# --- one ssh round trip collects everything --------------------------------
# Five probes over five connections would make one flaky link look like five
# separate findings, and would take five times as long. Remote stderr is NOT
# suppressed: it flows through ssh to this script's stderr (the journal), where
# an lsof or curl complaint stays visible without polluting the parsed stdout.
PROBE=$(
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" "$HOST" \
    "STATE_URL='$STATE_URL' SU_DUE=$SU_DUE bash -s" <<'REMOTE'
set -u
printf 'NOW=%s\n' "$(date +%s)"
df -k / | awk 'NR==2 { gsub(/%/, "", $5); printf "DISK_PCT=%s\nDISK_FREE_KB=%s\n", $5, $4 }'
# launchctl list: PID, Status, Label. Status is the LAST EXIT STATUS — the only
# "did it work" signal launchd offers, and the column the two-month failure hid in.
launchctl list | awk '$3 ~ /^com\.zig\./ { printf "JOB\t%s\t%s\t%s\n", $1, $2, $3 }'
# Non-privileged lsof: uid-501 listeners only, by design (see the header).
lsof -nP -iTCP -sTCP:LISTEN | awk 'NR > 1 && $9 != "" { printf "PORT\t%s\t%s\n", $9, $1 }' | sort -u
printf 'STATE_TS=%s\n' "$(curl -s --max-time 8 "$STATE_URL" | sed -n 's/.*"generated_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ "${SU_DUE:-0}" = 1 ]; then
    SU_OUT=$(softwareupdate -l 2>&1)
    printf 'SU_RC=%s\n' "$?"
    printf 'SU_RAN=1\n'
    printf '%s\n' "$SU_OUT" | awk -F'Title: ' '/Recommended: YES/ { split($2, t, ","); printf "SU\t%s\n", t[1] }'
else
    printf 'SU_RAN=0\n'
fi
REMOTE
) || {
  say "pico-health: cannot reach ${HOST} — the works cannot be verified, which"
  say "             is not the same as them being fine."
  VERDICT="unreachable"
  exit 10
}

get() { printf '%s\n' "$PROBE" | sed -n "s/^$1=//p" | head -1; }
rows() { printf '%s\n' "$PROBE" | awk -F'\t' -v k="$1" '$1 == k'; }
lines() { printf '%s' "$1" | grep -c . | tr -d ' '; }

NOW=$(get NOW)
DISK_PCT=$(get DISK_PCT)
DISK_FREE_KB=$(get DISK_FREE_KB)
STATE_TS=$(get STATE_TS)
SU_RAN=$(get SU_RAN)
SU_RC=$(get SU_RC)

say "pico-health — ${HOST} @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A probe that answered but said nothing is a broken checker, not a healthy host.
if [ -z "$NOW" ]; then
  broken "the probe returned no NOW= line — the remote payload did not run"
  exit 1
fi

# --- 1. launchd: the two-month silence -------------------------------------
# A POSITIVE last-exit status is a program that ran and failed. A NEGATIVE one is
# a signal (-15 SIGTERM on restart, -9 SIGKILL), which for a KeepAlive daemon is
# ordinary churn, not a failure. And a job that is UP RIGHT NOW (a real pid) is
# not the shape this was written for: a scheduled job that is DOWN with a
# non-zero exit is exactly the shape that hid for two months. Running jobs with a
# non-zero last exit are printed as notes so a flapper stays visible without
# holding the verdict red forever — the alarm fatigue that kills a watcher.
FAILED_JOBS=$(rows JOB | awk -F'\t' '$3 > 0 && $2 == "-" { print $4 " (exit " $3 ")" }' | sort)
FLAPPING=$(rows JOB | awk -F'\t' '$3 > 0 && $2 != "-" { print $4 " (running, last exit " $3 ")" }' | sort)
M_JOBS_FAILING=$(lines "$FAILED_JOBS")
say "  launchd: $(rows JOB | wc -l | tr -d ' ') com.zig.* jobs, ${M_JOBS_FAILING} failing"
while IFS= read -r j; do
  [ -n "$j" ] && degrade "launchd job failing: $j"
done <<<"$FAILED_JOBS"
while IFS= read -r j; do
  [ -n "$j" ] && note "restarted after a non-zero exit: $j"
done <<<"$FLAPPING"

# --- 2. disk ---------------------------------------------------------------
M_DISK_PCT="$DISK_PCT"
say "  disk: ${DISK_PCT}% used, $((DISK_FREE_KB / 1048576)) GiB free"
if [ -n "$DISK_PCT" ] && [ "$DISK_PCT" -ge "$DISK_MAX_PCT" ]; then
  degrade "root filesystem ${DISK_PCT}% used, at or over the ${DISK_MAX_PCT}% ceiling"
fi

# --- 3. the published state document ---------------------------------------
# The frozen-PWA finding: :10000 served a 7-day-old state.json that looked
# exactly like a fresh one. Until inot repoints this at the keep's harnessd, the
# age of THIS document is the check.
if [ -z "$STATE_TS" ]; then
  degrade "state document at ${STATE_URL} returned nothing parseable (no generated_at)"
else
  # No stderr suppression on `date`: an unparseable timestamp SHOULD say so in
  # the journal, and the empty stdout is what drives the finding below.
  STATE_EPOCH=$(date -u -d "$STATE_TS" +%s)
  if [ -z "$STATE_EPOCH" ]; then
    degrade "state document generated_at is unparseable: ${STATE_TS}"
  else
    M_STATE_AGE_H=$(((NOW - STATE_EPOCH) / 3600))
    say "  state: generated_at ${STATE_TS} (${M_STATE_AGE_H}h old)"
    if [ "$M_STATE_AGE_H" -gt "$STATE_MAX_AGE_H" ]; then
      stale_finding "published state is ${M_STATE_AGE_H}h old, over the ${STATE_MAX_AGE_H}h budget (${STATE_URL})"
    fi
  fi
fi

# --- 4. pending OS updates (daily) -----------------------------------------
# Counted from cache unless due. A probe that RAN and FAILED must never refresh
# the cache: "0 updates" and "could not ask" are the same number and opposite
# facts, and this whole file exists because those two got confused once already.
if [ "$SU_RAN" = "1" ] && [ "${SU_RC:-1}" = "0" ]; then
  mkdir -p "$(dirname "$SU_CACHE")" && {
    printf '# generated_at=%s\n' "$NOW_LOCAL"
    rows SU | awk -F'\t' '{ print $2 }'
  } >"$SU_CACHE.tmp" && mv "$SU_CACHE.tmp" "$SU_CACHE"
elif [ "$SU_RAN" = "1" ]; then
  note "softwareupdate -l failed on ${HOST} (rc=${SU_RC:-?}) — keeping the cached count"
fi
if [ -f "$SU_CACHE" ]; then
  M_UPDATES=$(grep -cv '^#' "$SU_CACHE" | tr -d ' ')
  say "  updates: ${M_UPDATES} recommended pending"
  # If a major-version offer is DELIBERATELY declined (Tahoe, 2026-08), raise
  # PICO_UPDATES_MAX in the unit and say why there. Do not delete the check.
  if [ "$M_UPDATES" -gt "$UPDATES_MAX" ]; then
    degrade "$(printf '%s recommended OS update(s) pending: %s' "$M_UPDATES" "$(grep -v '^#' "$SU_CACHE" | paste -sd';' -)")"
  fi
else
  degrade "no softwareupdate result available — pico's patch level is unknown"
fi

# --- 5. the listener set vs the checked-in manifest ------------------------
# The audit found three listeners nobody had written down (the romd/RomM stack).
# The point of a manifest is that the NEXT one is caught the day it appears,
# without anyone remembering to look. Both directions are findings: an unexpected
# listener is a surface on a firewall-less box, and a missing one is a service
# that is down — including, deliberately, the morning after a reboot.
if [ ! -f "$PORTS_MANIFEST" ]; then
  broken "the expected-ports manifest ${PORTS_MANIFEST} does not exist"
  exit 1
fi
EXPECTED=$(sed 's/#.*//' "$PORTS_MANIFEST" | awk 'NF { print $1 }' | sort -u)
ACTUAL=$(rows PORT | awk -F'\t' '{ print $2 }' | sort -u)
UNEXPECTED=$(comm -13 <(printf '%s\n' "$EXPECTED" | grep -v '^$') <(printf '%s\n' "$ACTUAL" | grep -v '^$'))
MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED" | grep -v '^$') <(printf '%s\n' "$ACTUAL" | grep -v '^$'))
M_PORTS_UNEXPECTED=$(lines "$UNEXPECTED")
M_PORTS_MISSING=$(lines "$MISSING")
say "  ports: $(lines "$ACTUAL") listening, ${M_PORTS_UNEXPECTED} unexpected, ${M_PORTS_MISSING} missing"
if [ "$M_PORTS_UNEXPECTED" -gt 0 ]; then
  degrade "$(printf 'undocumented listener(s): %s' "$(printf '%s' "$UNEXPECTED" | paste -sd' ' -)")"
fi
if [ "$M_PORTS_MISSING" -gt 0 ]; then
  degrade "$(printf 'expected listener(s) GONE: %s' "$(printf '%s' "$MISSING" | paste -sd' ' -)")"
fi

# --- the verdict -----------------------------------------------------------
if [ "$DEGRADED" -ne 0 ]; then
  VERDICT="degraded"
elif [ "$STALE" -ne 0 ]; then
  VERDICT="stale"
else
  VERDICT="ok"
  say "  healthy."
fi
