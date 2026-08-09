#!/usr/bin/env bash
# Test for pico-health.sh — the keep's fail-closed watcher on the works.
#
# HERMETIC. Nothing here touches pico, the network, or the real ledger. The seam
# is $PICO_SSH: the checker's ONE ssh round trip is replaced by a stub that cats
# a canned probe fixture and records its argv, so every branch of the checker is
# driven from a file. (vs14d/test/test_backup_health.sh builds its fixtures on
# the real host over real ssh; that suite SKIPs when pico is down, which is
# precisely when a watcher's suite most needs to run. Hence the stub.)
#
# EVERY CASE DRIVES A NON-ok OUTCOME except 1, 3, 4, 18, 21 and 26. The only
# interesting property of a health check is that it can FAIL, and this one was
# written after three launchd jobs failed for two months behind a green-looking
# box. Cases 3, 4 and 21 are the converse discipline: a watcher that cries wolf
# at ordinary KeepAlive churn, or at a VM that restarted, gets ignored — and an
# ignored watcher is the same silence in a louder costume.
#
# MEASURED mutant -> failing cases (2026-08-09; re-measure if you change a case,
# and do not write this map from memory):
#
#   M1  the launchd failing-job filter made vacuous       -> 2 12 14
#   M2  the ssh-failure path reports ok                   -> 11
#   M3  the unexpected-listener diff ignored              -> 8 22 24
#   M4  the state-age comparison made unreachable         -> 6 12
#   M5  the ledger append dropped                         -> 14 15
#   M6  the dynamic entry's process name dropped          -> 22
#   M7  the softwareupdate cache's build check made vacuous -> 25
#   M8  the dynamic entry's ephemeral-range check widened -> 24
#
# That map is EXECUTABLE, not a comment: mutate-pico-health.sh applies all eight
# and asserts each dies on exactly the cases named here. tools/githooks/pre-commit
# runs both.
#
# Convention matches the other agents/scheduler suites: executable bash, non-zero
# exit = failure, PASS/FAIL summary on the last line.

set -uo pipefail
export LC_ALL=C

CHECKER="$(cd "$(dirname "$0")" && pwd)/pico-health.sh"
REAL_MANIFEST="$(cd "$(dirname "$0")" && pwd)/pico-ports.manifest"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-pico-health.XXXXXX")
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  chmod -R u+rwx "$WORK" # case 15 makes a directory read-only on purpose
  rm -rf "$WORK"
}
trap cleanup EXIT

TAB=$'\t'

# --- the ssh stub: THE SEAM ------------------------------------------------
# Cats $PICO_PROBE_FIXTURE and records the argv it was called with, so a case can
# assert on what the checker ASKED for (case 18's SU_DUE) as well as on what it
# did with the answer.
cat >"$WORK/ssh-stub" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PICO_STUB_ARGV"
cat "$PICO_PROBE_FIXTURE"
EOS
chmod +x "$WORK/ssh-stub"

# Fails the way a real unreachable host does: a diagnostic on stderr, rc 255.
cat >"$WORK/ssh-dead" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PICO_STUB_ARGV"
printf 'ssh: connect to host pico port 2222: Operation timed out\n' >&2
exit 255
EOS
chmod +x "$WORK/ssh-dead"

# Answers, but says nothing — the "it ran, so it must be fine" shape.
cat >"$WORK/ssh-empty" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PICO_STUB_ARGV"
EOS
chmod +x "$WORK/ssh-empty"

# --- a small, self-contained expected-ports manifest -----------------------
# Deliberately NOT the checked-in one: a fixture derived from the file under test
# makes the port cases tautological. The real manifest gets its own case (20).
cat >"$WORK/ports.manifest" <<'EOM'
# fixture manifest
*:14829            # go-jamming
100.72.47.4:8080   # nginx
127.0.0.1:21848    # romd cappedproxy
127.0.0.1:dynamic limactl   # the un-pinnable one (cases 21-24)
EOM

