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
  agentgateway_user TEXT, agentgateway_group TEXT);
INSERT INTO request_logs VALUES
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

# --- the cap is a fact only the vendor has: unset degrades honestly -------
OUT=$(run budget)
assert_verdict "T15b.1 unset weekly cap degrades (never an invented cap)" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=weekly-cap-unset$'
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

mkconf "$FIX/conf-tick-tap" tap=tick
OUT=$(MARSHAL_CONF="$FIX/conf-tick-tap" MARSHAL_SQL_CMD="sqlite3 $DB2" run budget --weekly-cap 10000000)
assert_verdict "T3e.2 tap: tick in config degrades -- tick is a profile, not a tap" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=150000 reason=unknown-tap:tick$'

# --- T18 the config parser refuses anything that is not key=value ---------
printf 'repos=x:%s\nevil=$(touch %s/pwned)\n' "$FIX/repos/harnessd" "$FIX" > "$FIX/conf-evil"
OUT=$(MARSHAL_CONF="$FIX/conf-evil" run_err budget --weekly-cap 10)
assert_verdict "T18.1 a config line that is not key=value is refused" "$OUT" "MARSHAL_BUDGET=" \
  '^MARSHAL_BUDGET=degraded fallback_tokens=0 reason=bad-config$'
if [ -e "$FIX/pwned" ]; then bad "T18.2 config is DATA" "the config executed"; else ok "T18.2 config is DATA, never executed"; fi

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
if printf '%s' "$SRC" | grep -q 'marker_is_fleet'; then
  ok "T1d.1 the drain calls the library ID-based marker_is_fleet"
else
  bad "T1d.1 the drain calls the library ID-based marker_is_fleet" "not found"
fi
if printf '%s' "$SRC" | grep -qE '(grep|sed|awk)[^|]*[Ff]leet:'; then
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
