#!/bin/bash
# Test for the /desk step-9 `kind:cmd` done-proof string that lives in
# agents/skills/desk/SKILL.md (explore-1fcd).
#
# WHY THIS EXISTS. The done-proof is a shell one-liner embedded in a skill
# document. Nothing compiled it, nothing linted it, and nothing ever ran it
# against a memo that was supposed to FAIL. It silently weakened: the
# STOP-has-content clause stripped retraction blocks for the memo's word count
# but not for itself, so a `### STOP` whose entire body was a retraction block
# plus struck-through text counted as 13 lines of live content and passed.
# refs/desk/2026-07-31.md in ~/explore is the measured instance — it has no
# live STOP and the gate passed it.
#
# WHAT IT GUARDS. Three properties, and the middle one is the bug:
#
#     A. no `### STOP` at all             -> clause FAILS  (correct)
#     B. a STOP whose body is entirely
#        retracted / struck               -> clause FAILS  (the fix)
#     C. a genuine live STOP              -> clause PASSES (must not break)
#
# A and C are the guard rails. A fix that makes B fail by also breaking C is
# not a fix — hence C and C2 (a live STOP that legitimately quotes struck
# text alongside live prose).
#
# The clauses are EXTRACTED FROM THE SHIPPED SKILL, not restated here. A test
# that carried its own copy of the one-liner would go green while the skill
# drifted, which is the failure mode this file exists against.
#
# Note: the proof is evaluated at AUTHORING time only — pre-commit-checks.sh
# re-runs proofs for `done` rows that are NEW in the staged diff and never
# re-validates history. So "a stop retracted a day later" is never re-graded;
# what these cases grade is a memo committed with nothing live under §2.
#
# Hook test convention (see test-worktree-guard.sh). Runs under BASH.

set -u

SKILL="$(cd "$(dirname "$0")/../../.." && pwd)/agents/skills/desk/SKILL.md"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

if [ ! -f "$SKILL" ]; then
  echo "FAIL: cannot find $SKILL" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- extract the proof cmd + the two content clauses from the skill ---------
# The step-9 ledger row is a single JSON object line; `proof.cmd` is its shell
# one-liner. Split it on ' && ' and pick clauses by what they assert.
extract() {   # $1 = python predicate over the clause string `c`
  python3 - "$SKILL" "$1" <<'PY'
import json, sys
skill, pred = sys.argv[1], sys.argv[2]
lines = [l.strip() for l in open(skill) if l.strip().startswith('{"ts"')]
if len(lines) != 1:
    sys.exit(1)
cmd = json.loads(lines[0])["proof"]["cmd"]
hits = [c for c in cmd.split(" && ") if eval(pred, {"c": c})]
if len(hits) != 1:
    sys.exit(1)
print(hits[0])
PY
}

FULL_CMD=$(python3 - "$SKILL" <<'PY'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip().startswith('{"ts"')]
print(json.loads(lines[0])["proof"]["cmd"] if len(lines) == 1 else "")
PY
)

STOP_CLAUSE=$(extract "'### STOP' in c and '-ge 1' in c")
ASK_CLAUSE=$(extract "'THE ASK' in c and '-ge 1' in c and 'grep -Evc' in c")

# --- fixtures ---------------------------------------------------------------
# A: §2 present, no ### STOP candidate at all.
cat > "$TMP/a.md" <<'EOF'
## §2 WHAT TO STOP

## §3 SIGNALS FROM THE FLOOR
EOF

# B: the live-memo shape — a STOP whose whole body is a retraction block plus
#    struck-through original. Mirrors refs/desk/2026-07-31.md §2.
cat > "$TMP/b.md" <<'EOF'
## §2 WHAT TO STOP

### STOP — Stop routing new recommendations into `/ab` until it runs once.

<!-- retraction-start 2026-08-01 -->
> ⛔ **RETRACTED 2026-08-01 — do not act on this stop.** Its premise is ASK 1's,
> and ASK 1 is retracted above: `/ab` has already run four times. Throttling a
> 28-bead cluster on a disproved claim is the costlier half of this defect.
<!-- retraction-end -->

~~Four of this week's entries terminate in "measure it with `/ab`".
`regression-tax/FINDINGS.md` named this against itself. A cluster feeding a
stalled consumer — this repo's own name-the-consumer rule at cluster scale.
Either ASK 1 lands, or the 28 beads get closed.~~

## §3 SIGNALS FROM THE FLOOR
EOF

