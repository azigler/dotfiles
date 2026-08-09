#!/bin/bash
# test-marshal-drain.sh — regression suite for marshal-drain.sh (dotfiles-69qr),
# covering the spec's named test cases T1-T14 plus the verdict discipline.
#
# HERMETIC, and it has to be: this script's subject decides what an unattended
# 01:07 loop SPENDS and which beads it hands to a builder. Nothing here touches
# pico, the real requests.db, a real bead, a real repo, or a real systemd unit:
#
#   * a FIXTURE sqlite db (built locally) stands in for pico's requests.db via
#     MARSHAL_SQL_CMD — the same seam production uses to reach it over ssh;
#   * a FAKE `br` is prepended to PATH, so both marshal-drain's own
#     `br scheduler --json` AND bead-markers.sh's internal `br show --json`
#     (which the library hardcodes) resolve to the fixture;
#   * MARSHAL_CONF / MARSHAL_LEDGER / MARSHAL_FREEZE_SCRIPT / MARSHAL_NOW point
#     at per-case scratch;
#   * the `verify` cases build throwaway git repos under $TMPDIR.
#
# THE FOUR PROPERTIES THIS SUITE MUST NEVER LET REGRESS — each is a silent
# failure in production, which is why each also has a mutant in
# mutate-marshal-drain.sh:
#   - the budget SUBTRACTS Zig's daytime reserve, and a budget it cannot
#     compute degrades to the config floor, never to a large number;
#   - eligibility is MARKER-gated (an unmarked ready bead is never claimed);
#   - the type list outranks the marker (R10: a `Fleet: yes` decision bead is
#     REFUSED, not promoted);
#   - a demesne freeze means ZERO dispatches.
#
# Usage: bash agents/scheduler/test-marshal-drain.sh   (exit 0 = pass)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Overridable so a mutant copy runs through this same suite (CLAUDE.md rule 1:
# a green suite is not evidence a guard bites; only a mutant that dies is).
SCRIPT="${MD_SCRIPT:-$HERE/marshal-drain.sh}"

ROOT_T=$(mktemp -d "${TMPDIR:-/tmp}/marshal-test.XXXXXX")
PASS=0; FAIL=0
FAILED_NAMES=()

cleanup() { rm -rf "$ROOT_T"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s -- %s\n' "$1" "${2:-}"; }

eq() { # eq <name> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi
}
has() { # has <name> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to find [$3]" ;; esac
}
not_has() {
  case "$2" in *"$3"*) bad "$1" "did NOT want [$3]" ;; *) ok "$1" ;; esac
}
last_line() { printf '%s\n' "$1" | tail -n1; }

# assert_verdict <name> <stdout> <prefix> <expected-regex>
# The verdict discipline: exactly ONE marker line, and it is the LAST line.
assert_verdict() {
  local name=$1 out=$2 prefix=$3 re=$4 last cnt
  last=$(last_line "$out")
  cnt=$(printf '%s\n' "$out" | grep -c "^$prefix" || true)
  if [ "$cnt" -eq 1 ] && printf '%s' "$last" | grep -qE "$re"; then
    ok "$name"
  else
    bad "$name" "last=[$last] marker_count=$cnt"
  fi
}

# plan_json <stdout> -- everything except the trailing verdict line
plan_json() { printf '%s\n' "$1" | sed '$d'; }

jq_py() { # jq_py <json> <python-expr over `d`>
  printf '%s' "$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print($2)
" 2>&1
}

# ===========================================================================
# FIXTURES
# ===========================================================================
FIX="$ROOT_T/fix"
mkdir -p "$FIX/bin" "$FIX/beads" "$FIX/sched" "$FIX/repos/harnessd/.beads" \
         "$FIX/repos/dotfiles/.beads" "$FIX/repos/notoptin/.beads" "$FIX/state"

# --- the fake `br` --------------------------------------------------------
# `br scheduler --json` -> $MD_FIX/sched/<basename of cwd>.json
# `br show <id> --json`  -> $MD_FIX/beads/<id>.json (a LIST, like br 0.2.16)
cat > "$FIX/bin/br" <<'BR'
#!/bin/bash
verb=${1:-}
case "$verb" in
  scheduler)
    f="$MD_FIX/sched/$(basename "$PWD").json"
    [ -f "$f" ] || { echo "no scheduler fixture for $PWD" >&2; exit 1; }
    cat "$f" ;;
  show)
    id=${2:-}
    f="$MD_FIX/beads/$id.json"
    [ -f "$f" ] || { echo "[]"; exit 0; }
    cat "$f" ;;
  *) echo "fake br: unsupported verb '$verb'" >&2; exit 2 ;;
esac
BR
chmod +x "$FIX/bin/br"
export PATH="$FIX/bin:$PATH"
export MD_FIX="$FIX"

# mkbead <id> <description...>  — writes the br-show fixture
mkbead() {
  local id=$1 desc=$2
  MD_ID="$id" MD_DESC="$desc" python3 -c '
import json, os
print(json.dumps([{"id": os.environ["MD_ID"], "description": os.environ["MD_DESC"]}]))
' > "$FIX/beads/$id.json"
}

# mksched <repo-basename> <"id|type|title" ...> — writes the scheduler fixture
# in the given order (rank 1..n, score descending).
mksched() {
  local repo=$1; shift
  MD_ROWS="$(printf '%s\n' "$@")" python3 -c '
import json, os
rows = [r for r in os.environ["MD_ROWS"].splitlines() if r.strip()]
recs = []
for i, r in enumerate(rows, start=1):
    bid, btype, title = r.split("|", 2)
    recs.append({
        "rank": i, "fallback_rank": i, "score": 100 - i,
        "rationale": [f"{bid} scores {100-i} after evidence weighting",
                      "priority P1 contributes 30; 2 dependent issue(s) contribute 6"],
        "issue": {"id": bid, "issue_type": btype, "title": title,
                  "priority": 1, "status": "open"},
    })
print(json.dumps({"schema": "br.scheduler.v1", "recommendations": recs}))
' > "$FIX/sched/$repo.json"
}

# --- the fixture requests.db ---------------------------------------------
# now = 2026-08-09T06:00:00Z, tz offset -7 (PDT), weekly reset Wednesday 00:00
# local -> window starts 2026-08-05 07:00 UTC; next reset 2026-08-12 07:00 UTC,
# so days_to_reset = ceil(3d1h) = 4.
#
#   in-window personal ....... 300k + 400k + 300k = 1,000,000
#   daytime (08-22 local) over the trailing 7 days: 300k + 400k = 700,000
#   excluded: a work-tap row, an epoch-1 `work:` row, and a personal row
#             from BEFORE both windows.
DB="$FIX/requests.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE request_logs (
  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, total_tokens INTEGER,
  agentgateway_user TEXT, agentgateway_group TEXT, attributes_json TEXT);
INSERT INTO request_logs (id,started_at,total_tokens,agentgateway_user,agentgateway_group) VALUES
 ('a','2026-08-06T18:00:00.000000+00:00',300000,'zig-computer:dotfiles','personal'),
 ('b','2026-08-07T18:00:00.000000+00:00',400000,'zig-computer:marshal','zig-computer'),
 ('c','2026-08-08T09:00:00.000000+00:00',300000,'zig-computer:dotfiles','personal'),
 ('d','2026-08-06T18:00:00.000000+00:00',5000000,'zig-computer:linearb','work'),
 ('e','2026-08-06T18:30:00.000000+00:00',5000000,'work:di-monday','zig-computer'),
 ('f','2026-08-01T18:00:00.000000+00:00',9000000,'zig-computer:dotfiles','personal');
