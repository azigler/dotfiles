#!/bin/bash
# Test for the LAURELS + seat-history arc (bead dotfiles-qnfk): T1-T8 and T10
# of the spec's own case list. T9 (the hall's 🏅N column) is DEFERRED — the
# hall is owned by another builder this wave and this suite must not touch it.
#
# It is deliberately END-TO-END across three subjects, because the property the
# spec cares about is a property of the CHAIN, not of any one file:
#
#     agents/lib/seat-history.sh      the ONLY writer of a history
#     agents/skills/dream/dream.py    the placer (cap, ledger, all-or-none)
#     agents/scheduler/seneschal-gather.py   the brief Zig actually reads
#
# A unit test of the placer alone cannot see T2 (all three artifacts or none)
# or T10 (no ceremony without substance), and those are the two that make a
# direct-place class safe in a propose-only loop.
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on
# the last line (see test-validate-seats.sh, test-seat-resolve.sh).
#
# CASE FILTERING: `bash test-seat-history.sh T2 T4` runs only those cases. The
# mutation harness (mutate-laurels.sh) uses it to run ONLY the cases a mutant
# NAMES — this repo's rule 1, second clause: red-somewhere is not a kill.
#
# Everything runs against a FIXTURE roster and a temp history dir. Nothing here
# reads or writes the live roster, refs/seats/, or ~/.local/share.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/seat-history.sh"
VALIDATE="$HERE/validate-seats.py"
DREAM="$ROOT/agents/skills/dream/dream.py"
SENESCHAL="$ROOT/agents/scheduler/seneschal-gather.py"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1 (want [$2] got [$3])"; fi; }
has() { case "$3" in *"$2"*) ok ;; *) bad "$1 (missing [$2] in: $3)" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 (unexpected [$2] in: $3)" ;; *) ok ;; esac; }

BASE=$(mktemp -d)
trap 'chmod -R u+w "$BASE" 2>/dev/null; rm -rf "$BASE"' EXIT   # allow-suppress: teardown

# --- the fixture roster ----------------------------------------------------
# Shaped like the real one but INDEPENDENT of it: the roster churns (a seat
# rename may land in the same wave as this suite), and a suite that asserts on
# live seat names fails for reasons that are not about the code under test.
#
# `keeper` deliberately does NOT hold the name "dream": the R6 exclusion is
# keyed on the OFFICE, and a fixture that names the seat `dream` could not tell
# an office-keyed check from a name-keyed one.
ROSTER="$BASE/seats.yml"
cat > "$ROSTER" <<'EOF'
schema: 1
hosts: [zig-computer]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: []
seats:
  alpha:
    charter-line: "fixture seat alpha"
    office: "The Alpha"
    sigil: "📜"
    tap: personal
    home: ~/alpha-nonexistent
    model: fable
    effort: high
    aliases: []
    history: refs/seats/alpha.history.md
    schedules: []
  beta:
    charter-line: "fixture seat beta"
    office: "The Beta"
    sigil: "🧭"
    tap: personal
    home: ~/beta-nonexistent
    model: sonnet
    effort: high
    aliases: []
    history: refs/seats/beta.history.md
    schedules: []
  gamma:
    charter-line: "fixture seat gamma"
    office: "The Gamma"
    sigil: "🪙"
    tap: personal
    home: ~/gamma-nonexistent
    model: sonnet
    effort: high
    aliases: []
    history: refs/seats/gamma.history.md
    schedules: []
  delta:
    charter-line: "fixture seat delta"
    office: "The Delta"
    sigil: "🧱"
    tap: personal
    home: ~/delta-nonexistent
    model: sonnet
    effort: high
    aliases: []
    history: refs/seats/delta.history.md
    schedules: []
  keeper:
    charter-line: "fixture seat holding the excluded office"
    office: "The Remembrancer"
    sigil: "🏮"
    tap: personal
    home: ~/keeper-nonexistent
    model: fable
    effort: high
    aliases: []
    history: refs/seats/keeper.history.md
    schedules: []
