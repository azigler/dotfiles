#!/usr/bin/env bash
# pico-backup-pull.sh — the KEEP pulls pico's un-backed-up state off pico's disk.
#
#   bash agents/scheduler/pico-backup-pull.sh
#
# WHY THIS EXISTS (dotfiles-1x4g, from the 2026-08-09 works audit). `tmutil
# destinationinfo` on pico answers **No destinations configured**. There is no
# Time Machine, no off-box copy of anything, and the one backup job pico DOES
# run — the nightly vacation_station pg dump — writes to pico's own disk. A dump
# that shares its source's failure domain is restore-from-corruption, not
# disaster recovery. If that SSD dies, the fleet loses ~/.secrets, the ONLY
# agentgateway config.yaml, the gateway's attribution history, and every dump
# that was supposed to protect the database.
#
# WHY A PULL AND NOT A PUSH (orchestrator decision, 2026-08-09, standing
# authority). The keep already holds a working, authenticated ssh channel to
# pico — vs14d-backup-health.timer and gateway-host-update.timer both ride it.
# Pulling over that channel adds ZERO new trust surface and no new hardware. The
# direction matters: **pico never gets push access to the keep.** A host that
# can write into its own backups can also destroy them, and pico is the host
# whose compromise this backup exists to survive. Alternatives considered and
# rejected: a Time Machine disk (new hardware, and it lives in the same room as
# the thing it protects), and a pico-side push (inverts the trust and hands the
# untrusted end a write path into the archive).
#
# ---------------------------------------------------------------------------
# WHAT IS PULLED — and what is DELIBERATELY NOT
# ---------------------------------------------------------------------------
# Pulled (see DATASETS below):
#   secrets              ~/.secrets                          — 6 creds, mode 600
#   agentgateway-config  ~/.config/agentgateway/config.yaml  — the ONLY copy of
#                        fleet routing; the keep is a pure client
#   gojamming-config     ~/gojamming/config.json             — webmention token
#   sites-harness        ~/sites/harness                     — the PWA bundle
#   vacation-station     ~/backups/vacation-station          — the pg dumps,
#                        7 hardlinked generations (see RETENTION)
#   requests-db          ~/.local/share/agentgateway/requests.db (SNAPSHOTTED)
#
# requests.db is a HOT sqlite database under live fleet write traffic, so it is
# never copied byte-for-byte off the live file — an rsync of a WAL-mode sqlite
# mid-write yields a torn database that restores to garbage. It is snapshotted
# on pico first, with sqlite's own online-backup API:
#
#     sqlite3 "file:$DB?mode=ro" ".timeout 20000" ".backup $TMP/requests.db"
#
# and the SNAPSHOT is what gets pulled. That was measured before it was adopted,
# on the live 245 MB database on 2026-08-09: **0.41 s wall**, and
# `pragma integrity_check` on the result answered `ok`. Free space on pico at the
# time: 710 GiB. So it is cheap, it is safe, and the "accepted gap" escape hatch
# the task allowed for is not needed. The snapshot is removed from pico at the
# end of every run, success or failure.
#
# NOT pulled, on purpose:
#
#   colima volumes  — the keycloak realm, grafana/loki/prometheus, the RomM DB
#     and the ss14 replays all live inside colima's VM disk. That is one large
#     opaque qcow-ish image; copying it whole is both huge and useless (a
#     crash-consistent copy of a running VM's disk is not a restorable database).
#     Each volume needs its own consistent-export decision — pg_dump for the
#     RomM DB, a realm export for keycloak, a snapshot API for the TSDBs. That
#     is a per-volume design task, NOT a line in this script. FILE A BEAD; do
#     not extend DATASETS with a raw volume path.
#
#   ~/romd-data — RomM + MariaDB on disk, same shape as the colima volumes: a
#     live MariaDB datadir copied file-by-file is a torn database. It needs
#     `mysqldump` (or a stopped container), which means touching a running
#     service. Same call: FILE A BEAD, per-service, not here.
#
#   ~/picod — named in the audit's loss set, and it is NOT ON PICO. Verified
#     2026-08-09: `ls -ld /Users/pico/picod` -> No such file or directory. The
#     real ~/picod is on the KEEP and has an origin at
#     github.com/azigler/picod, so it was never un-backed-up state. The audit
#     line was a mis-transcription. `~/sites/harness` — a real pico-side entry
#     from the same loss line — is pulled in its place.
#
#   pico's LaunchAgents (~/Library/LaunchAgents/com.zig.*.plist) — the whole job
#     definition set, small, and genuinely un-backed-up. Out of scope for THIS
#     bead; noted here so the next reader does not think it was overlooked.
#
# ---------------------------------------------------------------------------
# RETENTION, and why it is not uniform
# ---------------------------------------------------------------------------
# Configs get a SINGLE CURRENT COPY. A stale copy of ~/.secrets or config.yaml
# is worse than no copy — it restores an identity that has since been rotated.
#
# vacation-station gets 7 DAILY GENERATIONS, hardlinked with rsync's
# --link-dest, because the failure mode it protects against is different:
# corruption that the nightly dump faithfully captures. A single mirrored copy
# would happily mirror the corruption. Seven generations cost almost nothing —
# unchanged dumps are hardlinks into yesterday's tree, not copies.
#
# PERMISSIONS. Everything under the destination is secret-bearing, so rsync is
# given --chmod=D700,F600 and the destination root is 700. --chmod (rather than
# a post-hoc chmod -R) is deliberate: --link-dest only hardlinks when the
# attributes match, so setting the mode at transfer time is what keeps the
# generations cheap.
#
# ---------------------------------------------------------------------------
# OUTCOME CONTRACT (the fleet pattern — see vs14d/bin/backup-health.sh)
# ---------------------------------------------------------------------------
# The last line is always
#
#     PICO_BACKUP_PULL_RESULT=<ok|degraded|unreachable>
#
# Exit codes: 0 ok · 10 a real finding (degraded/unreachable) · anything else,
# THIS SCRIPT is broken. The unit deliberately does NOT list 10 in
# SuccessExitStatus, so a backup that did not happen shows up in
# `systemctl --user --failed` rather than scrolling past in a journal. Every run
# also appends one JSON line to
# ~/.local/share/fleet-health/pico-backup.jsonl, because the keep's user journal
# holds roughly six hours (dotfiles-9h8n) and a verdict that rotates away before
# anyone reads it buys nothing.
#
# "IT RAN" IS NOT "IT WORKED". rsync exits 0 for a great many empty outcomes, so
# every dataset is verified AFTER the pull, against the source:
#   * the local file COUNT and BYTE TOTAL must equal what pico reported, and the
#     count must be >= 1 — an rsync that transferred nothing cannot read as ok;
#   * up to two sampled files per dataset are SHA256-compared end to end.
# Those two checks are the ones the mutation harness attacks
# (mutate-pico-backup-pull.sh, M1 and M2). A remote dataset that is missing or
# empty is a finding AND the pull is skipped, so a wiped source can never
# propagate over a good archive.
#
# SEAMS (used by test-pico-backup-pull.sh; all optional in production):
#   PICO_BACKUP_HOST          ssh target                       (default: pico)
#   PICO_BACKUP_SSH           remote-exec command, fed a script on stdin
#                             (default: ssh -o BatchMode=yes … $HOST)
#   PICO_BACKUP_REMOTE_PREFIX rsync source prefix     (default: "$HOST:";
#                             set to "" for a local fixture)
#   PICO_BACKUP_REMOTE_HOME   remote $HOME            (default: probed)
#   PICO_BACKUP_RSYNC         rsync binary                     (default: rsync)
#   PICO_BACKUP_RSH           rsync's -e transport (ignored when the prefix is
#                             empty, i.e. under test)
#   PICO_BACKUP_DEST          archive root       (default: ~/backups/pico-pull)
#   PICO_BACKUP_LEDGER        verdict ledger path
#   PICO_BACKUP_GENERATIONS   generations kept for the generational sets (7)