PORTS_OK="PORT${TAB}*:14829${TAB}go-jammin
PORT${TAB}100.72.47.4:8080${TAB}nginx
PORT${TAB}127.0.0.1:21848${TAB}cappedpro
PORT${TAB}127.0.0.1:52001${TAB}limactl"

JOBS_OK="JOB${TAB}-${TAB}0${TAB}com.zig.ss14-backup
JOB${TAB}84195${TAB}0${TAB}com.zig.agentgateway"

JOBS_FAILING="$JOBS_OK
JOB${TAB}-${TAB}128${TAB}com.zig.vs14-guidebook-build
JOB${TAB}-${TAB}1${TAB}com.zig.vs14-cookbook-build
JOB${TAB}-${TAB}1${TAB}com.zig.vs14-map-render"

# --- fixture builder -------------------------------------------------------
reset_fix() {
  FIX_NOW=$(date +%s)
  FIX_DISK=3
  FIX_FREE=744392460
  FIX_STATE=$(date -u -d '@'"$((FIX_NOW - 600))" +%Y-%m-%dT%H:%M:%SZ)
  FIX_JOBS="$JOBS_OK"
  FIX_PORTS="$PORTS_OK"
  FIX_SURAN=1
  FIX_SURC=0
  FIX_SU=""
  FIX_BUILD=25G76
}

mkfix() { # mkfix <path>
  {
    printf 'NOW=%s\n' "$FIX_NOW"
    [ -n "$FIX_BUILD" ] && printf 'OS_BUILD=%s\n' "$FIX_BUILD"
    printf 'DISK_PCT=%s\n' "$FIX_DISK"
    printf 'DISK_FREE_KB=%s\n' "$FIX_FREE"
    [ -n "$FIX_JOBS" ] && printf '%s\n' "$FIX_JOBS"
    [ -n "$FIX_PORTS" ] && printf '%s\n' "$FIX_PORTS"
    printf 'STATE_TS=%s\n' "$FIX_STATE"
    [ "$FIX_SURAN" = 1 ] && printf 'SU_RC=%s\n' "$FIX_SURC"
    printf 'SU_RAN=%s\n' "$FIX_SURAN"
    [ -n "$FIX_SU" ] && printf '%s\n' "$FIX_SU"
  } >"$1"
}