SQL

# mkconf <path> [key=value ...] — a full config with overrides applied last
# (the parser takes the LAST assignment, so overrides simply follow).
mkconf() {
  local out=$1; shift
  cat > "$out" <<CONF
repos=harnessd:$FIX/repos/harnessd,dotfiles:$FIX/repos/dotfiles
home_repo=dotfiles
week_reset_dow=3
week_reset_hour=0
tz_offset_hours=-7
tap=personal
weekly_cap_tokens=
zig_daytime_start_hour=8
zig_daytime_end_hour=22
zig_reserve_trailing_days=7
safety_margin_pct=20
budget_floor_tokens=150000
derive_freshness_hours=6
derive_min_spend_tokens=1000000
brake_5h_pct=85
window_start_hour=1
window_end_hour=6
max_consecutive_failures=3
default_model=sonnet
pico_host=pico
requests_db=/dev/null
CONF
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$out"; done
}

CONF="$FIX/marshal.conf"
mkconf "$CONF"

# --- the fixture taps.conf (dotfiles-5gob) --------------------------------
# mktaps <path> [extra lines...] — the production pool grammar with fixture
# config_dirs. The BASE fixture deliberately carries NO seat_home.marshal, so
# resolution falls through to rung 3 (marshal.conf tap=personal -> pool
# primary) and every pre-5gob budget case above keeps meaning what it meant.
# Cases that exercise the re-home write their own taps with the override.
mktaps() {
  local out=$1; shift
  cat > "$out" <<TAPS
order=primary,secondary,linearb
pool.primary.taps=primary,tick
pool.primary.config_dir=$FIX/cfg/primary
pool.primary.groups=primary,personal
pool.secondary.taps=secondary
pool.secondary.config_dir=$FIX/cfg/secondary
pool.secondary.groups=secondary
pool.linearb.taps=linearb
pool.linearb.config_dir=$FIX/cfg/linearb
pool.linearb.groups=linearb,work
TAPS
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$out"; done
}
TAPS="$FIX/taps.conf"
mktaps "$TAPS"

# A freeze stub, both ways.
cat > "$FIX/bin/freeze-clear" <<'F'
#!/bin/bash
echo "frozen: no"
echo "DEMESNE_FREEZE_RESULT=status-unfrozen"
F
cat > "$FIX/bin/freeze-active" <<'F'
#!/bin/bash
echo "frozen: yes (since 2026-08-09)"
echo "DEMESNE_FREEZE_RESULT=status-frozen"
F
chmod +x "$FIX/bin/freeze-clear" "$FIX/bin/freeze-active"

export MARSHAL_NOW="2026-08-09T06:00:00Z"
export MARSHAL_FREEZE_SCRIPT="$FIX/bin/freeze-clear"
export MARSHAL_BV_BIN="$FIX/bin/no-such-bv"
export HARNESS_STATE_DIR="$FIX/state"
export MARSHAL_SQL_CMD="sqlite3 $DB"
export MARSHAL_CONF="$CONF"
export MARSHAL_LEDGER="$FIX/state/drain-ledger.jsonl"
export MARSHAL_POST_LIB="$FIX/no-such-post.sh"
export MARSHAL_TAPS_CONF="$TAPS"
export MARSHAL_HOME="$FIX/home"
# CLAUDE_CONFIG_DIR is the FIRST rung of pool resolution and it is a REAL
# variable in any live agent session — a suite that inherited it would resolve
# a different pool on Zig's box than in CI. Cleared here, set per case.
unset CLAUDE_CONFIG_DIR

run() { bash "$SCRIPT" "$@" 2>/dev/null; }
run_err() { bash "$SCRIPT" "$@" 2>&1; }

echo "=== BUDGET ================================================================"

# --- T3 the derivation, against the fixture db ----------------------------
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DB" run budget --weekly-cap 10000000)
J=$(plan_json "$OUT")
eq  "T3.1 budget spent_this_window is window-bounded and tap-filtered" "$(jq_py "$J" 'd["spent_this_window"]')" "1000000"
eq  "T3.2 budget days_to_reset from the weekly window"                 "$(jq_py "$J" 'd["days_to_reset"]')"      "4"
eq  "T3.3 budget weekly_remaining"                                     "$(jq_py "$J" 'd["weekly_remaining"]')"   "9000000"
eq  "T3.4 budget nightly_share"                                        "$(jq_py "$J" 'd["nightly_share"]')"      "2250000"
eq  "T3.5 budget_tokens = (share - reserve) * (1 - margin)"            "$(jq_py "$J" 'd["budget_tokens"]')"      "1720000"
assert_verdict "T3.6 budget verdict discipline" "$OUT" "MARSHAL_BUDGET=" '^MARSHAL_BUDGET=1720000 status=computed$'

# --- T3b THE RESERVE IS LOAD-BEARING -------------------------------------
# Widen the daytime window and the 02:00-local row joins the reserve, which
# must move the budget DOWN by exactly the reserve delta. This is the case
# the budget-ignores-reserve mutant has to die on: without the subtraction
# both configs produce the same number, and the number looks perfectly sane.
mkconf "$FIX/conf-allday" zig_daytime_start_hour=0 zig_daytime_end_hour=24
OUT=$(MARSHAL_CONF="$FIX/conf-allday" run budget --weekly-cap 10000000)
J=$(plan_json "$OUT")
eq  "T3b.1 the daytime window bounds what counts as Zig's spend" \
    "$(jq_py "$J" 'd["zig_daytime_spend_trailing"]')" "1000000"
eq  "T3b.2 reserve = daytime spend / trailing days (1000000/7)" \
    "$(jq_py "$J" 'd["zig_daytime_reserve"]')" "142857"
eq  "T3b.3 the reserve is SUBTRACTED before the margin"  "$(jq_py "$J" 'd["budget_before_margin"]')" "2107143"
eq  "T3b.4 and the budget moves with it"                 "$(jq_py "$J" 'd["budget_tokens"]')"        "1685714"

# margin=0 isolates the reserve term completely: budget == share - reserve
mkconf "$FIX/conf-nomargin" safety_margin_pct=0
OUT=$(MARSHAL_CONF="$FIX/conf-nomargin" run budget --weekly-cap 10000000)
eq  "T3b.5 with no margin the budget IS share minus reserve" \
    "$(jq_py "$(plan_json "$OUT")" 'd["budget_tokens"]')" "2150000"

# the trailing window bounds the reserve's INPUT as well as its divisor
mkconf "$FIX/conf-trail1" zig_reserve_trailing_days=1
eq  "T3b.6 a 1-day trailing window sees only the last day's spend" \
    "$(jq_py "$(plan_json "$(MARSHAL_CONF="$FIX/conf-trail1" run budget --weekly-cap 10000000)")" 'd["zig_daytime_spend_trailing"]')" "0"

echo "=== DEGRADE ==============================================================="

# --- T15 the db is unreachable -> the FLOOR, and it says why --------------
OUT=$(MARSHAL_SQL_CMD="false" run budget --weekly-cap 10000000)
assert_verdict "T15.1 unreachable db degrades to the floor" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=db-unreachable$'
eq "T15.2 degraded budget_tokens IS the floor, never a large number" \
   "$(jq_py "$(plan_json "$OUT")" 'd["budget_tokens"]')" "150000"