set -uo pipefail

HOST=${PICO_BACKUP_HOST:-pico}
# SetEnv=LANG=C: ssh forwards the keep's LANG=C.UTF-8, macOS does not have that
# locale, and every remote round trip then prints eight lines of `perl: warning:
# Setting locale failed` onto stderr. Measured on the first live run — harmless,
# but it buries the real output in the journal, and noise that is always there is
# noise nobody reads past.
# shellcheck disable=SC2016  # $HOST is meant to expand here, in the default
SSH_CMD=${PICO_BACKUP_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=20 -o SetEnv=LANG=C $HOST}
REMOTE_PREFIX=${PICO_BACKUP_REMOTE_PREFIX-$HOST:}
RSYNC_BIN=${PICO_BACKUP_RSYNC:-rsync}
# rsync spawns its OWN ssh, so the locale fix above has to be repeated here or
# six of the eight warning blocks come back.
RSH=${PICO_BACKUP_RSH:-ssh -o BatchMode=yes -o ConnectTimeout=20 -o SetEnv=LANG=C}
DEST_ROOT=${PICO_BACKUP_DEST:-$HOME/backups/pico-pull}
LEDGER=${PICO_BACKUP_LEDGER:-$HOME/.local/share/fleet-health/pico-backup.jsonl}
GENERATIONS=${PICO_BACKUP_GENERATIONS:-7}