# --- the runner ------------------------------------------------------------
# Each run gets its own ledger, SU cache and argv log unless the caller pins
# them, so cases cannot leak into each other.
CASE_N=0
run() { # run [stub]  -> $OUT, $RC, $VERDICT_LINE, $LEDGER, $ARGV
  local stub="${1:-$WORK/ssh-stub}"
  CASE_N=$((CASE_N + 1))
  RUNDIR="$WORK/run$CASE_N"
  mkdir -p "$RUNDIR"
  LEDGER="${PIN_LEDGER:-$RUNDIR/pico.jsonl}"
  ARGV="${PIN_ARGV:-$RUNDIR/argv}"
  SUCACHE="${PIN_SUCACHE:-$RUNDIR/su.cache}"
  OUT=$(
    PICO_SSH="$stub" \
      PICO_PROBE_FIXTURE="$FIXTURE" \
      PICO_STUB_ARGV="$ARGV" \
      PICO_HEALTH_LEDGER="$LEDGER" \
      PICO_SU_CACHE="$SUCACHE" \
      PICO_PORTS_MANIFEST="${PIN_MANIFEST:-$WORK/ports.manifest}" \
      PICO_HOST=pico-test \
      bash "$CHECKER" 2>&1
  )
  RC=$?
  VERDICT_LINE=$(printf '%s\n' "$OUT" | tail -1)
  VERDICT=${VERDICT_LINE#PICO_HEALTH_RESULT=}
}

expect() { # expect <n> <label> <verdict> <rc>
  local n=$1 label=$2 want_v=$3 want_rc=$4
  if [ "$VERDICT" = "$want_v" ] && [ "$RC" -eq "$want_rc" ]; then
    ok "$n $label"
  else
    bad "$n $label" "expected verdict=$want_v rc=$want_rc, got verdict=${VERDICT:-<none>} rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
  fi
}

FIXTURE="$WORK/probe"
unset PIN_LEDGER PIN_ARGV PIN_SUCACHE PIN_MANIFEST

echo "=== pico-health.sh ========================================================"

# --- 1 -----------------------------------------------------------------------
reset_fix
mkfix "$FIXTURE"
run
expect 1 "a healthy works is ok, exit 0" ok 0

# --- 2 -- THE CASE THIS FILE EXISTS FOR --------------------------------------
# Three com.zig.* jobs, down, with positive exits. Two months of exactly this.
reset_fix
FIX_JOBS="$JOBS_FAILING"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: launchd job failing: com.zig.vs14-guidebook-build (exit 128)' &&
  printf '%s' "$OUT" | grep -q 'FINDING: launchd job failing: com.zig.vs14-cookbook-build (exit 1)' &&
  printf '%s' "$OUT" | grep -q 'FINDING: launchd job failing: com.zig.vs14-map-render (exit 1)'; then
  ok "2 three failing launchd jobs -> degraded, each NAMED with its exit code"
else
  bad "2 three failing launchd jobs are named" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 3 -----------------------------------------------------------------------
# A KeepAlive daemon SIGTERMed on restart shows -15. Treating that as a failure
# makes the checker permanently red, which is how a watcher gets ignored.
reset_fix
FIX_JOBS="$JOBS_OK
JOB${TAB}49929${TAB}-15${TAB}com.zig.gojamming
JOB${TAB}39331${TAB}-9${TAB}com.zig.romd-cappedproxy"
mkfix "$FIXTURE"
run
expect 3 "signal-terminated daemons (-15 / -9) are churn, not findings" ok 0

# --- 4 -----------------------------------------------------------------------
# The live shape of com.zig.vs14-web: UP now, last exit 1. Visible as a note,
# but it does not hold the verdict red.
reset_fix
FIX_JOBS="$JOBS_OK
JOB${TAB}59141${TAB}1${TAB}com.zig.vs14-web"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = ok ] && [ "$RC" -eq 0 ] &&
  printf '%s' "$OUT" | grep -q 'note: restarted after a non-zero exit: com.zig.vs14-web'; then
  ok "4 a RUNNING job with a non-zero last exit is a note, not a finding"
else
  bad "4 running job with non-zero last exit is a note" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 5 -----------------------------------------------------------------------
reset_fix
FIX_DISK=91
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] && printf '%s' "$OUT" | grep -q 'FINDING: root filesystem 91% used'; then
  ok "5 disk over the ceiling -> degraded"
else
  bad "5 disk over the ceiling" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 6 -- the frozen PWA -----------------------------------------------------
# The audit's most dangerous state: a document that looks exactly like a fresh
# one and has not moved in a week. `stale` is its own verdict so it stays legible.
reset_fix
FIX_STATE=$(date -u -d '@'"$((FIX_NOW - 167 * 3600))" +%Y-%m-%dT%H:%M:%SZ)
mkfix "$FIXTURE"
run
if [ "$VERDICT" = stale ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: published state is 167h old'; then
  ok "6 a 7-day-frozen state document -> stale (its OWN verdict), exit 10"
else
  bad "6 frozen state document -> stale" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 7 -----------------------------------------------------------------------
reset_fix
FIX_STATE=""
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] && printf '%s' "$OUT" | grep -q 'FINDING: state document.*nothing parseable'; then
  ok "7 a state endpoint that answers with nothing parseable -> degraded"
else
  bad "7 unparseable state endpoint" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 8 -- the NEXT undocumented listener -------------------------------------
reset_fix
FIX_PORTS="$PORTS_OK
PORT${TAB}*:31337${TAB}mystery"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: undocumented listener(s): \*:31337'; then
  ok "8 a listener absent from the manifest -> degraded, NAMED"
else
  bad "8 undocumented listener is caught" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 9 -----------------------------------------------------------------------
