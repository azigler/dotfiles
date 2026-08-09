#!/bin/bash
# Test for pico-backup-pull.sh — the keep's off-box pull of pico's state.
#
# HERMETIC, AND WITHOUT FAKING THE THING UNDER TEST. There is no ssh here and no
# pico: the script's remote-exec seam (PICO_BACKUP_SSH) is pointed at `bash -c`
# and its rsync source prefix (PICO_BACKUP_REMOTE_PREFIX) is emptied, so the
# whole script runs against a LOCAL FIXTURE that stands in for pico's $HOME.
# rsync is REAL, sqlite3 is REAL, the checksums are REAL. Only the transport is
# short-circuited — which is the one part with no logic in it.
#
# WHY THAT SHAPE. The failure this script exists to prevent is a backup that
# reports success and holds nothing, so the assertions that matter are about
# what is ON DISK afterwards and whether it matches the source byte for byte. A
# stubbed rsync would test the stub. A stubbed sha256 would test nothing at all.
#
# THE CASES THE MUTATION HARNESS AIMS AT — all three drive the real script
# through PICO_BACKUP_RSYNC, a seam that stands in for a transport that lies:
#
#   8  a "successful" rsync that transfers NOTHING must not read as ok
#   9  a pull whose bytes differ from the source must not read as ok (the
#      alteration is LENGTH-PRESERVING, so only a checksum can see it)
#   19 a pull that silently DROPS one file the sampler never looks at — only
#      the count/byte comparison can see that one
#
# 19 exists because 8 alone does not prove guard 1 earns its keep: with an empty
# destination the sha256 guard fires too (its samples are missing), so removing
# the count check there merely changes which finding is printed.
#
# MEASURED mutant -> failing cases (2026-08-09; re-measure if you change a case,
# and do not write this map from memory):
#
#   M1  the local-vs-remote count/byte assertion deleted   -> 8 19
#   M2  the sha256 comparison deleted                      -> 9
#
# That map is executable, not a comment: mutate-pico-backup-pull.sh applies both
# and asserts each dies on exactly the case named here. Per this repo's rule 1, a
# green suite is not evidence that a guard bites; only a mutant that dies is.
#
# Convention matches the other agents/scheduler suites: executable bash,
# non-zero exit = failure, PASS/FAIL summary on the last line.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/pico-backup-pull.sh"
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

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pbp-test.XXXXXX")
# shellcheck disable=SC2317  # invoked via trap
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

HAVE_SQLITE=0
command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE=1   # allow-suppress: capability probe

# --- the fixture that stands in for pico's $HOME ---------------------------
# Same shape as the real thing: a mode-600 secrets FILE, a mode-600 gateway
# config, a world-readable gojamming token, a static site tree, a dumps
# directory, and (when sqlite3 exists) a real database at the path the script
# snapshots.
build_fixture() {
  local h=$1
  rm -rf "$h"
  mkdir -p "$h/.config/agentgateway" "$h/gojamming" "$h/sites/harness/icons" \
           "$h/backups/vacation-station" "$h/.local/share/agentgateway"
  printf 'ANTHROPIC_API_KEY=sk-fixture-not-a-real-key\nAGW_CC_KEY=fixture\n' >"$h/.secrets"
  chmod 600 "$h/.secrets"
  # shellcheck disable=SC2016  # the ${…} is literal config-file syntax, as on pico
  printf 'binds:\n  - port: 17017\n    key: "${AGW_CC_KEY}"\n' >"$h/.config/agentgateway/config.yaml"
  chmod 600 "$h/.config/agentgateway/config.yaml"
  printf '{"token":"fixture-token","allowed":["example.com"]}\n' >"$h/gojamming/config.json"
  # pico's real one is 0644 — a plaintext token readable by every local account
  # (audit finding). Set it explicitly rather than inheriting the keep's umask,
  # so case 4 tests the archive's hardening and not this box's umask.
  chmod 644 "$h/gojamming/config.json"
  printf '<!doctype html><title>harness</title>\n' >"$h/sites/harness/index.html"
  printf 'body{color:#fff}\n' >"$h/sites/harness/app.css"
  printf 'PNGFIXTURE\n' >"$h/sites/harness/icons/icon-192.png"
  local d
  for d in 20260801 20260802 20260803; do
    head -c 4096 /dev/urandom >"$h/backups/vacation-station/daily-vs-$d.dump"
    printf 'deadbeef  daily-vs-%s.dump\n' "$d" >"$h/backups/vacation-station/daily-vs-$d.dump.sha256"
  done
  printf '{"verdict":"ok"}\n' >"$h/backups/vacation-station/STATUS.json"
  if [ "$HAVE_SQLITE" -eq 1 ]; then
    sqlite3 "$h/.local/share/agentgateway/requests.db" \
      'pragma journal_mode=wal; create table requests(id integer primary key, body text);
       insert into requests(body) values ("alpha"),("beta"),("gamma");' >/dev/null
  fi
}

