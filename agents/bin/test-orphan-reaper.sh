#!/usr/bin/env bash
# test-orphan-reaper.sh — regression suite for orphan-reaper.sh (dotfiles-415c).
#
# Hermetic: every fixture process is a real `sleep`/trap-script this suite
# spawns itself under a throwaway mktemp dir, never a real worktree or a real
# scratchpad. The suite kills anything it spawns that survives, in a trap.
#
# THE SAFETY ASSERTION THIS SUITE EXISTS TO PROVE (case 4): a process whose
# cwd is a LIVE (non-deleted) `.claude/worktrees/...` dir must survive a full
# sweep. That is the property the bead was filed to guarantee — a builder
# mid-test must never be killed by the reaper.
#
# Usage: bash agents/bin/test-orphan-reaper.sh   (exit 0 = all pass)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/orphan-reaper.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/orphan-reaper-suite.XXXXXX")
LEDGER="$WORK/reaper.jsonl"

PASS=0; FAIL=0
FAILED_NAMES=()
SPAWNED_PIDS=()

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

cleanup() {
  local p
  for p in "${SPAWNED_PIDS[@]+"${SPAWNED_PIDS[@]}"}"; do
    kill -9 "$p" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# spawn_sleep DIR -> prints pid; process cwd's to DIR and sleeps.
#
# The </dev/null >/dev/null 2>&1 on the backgrounded subshell is NOT cosmetic:
# spawn_sleep is invoked as `P1=$(spawn_sleep "$D1")`, a command substitution
# whose read() blocks until every writer of its pipe closes. Without the
# redirect, the `&` job inherits that pipe's write end and holds it open for
# its entire 300s lifetime — the substitution (and the whole suite) hangs
# until the fixture process exits, which defeats the fixture's purpose.
spawn_sleep() {
  local dir=$1
  ( cd "$dir" && exec sleep 300 ) </dev/null >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  # give the kernel a moment to actually chdir before /proc is read
  local i=0
  while [ ! -e "/proc/$pid/cwd" ] && [ "$i" -lt 50 ]; do sleep 0.05; i=$((i+1)); done
  sleep 0.1
  echo "$pid"
}

# spawn_term_trap DIR -> a process that exits cleanly on SIGTERM (no KILL needed).
# Same pipe-leak hazard as spawn_sleep above -- same fix.
spawn_term_trap() {
  local dir=$1
  ( cd "$dir" && exec bash -c 'trap "exit 0" TERM; while true; do sleep 1; done' ) </dev/null >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  sleep 0.2
  echo "$pid"
}

# ORPHAN_REAPER_SCOPE_PREFIX=$WORK: a full (non---worktree) sweep otherwise
# scans the WHOLE machine's /proc, which would make this suite a genuine
# hazard to run -- any real process on the box with a matching cwd would be
# killed for real. Scoping to $WORK makes every full-sweep case below a REAL
# sweep (not a mock), just one that can only ever see this suite's own
# fixtures.
run_reaper() {
  rm -f "$LEDGER"
  OUT=$(ORPHAN_REAPER_LEDGER="$LEDGER" ORPHAN_REAPER_SCOPE_PREFIX="$WORK" "$SCRIPT" "$@" 2>&1)
  RC=$?
}

result_tag() { printf '%s\n' "$OUT" | grep -o 'ORPHAN_REAPER_RESULT=[a-z:0-9]*'; }

echo "=== orphan-reaper.sh ======================================================="

# --- 1: dry-run reports a deleted-worktree candidate but does not kill -----
D1="$WORK/case1/.claude/worktrees/agent-x"
mkdir -p "$D1"
P1=$(spawn_sleep "$D1")
rm -rf "$D1"
run_reaper --dry-run --floor 1
if [ "$RC" -eq 0 ] && alive "$P1" && printf '%s' "$OUT" | grep -q "DRY-RUN would reap pid=$P1"; then
  ok "1 dry-run lists a deleted-worktree candidate and does not kill it"
else bad "1 dry-run lists without killing" "rc=$RC out=$OUT alive=$(alive "$P1" && echo yes || echo no)"; fi
kill -9 "$P1" 2>/dev/null

# --- 2: real sweep reaps a deleted-worktree cwd process, writes the ledger -
D2="$WORK/case2/.claude/worktrees/agent-y"
mkdir -p "$D2"
P2=$(spawn_sleep "$D2")
rm -rf "$D2"
run_reaper --grace 2 --floor 1
if [ "$RC" -eq 0 ] && ! alive "$P2" && [ "$(result_tag)" = "ORPHAN_REAPER_RESULT=reaped:1" ] \
   && grep -q "\"pid\":$P2" "$LEDGER" && grep -q '"comm":"sleep"' "$LEDGER"; then
  ok "2 real sweep reaps a deleted-worktree cwd process and logs it"
else bad "2 real sweep reaps deleted-worktree process" "rc=$RC out=$OUT alive=$(alive "$P2" && echo yes || echo no) ledger=$(cat "$LEDGER" 2>/dev/null)"; fi

# --- 3: real sweep reaps a LIVE (non-deleted) scratchpad cwd process -------
D3="$WORK/case3/somewhere/scratchpad/inner"
mkdir -p "$D3"
P3=$(spawn_sleep "$D3")
run_reaper --grace 2 --floor 1
if [ "$RC" -eq 0 ] && ! alive "$P3" && [ -d "$D3" ]; then
  ok "3 real sweep reaps a LIVE scratchpad cwd process (dir was never deleted)"
else bad "3 real sweep reaps live scratchpad process" "rc=$RC out=$OUT alive=$(alive "$P3" && echo yes || echo no)"; fi

# --- 4: THE SAFETY ASSERTION — a LIVE worktree cwd process survives --------
D4="$WORK/case4/.claude/worktrees/agent-live"
mkdir -p "$D4"
P4=$(spawn_sleep "$D4")
run_reaper --grace 2 --floor 1
if [ "$RC" -eq 0 ] && alive "$P4"; then
  ok "4 a LIVE (non-deleted) worktree cwd process SURVIVES the full sweep"
else bad "4 live worktree process must survive the sweep" "rc=$RC out=$OUT alive=$(alive "$P4" && echo yes || echo no)"; fi
kill -9 "$P4" 2>/dev/null

# --- 5: --worktree mode kills a process rooted under the named path -------
D5A="$WORK/case5/target-wt/sub"
D5B="$WORK/case5/other-wt"
mkdir -p "$D5A" "$D5B"
P5A=$(spawn_sleep "$D5A")
P5B=$(spawn_sleep "$D5B")
run_reaper --worktree "$WORK/case5/target-wt" --grace 2 --floor 1
if [ "$RC" -eq 0 ] && ! alive "$P5A" && alive "$P5B"; then
  ok "5 --worktree mode kills only the process rooted under the named path"
else bad "5 --worktree mode isolates the target path" "rc=$RC out=$OUT A=$(alive "$P5A" && echo UP || echo dead) B=$(alive "$P5B" && echo up || echo DEAD)"; fi
kill -9 "$P5B" 2>/dev/null

# --- 6: --worktree mode against a path with no matching processes is clean -
run_reaper --worktree "$WORK/case6/nothing-here" --grace 1 --floor 1
if [ "$RC" -eq 0 ] && [ "$(result_tag)" = "ORPHAN_REAPER_RESULT=clean" ]; then
  ok "6 --worktree mode against an empty target reports clean"
else bad "6 --worktree mode empty-target is clean" "rc=$RC out=$OUT"; fi

# --- 7: full sweep with nothing to reap reports clean ----------------------
run_reaper --floor 1
if [ "$RC" -eq 0 ] && [ "$(result_tag)" = "ORPHAN_REAPER_RESULT=clean" ]; then
  ok "7 full sweep with no matching processes reports clean"
else bad "7 full sweep clean case" "rc=$RC out=$OUT"; fi

# --- 8: --floor excludes a real pid even when its cwd matches --------------
D8="$WORK/case8/.claude/worktrees/agent-floored"
mkdir -p "$D8"
P8=$(spawn_sleep "$D8")
rm -rf "$D8"
run_reaper --grace 1 --floor 999999999
if [ "$RC" -eq 0 ] && alive "$P8" && [ "$(result_tag)" = "ORPHAN_REAPER_RESULT=clean" ]; then
  ok "8 --floor above every real pid excludes all candidates"
else bad "8 floor exclusion" "rc=$RC out=$OUT alive=$(alive "$P8" && echo yes || echo no)"; fi
kill -9 "$P8" 2>/dev/null

# --- 9: a cooperating process dies on SIGTERM alone, inside the grace ------
D9="$WORK/case9/.claude/worktrees/agent-cooperative"
mkdir -p "$D9"
P9=$(spawn_term_trap "$D9")
rm -rf "$D9"
START=$(date +%s)
run_reaper --grace 10 --floor 1
ELAPSED=$(( $(date +%s) - START ))
if [ "$RC" -eq 0 ] && ! alive "$P9" && [ "$ELAPSED" -lt 8 ]; then
  ok "9 TERM alone is sufficient when the process cooperates (no KILL needed)"
else bad "9 TERM-first path" "rc=$RC out=$OUT elapsed=${ELAPSED}s alive=$(alive "$P9" && echo yes || echo no)"; fi

# --- 10: ledger has exactly one line per reap, well-formed JSON fields -----
D10="$WORK/case10/.claude/worktrees/agent-ledger"
mkdir -p "$D10"
P10=$(spawn_sleep "$D10")
rm -rf "$D10"
run_reaper --grace 2 --floor 1
LINES=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
if [ "$LINES" -eq 1 ] && grep -q '"ts":"' "$LEDGER" && grep -q "\"pid\":$P10" "$LEDGER" \
   && grep -q '"age":' "$LEDGER" && grep -q '"comm":"sleep"' "$LEDGER" && grep -q '"cwd":"' "$LEDGER"; then
  ok "10 ledger gets exactly one line per reap with ts/pid/age/comm/cwd"
else bad "10 ledger line shape" "lines=$LINES content=$(cat "$LEDGER" 2>/dev/null)"; fi

# --- 11: usage errors exit 2 ------------------------------------------------
"$SCRIPT" --worktree >/dev/null 2>&1
RC11A=$?
"$SCRIPT" --bogus-flag >/dev/null 2>&1
RC11B=$?
if [ "$RC11A" -eq 2 ] && [ "$RC11B" -eq 2 ]; then
  ok "11 usage errors (missing --worktree arg, unknown flag) exit 2"
else bad "11 usage errors exit 2" "rc11a=$RC11A rc11b=$RC11B"; fi

# --- 12: the reaper never targets its own pid or an ancestor's -------------
# Indirect proof: run a full sweep from inside a cwd that itself matches the
# scratchpad predicate and confirm the suite (this very process tree) is
# still alive to report the result -- if self-exclusion were broken, the
# reaper would SIGKILL its own ancestor mid-run and this suite would never
# reach this line.
D12="$WORK/case12/scratchpad/self"
mkdir -p "$D12"
(
  cd "$D12" || exit 1
  ORPHAN_REAPER_LEDGER="$LEDGER" ORPHAN_REAPER_SCOPE_PREFIX="$WORK" "$SCRIPT" --floor 1 >/tmp/orphan-reaper-case12.out 2>&1
)
RC12=$?
if [ "$RC12" -eq 0 ] && kill -0 $$ 2>/dev/null; then
  ok "12 the reaper does not kill itself or its own ancestor chain (this suite is still alive)"
else bad "12 self/ancestor exclusion" "rc=$RC12"; fi
rm -f /tmp/orphan-reaper-case12.out

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