reset_fix
FIX_PORTS="PORT${TAB}*:14829${TAB}go-jammin
PORT${TAB}127.0.0.1:21848${TAB}cappedpro
PORT${TAB}127.0.0.1:52001${TAB}limactl"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: expected listener(s) GONE: 100.72.47.4:8080'; then
  ok "9 an expected listener that has vanished -> degraded, NAMED"
else
  bad "9 vanished listener is caught" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 10 ----------------------------------------------------------------------
reset_fix
FIX_SU="SU${TAB}macOS Sonoma 14.8.9
SU${TAB}macOS Tahoe 26.6.1"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: 2 recommended OS update(s) pending: macOS Sonoma 14.8.9;macOS Tahoe 26.6.1'; then
  ok "10 pending recommended OS updates -> degraded, each NAMED"
else
  bad "10 pending OS updates are caught" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 11 -- unverifiable is NOT fine ------------------------------------------
reset_fix
mkfix "$FIXTURE"
run "$WORK/ssh-dead"
if [ "$VERDICT" = unreachable ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'is not the same as them being fine'; then
  ok "11 an unreachable works -> unreachable, exit 10 (never ok)"
else
  bad "11 unreachable host" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 12 -- precedence --------------------------------------------------------
reset_fix
FIX_JOBS="$JOBS_FAILING"
FIX_STATE=$(date -u -d '@'"$((FIX_NOW - 167 * 3600))" +%Y-%m-%dT%H:%M:%SZ)
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: published state is 167h old' &&
  printf '%s' "$OUT" | grep -q 'FINDING: launchd job failing'; then
  ok "12 degraded outranks stale, and the stale finding is still NAMED"
else
  bad "12 degraded outranks stale" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 13 -- the outcome contract ----------------------------------------------
reset_fix
mkfix "$FIXTURE"
run
if printf '%s\n' "$OUT" | tail -1 | grep -qE '^PICO_HEALTH_RESULT=(ok|degraded|unreachable|stale)$'; then
  ok "13 the LAST line is the four-valued outcome contract, nothing else"
else
  bad "13 last line is the outcome contract" "last=[$(printf '%s\n' "$OUT" | tail -1)]"
fi

# --- 14 -- durability --------------------------------------------------------
# A verdict that only reaches a 6h journal rotates away unseen. One JSON object
# per run, APPENDED — a ledger that truncates is a ledger with one row.
reset_fix
FIX_JOBS="$JOBS_FAILING"
mkfix "$FIXTURE"
PIN_LEDGER="$WORK/shared-ledger.jsonl"
run
L1=$(wc -l <"$PIN_LEDGER" | tr -d ' ')
run
L2=$(wc -l <"$PIN_LEDGER" | tr -d ' ')
LEDGER_CHECK=$(
  python3 - "$PIN_LEDGER" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, f"want 2 rows, got {len(rows)}"
for d in rows:
    assert d["verdict"] == "degraded", d
    assert d["jobs_failing"] == 3, d
    assert any("map-render" in f for f in d["findings"]), d
print("ok")
PY
)
unset PIN_LEDGER
if [ "$L1" = 1 ] && [ "$L2" = 2 ] && [ "$LEDGER_CHECK" = ok ]; then
  ok "14 every run APPENDS one valid JSON verdict (with its findings) to the ledger"
else
  bad "14 the durable ledger" "lines after run1=$L1 run2=$L2 check=$LEDGER_CHECK"
fi

# --- 15 -- a checker that cannot record its verdict is BROKEN ----------------
mkdir -p "$WORK/ro"
chmod 500 "$WORK/ro"
reset_fix
mkfix "$FIXTURE"
PIN_LEDGER="$WORK/ro/nope/pico.jsonl"
run
unset PIN_LEDGER
chmod 700 "$WORK/ro"
if [ "$RC" -ne 0 ] && [ "$RC" -ne 10 ] &&
  printf '%s' "$OUT" | grep -q 'CHECKER BROKEN' &&
  printf '%s\n' "$OUT" | tail -1 | grep -q '^PICO_HEALTH_RESULT='; then
  ok "15 an unwritable ledger is a BROKEN CHECKER (rc $RC: not 0, not 10)"
else
  bad "15 unwritable ledger -> checker-broken" "rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 16 ----------------------------------------------------------------------
reset_fix
mkfix "$FIXTURE"
PIN_MANIFEST="$WORK/no-such.manifest"
run
unset PIN_MANIFEST
if [ "$RC" -ne 0 ] && [ "$RC" -ne 10 ] && printf '%s' "$OUT" | grep -q 'CHECKER BROKEN'; then
  ok "16 a missing ports manifest is a BROKEN CHECKER, not a clean bill of health"
else
  bad "16 missing manifest -> checker-broken" "rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 17 ----------------------------------------------------------------------
# ssh exits 0 and says nothing. `exit 0, no verdict` is the exact shape the
# verdict contract exists to refuse.
reset_fix
mkfix "$FIXTURE"
run "$WORK/ssh-empty"
if [ "$RC" -ne 0 ] && [ "$RC" -ne 10 ] && printf '%s' "$OUT" | grep -q 'CHECKER BROKEN'; then
  ok "17 a probe that exits 0 and says NOTHING is a broken checker, not ok"
else
  bad "17 empty probe -> checker-broken" "rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 18 -- softwareupdate is asked DAILY, not 48 times a day -----------------
reset_fix
FIX_SU="SU${TAB}macOS Tahoe 26.6.1"
mkfix "$FIXTURE"
PIN_ARGV="$WORK/shared-argv"
PIN_SUCACHE="$WORK/shared-su.cache"
run
run
A1=$(sed -n 1p "$PIN_ARGV")
A2=$(sed -n 2p "$PIN_ARGV")
unset PIN_ARGV PIN_SUCACHE
if printf '%s' "$A1" | grep -q 'SU_DUE=1' && printf '%s' "$A2" | grep -q 'SU_DUE=0'; then
  ok "18 softwareupdate is probed once per window, then served from cache"
else
  bad "18 softwareupdate probe is rate-limited" "call1=[$A1] call2=[$A2]"
fi

# --- 19 -- 0 updates and 'could not ask' are opposite facts ------------------
reset_fix
FIX_SURC=1
FIX_SU=""
mkfix "$FIXTURE"
SEEDED="$WORK/seeded-su.cache"
{
  printf '# generated_at=%s\n' "$((FIX_NOW - 90000))"
  printf '# os_build=%s\n' "$FIX_BUILD" # same build: case 25 owns the mismatch
  printf 'macOS Sonoma 14.8.9\n'
  printf 'macOS Tahoe 26.6.1\n'
} >"$SEEDED"
PIN_SUCACHE="$SEEDED"
run
unset PIN_SUCACHE
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'note: softwareupdate -l failed' &&
  printf '%s' "$OUT" | grep -q 'updates: 2 recommended pending' &&
  [ "$(grep -cv '^#' "$SEEDED")" = 2 ]; then
  ok "19 a FAILED softwareupdate probe never overwrites the cache with 0"
else
  bad "19 failed softwareupdate probe keeps the cached count" "verdict=$VERDICT cache=$(cat "$SEEDED")
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 20 -- the CHECKED-IN manifest is data, and data can rot -----------------
# The convention arm of tools/githooks/pre-commit only gates scripts; without
# this case a hand-edit to the real manifest — a duplicate, a stray word, an
# empty file — would be gated on nothing.
MF_ROWS=$(sed 's/#.*//' "$REAL_MANIFEST" | awk 'NF')
MF_ENTRIES=$(printf '%s\n' "$MF_ROWS" | awk '{ print $1 }')
MF_N=$(printf '%s' "$MF_ENTRIES" | grep -c .)
MF_DUPES=$(printf '%s\n' "$MF_ENTRIES" | sort | uniq -d)
MF_JUNK=$(printf '%s\n' "$MF_ENTRIES" | grep -vE '^(\*|\[[0-9a-f:]+\]|[0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]{1,5}|dynamic)$')
# A pinned entry carries nothing but its addr:port. A dynamic entry MUST carry
# exactly one process name: without it the rule matches EVERY ephemeral listener
# on that address, which is the manifest failing open — the one way this grammar
# can be used to launder an undocumented listener instead of documenting it.
MF_EXTRA=$(printf '%s\n' "$MF_ROWS" | awk '
  $1 !~ /:dynamic$/ && NF > 1 { print }
  $1 ~ /:dynamic$/ && (NF != 2 || $2 !~ /^[A-Za-z0-9._-]+$/) { print }')
if [ "$MF_N" -ge 20 ] && [ -z "$MF_DUPES" ] && [ -z "$MF_JUNK" ] && [ -z "$MF_EXTRA" ]; then
  ok "20 the checked-in pico-ports.manifest parses: $MF_N entries, no dupes, no junk"
else
  bad "20 the checked-in manifest parses" "n=$MF_N dupes=[$MF_DUPES] junk=[$MF_JUNK] extra-words=[$MF_EXTRA]"
fi

# --- 21 -- THE DRIFT THAT PRODUCED dotfiles-c9yi -----------------------------
# colima restarts; the kernel hands `limactl usernet` a different ephemeral
# loopback port. Against a PINNED manifest line that is two findings for one
# non-event — "expected listener GONE: 127.0.0.1:60121" and "undocumented
# listener: 127.0.0.1:49265" — and it recurs at every VM restart, which is how a
# watcher trains its readers to skip it. Both ports below are ephemeral and both
# belong to limactl, so neither run has anything to say.
reset_fix
mkfix "$FIXTURE"
run
V21A=$VERDICT
O21A=$OUT
FIX_PORTS=${PORTS_OK//52001/61999}
mkfix "$FIXTURE"
run
if [ "$V21A" = ok ] && [ "$VERDICT" = ok ] &&
  ! printf '%s' "$O21A$OUT" | grep -q 'undocumented listener' &&
  ! printf '%s' "$O21A$OUT" | grep -q 'listener(s) GONE'; then
  ok "21 an ephemeral port that MOVES between runs (52001 -> 61999) is not a finding"
else
  bad "21 a moving ephemeral port is not a finding" "run1=$V21A run2=$VERDICT
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 22 -- and the guard stays sharp -----------------------------------------
# The whole risk of a dynamic entry is that it becomes a wildcard. A DIFFERENT
# process on a loopback ephemeral port is exactly the next undocumented listener
# the manifest exists to catch, and the rule must not launder it.
reset_fix
FIX_PORTS="$PORTS_OK
PORT${TAB}127.0.0.1:52002${TAB}nc"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: undocumented listener(s): 127.0.0.1:52002'; then
  ok "22 a DIFFERENT process on a loopback ephemeral port is still undocumented"
else
  bad "22 dynamic entries do not launder other processes" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 23 ----------------------------------------------------------------------
# The other direction: the named process gone entirely is still a service that
# is down, reported under the token the manifest speaks.
reset_fix
FIX_PORTS="PORT${TAB}*:14829${TAB}go-jammin
PORT${TAB}100.72.47.4:8080${TAB}nginx
PORT${TAB}127.0.0.1:21848${TAB}cappedpro"
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: expected listener(s) GONE: 127.0.0.1:dynamic'; then
  ok "23 the named process vanishing is still GONE, not silence"
else
  bad "23 a vanished dynamic listener is caught" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 24 ----------------------------------------------------------------------
# A dynamic entry is scoped to the EPHEMERAL range, so it cannot be used to
# whitelist a service port by naming its process. limactl on :9999 is both an
# undocumented listener and a rule with nothing to match.
reset_fix
FIX_PORTS=${PORTS_OK//52001/9999}
mkfix "$FIXTURE"
run
if [ "$VERDICT" = degraded ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: undocumented listener(s): 127.0.0.1:9999' &&
  printf '%s' "$OUT" | grep -q 'FINDING: expected listener(s) GONE: 127.0.0.1:dynamic'; then
  ok "24 the named process OUTSIDE the ephemeral range is not laundered by the rule"
else
  bad "24 dynamic entries are scoped to the ephemeral range" "verdict=$VERDICT rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 25 -- THE CONTRADICTION -------------------------------------------------
# dotfiles-c9yi: pico upgraded to 26.6.1 (25G76) at 12:36Z, the softwareupdate
# cache had been written at 03:43Z, and 20h-by-the-clock said "still fresh". For
# six hours the checker reported the two offers that upgrade had just CONSUMED —
# "macOS Sonoma 14.8.9; macOS Tahoe 26.6.1" — against a live `softwareupdate -l`
# on the same box showing none. A count is a fact about the build it was measured
# on; on a different build it is not stale, it is VOID.
reset_fix
FIX_SURAN=0
mkfix "$FIXTURE"
SEEDED="$WORK/preupgrade-su.cache"
{
  printf '# generated_at=%s\n' "$FIX_NOW"
  printf '# os_build=%s\n' "24G90"
  printf 'macOS Sonoma 14.8.9\n'
  printf 'macOS Tahoe 26.6.1\n'
} >"$SEEDED"
PIN_SUCACHE="$SEEDED"
run
unset PIN_SUCACHE
if [ "$VERDICT" = degraded ] && [ "$RC" -eq 10 ] &&
  printf '%s' "$OUT" | grep -q 'FINDING: softwareupdate cache discarded — measured on OS build 24G90' &&
  ! printf '%s' "$OUT" | grep -q 'macOS Sonoma 14.8.9' &&
  [ ! -f "$SEEDED" ]; then
  ok "25 a cache measured on an OLDER OS build is VOID — discarded, never reported"
else
  bad "25 an OS upgrade voids the softwareupdate cache" "verdict=$VERDICT rc=$RC cache-still-there=$([ -f "$SEEDED" ] && echo yes || echo no)
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

# --- 26 ----------------------------------------------------------------------
# The other half of the same fix, and the half that keeps 25 from firing in
# practice: the cached build is handed to the probe, which re-asks in the SAME
# round trip when it no longer matches — and a refreshed cache records the build
# its answer is about.
reset_fix
FIX_SU=""
mkfix "$FIXTURE"
SEEDED2="$WORK/rekeyed-su.cache"
{
  printf '# generated_at=%s\n' "$FIX_NOW"
  printf '# os_build=%s\n' "24G90"
  printf 'macOS Tahoe 26.6.1\n'
} >"$SEEDED2"
PIN_SUCACHE="$SEEDED2"
PIN_ARGV="$WORK/rekey-argv"
run
unset PIN_SUCACHE PIN_ARGV
if [ "$VERDICT" = ok ] && [ "$RC" -eq 0 ] &&
  grep -q "SU_CACHED_BUILD='24G90'" "$WORK/rekey-argv" &&
  grep -q '^# os_build=25G76$' "$SEEDED2" &&
  [ "$(grep -cv '^#' "$SEEDED2")" = 0 ]; then
  ok "26 the cached build is handed to the probe, and a refresh re-keys the cache"
else
  bad "26 the cache is keyed to the OS build" "verdict=$VERDICT rc=$RC argv=[$(cat "$WORK/rekey-argv")]
        cache=[$(cat "$SEEDED2")]"
fi

# --- 27 ----------------------------------------------------------------------
# No build means the guard above is not running, and its absence is silent —
# which is the same class of defect as the cache it protects. Broken checker.
reset_fix
FIX_BUILD=""
mkfix "$FIXTURE"
run
if [ "$RC" -ne 0 ] && [ "$RC" -ne 10 ] &&
  printf '%s' "$OUT" | grep -q 'CHECKER BROKEN: the probe returned no OS_BUILD='; then
  ok "27 a probe that cannot say which OS build it measured is a BROKEN CHECKER"
else
  bad "27 a missing OS_BUILD is checker-broken" "rc=$RC
$(printf '%s\n' "$OUT" | sed 's/^/        | /')"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