# --- unset cap tries DERIVED mode (dw3r); with no observation on record it
# still degrades honestly -- a cap is never invented, only derived or refused.
OUT=$(run budget)
assert_verdict "T15b.1 unset cap + no observation degrades (never an invented cap)" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-no-observation$'
eq "T15b.2 a degraded run still reports MEASURED spend" \
   "$(jq_py "$(plan_json "$OUT")" 'd["spent_this_window"]')" "1000000"

# --- T3e (dotfiles-iez1): 'tick' is a jail PROFILE of `personal`, not a tap
# of its own -- group='tick' rows count as personal spend, and a schedule's
# own `tap: tick` is no longer a real tap value; it degrades honestly rather
# than silently matching nothing. Isolated fixture db so this doesn't disturb
# the shared $DB's row set every other BUDGET case above asserts against.
DB2="$FIX/requests-tick.db"
sqlite3 "$DB2" <<'SQL'
CREATE TABLE request_logs (
  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, total_tokens INTEGER,
  agentgateway_user TEXT, agentgateway_group TEXT);
INSERT INTO request_logs VALUES
 ('a','2026-08-06T18:00:00.000000+00:00',300000,'zig-computer:dotfiles','personal'),
 ('t','2026-08-07T18:00:00.000000+00:00',500000,'zig-computer:dive','tick'),
 ('d','2026-08-06T18:00:00.000000+00:00',5000000,'zig-computer:linearb','work');
SQL

OUT=$(MARSHAL_SQL_CMD="sqlite3 $DB2" run budget --weekly-cap 10000000)
eq "T3e.1 group='tick' rows count toward the personal tap (dotfiles-iez1)" \
   "$(jq_py "$(plan_json "$OUT")" 'd["spent_this_window"]')" "800000"

# `tap: tick` still refuses to resolve under the epoch-3 pool ladder (5gob):
# tick is a jail PROFILE of primary's account, and a schedule that names it as
# a tap of its own is a config error that must be LOUD. The vocabulary moved
# from unknown-tap: to unknown-pool: — the pool is what gets metered now.
mkconf "$FIX/conf-tick-tap" tap=tick
OUT=$(MARSHAL_CONF="$FIX/conf-tick-tap" MARSHAL_SQL_CMD="sqlite3 $DB2" run budget --weekly-cap 10000000)
assert_verdict "T3e.2 tap: tick in config degrades -- tick is a profile, not a tap" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=unknown-pool:tick$'

# --- T18 the config parser refuses anything that is not key=value ---------
printf 'repos=x:%s\nevil=$(touch %s/pwned)\n' "$FIX/repos/harnessd" "$FIX" > "$FIX/conf-evil"
OUT=$(MARSHAL_CONF="$FIX/conf-evil" run_err budget --weekly-cap 10)
assert_verdict "T18.1 a config line that is not key=value is refused" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=0 reason=bad-config$'
if [ -e "$FIX/pwned" ]; then bad "T18.2 config is DATA" "the config executed"; else ok "T18.2 config is DATA, never executed"; fi

echo "=== DERIVED CAP (dotfiles-dw3r) ==========================================="

# mkdrvdb <path> <obs_started_at> <attrs_json> — a fixture db with a KNOWN
# spend shape (3,000,000 in-window personal; a work row excluded) plus one
# observation row carrying the given attributes_json (0 tokens, so the spend
# arithmetic stays untouched). The attrs mirror the real capture byte-for-byte:
# dotted keys, STRING values ("0.60").
mkdrvdb() {
  local db=$1 obs_ts=$2 attrs=$3
  rm -f "$db"
  sqlite3 "$db" <<SQL
CREATE TABLE request_logs (
  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, total_tokens INTEGER,
  agentgateway_user TEXT, agentgateway_group TEXT, attributes_json TEXT);
INSERT INTO request_logs (id,started_at,total_tokens,agentgateway_user,agentgateway_group) VALUES
 ('a','2026-08-06T18:00:00.000000+00:00',1500000,'zig-computer:dotfiles','personal'),
 ('b','2026-08-07T18:00:00.000000+00:00',1500000,'zig-computer:dotfiles','personal'),
 ('w','2026-08-06T18:00:00.000000+00:00',5000000,'zig-computer:linearb','work');
INSERT INTO request_logs VALUES
 ('o','$obs_ts',0,'zig-computer:marshal','personal','$attrs');
SQL
}

# --- TD1 the derivation, with numbers a reader can re-derive by hand -------
#   spend = 3,000,000; u7d = "0.60" -> cap_est = 5,000,000 (Fraction-exact:
#   float 3000000/0.6 is 4999999.99..). remaining = 2,000,000; days = 4 ->
#   share = 500,000. daytime trailing = 3,000,000 -> reserve = 428,571 ->
#   raw = 71,429 -> 20% margin -> 57,143. obs 04:00Z vs now 06:00Z -> 2.0h.
DRV="$FIX/requests-derive.db"
mkdrvdb "$DRV" '2026-08-09T04:00:00.000000+00:00' '{"anthropic.ratelimit.5h":"0.57","anthropic.ratelimit.7d":"0.60"}'
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DRV" run budget)
J=$(plan_json "$OUT")
eq "TD1.1 derived: spend is the same window-bounded, tap-filtered sum" "$(jq_py "$J" 'd["spent_this_window"]')" "3000000"
eq "TD1.2 derived: cap_est = spend / u7d, exact"                       "$(jq_py "$J" 'd["weekly_cap_tokens"]')" "5000000"
eq "TD1.3 derived: the EXISTING pipeline runs on cap_est"              "$(jq_py "$J" 'd["weekly_remaining"]')" "2000000"
eq "TD1.4 derived: nightly share"                                      "$(jq_py "$J" 'd["nightly_share"]')" "500000"
eq "TD1.5 derived: the reserve still bites"                            "$(jq_py "$J" 'd["budget_before_margin"]')" "71429"
eq "TD1.6 derived: budget_tokens"                                      "$(jq_py "$J" 'd["budget_tokens"]')" "57143"
eq "TD1.7 derived: cap source is named"                                "$(jq_py "$J" 'd["weekly_cap_source"]')" "derived"
eq "TD1.8 derived: both utilizations ride into the JSON verbatim" \
   "$(jq_py "$J" 'd["utilization_7d"]+"/"+d["utilization_5h"]')" "0.60/0.57"
eq "TD1.10 derived: the METERED POOL rides into the JSON, with the rung that resolved it" \
   "$(jq_py "$J" 'd["pool"]+"/"+d["pool_source"]')" "primary/conf-tap-epoch2"
eq "TD1.11 derived: the 5h brake says it was enforced on a fresh observation" \
   "$(jq_py "$J" 'd["brake_5h_state"]')" "enforced"
assert_verdict "TD1.9 the derived verdict carries every input (re-derivable by hand)" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=57143 status=derived reason=derived-cap\(pool=primary,u7d=0\.60,u5h=0\.57,spend=3000000,cap_est=5000000,obs_age_h=2\.0\)$'

# --- TD2 an EXPLICIT cap outranks derivation, on both routes ---------------
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DRV" run budget --weekly-cap 10000000)
J=$(plan_json "$OUT")
eq "TD2.1 --weekly-cap wins over a fresh observation" "$(jq_py "$J" 'd["status"]')" "computed"
eq "TD2.2 and the source says flag"                   "$(jq_py "$J" 'd["weekly_cap_source"]')" "flag"
mkconf "$FIX/conf-capset" weekly_cap_tokens=10000000
OUT=$(MARSHAL_CONF="$FIX/conf-capset" MARSHAL_SQL_CMD="sqlite3 $DRV" run budget)
eq "TD2.3 a config cap wins over a fresh observation" "$(jq_py "$(plan_json "$OUT")" 'd["weekly_cap_source"]')" "config"