EOF
export SEATS_YML="$ROSTER"

FIXTURE_SEATS=5   # asserted against the roster at runtime in T1, never trusted

# fresh_dir <name> -> a history dir with the founding backfill already run
fresh_dir() {
  local d="$BASE/$1"
  chmod -R u+w "$d" 2>/dev/null   # allow-suppress: 0444 files from a prior run
  rm -rf "$d"
  SEAT_HISTORY_DIR="$d" bash "$LIB" init > /dev/null || return 1
  printf '%s' "$d"
}

# rows <file> -> non-empty line count, 0 for an absent file. NOT
# `grep -c . f || echo 0`: grep -c PRINTS 0 and EXITS 1 on no match, so the
# fallback fires too and the idiom yields "0\n0" — a false failure that reads
# like a real one (caught by this suite on its first run).
rows() { [ -f "$1" ] || { printf '0'; return 0; }; grep -c . "$1" | tr -d '\n'; }

place() { # <history-dir> <ledger> <json-file> [extra dream flags...]
  local d="$1" ledger="$2" file="$3"; shift 3
  python3 "$DREAM" laurels --place "$file" --ledger "$ledger" \
    --history-dir "$d" --history-lib "$LIB" --now 2026-08-09T12:00:00Z "$@"
}

brief() { # <ledger> -> the rendered brief
  SENESCHAL_LAURELS="$1" SENESCHAL_STATE_URL="http://127.0.0.1:9/state.json" \
    python3 "$SENESCHAL" --out - --roster "$ROSTER" --now 2026-08-09T18:00:00Z 2>/dev/null
}

# ===========================================================================
# T1 — every roster seat gets a founding APPOINTED entry; a seat with no
#      history file FAILS the validator; so does an orphan history.
# ===========================================================================
case_T1() {
  local d n
  d=$(fresh_dir t1)
  n=$(ls "$d" | grep -c '\.history\.md$')
  # The count is DERIVED from the roster at runtime — never a hardcoded 18 (or
  # 5). The roster is the source of truth for who exists; a suite that pins the
  # number breaks on the next seating and teaches people to edit the number.
  eq "T1 one history per roster seat" "$(SEATS_YML=$ROSTER bash "$LIB" seats | grep -c .)" "$n"
  eq "T1 fixture roster is the size this suite expects" "$FIXTURE_SEATS" "$n"
  has "T1 APPOINTED entry" "· APPOINTED · The Alpha" "$(cat "$d/alpha.history.md")"
  has "T1 cites ojjf" "dotfiles-seat-roster-from-windows-ojjf" "$(cat "$d/alpha.history.md")"
  has "T1 founding date" "## 2026-08-08 ·" "$(cat "$d/alpha.history.md")"
  eq "T1 init is idempotent" "kept alpha" \
     "$(SEAT_HISTORY_DIR=$d bash "$LIB" init | grep '^kept alpha$')"

  eq "T1 validator green with every history present" "0" \
     "$(python3 "$VALIDATE" "$ROSTER" --histories "$d" >/dev/null 2>&1; echo $?)"

  chmod u+w "$d/beta.history.md"; rm -f "$d/beta.history.md"
  local out
  out=$(python3 "$VALIDATE" "$ROSTER" --histories "$d" 2>&1)
  eq "T1 missing history FAILS the validator" "1" \
     "$(python3 "$VALIDATE" "$ROSTER" --histories "$d" >/dev/null 2>&1; echo $?)"
  has "T1 names the seat with no history" "seat 'beta' has NO history file" "$out"

  SEAT_HISTORY_DIR=$d bash "$LIB" init > /dev/null
  printf 'x\n' > "$d/ghost.history.md"
  out=$(python3 "$VALIDATE" "$ROSTER" --histories "$d" 2>&1)
  has "T1 orphan history is named" "orphan history 'ghost.history.md'" "$out"
}