# key|kind|retention|path-relative-to-remote-$HOME
#   kind:      file | dir | sqlite      retention: current | generational
DATASETS=(
  "secrets|file|current|.secrets"
  "agentgateway-config|file|current|.config/agentgateway/config.yaml"
  "gojamming-config|file|current|gojamming/config.json"
  "sites-harness|dir|current|sites/harness"
  "vacation-station|dir|generational|backups/vacation-station"
  "requests-db|sqlite|current|.local/share/agentgateway/requests.db"
)

START_TS=$(date -u +%s)
GEN=$(date -u +%Y-%m-%d)
VERDICT="unreachable"
FINDINGS=()
STATUS_PAIRS=()
TOTAL_BYTES=0
REMOTE_SNAPDIR=""

say() { printf '%s\n' "$*"; }
note_finding() { FINDINGS+=("$1"); say "  ! $1"; }

# One string arg, executed as a shell script on the remote. Fed on STDIN rather
# than as argv so nothing has to survive a second round of shell quoting —
# that quoting is where remote-probe scripts go to die.
remote_script() {
  # shellcheck disable=SC2086  # SSH_CMD is a command line and must word-split
  printf '%s' "$1" | $SSH_CMD 'bash -s'
}

lsum() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# "<file-count> <byte-total>" for a directory tree. `-exec … +` (not xargs) on
# purpose: BSD xargs will run the utility once with NO arguments on empty input,
# and `wc -c` with no arguments blocks on stdin forever.
tree_stat() {
  # read-only measurement, no state change  # allow-suppress
  find "$1" -type f -exec wc -c {} + 2>/dev/null |
    awk '$2!="total"{n++; b+=$1} END{printf "%d %d\n", n+0, b+0}'
}

# shellcheck disable=SC2317  # both are reached from the EXIT trap
json_escape() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# shellcheck disable=SC2317
write_ledger() {
  local dir ts dur pairs first f
  dir=$(dirname "$LEDGER")
  mkdir -p "$dir" && chmod 700 "$dir"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dur=$(( $(date -u +%s) - START_TS ))
  pairs=""; first=1
  for f in ${STATUS_PAIRS+"${STATUS_PAIRS[@]}"}; do
    [ "$first" -eq 1 ] || pairs="$pairs,"
    first=0
    pairs="$pairs\"${f%%=*}\":\"${f#*=}\""
  done
  local flist="" ffirst=1
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$ffirst" -eq 1 ] || flist="$flist,"
    ffirst=0
    flist="$flist\"$(json_escape "$f")\""
  done
  printf '{"ts":"%s","host":"%s","verdict":"%s","generation":"%s","duration_s":%d,"bytes":%d,"datasets":{%s},"findings":[%s]}\n' \
    "$ts" "$HOST" "$VERDICT" "$GEN" "$dur" "$TOTAL_BYTES" "$pairs" "$flist" >>"$LEDGER"
  chmod 600 "$LEDGER"
}