# run <fixture-home> <dest> [env assignments...] -> $RC, $OUT
run() {
  local h=$1 dest=$2
  shift 2
  OUT=$(env \
    PICO_BACKUP_HOST=fixture-pico \
    PICO_BACKUP_SSH="bash -c" \
    PICO_BACKUP_REMOTE_PREFIX= \
    PICO_BACKUP_REMOTE_HOME="$h" \
    PICO_BACKUP_DEST="$dest" \
    PICO_BACKUP_LEDGER="$dest.ledger.jsonl" \
    "$@" \
    bash "$SCRIPT" 2>&1)
  RC=$?
}

verdict_of() { printf '%s\n' "$1" | tail -1 | sed -n 's/^PICO_BACKUP_PULL_RESULT=//p'; }
mode_of() { stat -c '%a' "$1"; }

CASE=1
H="$ROOT/home"
D="$ROOT/dest"

# --- 1 happy path -----------------------------------------------------------
build_fixture "$H"
run "$H" "$D"
if [ "$RC" -eq 0 ] && [ "$(verdict_of "$OUT")" = ok ]; then
  ok "$CASE a complete fixture pulls clean: verdict ok, exit 0"
else bad "$CASE happy path is ok/0" "rc=$RC verdict=$(verdict_of "$OUT") out=$OUT"; fi
CASE=2

# --- 2 the bytes are actually there -----------------------------------------
MISSING=""
for f in "$D/secrets/.secrets" \
         "$D/agentgateway-config/config.yaml" \
         "$D/gojamming-config/config.json" \
         "$D/sites-harness/index.html" \
         "$D/sites-harness/icons/icon-192.png" \
         "$D/vacation-station/$(date -u +%F)/STATUS.json"; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ] && cmp -s "$H/.secrets" "$D/secrets/.secrets" \
   && cmp -s "$H/sites/harness/index.html" "$D/sites-harness/index.html"; then
  ok "$CASE every dataset landed and the contents match the source"
else bad "$CASE datasets land with matching content" "missing:$MISSING"; fi
CASE=3

# --- 3 secrets land 0700 dir / 0600 files -----------------------------------
if [ "$(mode_of "$D/secrets")" = 700 ] && [ "$(mode_of "$D/secrets/.secrets")" = 600 ] \
   && [ "$(mode_of "$D/agentgateway-config/config.yaml")" = 600 ]; then
  ok "$CASE pulled secrets are 0700 dir / 0600 files on the keep"
else bad "$CASE secret perms" "dir=$(mode_of "$D/secrets") file=$(mode_of "$D/secrets/.secrets") cfg=$(mode_of "$D/agentgateway-config/config.yaml")"; fi
CASE=4

# --- 4 a world-readable source does NOT stay world-readable in the archive --
if [ "$(mode_of "$H/gojamming/config.json")" = 644 ] \
   && [ "$(mode_of "$D/gojamming-config/config.json")" = 600 ]; then
  ok "$CASE a 0644 source file is archived 0600 (--chmod, not the source's mode)"