# --- TD3 staleness is the knob's call: the SAME 2.0h observation, refused --
mkconf "$FIX/conf-fresh1" derive_freshness_hours=1
OUT=$(MARSHAL_CONF="$FIX/conf-fresh1" MARSHAL_SQL_CMD="sqlite3 $DRV" run budget)
assert_verdict "TD3 a stale observation floors, and says how stale" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-stale-observation\(obs_age_h=2\.0,limit_h=1\)$'

# --- TD4 the 5h BRAKE floors the night whatever the week says --------------
DRVB="$FIX/requests-derive-brake.db"
mkdrvdb "$DRVB" '2026-08-09T04:00:00.000000+00:00' '{"anthropic.ratelimit.5h":"0.90","anthropic.ratelimit.7d":"0.60"}'
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DRVB" run budget)
assert_verdict "TD4 5h brake -> the floor, regardless of the weekly math" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=brake-5h\(u5h=0\.90,brake_pct=85\)$'

# --- TD5 an implausible u7d (division-blowup territory) --------------------
DRVI="$FIX/requests-derive-implausible.db"
mkdrvdb "$DRVI" '2026-08-09T04:00:00.000000+00:00' '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.01"}'
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DRVI" run budget)
assert_verdict "TD5 u7d <= 0.02 floors as implausible" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-implausible-utilization\(u7d=0\.01\)$'

# --- TD6 an unparseable value floors, naming the bytes it refused ----------
DRVG="$FIX/requests-derive-garbage.db"
mkdrvdb "$DRVG" '2026-08-09T04:00:00.000000+00:00' '{"anthropic.ratelimit.5h":"0.57","anthropic.ratelimit.7d":"garbage"}'
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DRVG" run budget)
assert_verdict "TD6 an unparseable observation floors" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-unparseable\(u7d=garbage\)$'

# --- TD7 a tiny numerator makes cap_est noise: min-spend floors ------------
mkconf "$FIX/conf-minspend" derive_min_spend_tokens=5000000
OUT=$(MARSHAL_CONF="$FIX/conf-minspend" MARSHAL_SQL_CMD="sqlite3 $DRV" run budget)
assert_verdict "TD7 spend below derive_min_spend_tokens floors" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-low-spend\(spend=3000000,min=5000000\)$'

# --- TD8 a db the observation query cannot answer (schema without
# attributes_json -- $DB2 predates the 7qi7 capture) floors as a db error,
# never as "no data". sqlite3 exits 1 on the parse error (measured).
OUT=$(MARSHAL_SQL_CMD="sqlite3 $DB2" run budget)
assert_verdict "TD8 an unanswerable observation query floors as derive-db-error" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-db-error$'

echo "=== POOL RESOLUTION (dotfiles-5gob) ======================================="

# The marshal was re-homed onto the fresh `secondary` pool and the budget verb
# could not see it: it read `tap` out of marshal.conf and metered a pool the
# process was not running on. These cases walk the whole ladder, in order.
mkdir -p "$FIX/cfg/primary" "$FIX/cfg/secondary" "$FIX/cfg/linearb"

pool_of() { # pool_of <budget stdout> -> "<pool>/<source>"
  jq_py "$(plan_json "$1")" 'str(d["pool"])+"/"+str(d["pool_source"])'
}

# --- TP1 rung 1: the LAUNCH ENV wins. CLAUDE_CONFIG_DIR is what the identity
# wrapper fixes at exec, so it is what the process IS using — derived from what
# runs, never asserted from a roster.
OUT=$(CLAUDE_CONFIG_DIR="$FIX/cfg/secondary" run budget --weekly-cap 10000000)
eq "TP1.1 CLAUDE_CONFIG_DIR resolves the pool through taps.conf config_dir" \
   "$(pool_of "$OUT")" "secondary/env-config-dir"
OUT=$(CLAUDE_CONFIG_DIR="$FIX/cfg/secondary/" run budget --weekly-cap 10000000)
eq "TP1.2 a trailing slash is the same directory" "$(pool_of "$OUT")" "secondary/env-config-dir"

# --- TP2 rung 2: taps.conf seat_home.<seat> — Zig's re-home ruling.
mktaps "$FIX/taps-rehome" seat_home.marshal=secondary
OUT=$(MARSHAL_TAPS_CONF="$FIX/taps-rehome" run budget --weekly-cap 10000000)
eq "TP2.1 seat_home.marshal re-homes the drain with no config edit at all" \
   "$(pool_of "$OUT")" "secondary/seat-home"
OUT=$(MARSHAL_TAPS_CONF="$FIX/taps-rehome" CLAUDE_CONFIG_DIR="$FIX/cfg/linearb" run budget --weekly-cap 10000000)
eq "TP2.2 the launch env OUTRANKS seat_home (what runs beats what is ruled)" \
   "$(pool_of "$OUT")" "linearb/env-config-dir"
# A seat_home naming a pool that does not exist is a config error, and it is
# LOUD: falling through to the next rung would meter a pool nobody chose.
mktaps "$FIX/taps-badseat" seat_home.marshal=nosuchpool
OUT=$(MARSHAL_TAPS_CONF="$FIX/taps-badseat" run budget --weekly-cap 10000000)
assert_verdict "TP2.3 seat_home naming an unknown pool degrades, never falls through" "$OUT" \
  "MARSHAL_BUDGET=" '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=unknown-pool:nosuchpool$'
# `seat` selects WHICH override applies: a differently-named seat ignores it.
mkconf "$FIX/conf-seat-other" seat=consul
OUT=$(MARSHAL_CONF="$FIX/conf-seat-other" MARSHAL_TAPS_CONF="$FIX/taps-rehome" run budget --weekly-cap 10000000)
eq "TP2.4 seat_home.<seat> is keyed on the configured seat name" \
   "$(pool_of "$OUT")" "primary/conf-tap-epoch2"

# --- TP3 rung 3: marshal.conf `tap`, mapped epoch-2 -> pool.
OUT=$(run budget --weekly-cap 10000000)
eq "TP3.1 tap=personal maps to pool primary (epoch 2 -> epoch 3)" \
   "$(pool_of "$OUT")" "primary/conf-tap-epoch2"
mkconf "$FIX/conf-tap-work" tap=work
OUT=$(MARSHAL_CONF="$FIX/conf-tap-work" run budget --weekly-cap 10000000)
eq "TP3.2 tap=work maps to pool linearb" "$(pool_of "$OUT")" "linearb/conf-tap-epoch2"
mkconf "$FIX/conf-tap-sec" tap=secondary
OUT=$(MARSHAL_CONF="$FIX/conf-tap-sec" run budget --weekly-cap 10000000)
eq "TP3.3 an epoch-3 pool NAME in tap= is taken as-is" "$(pool_of "$OUT")" "secondary/conf-tap"
# An unmatched CLAUDE_CONFIG_DIR is not a resolution: the ladder continues.
OUT=$(CLAUDE_CONFIG_DIR="$FIX/cfg/nowhere" run budget --weekly-cap 10000000)
eq "TP3.4 a CLAUDE_CONFIG_DIR matching no pool falls through, it does not guess" \
   "$(pool_of "$OUT")" "primary/conf-tap-epoch2"