# shellcheck disable=SC2317  # invoked via trap
finish() {
  local rc=$?
  if [ -n "$REMOTE_SNAPDIR" ]; then
    remote_script "rm -rf -- '$REMOTE_SNAPDIR'" >/dev/null || \
      say "  ! could not remove the snapshot dir $REMOTE_SNAPDIR on $HOST"
    REMOTE_SNAPDIR=""
  fi
  write_ledger
  printf 'PICO_BACKUP_PULL_RESULT=%s\n' "$VERDICT"
  case "$VERDICT" in
    ok) exit 0 ;;
    degraded | unreachable) exit 10 ;;
    *) exit $((rc == 0 ? 1 : rc)) ;;
  esac
}
trap finish EXIT

umask 077
mkdir -p "$DEST_ROOT" || { say "cannot create $DEST_ROOT"; VERDICT="broken"; exit 1; }
chmod 700 "$DEST_ROOT"

say "pico backup pull — $HOST -> $DEST_ROOT  (generation $GEN)"

# --- reach the host -------------------------------------------------------
REMOTE_HOME=${PICO_BACKUP_REMOTE_HOME:-}
if [ -z "$REMOTE_HOME" ]; then
  # shellcheck disable=SC2016  # $HOME must expand on PICO, not here
  REMOTE_HOME=$(remote_script 'printf %s "$HOME"') || REMOTE_HOME=""
fi
if [ -z "$REMOTE_HOME" ]; then
  say "  cannot reach $HOST — the state is unprotected, which is not the same"
  say "  as it being safe."
  note_finding "unreachable: $HOST"
  VERDICT="unreachable"
  exit 10
fi
say "  remote home: $REMOTE_HOME"

# --- one round trip: snapshot the hot sqlite, then measure every dataset ----
SPECS=""
SNAP_REL=""
for d in "${DATASETS[@]}"; do
  IFS='|' read -r k kind _ rel <<<"$d"
  SPECS="$SPECS $k|$kind|$rel"
  [ "$kind" = "sqlite" ] && SNAP_REL="$rel"
done