# ===========================================================================
# T2 — a placement writes history AND ledger AND the brief section. All three
#      or none. (The mutant `ledger-drop` removes the ledger write; the brief
#      assertion below is what kills it, because the brief is DERIVED.)
# ===========================================================================
case_T2() {
  local d ledger out
  d=$(fresh_dir t2)
  ledger="$BASE/t2.jsonl"; rm -f "$ledger"
  cat > "$BASE/t2.json" <<'EOF'
{"run_id":"run-t2","placements":[
  {"seat":"alpha","title":"recurrence fix verified held","why":"The ledger signature went to zero.","bead":"dotfiles-abc1","commit":"deadbee"}
]}
EOF
  out=$(place "$d" "$ledger" "$BASE/t2.json" 2>/dev/null)
  eq "T2 one placed" "1" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  has "T2 history entry" "🏅 LAUREL · recurrence fix verified held" "$(cat "$d/alpha.history.md")"
  has "T2 history carries the citation" "citation: bead dotfiles-abc1 · commit deadbee" "$(cat "$d/alpha.history.md")"
  eq "T2 exactly one ledger row" "1" "$(grep -c . "$ledger")"
  has "T2 ledger row names the seat" '"seat": "alpha"' "$(cat "$ledger")"
  has "T2 brief renders the LAURELS section" "🏅 LAURELS — 1 placed" "$(brief "$ledger")"
  has "T2 brief names the laurel" "recurrence fix verified held" "$(brief "$ledger")"
  eq "T2 integrity holds after the append" "OK alpha" \
     "$(SEAT_HISTORY_DIR=$d bash "$LIB" verify alpha)"
}

# ===========================================================================
# T2R — the other half of all-three-or-none: when the HISTORY write fails
#       after the ledger row is already down, the row is UNWOUND. Without
#       this, a failed placement leaves a ledger row (and therefore a LAURELS
#       line in the brief) citing a history entry that does not exist.
# ===========================================================================
case_T2R() {
  local d ledger out
  d=$(fresh_dir t2r)
  ledger="$BASE/t2r.jsonl"; rm -f "$ledger"
  cat > "$BASE/t2r.json" <<'EOF'
{"placements":[{"seat":"alpha","title":"will not land","why":"w","bead":"b1","commit":"c1"}]}
EOF
  # A read-only history DIR passes --check-only (which only reads) and then
  # fails the real append — the exact interleaving the rollback exists for.
  chmod 0555 "$d"
  out=$(place "$d" "$ledger" "$BASE/t2r.json" 2>/dev/null)
  chmod 0755 "$d"
  eq "T2R nothing placed" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  eq "T2R it is reported as refused" "1" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_refused"])')"
  eq "T2R the ledger row was UNWOUND" "0" "$(rows "$ledger")"
  hasnt "T2R the brief shows nothing" "will not land" "$(brief "$ledger")"
  eq "T2R the history is unchanged" "0" "$(SEAT_HISTORY_DIR=$d bash "$LIB" count alpha)"
}

# ===========================================================================
# T3 — the cap: 4 proposed, 3 placed, the 4th DROPPED and logged.
# ===========================================================================
case_T3() {
  local d ledger out err
  d=$(fresh_dir t3)
  ledger="$BASE/t3.jsonl"; rm -f "$ledger"
  cat > "$BASE/t3.json" <<'EOF'
{"run_id":"run-t3","placements":[
  {"seat":"alpha","title":"one","why":"w","bead":"b1","commit":"c1"},
  {"seat":"beta","title":"two","why":"w","bead":"b2","commit":"c2"},
  {"seat":"gamma","title":"three","why":"w","bead":"b3","commit":"c3"},
  {"seat":"delta","title":"four","why":"w","bead":"b4","commit":"c4"}
]}
EOF
  err="$BASE/t3.err"
  out=$(place "$d" "$ledger" "$BASE/t3.json" 2>"$err")
  eq "T3 exactly the cap is placed" "3" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  eq "T3 the over-cap one is dropped" "1" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_dropped"])')"
  has "T3 the drop is LOGGED" "DROPPED — over the weekly cap" "$(cat "$err")"
  eq "T3 the 4th seat got no entry" "0" "$(SEAT_HISTORY_DIR=$d bash "$LIB" count delta)"
  eq "T3 ledger holds only the placed" "3" "$(grep -c . "$ledger")"
}