# C: a genuine live STOP.
cat > "$TMP/c.md" <<'EOF'
## §2 WHAT TO STOP

### STOP — Close the 28-bead `/ab` cluster.

The rig has run four times; the cluster is a producer with no consumer.

## §3 SIGNALS FROM THE FLOOR
EOF

# C2: a live STOP that also quotes struck text. The over-correction ("strip
#     ~~...~~ everywhere") must not eat the live sentence beside it.
cat > "$TMP/c2.md" <<'EOF'
## §2 WHAT TO STOP

### STOP — Retire the `~/explore` corpus-v2 program.

~~An earlier candidate, struck when its premise was disproved.~~
Defund it: the index shipped, and the program it was waiting on closed.

## §3 SIGNALS FROM THE FLOOR
EOF

# D: §1 with every ask retracted — the same defect one section up.
cat > "$TMP/d.md" <<'EOF'
## §1 THE ASK

### ASK 1 — Fund corpus v2.

<!-- retraction-start 2026-08-01 -->
> ⛔ **RETRACTED 2026-08-01.** The bead this rests on closed on 2026-07-03.
<!-- retraction-end -->

~~Corpus v2 is the ripest program in the compendium and nothing is funding it.~~

## §2 WHAT TO STOP
EOF

# D2: §1 with one retracted ask and one live one — the live-memo shape, which
#     must keep passing.
cat > "$TMP/d2.md" <<'EOF'
## §1 THE ASK

### ASK 1 — Fund corpus v2.

<!-- retraction-start 2026-08-01 -->
> ⛔ **RETRACTED 2026-08-01.** The bead this rests on closed on 2026-07-03.
<!-- retraction-end -->

~~Corpus v2 is the ripest program in the compendium.~~

### ASK 2 — The desk's read half broke today.

Fund an hour on the corpus loader; the failure was success-shaped.

## §2 WHAT TO STOP
EOF

run_clause() {   # $1 = clause, $2 = fixture path -> exit code
  bash -c "D=$2; $1" >/dev/null 2>&1
}
expect_fail() {  # $1 = clause, $2 = fixture, $3 = case name
  if [ -z "$1" ]; then bad "$3 (no clause extracted)"; return; fi
  if run_clause "$1" "$2"; then bad "$3"; else ok; fi
}
expect_pass() {
  if [ -z "$1" ]; then bad "$3 (no clause extracted)"; return; fi
  if run_clause "$1" "$2"; then ok; else bad "$3"; fi
}

# --- 1. the shipped proof string still parses ------------------------------
if [ -n "$FULL_CMD" ] && bash -n -c "$FULL_CMD" 2>/dev/null; then ok; else
  bad "step-9 proof cmd is syntactically valid shell"
fi

# --- 2-5. the STOP-has-content clause -------------------------------------
if [ -n "$STOP_CLAUSE" ]; then ok; else bad "STOP-content clause found in the skill"; fi

expect_fail "$STOP_CLAUSE" "$TMP/a.md"  "A: no ### STOP at all -> clause FAILS"
expect_fail "$STOP_CLAUSE" "$TMP/b.md"  "B: fully-retracted STOP -> clause FAILS"
expect_pass "$STOP_CLAUSE" "$TMP/c.md"  "C: genuine live STOP -> clause PASSES"
expect_pass "$STOP_CLAUSE" "$TMP/c2.md" "C2: live STOP quoting struck text -> clause PASSES"

# --- 6-8. the same treatment on §1's floor ---------------------------------
if [ -n "$ASK_CLAUSE" ]; then ok; else bad "§1-content clause found in the skill"; fi

expect_fail "$ASK_CLAUSE" "$TMP/d.md"  "D: every ask retracted -> clause FAILS"
expect_pass "$ASK_CLAUSE" "$TMP/d2.md" "D2: one retracted + one live ask -> clause PASSES"

# --- 9. the crosslink freshness clause is present and dated-bounded --------
CL_CLAUSE=$(python3 - "$SKILL" <<'PY'
import json, sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip().startswith('{"ts"')]
cmd = json.loads(lines[0])["proof"]["cmd"] if len(lines) == 1 else ""
print("yes" if "crosslink.md" in cmd and "-le 8" in cmd else "")
PY
)
[ -n "$CL_CLAUSE" ] && ok || bad "done-proof carries the refs/crosslink.md freshness clause (<= 8 days)"

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi

echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
