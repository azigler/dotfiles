#!/usr/bin/env bash
# Test for pre-worktree-remove-guard.sh — the PreToolUse:Bash gate that refuses
# `git worktree remove` while a LIVE agent still owns the tree (dotfiles-3135).
#
# Hook test convention (see test-pre-tmux-kill-guard.sh, test-orphan-reaper.sh):
#   - executable bash; non-zero exit = suite failed
#   - PASS/FAIL summary on the last line
#   - every failure line begins with its CASE NUMBER, because the mutation
#     harness asserts that a mutant dies on the case(s) it NAMES
#
# HERMETIC. Every fixture process is spawned by this suite into a throwaway
# mktemp tree; nothing here touches a real worktree, and no process outside the
# suite's own children is ever signalled. All fixtures are SIGKILLed in an EXIT
# trap. The guard itself is read-only — it inspects /proc and exits — so running
# the real scan against the real machine is safe by construction.
#
# TWO FIXTURE TRICKS WORTH KNOWING BEFORE YOU EDIT THIS:
#
#  1. The "live agent" fixture is a COPY OF BASH NAMED `node`. /proc/PID/comm
#     comes from the basename of the executed FILE (not argv[0], so `exec -a`
#     cannot fake it), and the guard's live/debris split is comm-driven — so a
#     file named `node` is exactly what a real claude/node agent looks like to
#     the code under test. The first attempt copied `sleep` instead and the
#     fixture died instantly: coreutils on this box is uutils, a MULTI-CALL
#     binary that dispatches on its own name and exits when invoked as `node`.
#     bash does not care what it is called.
#
#  2. Idle fixtures block on an unopened FIFO (`read _ < fifo`). `read` is a
#     builtin, so the process has NO children and burns NO CPU — which is what
#     makes it debris under the guard's definition. The obvious alternative,
#     `while true; do sleep 1; done`, forks a `sleep` every second and would be
#     classified LIVE by the working-descendant rule, correctly but uselessly.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-worktree-remove-guard.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wt-remove-guard-suite.XXXXXX")

PASS=0; FAIL=0
FAILED_NAMES=()
SPAWNED=()

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n     -> %s\n' "$1" "${2:-}"; }