# --- TP4 nothing resolves -> the FLOOR, with a named reason. A budget metered
# against a pool nobody chose is wrong in both directions at once.
mkconf "$FIX/conf-tap-bogus" tap=nosuchtap
OUT=$(MARSHAL_CONF="$FIX/conf-tap-bogus" run budget --weekly-cap 10000000)
assert_verdict "TP4.1 an unresolvable tap degrades to the floor, naming it" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=unknown-pool:nosuchtap$'
eq "TP4.2 the degraded row carries a NULL pool, never a default" \
   "$(jq_py "$(plan_json "$OUT")" 'str(d["pool"])')" "None"
OUT=$(MARSHAL_TAPS_CONF="$FIX/no-such-taps.conf" run budget --weekly-cap 10000000)
assert_verdict "TP4.3 no taps.conf at all degrades, it does not fall back to a literal" "$OUT" \
  "MARSHAL_BUDGET=" '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=taps-conf-unreadable$'

echo "=== EPOCH-3 PREDICATES (the MIXED SWEEP, dotfiles-5gob) ==================="

# THE DEFECT THIS SECTION GUARDS. Epoch 3 renamed the taps (personal->primary,
# work->linearb) and added a genuinely new pool (secondary), and the epoch-2
# `personal` predicate's catch-all excluded only ('personal','work','tick') —
# so EVERY epoch-3 row fell through it and counted as personal spend. The
# fixture below carries all three epochs at once; the old predicate sweeps
# 2,250,000 of it into primary, the generated one counts 650,000.
DB3="$FIX/requests-epoch3.db"
sqlite3 "$DB3" <<'SQL'
CREATE TABLE request_logs (
  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, total_tokens INTEGER,
  agentgateway_user TEXT, agentgateway_group TEXT, attributes_json TEXT);
INSERT INTO request_logs (id,started_at,total_tokens,agentgateway_user,agentgateway_group) VALUES
 ('p3','2026-08-06T18:00:00.000000+00:00',200000,'zig-computer:dotfiles','primary'),
 ('p2','2026-08-06T18:00:00.000000+00:00',300000,'zig-computer:dotfiles','personal'),
 ('tk','2026-08-07T18:00:00.000000+00:00',100000,'zig-computer:dive','tick'),
 ('h1','2026-08-07T18:00:00.000000+00:00', 50000,'dive:1','zig-computer'),
 ('hw','2026-08-07T18:00:00.000000+00:00',400000,'work:di-monday','zig-computer'),
 ('s1','2026-08-08T09:00:00.000000+00:00',700000,'zig-computer:marshal','secondary'),
 ('l3','2026-08-06T18:00:00.000000+00:00',900000,'zig-computer:linearb','linearb'),
 ('l2','2026-08-06T18:00:00.000000+00:00',1100000,'zig-computer:linearb','work');
SQL

spend_of() { jq_py "$(plan_json "$1")" 'd["spent_this_window"]'; }

SPEND_PRIMARY=$(spend_of "$(MARSHAL_SQL_CMD="sqlite3 $DB3" run budget --weekly-cap 10000000)")
eq "TE1.1 primary counts BOTH epochs of its own names, plus the tick jail (200k+300k+100k) and the epoch-1 hostname row (50k) -- and NOTHING from secondary/linearb" \
   "$SPEND_PRIMARY" "650000"
SPEND_SECONDARY=$(spend_of "$(MARSHAL_CONF="$FIX/conf-tap-sec" MARSHAL_SQL_CMD="sqlite3 $DB3" run budget --weekly-cap 10000000)")
eq "TE1.2 secondary sees ONLY its own group -- a fresh pool never inherits spend it did not make" \
   "$SPEND_SECONDARY" "700000"
SPEND_LINEARB=$(spend_of "$(MARSHAL_CONF="$FIX/conf-tap-work" MARSHAL_SQL_CMD="sqlite3 $DB3" run budget --weekly-cap 10000000)")
eq "TE1.3 linearb is exact group-list membership across epochs (linearb 900k + work 1100k)" \
   "$SPEND_LINEARB" "2000000"
# The three MEASURED sums must PARTITION the log against the db's own total:
# nothing counted twice, nothing invented. The only unattributed row is the
# epoch-1 `work:` one (400k) — the legacy catch-all excludes it on purpose
# rather than handing LinearB's spend to primary, and epoch-3 linearb is
# group-matched, so it has no home. Erring toward unattributed is the
# conservative direction (it shrinks cap_est and remaining together).
TOTAL3=$(sqlite3 "$DB3" "SELECT COALESCE(SUM(total_tokens),0) FROM request_logs;")
eq "TE1.4 the three pools partition the whole log against its own total" \
   "$(( SPEND_PRIMARY + SPEND_SECONDARY + SPEND_LINEARB + 400000 ))" "$TOTAL3"

echo "=== CROSS-POOL CAP TRANSFER (dotfiles-5gob / decision dotfiles-bg71) ======"

# mkxferdb <path> <primary-spend> <primary-attrs> <secondary-spend> <secondary-attrs>
# A two-pool fixture: primary carries history (and the observation the cap is
# derived from), secondary is the fresh pool the marshal was re-homed onto.
# An EMPTY attrs argument means the pool has no observation at all — the real
# shape of a pool nothing has run on.
mkxferdb() {
  local db=$1 pspend=$2 pattrs=$3 sspend=$4 sattrs=$5
  rm -f "$db"
  sqlite3 "$db" <<SQL
CREATE TABLE request_logs (
  id TEXT PRIMARY KEY, started_at TEXT NOT NULL, total_tokens INTEGER,
  agentgateway_user TEXT, agentgateway_group TEXT, attributes_json TEXT);
INSERT INTO request_logs (id,started_at,total_tokens,agentgateway_user,agentgateway_group) VALUES
 ('p','2026-08-06T18:00:00.000000+00:00',$pspend,'zig-computer:dotfiles','primary'),
 ('s','2026-08-06T18:00:00.000000+00:00',$sspend,'zig-computer:marshal','secondary');
SQL
  [ -n "$pattrs" ] && sqlite3 "$db" "INSERT INTO request_logs VALUES ('po','2026-08-09T04:00:00.000000+00:00',0,'zig-computer:dotfiles','primary','$pattrs');"
  [ -n "$sattrs" ] && sqlite3 "$db" "INSERT INTO request_logs VALUES ('so','2026-08-09T04:00:00.000000+00:00',0,'zig-computer:marshal','secondary','$sattrs');"
  return 0
}

# The re-homed shape: taps.conf says secondary, marshal.conf names primary as
# the same-tier reference.
mkconf "$FIX/conf-xfer" cap_reference_pool=primary
XFER="$FIX/requests-xfer.db"

# --- TT1 THE TRANSFER. secondary is empty and has never carried an
# observation; primary has 3,000,000 at u7d=0.60 -> cap_est 5,000,000. The cap
# crosses, the SPEND does not: remaining 5,000,000 / 4 days = 1,250,000, no
# daytime spend on secondary to reserve, 20% margin -> 1,000,000.
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
J=$(plan_json "$OUT")
eq "TT1.1 the LAUNCH pool is what is metered"        "$(pool_of "$OUT")" "secondary/seat-home"
eq "TT1.2 spend stays the launch pool's (fresh = 0)" "$(jq_py "$J" 'd["spent_this_window"]')" "0"
eq "TT1.3 the CAP is the reference pool's estimate"  "$(jq_py "$J" 'd["weekly_cap_tokens"]')" "5000000"
eq "TT1.4 the cap source names the transfer"         "$(jq_py "$J" 'd["weekly_cap_source"]')" "transfer"
eq "TT1.5 and the reference pool is named in the row" "$(jq_py "$J" 'd["cap_reference_pool"]')" "primary"
eq "TT1.6 the reference pool's spend rides along (the numerator)" \
   "$(jq_py "$J" 'd["cap_reference_spend_this_window"]')" "3000000"