# RHOME is injected rather than read as $HOME on the far side. In production the
# two are identical (RHOME was probed FROM the remote's $HOME); under test the
# seam runs the probe on THIS box, where $HOME is the keep's — and a probe that
# silently measured /home/ubuntu/.secrets instead of the fixture's would report
# a green pull of the wrong machine's secrets. Caught exactly that way, first run.
PROBE_SCRIPT="SPECS='${SPECS# }'
SNAP_REL='$SNAP_REL'
RHOME='$REMOTE_HOME'
$(cat <<'EOS'
set -u
sumf() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
tstat() {
  find "$1" -type f -exec wc -c {} + 2>/dev/null |
    awk '$2!="total"{n++; b+=$1} END{printf "%d %d\n", n+0, b+0}'
}

SNAPDIR=""
if [ -n "$SNAP_REL" ] && [ -f "$RHOME/$SNAP_REL" ]; then
  SNAPDIR=$(mktemp -d "${TMPDIR:-/tmp}/pico-backup-pull.XXXXXX") || SNAPDIR=""
  if [ -n "$SNAPDIR" ]; then
    if ! sqlite3 "file:$RHOME/$SNAP_REL?mode=ro" ".timeout 20000" \
        ".backup $SNAPDIR/$(basename "$SNAP_REL")" >&2; then
      rm -rf -- "$SNAPDIR"; SNAPDIR=""
    fi
  fi
fi
printf 'SNAPDIR %s\n' "$SNAPDIR"

for spec in $SPECS; do
  key=${spec%%|*}; r=${spec#*|}; kind=${r%%|*}; rel=${r#*|}
  if [ "$kind" = sqlite ]; then
    if [ -n "$SNAPDIR" ]; then p="$SNAPDIR/$(basename "$rel")"; else p=""; fi
  else
    p="$RHOME/$rel"
  fi
  if [ -z "$p" ] || [ ! -e "$p" ]; then
    printf 'DS %s 0 0 0 %s\n' "$key" "${p:-<no-snapshot>}"
    continue
  fi
  printf 'PATH %s %s\n' "$key" "$p"
  if [ -d "$p" ]; then
    ts=$(tstat "$p")
    printf 'DS %s 1 %s\n' "$key" "$ts"
    LIST=$(find "$p" -type f | LC_ALL=C sort)
    if [ -n "$LIST" ]; then
      f1=$(printf '%s\n' "$LIST" | head -1)
      f2=$(printf '%s\n' "$LIST" | tail -1)
      printf 'SAMPLE %s %s %s\n' "$key" "$(sumf "$f1")" "${f1#"$p"/}"
      [ "$f1" != "$f2" ] && printf 'SAMPLE %s %s %s\n' "$key" "$(sumf "$f2")" "${f2#"$p"/}"
    fi
  else
    printf 'DS %s 1 1 %s\n' "$key" "$(wc -c <"$p" | tr -d ' ')"
    printf 'SAMPLE %s %s %s\n' "$key" "$(sumf "$p")" "$(basename "$p")"
  fi
done
EOS
)"

PROBE=$(remote_script "$PROBE_SCRIPT")
if [ -z "$PROBE" ]; then
  say "  the probe returned nothing — treating $HOST as unreachable."
  note_finding "unreachable: probe on $HOST returned no output"
  VERDICT="unreachable"
  exit 10
fi

REMOTE_SNAPDIR=$(printf '%s\n' "$PROBE" | awk '/^SNAPDIR /{print $2; exit}')

# --- pull + verify, dataset by dataset ------------------------------------
DEGRADED=0
for d in "${DATASETS[@]}"; do
  IFS='|' read -r key kind retention rel <<<"$d"

  read -r _ _ rexists rfiles rbytes _rest <<<"$(printf '%s\n' "$PROBE" | grep -m1 "^DS $key ")"
  rpath=$(printf '%s\n' "$PROBE" | awk -v k="$key" '$1=="PATH" && $2==k {print $3; exit}')

  if [ "${rexists:-0}" != "1" ]; then
    note_finding "$key: absent on $HOST ($REMOTE_HOME/$rel) — nothing pulled"
    STATUS_PAIRS+=("$key=missing"); DEGRADED=1; continue
  fi
  if [ "${rfiles:-0}" -lt 1 ] || [ "${rbytes:-0}" -lt 1 ]; then
    note_finding "$key: source holds $rfiles file(s) / $rbytes byte(s) — refusing to pull an empty set over a good archive"
    STATUS_PAIRS+=("$key=empty-source"); DEGRADED=1; continue
  fi

  # Where this dataset lands. Generational sets get a dated dir hardlinked
  # against the newest previous one.
  LINKDEST=()
  if [ "$retention" = generational ]; then
    LAND="$DEST_ROOT/$key/$GEN"
    prev=$(find "$DEST_ROOT/$key" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
             grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | grep -vx "$GEN" | LC_ALL=C sort | tail -1)
    [ -n "$prev" ] && LINKDEST=(--link-dest="$DEST_ROOT/$key/$prev")
  else
    LAND="$DEST_ROOT/$key"
  fi
  mkdir -p "$LAND"

  if [ "$kind" = dir ]; then
    SRC="$REMOTE_PREFIX$rpath/"
    DEL=(--delete)
  else
    SRC="$REMOTE_PREFIX$rpath"
    DEL=()
  fi

  # -e only when there IS a remote side; on a local fixture copy rsync has no
  # transport to configure.
  RSH_OPT=()
  [ -n "$REMOTE_PREFIX" ] && RSH_OPT=(-e "$RSH")

  RSOUT=$("$RSYNC_BIN" -a --no-o --no-g --chmod=D700,F600 \
            ${RSH_OPT+"${RSH_OPT[@]}"} ${DEL+"${DEL[@]}"} ${LINKDEST+"${LINKDEST[@]}"} \
            "$SRC" "$LAND/" 2>&1)
  RC=$?
  if [ "$RC" -ne 0 ]; then
    note_finding "$key: rsync exited $RC — $(printf '%s' "$RSOUT" | tail -1)"
    STATUS_PAIRS+=("$key=rsync-failed"); DEGRADED=1; continue
  fi

  # --- IT RAN IS NOT IT WORKED (guard 1: nothing silently empty) -----------
  read -r lfiles lbytes <<<"$(tree_stat "$LAND")"
  if [ "${lfiles:-0}" -lt 1 ] || [ "$lfiles" != "$rfiles" ] || [ "$lbytes" != "$rbytes" ]; then
    note_finding "$key: pulled $lfiles file(s)/$lbytes byte(s) but $HOST reported $rfiles/$rbytes — the pull did not land"
    STATUS_PAIRS+=("$key=short-pull"); DEGRADED=1; continue
  fi

  # --- guard 2: the bytes that arrived are the bytes that left -------------
  BAD=0
  while read -r _ skey ssum srel; do
    [ "$skey" = "$key" ] || continue
    [ -n "$srel" ] || continue
    if [ ! -f "$LAND/$srel" ]; then
      note_finding "$key: sampled file '$srel' is missing from the pulled copy"
      BAD=1; continue
    fi
    got=$(lsum "$LAND/$srel")
    if [ "$got" != "$ssum" ]; then
      note_finding "$key: sha256 MISMATCH on '$srel' (pico $ssum, keep $got)"
      BAD=1
    fi
  done <<<"$(printf '%s\n' "$PROBE" | grep "^SAMPLE $key ")"
  if [ "$BAD" -ne 0 ]; then
    STATUS_PAIRS+=("$key=checksum-mismatch"); DEGRADED=1; continue
  fi

  TOTAL_BYTES=$((TOTAL_BYTES + lbytes))
  STATUS_PAIRS+=("$key=ok")
  say "  ok $key -> $LAND  ($lfiles file(s), $lbytes bytes)"

  # --- retention ----------------------------------------------------------
  if [ "$retention" = generational ]; then
    ln -sfn "$LAND" "$DEST_ROOT/$key/current"
    mapfile -t gens < <(find "$DEST_ROOT/$key" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
                          grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | LC_ALL=C sort)
    n=${#gens[@]}
    if [ "$n" -gt "$GENERATIONS" ]; then
      for ((i = 0; i < n - GENERATIONS; i++)); do
        # ${gens[i]:?} — a prune that expands to the archive root would delete
        # every generation it exists to keep.
        rm -rf -- "$DEST_ROOT/${key:?}/${gens[$i]:?}"
        say "     pruned generation ${gens[$i]} (keeping $GENERATIONS)"
      done
    fi
  fi
done

# Everything under here is secret-bearing; the root's mode is the one thing
# rsync's --chmod cannot set.
chmod 700 "$DEST_ROOT"

if [ "$DEGRADED" -ne 0 ]; then
  say "  ${#FINDINGS[@]} finding(s) — pico's state is NOT fully protected."
  VERDICT="degraded"
  exit 10
fi

say "  all ${#DATASETS[@]} datasets pulled and verified."
VERDICT="ok"
exit 0