# ===========================================================================
# T4 — no citable evidence => REFUSED, and NOTHING is written anywhere.
# ===========================================================================
case_T4() {
  local d ledger out before err
  d=$(fresh_dir t4)
  ledger="$BASE/t4.jsonl"; rm -f "$ledger"
  before=$(md5sum < "$d/alpha.history.md")
  cat > "$BASE/t4.json" <<'EOF'
{"run_id":"run-t4","placements":[
  {"seat":"alpha","title":"uncited praise","why":"it felt good"},
  {"seat":"beta","title":"bead but no commit","why":"w","bead":"b9"},
  {"seat":"gamma","title":"commit but no bead","why":"w","commit":"c9"}
]}
EOF
  err="$BASE/t4.err"
  out=$(place "$d" "$ledger" "$BASE/t4.json" 2>"$err")
  eq "T4 nothing placed" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  eq "T4 all three refused" "3" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_refused"])')"
  has "T4 the refusal says WHY" "no citable evidence" "$(cat "$err")"
  eq "T4 history untouched" "$before" "$(md5sum < "$d/alpha.history.md")"
  eq "T4 no ledger row" "0" "$(rows "$ledger")"
  hasnt "T4 brief has no section" "🏅 LAURELS" "$(brief "$ledger")"
  # The lib refuses on its own too — dream.py is not the only layer.
  eq "T4 the lib itself refuses rc 4" "4" \
     "$(SEAT_HISTORY_DIR=$d bash "$LIB" laurel --seat alpha --title t --why w >/dev/null 2>&1; echo $?)"
}

# ===========================================================================
# T5 — onboard injection: office line + last laurels; absent file = SILENT.
# ===========================================================================
case_T5() {
  local d ledger out err rc
  d=$(fresh_dir t5)
  ledger="$BASE/t5.jsonl"; rm -f "$ledger"
  cat > "$BASE/t5.json" <<'EOF'
{"placements":[{"seat":"alpha","title":"first","why":"one","bead":"b1","commit":"c1"}]}
EOF
  place "$d" "$ledger" "$BASE/t5.json" > /dev/null 2>&1
  # Four more, one at a time, so the head must pick the LAST three.
  for i in 2 3 4 5; do
    SEAT_HISTORY_DIR=$d bash "$LIB" laurel --seat alpha --title "entry $i" \
      --why "why $i" --bead "b$i" --commit "c$i" --date "2026-08-1$i" > /dev/null 2>&1
  done
  out=$(SEAT_HISTORY_DIR=$d bash "$LIB" head --seat alpha --laurels 3)
  has "T5 head renders the office" "The Alpha" "$out"
  has "T5 head renders the sigil" "📜" "$out"
  has "T5 head renders the appointed date" "seated 2026-08-08" "$out"
  eq  "T5 head renders exactly 3 laurels" "3" "$(printf '%s\n' "$out" | grep -c '^🏅')"
  has "T5 head keeps the LAST laurels" "entry 5" "$out"
  hasnt "T5 head drops the oldest" "· first —" "$out"

  err="$BASE/t5.err"
  out=$(SEAT_HISTORY_DIR="$BASE/no-such-dir" bash "$LIB" head --seat alpha 2>"$err"); rc=$?
  eq "T5 absent file: no stdout" "" "$out"
  eq "T5 absent file: no stderr (an unregistered window is not an incident)" "" "$(cat "$err")"
  eq "T5 absent file: rc 1" "1" "$rc"
}