eq "TT1.7 the budget the fresh pool actually funds"  "$(jq_py "$J" 'd["budget_tokens"]')" "1000000"
assert_verdict "TT1.8 the transfer verdict names BOTH pools and every input (re-derivable by hand)" "$OUT" \
  "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=1000000 status=derived reason=derived-cap-transfer\(pool=secondary,cap_from=primary,u7d=0\.60,spend=3000000,cap_est=5000000,obs_age_h=2\.0\)$'

# --- TT2 the reference is underivable TOO -> the floor, honestly, naming both
# refusals. A transfer that fell back to a guess would be the invented cap this
# whole mechanism exists to avoid.
mkxferdb "$XFER" 500000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
assert_verdict "TT2.1 an underivable reference denies the transfer, naming both reasons" "$OUT" \
  "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-transfer-denied\(pool=secondary,cap_from=primary,launch=derive-no-observation,ref=derive-low-spend\(spend=500000,min=1000000\)\)$'

# the reference has history but its observation is STALE -> still denied
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
mkconf "$FIX/conf-xfer-fresh1" cap_reference_pool=primary derive_freshness_hours=1
OUT=$(MARSHAL_CONF="$FIX/conf-xfer-fresh1" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
has "TT2.2 a STALE reference observation denies the transfer (a cap is never guessed forward)" \
    "$(last_line "$OUT")" "ref=derive-stale-observation(obs_age_h=2.0,limit_h=1)"

# --- TT3 no reference configured -> the launch pool's own reason stands,
# exactly as it did before this bead (the dw3r contract, unchanged).
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
mkconf "$FIX/conf-noref"
OUT=$(MARSHAL_CONF="$FIX/conf-noref" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
assert_verdict "TT3.1 with cap_reference_pool unset the pre-5gob degrade is untouched" "$OUT" \
  "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=derive-no-observation$'
# reference == launch pool is not a transfer either: there is nothing to
# transfer FROM, and pretending otherwise would derive a pool's cap from itself.
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_SQL_CMD="sqlite3 $DRV" run budget)
eq "TT3.2 reference == launch pool is not a transfer" \
   "$(jq_py "$(plan_json "$OUT")" 'd["weekly_cap_source"]')" "derived"

# --- TT4 an EXPLICIT cap still outranks everything, transfer included
# (unchanged dw3r contract; brake-on-explicit-cap is dotfiles-vosr's scope).
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget --weekly-cap 8000000)
J=$(plan_json "$OUT")
eq "TT4.1 --weekly-cap wins over the transfer"  "$(jq_py "$J" 'd["weekly_cap_source"]')" "flag"
eq "TT4.2 and it is the flag's number that budgets" "$(jq_py "$J" 'd["weekly_cap_tokens"]')" "8000000"

echo "=== THE 5h BRAKE ON A RE-HOMED POOL (dotfiles-5gob) ======================="

# --- TB1 THE COLD-POOL WAIVER. A pool with no fresh observation AND less than
# derive_min_spend_tokens of weekly spend is PROVABLY cold: there is no hot 5h
# window to protect, and no observation because nothing has run on it. The
# waiver is NAMED in the row — a silent waiver would be indistinguishable from
# a brake that never ran.
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 0 ''
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
J=$(plan_json "$OUT")
eq "TB1.1 a provably cold launch pool waives the 5h brake" \
   "$(jq_py "$J" 'd["brake_5h_state"]')" "waived-cold-pool"
eq "TB1.2 and the waiver says WHY, with the numbers that proved it" \
   "$(jq_py "$J" 'd["brake_5h_reason"]')" "brake-waived-cold-pool(spend=0,min=1000000,obs_age_h=none)"

# --- TB2 THE BRAKE STILL BITES ON THE LAUNCH POOL. Same fresh pool, but this
# time it HAS a reading and the 5h window is hot: the transfer must not paper
# over it. This is the case a transfer that skipped the brake would fail open.
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' \
         0 '{"anthropic.ratelimit.5h":"0.90","anthropic.ratelimit.7d":"0.03"}'
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
assert_verdict "TB2.1 a hot 5h window on the LAUNCH pool floors the night, transfer or not" "$OUT" \
  "MARSHAL_BUDGET=" '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=brake-5h\(u5h=0\.90,brake_pct=85\)$'

# --- TB3 NO FRESH READING ON A POOL WITH REAL SPEND -> DEGRADE. Never fail
# open: unmeasured is not the same as cold, and only coldness is provable.
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' 2000000 ''
OUT=$(MARSHAL_CONF="$FIX/conf-xfer" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
assert_verdict "TB3.1 real spend and no reading degrades -- unmeasured never means unlimited" "$OUT" \
  "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=brake-no-fresh-observation\(obs_age_h=none,limit_h=6,spend=2000000\)$'

# a STALE reading on a pool with real spend is not a reading either
mkxferdb "$XFER" 3000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}' \
         2000000 '{"anthropic.ratelimit.5h":"0.10","anthropic.ratelimit.7d":"0.60"}'
OUT=$(MARSHAL_CONF="$FIX/conf-xfer-fresh1" MARSHAL_TAPS_CONF="$FIX/taps-rehome" MARSHAL_SQL_CMD="sqlite3 $XFER" run budget)
has "TB3.2 a stale reading on a spending pool is refused, naming its age" \
    "$(last_line "$OUT")" "derive-stale-observation(obs_age_h=2.0,limit_h=1)"

echo "=== SELECTION ============================================================="

# The bead fixtures: one of every eligibility shape.
mkbead marked-1   "## Context
A crisp, cold-buildable bead.

Fleet: yes"
mkbead marked-2   "Another one.

Fleet: yes"
mkbead marked-opus "Needs the big model.

Fleet: yes
Fleet-Model: opus"
mkbead unmarked-1 "## Context
No marker anywhere. Ready, well-formed, and NOT the drain's."
mkbead human-1    "A bead for Zig.

Fleet: yes"
mkbead outward-1  "Touches the world.

Fleet: yes
Outward: yes"
mkbead decision-1 "## Context
A decision bead that someone marked by mistake.

Fleet: yes"
mkbead spec-1     "A spec.

Fleet: yes"
mkbead yesterday-1 "Grammar bait.

Fleet: yesterday"
mkbead home-1     "In the marshal's own repo.

Fleet: yes"
mkbead notoptin-1 "Marked, but its repo never opted in.

Fleet: yes"

mksched harnessd \
  "marked-1|task|task: a drainable one" \
  "unmarked-1|task|task: nobody marked this" \
  "human-1|task|human: ask Zig about the cutover" \
  "outward-1|task|task: publish the thing" \
  "decision-1|decision|decision: which backend" \
  "spec-1|spec|spec: the next subsystem" \
  "yesterday-1|task|task: fleet: yesterday" \
  "marked-opus|feature|feature: the big one" \
  "marked-2|bug|bug: a second drainable one"
mksched dotfiles "home-1|task|task: in the home repo"
mksched notoptin "notoptin-1|task|task: not on the list"

OUT=$(run plan --budget 1000000 --limit 10)
J=$(plan_json "$OUT")
PICKS=$(jq_py "$J" '" ".join(p["bead"] for p in d["picks"])')
REFUSED=$(jq_py "$J" '" ".join(p["bead"]+":"+p["reason"] for p in d["refused"])')