else bad "$CASE 0644 source archived 0600" "src=$(mode_of "$H/gojamming/config.json") dst=$(mode_of "$D/gojamming-config/config.json")"; fi
CASE=5

# --- 5 the archive root is not readable by anyone else ----------------------
if [ "$(mode_of "$D")" = 700 ]; then
  ok "$CASE the archive root is 0700"
else bad "$CASE archive root 0700" "mode=$(mode_of "$D")"; fi
CASE=6

# --- 6 the verdict is durable, parseable, and last --------------------------
LEDGER="$D.ledger.jsonl"
LAST=$(tail -1 "$LEDGER" 2>/dev/null)   # allow-suppress: existence-tolerant read
if [ -f "$LEDGER" ] && printf '%s' "$LAST" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["verdict"]=="ok" and d["datasets"]["secrets"]=="ok" and d["bytes"]>0 else 1)'; then
  ok "$CASE a JSON verdict line is appended to the fleet-health ledger"
else bad "$CASE ledger line" "ledger=$LEDGER last=$LAST"; fi
CASE=7

# --- 7 a missing source is a FINDING, never silence -------------------------
H2="$ROOT/home2"; D2="$ROOT/dest2"
build_fixture "$H2"
rm -f "$H2/.secrets"
run "$H2" "$D2"
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = degraded ] \
   && printf '%s' "$OUT" | grep -q 'secrets: absent'; then
  ok "$CASE a dataset missing on pico is degraded + exit 10, and says which"
else bad "$CASE missing source is degraded/10" "rc=$RC verdict=$(verdict_of "$OUT")"; fi
CASE=8

# --- 8 THE SILENT-EMPTY CASE (mutant M1's sole detector) --------------------
# rsync that exits 0 and moves nothing. The source is intact and non-empty, the
# transport reports success, and the destination is empty. This is the exact
# shape of the backup-that-holds-nothing, and it must NOT read as ok.
STUB="$ROOT/rsync-noop"
cat >"$STUB" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB"
H3="$ROOT/home3"; D3="$ROOT/dest3"
build_fixture "$H3"
run "$H3" "$D3" PICO_BACKUP_RSYNC="$STUB"
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = degraded ] \
   && printf '%s' "$OUT" | grep -q 'the pull did not land'; then
  ok "$CASE an rsync that exits 0 and transfers NOTHING is degraded, not ok"
else bad "$CASE silent-empty pull is degraded" "rc=$RC verdict=$(verdict_of "$OUT") out=$(printf '%s' "$OUT" | tail -4)"; fi
CASE=9

# --- 9 THE CORRUPTED-PULL CASE (mutant M2's sole detector) ------------------
# Real rsync, then one landed file is altered IN PLACE at the same length — so
# the count and the byte total still match and only the checksum can see it.
# Length-preserving is the whole point: a truncation would be caught by case 8's
# guard and prove nothing about the checksum.
WRAP="$ROOT/rsync-corrupt"
cat >"$WRAP" <<'EOF'
#!/bin/bash
rsync "$@" || exit $?
for a in "$@"; do dest="$a"; done   # rsync's destination is its last argument
f="$dest/index.html"
if [ -f "$f" ]; then
  n=$(wc -c <"$f")
  head -c "$n" /dev/zero | tr '\0' 'X' >"$f.tmp" && mv "$f.tmp" "$f"
fi
exit 0
EOF
chmod +x "$WRAP"
H4="$ROOT/home4"; D4="$ROOT/dest4"
build_fixture "$H4"
run "$H4" "$D4" PICO_BACKUP_RSYNC="$WRAP"
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = degraded ] \
   && printf '%s' "$OUT" | grep -q 'sha256 MISMATCH'; then
  ok "$CASE a same-length corrupted file is caught by the sha256 compare"
else bad "$CASE corrupted pull is degraded" "rc=$RC verdict=$(verdict_of "$OUT") out=$(printf '%s' "$OUT" | tail -4)"; fi
CASE=10