# ===========================================================================
# T6 — a seat cannot write its own history. Two mechanisms, both asserted.
# ===========================================================================
case_T6() {
  local d rc out
  d=$(fresh_dir t6)
  # (1) generation-only: the generated file is not writable, so the obvious
  #     self-award (`>> history.md`) fails at the shell.
  ( printf 'forged\n' >> "$d/alpha.history.md" ) 2>/dev/null; rc=$?
  eq "T6 append to a generated history is refused by the filesystem" "1" "$rc"

  # (2) the checksum: forcing the write anyway is DETECTED, and blocks a commit.
  chmod u+w "$d/alpha.history.md"
  cat >> "$d/alpha.history.md" <<'EOF'
## 2026-08-10 · 🏅 LAUREL · awarded myself
I did a great job.
citation: bead b · commit c
EOF
  out=$(SEAT_HISTORY_DIR=$d bash "$LIB" verify alpha); rc=$?
  has "T6 verify reports the forgery" "TAMPERED alpha" "$out"
  eq "T6 verify exits non-zero" "1" "$rc"
  out=$(python3 "$VALIDATE" "$ROSTER" --histories "$d" 2>&1)
  has "T6 the commit gate names it" "FAILS its own integrity checksum" "$out"
  eq "T6 the commit gate BLOCKS" "1" \
     "$(python3 "$VALIDATE" "$ROSTER" --histories "$d" >/dev/null 2>&1; echo $?)"
}

# ===========================================================================
# T7 — retirement: final entry with the laurel tally, roster row moves to
#      `retired:`, validator green with the history PRESERVED.
# ===========================================================================
case_T7() {
  local d out retired
  d=$(fresh_dir t7)
  SEAT_HISTORY_DIR=$d bash "$LIB" laurel --seat gamma --title "held the line" \
    --why "w" --bead b1 --commit c1 --date 2026-08-09 > /dev/null
  out=$(SEAT_HISTORY_DIR=$d bash "$LIB" retire --seat gamma \
        --reason "The employment ended." --date 2026-09-01)
  has "T7 retire reports the tally" "laurels=1" "$out"
  has "T7 RETIRED entry" "## 2026-09-01 · RETIRED · The Gamma" "$(cat "$d/gamma.history.md")"
  has "T7 the reason is recorded" "The employment ended." "$(cat "$d/gamma.history.md")"
  has "T7 the tally is in the entry" "laurels: 1" "$(cat "$d/gamma.history.md")"
  has "T7 the laurel survives retirement" "held the line" "$(cat "$d/gamma.history.md")"
  eq "T7 integrity still holds" "OK gamma" "$(SEAT_HISTORY_DIR=$d bash "$LIB" verify gamma)"

  # The roster side: gamma moves out of `seats:` and into `retired:`. Its
  # history file stays exactly where it is — that is the point of Art. IV.
  retired="$BASE/seats-retired.yml"
  python3 - "$ROSTER" "$retired" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines(True)
out, block, grabbing = [], [], False
for ln in lines:
    if ln.startswith("  gamma:"):
        grabbing = True
    elif grabbing and ln.startswith("  ") and not ln.startswith("    "):
        grabbing = False
    if grabbing:
        block.append(ln)
    else:
        out.append(ln)
out.append("\nretired:\n")
out.extend(block)
open(dst, "w", encoding="utf-8").write("".join(out))
PY
  eq "T7 validator green with a retired: section" "0" \
     "$(python3 "$VALIDATE" "$retired" --histories "$d" >/dev/null 2>&1; echo $?)"
  has "T7 validator counts the retired seat" "1 retired" \
     "$(python3 "$VALIDATE" "$retired" --histories "$d" 2>&1)"
  # A retired seat that LOST its history is the failure Art. IV forbids.
  chmod u+w "$d/gamma.history.md"; rm -f "$d/gamma.history.md"
  has "T7 a deleted retired history FAILS" "retired 'gamma' has NO history file" \
     "$(python3 "$VALIDATE" "$retired" --histories "$d" 2>&1)"
}