assert_verdict "T0.1 plan verdict discipline" "$OUT" "MARSHAL_PLAN_RESULT=" '^MARSHAL_PLAN_RESULT=planned:[0-9]+$'
has     "T1.1 an UNMARKED ready bead is refused with a reason" "$REFUSED" "unmarked-1:unmarked"
not_has "T1.2 an UNMARKED ready bead is never picked"          "$PICKS"   "unmarked-1"
has     "T2.1 a human:-titled bead is skipped even when marked" "$REFUSED" "human-1:human-tagged"
not_has "T2.2 a human:-titled bead is never picked"             "$PICKS"   "human-1"
has     "T14.1 a DECISION bead with Fleet: yes is REFUSED (type outranks marker)" \
        "$REFUSED" "decision-1:type-outranks-marker(decision)"
not_has "T14.2 a marked decision bead is never picked"          "$PICKS"   "decision-1"
has     "T14b a marked SPEC bead is refused the same way"     "$REFUSED" "spec-1:type-outranks-marker(spec)"
has     "T16.1 an outward-marked bead is skipped unconditionally" "$REFUSED" "outward-1:outward-marked"
not_has "T16.2 an outward-marked bead is never picked"          "$PICKS"   "outward-1"
# (no backticks in a case name: inside a double-quoted argument they are
# COMMAND SUBSTITUTION, and this one really did run `Fleet: yesterday` as a
# command — harmless noise here, arbitrary execution in the general case, and
# it ate the words out of the printed name either way.)
has     "T1b a fleet marker reading 'yesterday' is well-formed but NOT true" \
        "$REFUSED" "yesterday-1:unmarked"
has     "T1c.1 the marked beads ARE picked"                     "$PICKS"   "marked-1"
has     "T1c.2 the marked beads ARE picked (2)"                 "$PICKS"   "marked-2"
eq      "T22 a repo that never opted in contributes nothing" \
        "$(printf '%s' "$PICKS$REFUSED" | grep -c notoptin-1 || true)" "0"

eq "T17.1 Fleet-Model: opus is honoured" \
   "$(jq_py "$J" '[p["model"] for p in d["picks"] if p["bead"]=="marked-opus"][0]')" "opus"
eq "T17.2 an unmarked model falls back to the config default" \
   "$(jq_py "$J" '[p["model"] for p in d["picks"] if p["bead"]=="marked-1"][0]')" "sonnet"

eq "T12.1 a FOREIGN repo's picks serialize (one writer at a time)" \
   "$(jq_py "$J" '" ".join(p["lane"]+"/"+str(p["wave"]) for p in d["picks"] if p["repo"]=="harnessd")')" \
   "serial:harnessd/1 serial:harnessd/2 serial:harnessd/3"
eq "T12.2 the HOME repo swarms (Land-Rush, worktree isolation covers it)" \
   "$(jq_py "$J" '" ".join(p["lane"]+"/"+str(p["wave"]) for p in d["picks"] if p["repo"]=="dotfiles")')" \
   "home:parallel/1"

eq "T0.2 the scheduler rationale rides into the plan (the audit trail)" \
   "$(jq_py "$J" '[len(p["rationale"]) for p in d["picks"] if p["bead"]=="marked-1"][0]')" "2"
has "T0.3 the plan names a verify command per pick" \
    "$(jq_py "$J" 'd["picks"][0]["verify_cmd"]')" "verify --repo"
has "T0.4 the absent post spool is NOTED, not silently skipped" \
    "$(jq_py "$J" 'd["mail"]')" "post-spool-absent"

# --- T9 / dotfiles-9060: the molt pacing in the plan is the DERIVED one ----
eq "T9.1 the plan publishes the molt pacing threshold" "$(jq_py "$J" 'd["molt_pacing_pct"]')" "50"
eq "T9.2 the plan publishes the backstop it was derived from" "$(jq_py "$J" 'd["molt_backstop_pct"]')" "75"

echo "=== FREEZE + BUDGET GATES ================================================="

# --- T11 a frozen demesne means ZERO dispatches --------------------------
OUT=$(MARSHAL_FREEZE_SCRIPT="$FIX/bin/freeze-active" run plan --budget 1000000)
assert_verdict "T11.1 freeze -> the tick plans nothing" "$OUT" "MARSHAL_PLAN_RESULT=" '^MARSHAL_PLAN_RESULT=frozen$'
eq "T11.2 a frozen plan has an EMPTY pick list" \
   "$(jq_py "$(plan_json "$OUT")" 'len(d["picks"])')" "0"

# the marker file alone freezes, with no freeze script at all
touch "$FIX/state/demesne-freeze-active"
OUT=$(MARSHAL_FREEZE_SCRIPT="$FIX/bin/no-such-freeze" run plan --budget 1000000)
assert_verdict "T11b the freeze MARKER alone is enough" "$OUT" "MARSHAL_PLAN_RESULT=" '^MARSHAL_PLAN_RESULT=frozen$'
rm -f "$FIX/state/demesne-freeze-active"

# --- T3/R2: no budget, no dispatch ---------------------------------------
OUT=$(run plan --budget 0)
assert_verdict "T3c a zero budget dispatches nothing" "$OUT" "MARSHAL_PLAN_RESULT=" '^MARSHAL_PLAN_RESULT=no-budget$'

# --- an empty queue is a verdict, not an error ---------------------------
mksched harnessd "unmarked-1|task|task: nobody marked this"
mksched dotfiles "unmarked-1|task|task: nobody marked this"
OUT=$(run plan --budget 1000000)
assert_verdict "T0.5 empty queue is its own verdict" "$OUT" "MARSHAL_PLAN_RESULT=" '^MARSHAL_PLAN_RESULT=empty-queue$'
# restore the full fixture for anything after this point
mksched harnessd \
  "marked-1|task|task: a drainable one" \
  "marked-2|bug|bug: a second drainable one"
mksched dotfiles "home-1|task|task: in the home repo"

echo "=== LEDGER + R6 CONVERGENCE ==============================================="

LED="$FIX/state/drain-ledger.jsonl"
rm -f "$LED"

OUT=$(run record --night N1 --outcome night-start --reason "budget=1720000")
assert_verdict "T13.1 a ledger row is recorded" "$OUT" "MARSHAL_RECORD_RESULT=" '^MARSHAL_RECORD_RESULT=recorded streak=0$'
eq "T13.2 the ledger is JSONL, one row per event" "$(grep -c . "$LED")" "1"
eq "T13.3 the row carries the night" "$(jq_py "$(head -1 "$LED")" 'd["night"]')" "N1"

run record --night N1 --bead b1 --repo harnessd --outcome dispatched --model sonnet \
  --rank 3 --score 49 --rationale "P1 contributes 30 | 5 dependents contribute 15" >/dev/null
eq "T13.4 the scheduler rationale is preserved in the ledger" \
   "$(jq_py "$(sed -n 2p "$LED")" 'len(d["rationale"])')" "2"

OUT=$(run record --night N1 --bead b1 --repo harnessd --outcome merged --tokens 120000 \
       --evidence "suites green on main; sha 1a2b3c")
assert_verdict "T10.0 a merge resets the streak" "$OUT" "MARSHAL_RECORD_RESULT=" '^MARSHAL_RECORD_RESULT=recorded streak=0$'