# --- 10 an unreachable host is a finding, not "no news" ---------------------
D5="$ROOT/dest5"
OUT=$(env PICO_BACKUP_HOST=fixture-pico PICO_BACKUP_SSH="false" \
       PICO_BACKUP_REMOTE_PREFIX= PICO_BACKUP_DEST="$D5" \
       PICO_BACKUP_LEDGER="$D5.ledger.jsonl" bash "$SCRIPT" 2>&1); RC=$?
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = unreachable ]; then
  ok "$CASE an unreachable host is verdict unreachable + exit 10"
else bad "$CASE unreachable host" "rc=$RC verdict=$(verdict_of "$OUT")"; fi
CASE=11

# --- 11 generations: a second run on a later date adds, never replaces ------
# The generation name is the UTC date, so a second same-day run is idempotent by
# design. PICO_BACKUP_GENERATIONS and a hand-planted older generation are how
# the rotation is exercised without waiting a week.
H6="$ROOT/home6"; D6="$ROOT/dest6"
build_fixture "$H6"
run "$H6" "$D6"
mkdir -p "$D6/vacation-station/2026-01-01"
cp "$H6/backups/vacation-station/STATUS.json" "$D6/vacation-station/2026-01-01/"
run "$H6" "$D6"
GENS=$(find "$D6/vacation-station" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
if [ "$(verdict_of "$OUT")" = ok ] && printf '%s' "$GENS" | grep -q '2026-01-01' \
   && printf '%s' "$GENS" | grep -q "$(date -u +%F)"; then
  ok "$CASE the generational set keeps prior generations alongside today's"
else bad "$CASE generations accumulate" "gens=[$GENS] verdict=$(verdict_of "$OUT")"; fi
CASE=12

# --- 12 retention prunes to exactly N, oldest first -------------------------
H7="$ROOT/home7"; D7="$ROOT/dest7"
build_fixture "$H7"
mkdir -p "$D7"
for d in 2026-01-01 2026-01-02 2026-01-03 2026-01-04; do
  mkdir -p "$D7/vacation-station/$d"
  cp "$H7/backups/vacation-station/STATUS.json" "$D7/vacation-station/$d/"
done
run "$H7" "$D7" PICO_BACKUP_GENERATIONS=3
GENS=$(find "$D7/vacation-station" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')
NGEN=$(printf '%s' "$GENS" | wc -w)
if [ "$NGEN" -eq 3 ] && ! printf '%s' "$GENS" | grep -q '2026-01-01' \
   && printf '%s' "$GENS" | grep -q '2026-01-04'; then
  ok "$CASE retention keeps exactly N generations and drops the oldest"
else bad "$CASE retention prunes to N" "n=$NGEN gens=[$GENS]"; fi
CASE=13

# --- 13 the generations are HARDLINKS, not N full copies --------------------
H8="$ROOT/home8"; D8="$ROOT/dest8"
build_fixture "$H8"
run "$H8" "$D8"
TODAY=$(date -u +%F)
mv "$D8/vacation-station/$TODAY" "$D8/vacation-station/2026-01-01"
run "$H8" "$D8"
A_INO=$(stat -c '%i' "$D8/vacation-station/2026-01-01/STATUS.json")
B_INO=$(stat -c '%i' "$D8/vacation-station/$TODAY/STATUS.json")
if [ "$A_INO" = "$B_INO" ]; then
  ok "$CASE an unchanged dump is hardlinked into the previous generation"
else bad "$CASE --link-dest hardlinks unchanged files" "a=$A_INO b=$B_INO"; fi
CASE=14

# --- 14 `current` points at the newest generation ---------------------------
if [ -L "$D8/vacation-station/current" ] \
   && [ "$(readlink "$D8/vacation-station/current")" = "$D8/vacation-station/$TODAY" ]; then
  ok "$CASE the 'current' symlink follows the newest generation"
else bad "$CASE current symlink" "target=$(readlink "$D8/vacation-station/current" || echo none)"; fi
CASE=15

# --- 15 the hot sqlite database is snapshotted, not copied raw --------------
if [ "$HAVE_SQLITE" -eq 1 ]; then
  if [ -f "$D/requests-db/requests.db" ] \
     && [ "$(sqlite3 "$D/requests-db/requests.db" 'pragma integrity_check;')" = ok ] \
     && [ "$(sqlite3 "$D/requests-db/requests.db" 'select count(*) from requests;')" = 3 ]; then
    ok "$CASE the pulled requests.db passes integrity_check and holds every row"
  else bad "$CASE sqlite snapshot is a restorable database" "present=$([ -f "$D/requests-db/requests.db" ] && echo y || echo n)"; fi
else
  ok "$CASE (skipped: no sqlite3 on this box)"
fi
CASE=16

# --- 16 the snapshot does not stay behind on pico ---------------------------
LEFTOVER=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'pico-backup-pull.*' -type d 2>/dev/null | wc -l)
if [ "$LEFTOVER" -eq 0 ]; then
  ok "$CASE the remote snapshot dir is removed after the pull"
else bad "$CASE snapshot cleaned up" "$LEFTOVER dir(s) left in ${TMPDIR:-/tmp}"; fi
CASE=17

# --- 17 the verdict line is the LAST line, always ---------------------------
if [ "$(printf '%s\n' "$OUT" | tail -1 | cut -d= -f1)" = PICO_BACKUP_PULL_RESULT ]; then
  ok "$CASE the outcome contract's verdict is the final line of output"
else bad "$CASE verdict is last" "last=[$(printf '%s\n' "$OUT" | tail -1)]"; fi
CASE=18

# --- 18 an empty source directory never overwrites a good archive ----------
H9="$ROOT/home9"; D9="$ROOT/dest9"
build_fixture "$H9"
run "$H9" "$D9"
BEFORE=$(find "$D9/sites-harness" -type f | wc -l)
rm -f "$H9/sites/harness/index.html" "$H9/sites/harness/app.css" \
      "$H9/sites/harness/icons/icon-192.png"
run "$H9" "$D9"
AFTER=$(find "$D9/sites-harness" -type f | wc -l)
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = degraded ] \
   && [ "$BEFORE" -eq "$AFTER" ] && [ "$AFTER" -gt 0 ]; then
  ok "$CASE a wiped source is a finding and the previous good copy survives"