cleanup() {
  local p
  for p in "${SPAWNED[@]+"${SPAWNED[@]}"}"; do kill -9 "$p" 2>/dev/null; done  # allow-suppress
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin"
cp "$(command -v bash)" "$WORK/bin/node"
mkfifo "$WORK/park"

# wait_for_cwd PID — the kernel must have completed the chdir before /proc is read
wait_for_cwd() {
  local i=0
  while [ ! -e "/proc/$1/cwd" ] && [ "$i" -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
  sleep 0.15
}

# spawn_live DIR -> pid of a process whose comm is `node`, parked on the fifo.
spawn_live() {
  ( cd "$1" && exec "$WORK/bin/node" -c "read -r _ < '$WORK/park'" ) </dev/null >/dev/null 2>&1 &
  local pid=$!
  SPAWNED+=("$pid")
  wait_for_cwd "$pid"
  echo "$pid"
}

# spawn_debris DIR -> pid of an idle shell: comm=bash, no children, no CPU.
spawn_debris() {
  ( cd "$1" && exec bash -c "read -r _ < '$WORK/park'" ) </dev/null >/dev/null 2>&1 &
  local pid=$!
  SPAWNED+=("$pid")
  wait_for_cwd "$pid"
  echo "$pid"
}

# spawn_busy_shell DIR -> an idle-LOOKING shell (comm=bash, 0 CPU) whose CHILD
# is doing work in a different directory. Debris by every test except the
# working-descendant rule, which is the point.
spawn_busy_shell() {
  ( cd "$1" && exec bash -c "( cd / && exec sleep 600 ) ; :" ) </dev/null >/dev/null 2>&1 &
  local pid=$!
  SPAWNED+=("$pid")
  wait_for_cwd "$pid"
  echo "$pid"
}

# fire <command> [cwd] -> RC + OUT (the hook's stderr and stdout together)
fire() {
  OUT=$(printf '%s' "$1" | jq -Rs --arg c "${2:-$WORK}" '{tool_input:{command:.},cwd:$c}' \
        | bash "$HOOK" 2>&1)
  RC=$?
}

echo "=== pre-worktree-remove-guard.sh =========================================="

# --- MUST NOT FIRE AT ALL --------------------------------------------------

fire 'git status'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "1 an unrelated command is untouched (exit 0, silent)"
else bad "1 unrelated command untouched" "rc=$RC out=$OUT"; fi

fire 'git worktree list --porcelain'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "2 a non-removal worktree subcommand is untouched"
else bad "2 git worktree list untouched" "rc=$RC out=$OUT"; fi

fire 'git commit -m "guard: refuse git worktree remove while a live agent owns the tree"'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "3 prose that MENTIONS the command never trips the guard"
else bad "3 prose mention untouched" "rc=$RC out=$OUT"; fi

# --- THE CLEAN CASE: a tree with no processes must never be blocked ---------
C4="$WORK/case4/wt"
mkdir -p "$C4"
fire "git worktree remove --force --force $C4"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "4 a worktree with NO processes under it is removed silently"
else bad "4 empty worktree removal is silent" "rc=$RC out=$OUT"; fi

# --- THE INCIDENT: live agent work blocks ----------------------------------
C5="$WORK/case5/wt"
mkdir -p "$C5/src"
P5=$(spawn_live "$C5/src")
fire "git worktree remove --force --force $C5"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P5" \
   && printf '%s' "$OUT" | grep -q 'dotfiles-3135'; then
  ok "5 a LIVE agent process (comm=node) BLOCKS, naming its pid and the incident"
else bad "5 live agent blocks" "rc=$RC pid=$P5 out=$OUT"; fi

C6="$WORK/case6/wt"
mkdir -p "$C6"
P6=$(spawn_busy_shell "$C6")
fire "git worktree remove $C6"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P6"; then
  ok "6 an idle-looking shell with a WORKING CHILD elsewhere blocks"
else bad "6 shell with working child blocks" "rc=$RC pid=$P6 out=$OUT"; fi

# --- DEBRIS: allowed, with a note that names it and the reaper -------------
C7="$WORK/case7/wt"
mkdir -p "$C7"
P7=$(spawn_debris "$C7")
fire "git worktree remove --force $C7"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "pid $P7" \
   && printf '%s' "$OUT" | grep -q 'orphan-reaper.sh --worktree'; then
  ok "7 reapable debris (idle shell, no children, no CPU) ALLOWS, with a note naming it"
else bad "7 debris allows with a note" "rc=$RC pid=$P7 out=$OUT"; fi

# --- OVERRIDE: allowed, loudly ---------------------------------------------
C8="$WORK/case8/wt"
mkdir -p "$C8"
P8=$(spawn_live "$C8")
fire "WORKTREE_REMOVE_OVERRIDE_LIVE=1 git worktree remove --force --force $C8"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'OVERRIDE ACCEPTED' \
   && printf '%s' "$OUT" | grep -q 'DISCARDING LIVE WORK' \
   && printf '%s' "$OUT" | grep -q "pid $P8"; then
  ok "8 an in-command override allows the removal and says loudly what is being discarded"
else bad "8 override allows loudly" "rc=$RC pid=$P8 out=$OUT"; fi

# The same tree, WITHOUT the override, must still block — otherwise case 8
# proves nothing about the override and only that this tree is allowed.
fire "git worktree remove --force --force $C8"
if [ "$RC" -eq 2 ]; then
  ok "8b the same live tree without the override still blocks (case 8 is not vacuous)"
else bad "8b override is load-bearing" "rc=$RC out=$OUT"; fi

# --- FAIL OPEN, LOUDLY ------------------------------------------------------
fire 'git worktree remove --force "$WT"'
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'could not resolve' \
   && printf '%s' "$OUT" | grep -q 'FAILING OPEN'; then
  ok "9 an unexpandable (variable) path FAILS OPEN and announces the degradation"
else bad "9 variable path fails open loudly" "rc=$RC out=$OUT"; fi

fire 'git worktree remove --force'
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'FAILING OPEN'; then
  ok "10 a removal with NO path argument FAILS OPEN and announces it"
else bad "10 missing path fails open loudly" "rc=$RC out=$OUT"; fi

fire ''
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "11 an empty command is a silent no-op"
else bad "11 empty command" "rc=$RC out=$OUT"; fi

# --- PATH SCOPING: a SIBLING tree's live work is not this tree's ------------
# The sibling shares a string prefix with the target on purpose: a prefix match
# without a path-component boundary would swallow it, which is mutant M4.
C12="$WORK/case12/wt"
C12S="$WORK/case12/wt-sibling"
mkdir -p "$C12" "$C12S"
P12=$(spawn_live "$C12S")
fire "git worktree remove --force $C12"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "12 live work in a PREFIX-SHARING sibling tree does not block this removal"
else bad "12 sibling tree isolation" "rc=$RC pid=$P12 out=$OUT"; fi

# --- COMMAND SHAPES the real cleanup sequence uses --------------------------
C13="$WORK/case13/wt"
mkdir -p "$C13"
P13=$(spawn_live "$C13")

fire "git worktree remove --force \"$C13\""
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P13"; then
  ok "13 a QUOTED literal path is still resolved (skeleton blanks it; raw is the fallback)"
else bad "13 quoted literal path" "rc=$RC out=$OUT"; fi

fire "git -C $WORK worktree remove --force --force $C13"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P13"; then
  ok "14 \`git -C <repo> worktree remove\` with repeated flags is matched"
else bad "14 git -C form with repeated flags" "rc=$RC out=$OUT"; fi

fire "cd $WORK && git worktree remove $C13 ; echo done"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P13"; then
  ok "15 a removal chained inside && / ; is matched (trailing punctuation tolerated)"
else bad "15 chained removal" "rc=$RC out=$OUT"; fi

fire "git worktree remove ../case13/wt" "$WORK/case13"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P13"; then
  ok "16 a RELATIVE path resolves against the tool call's cwd, not the hook's"
else bad "16 relative path resolution" "rc=$RC out=$OUT"; fi

# --- DEBRIS AND LIVE TOGETHER ----------------------------------------------
C17="$WORK/case17/wt"
mkdir -p "$C17/a" "$C17/b"
P17L=$(spawn_live "$C17/a")
P17D=$(spawn_debris "$C17/b")
fire "git worktree remove --force $C17"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "pid $P17L" \
   && printf '%s' "$OUT" | grep -q 'reapable debris, not the reason' \
   && printf '%s' "$OUT" | grep -q "pid $P17D"; then
  ok "17 debris beside live work blocks, and the debris is named as NOT the reason"
else bad "17 mixed debris + live" "rc=$RC live=$P17L debris=$P17D out=$OUT"; fi

# --- THE BLOCK MESSAGE IS PART OF THE GUARD --------------------------------
# A block the agent cannot act on gets overridden reflexively. The message must
# carry the incident and BOTH legitimate ways forward.
C18="$WORK/case18/wt"
mkdir -p "$C18"
P18=$(spawn_live "$C18")
fire "git worktree remove --force $C18"
if [ "$RC" -eq 2 ] \
   && printf '%s' "$OUT" | grep -q 'dotfiles-3135, 2026-08-09' \
   && printf '%s' "$OUT" | grep -q 'WAIT for the agent' \
   && printf '%s' "$OUT" | grep -q 'WORKTREE_REMOVE_OVERRIDE_LIVE=1 git worktree remove'; then
  ok "18 the block names the incident and BOTH legitimate paths (wait / explicit override)"
else bad "18 block message content" "rc=$RC pid=$P18 out=$OUT"; fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf 'PASS %d/%d\n' "$PASS" "$((PASS + FAIL))"
  exit 0
fi
printf 'FAILED:\n'
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
printf 'FAIL %d/%d\n' "$FAIL" "$((PASS + FAIL))"
exit 1