# --- T10 three consecutive failures across DIFFERENT beads end the night ---
run record --night N1 --bead b2 --outcome dispatched >/dev/null
OUT=$(run record --night N1 --bead b2 --outcome failed --reason "builder returned red")
assert_verdict "T10.1 one failure -> continue" "$OUT" "MARSHAL_RECORD_RESULT=" '^MARSHAL_RECORD_RESULT=recorded streak=1$'
run record --night N1 --bead b3 --outcome dispatched >/dev/null
OUT=$(run record --night N1 --bead b3 --outcome failed)
assert_verdict "T10.2 two failures -> still converging" "$OUT" "MARSHAL_RECORD_RESULT=" '^MARSHAL_RECORD_RESULT=recorded streak=2$'
run record --night N1 --bead b4 --outcome dispatched >/dev/null
OUT=$(run record --night N1 --bead b4 --outcome failed)
assert_verdict "T10.3 THREE across different beads -> end the night" "$OUT" "MARSHAL_RECORD_RESULT=" \
  '^MARSHAL_RECORD_RESULT=three-strikes streak=3$'

# --- R6 the SAME bead twice -> park it, do not count it as a third strike --
rm -f "$LED"
run record --night N2 --bead b9 --outcome dispatched >/dev/null
run record --night N2 --bead b9 --outcome failed >/dev/null
run record --night N2 --bead b9 --outcome dispatched >/dev/null
OUT=$(run record --night N2 --bead b9 --outcome failed)
assert_verdict "T10.4 the same bead failing twice is a PARK, not a strike" "$OUT" "MARSHAL_RECORD_RESULT=" \
  '^MARSHAL_RECORD_RESULT=park-repeat-failure'

# --- T10b the night's tally is computed from the ledger, not remembered ---
OUT=$(run record --night N2 --outcome night-end --reason "three-strikes")
TALLY=$(jq_py "$(tail -1 "$LED")" 'json.dumps(d["tally"], sort_keys=True)')
has "T10b.1 night-end carries a tally computed off the ledger" "$TALLY" '"failed": 2'
has "T10b.2 the tally counts distinct attempted beads"         "$TALLY" '"attempted": 1'
has "T10b.3 the tally sums tokens"                             "$TALLY" '"tokens_spent": 0'

OUT=$(run record --outcome not-a-real-outcome)
assert_verdict "T13.5 an unknown outcome is refused, not silently logged" "$OUT" "MARSHAL_RECORD_RESULT=" \
  '^MARSHAL_RECORD_RESULT=failed-usage$'

echo "=== VERIFY (the guarded-merge assertions) ================================="

GR="$ROOT_T/gitrepo"
mkdir -p "$GR"
(
  cd "$GR" || exit 1
  git init -q -b main .
  git config user.email t@t; git config user.name t
  echo one > f; git add f; git commit -qm one
) >/dev/null 2>&1
BEFORE=$(git -C "$GR" rev-parse HEAD)
(
  cd "$GR" || exit 1
  git checkout -q -b worktree-agent-x
  echo two > f; git add f; git commit -qm two
  git checkout -q main
  git merge -q --no-edit worktree-agent-x
) >/dev/null 2>&1
AGENT_SHA=$(git -C "$GR" rev-parse worktree-agent-x)

OUT=$(run verify --repo "$GR" --bead b1 --before "$BEFORE" --agent-sha "$AGENT_SHA")
assert_verdict "T4.1 a real merge verifies" "$OUT" "MARSHAL_VERIFY_RESULT=" '^MARSHAL_VERIFY_RESULT=ok$'

AFTER=$(git -C "$GR" rev-parse HEAD)
OUT=$(run verify --repo "$GR" --bead b1 --before "$AFTER" --agent-sha "$AGENT_SHA")
assert_verdict "T4.2 a no-op merge ABORTS ('Already up to date' exits 0)" "$OUT" \
  "MARSHAL_VERIFY_RESULT=" '^MARSHAL_VERIFY_RESULT=abort-sha-unmoved$'

git -C "$GR" checkout -q worktree-agent-x
OUT=$(run verify --repo "$GR" --bead b1 --before "$BEFORE" --agent-sha "$AGENT_SHA")
assert_verdict "T4.3 verifying from the AGENT own branch aborts" "$OUT" \
  "MARSHAL_VERIFY_RESULT=" '^MARSHAL_VERIFY_RESULT=abort-wrong-branch$'
git -C "$GR" checkout -q main

OUT=$(run verify --repo "$GR" --bead b1 --before "$BEFORE" --agent-sha "$BEFORE~0^{commit}")
OUT=$(run verify --repo "$GR" --bead b1 --before "$BEFORE" --agent-sha 0000000000000000000000000000000000000000)
assert_verdict "T4.4 an agent commit that is not an ancestor aborts" "$OUT" \
  "MARSHAL_VERIFY_RESULT=" '^MARSHAL_VERIFY_RESULT=abort-not-ancestor$'

OUT=$(run verify --repo "$ROOT_T/not-a-repo" --bead b1 --before x --agent-sha y)
assert_verdict "T4.5 a non-repo aborts" "$OUT" "MARSHAL_VERIFY_RESULT=" '^MARSHAL_VERIFY_RESULT=abort-not-a-repo$'

echo "=== R10 / SAFETY: WHAT THE SCRIPT MAY NOT CONTAIN ========================="

# T5 — the deciding half must stay the deciding half. Every destructive verb
# belongs to the marshal SESSION under the guarded-merge sequence, where a
# human-legible refusal can stop it. A drain that grew hands would pass every
# other case in this file.
SRC=$(grep -vE '^\s*#' "$SCRIPT")
for verb in 'br close' 'br update --status' 'br create' 'git merge ' 'git push' \
            'worktree remove' 'git stash' 'pkill' 'kill -9'; do
  case "$SRC" in
    *"$verb"*) bad "T5 the drain never runs '$verb'" "found in $SCRIPT" ;;
    *) ok "T5 the drain never runs '$verb'" ;;
  esac
done

# --- the marker grammar is IMPORTED, never re-implemented -----------------
# dh89 shipped ONE implementation and 69qr R1c makes the drain its consumer.
# The label-backed upgrade of that library is a separate bead: consuming the
# ID-based API is what makes this script INHERIT it. A local grep for `Fleet:`
# would be a second grammar that silently stops agreeing with the first.
# ⚠️ HERESTRING, NOT `printf … | grep -q` (measured 2026-08-09). Under
# `set -o pipefail` that idiom FLAKES: grep -q exits the moment it matches, the
# still-writing printf takes EPIPE/SIGPIPE (141), pipefail hands the pipeline
# that status, and the `if` reads a PRESENT string as ABSENT. 300 trials on
# this very check: 18 false failures at HEAD's 33,888-byte source, 68 at the
# 43,100-byte one — i.e. a guard that gets flakier as the file it guards grows,
# and whose only symptom is a red case nobody can reproduce. `<<<` has no pipe.
if grep -q 'marker_is_fleet' <<< "$SRC"; then
  ok "T1d.1 the drain calls the library ID-based marker_is_fleet"
else
  bad "T1d.1 the drain calls the library ID-based marker_is_fleet" "not found"
fi
if grep -qE '(grep|sed|awk)[^|]*[Ff]leet:' <<< "$SRC"; then
  bad "T1d.2 no second marker grammar" "the drain greps for the marker itself"
else
  ok "T1d.2 no second marker grammar (one implementation, dh89)"
fi

if [ -x "$SCRIPT" ] && bash -n "$SCRIPT"; then
  ok "T0.6 marshal-drain.sh is executable and parses"
else
  bad "T0.6 marshal-drain.sh is executable and parses" "exec=$([ -x "$SCRIPT" ] && echo y || echo n)"
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