else bad "$CASE empty source does not propagate" "rc=$RC before=$BEFORE after=$AFTER verdict=$(verdict_of "$OUT")"; fi
CASE=19

# --- 19 THE PARTIAL PULL — guard 1's SOLE detector -------------------------
# Case 8 is not enough on its own to prove the count/byte assertion earns its
# keep: with the destination completely empty, the sha256 guard ALSO fires
# (its sampled files are missing), so deleting the count check there only
# changes which finding is reported. This case removes a file the sampler never
# looks at — the middle of three, where the samples are the first and the last —
# so every checksum still matches and ONLY the count/byte comparison can see
# that a file went missing in transit.
PART="$ROOT/rsync-partial"
cat >"$PART" <<'EOF'
#!/bin/bash
rsync "$@" || exit $?
for a in "$@"; do dest="$a"; done   # rsync's destination is its last argument
[ -f "$dest/icons/icon-192.png" ] && rm -f "$dest/icons/icon-192.png"
exit 0
EOF
chmod +x "$PART"
H10="$ROOT/home10"; D10="$ROOT/dest10"
build_fixture "$H10"
run "$H10" "$D10" PICO_BACKUP_RSYNC="$PART"
if [ "$RC" -eq 10 ] && [ "$(verdict_of "$OUT")" = degraded ] \
   && printf '%s' "$OUT" | grep -q 'sites-harness: pulled 2 file(s)' \
   && ! printf '%s' "$OUT" | grep -q 'sites-harness: sha256 MISMATCH'; then
  ok "$CASE a file dropped in transit is caught by the count/byte compare alone"
else bad "$CASE partial pull is degraded" "rc=$RC verdict=$(verdict_of "$OUT") out=$(printf '%s' "$OUT" | grep sites-harness)"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