# ===========================================================================
# T8 — the Remembrancer exclusion, keyed on the OFFICE not the seat name.
# ===========================================================================
case_T8() {
  local d ledger out err
  d=$(fresh_dir t8)
  ledger="$BASE/t8.jsonl"; rm -f "$ledger"
  eq "T8 the office resolves to its seat at runtime" "keeper" \
     "$(SEATS_YML=$ROSTER bash "$LIB" remembrancer)"
  cat > "$BASE/t8.json" <<'EOF'
{"placements":[{"seat":"keeper","title":"placed three laurels","why":"it did its own job","bead":"b1","commit":"c1"}]}
EOF
  err="$BASE/t8.err"
  out=$(place "$d" "$ledger" "$BASE/t8.json" 2>"$err")
  eq "T8 nothing placed on the Remembrancer" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  has "T8 the refusal names the office" "it holds the office of The Remembrancer" "$(cat "$err")"
  eq "T8 no entry was written" "0" "$(SEAT_HISTORY_DIR=$d bash "$LIB" count keeper)"
  eq "T8 no ledger row" "0" "$(rows "$ledger")"
  # The lord's escape hatch exists and is NOT reachable from the weekly flow
  # (dream.py never passes --by-lord).
  SEAT_HISTORY_DIR=$d bash "$LIB" laurel --seat keeper --title "non-laurel work" \
    --why "w" --bead b --commit c --date 2026-08-09 --by-lord > /dev/null 2>&1
  eq "T8 the lord may still award by hand" "1" "$(SEAT_HISTORY_DIR=$d bash "$LIB" count keeper)"
  hasnt "T8 dream.py never passes --by-lord" "by-lord" "$(grep -o '\-\-by-lord' "$DREAM" || true)"
}

# ===========================================================================
# T10 — no ceremony without substance: a non-placement week has NO section.
# ===========================================================================
case_T10() {
  local ledger out
  ledger="$BASE/t10.jsonl"; rm -f "$ledger"
  out=$(brief "$ledger")
  hasnt "T10 absent ledger: no LAURELS heading" "LAURELS" "$out"
  has  "T10 the rest of the brief still renders" "SENESCHAL BRIEF" "$out"

  # A row OUTSIDE the window is the same as no row — the section is about THIS
  # week, and a stale laurel re-rendered forever is the two-copies defect.
  printf '%s\n' '{"ts":"2026-06-01T00:00:00Z","seat":"alpha","title":"old","why":"w","bead":"b","commit":"c"}' > "$ledger"
  hasnt "T10 out-of-window row: still no heading" "LAURELS" "$(brief "$ledger")"

  printf '%s\n' '{"ts":"2026-08-09T00:00:00Z","seat":"alpha","title":"fresh","why":"w","bead":"b","commit":"c"}' >> "$ledger"
  has "T10 an in-window row DOES render" "🏅 LAURELS — 1 placed" "$(brief "$ledger")"
  hasnt "T10 the stale row is not re-rendered" "· old" "$(brief "$ledger")"
}

# ===========================================================================
# CONF — a laurel naming a confidential project never reaches a pushed file.
# ===========================================================================
case_CONF() {
  local d ledger out err
  d=$(fresh_dir conf)
  ledger="$BASE/conf.jsonl"; rm -f "$ledger"
  cat > "$BASE/conf.json" <<'EOF'
{"placements":[{"seat":"alpha","title":"linearb reporting held","why":"w","bead":"lin-9","commit":"c1"}]}
EOF
  err="$BASE/conf.err"
  out=$(place "$d" "$ledger" "$BASE/conf.json" 2>"$err")
  eq "CONF nothing placed" "0" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_placed"])')"
  has "CONF the refusal names the reason" "denied project" "$(cat "$err")"
  eq "CONF no ledger row" "0" "$(rows "$ledger")"
}

# --- runner ----------------------------------------------------------------
ALL="T1 T2 T2R T3 T4 T5 T6 T7 T8 T10 CONF"
WANT="${*:-$ALL}"
for c in $WANT; do
  if ! type "case_$c" > /dev/null 2>&1; then
    echo "no such case: $c (have: $ALL)" >&2
    exit 2
  fi
  "case_$c"
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$PASS assertions ($WANT)"
  exit 0
fi
echo "FAILURES:"
for f in "${FAILED[@]}"; do echo "  - $f"; done
echo "FAIL: $FAIL failed, $PASS passed ($WANT)"
exit 1
