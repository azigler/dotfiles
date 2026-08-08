#!/bin/bash
# Test for the hook/skills symlink TRIPLE guard in session-start.sh
# (dotfiles-qvee).
#
# What it guards: ~/.claude, ~/.claude-work, ~/.claude-tick each symlink
# hooks/ and skills/ INDEPENDENTLY to the same target. A retarget (the
# demesne-split cutover, dotfiles-retarget-claude-symlinks-860z) that repoints
# one tap and misses the others leaves the missed seat(s) silently running the
# pre-move tier — a fleet config split with no signal anywhere.
#
# Hook test convention (see test-worktree-guard.sh):
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# HERMETIC BY CONSTRUCTION, same discipline as
# test-session-start-settings-symlink.sh: every case runs under a temp $HOME,
# so the real ~/.claude, ~/.claude-work, ~/.claude-tick symlinks are never
# read or written by this suite. The final case asserts that explicitly.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

REAL_SEATS=("$HOME/.claude" "$HOME/.claude-work" "$HOME/.claude-tick")
REAL_BEFORE=()
for _s in "${REAL_SEATS[@]}"; do
  if [ -L "$_s/hooks" ]; then REAL_BEFORE+=("$(readlink -f "$_s/hooks" 2>/dev/null)"); else REAL_BEFORE+=("<none>"); fi
  if [ -L "$_s/skills" ]; then REAL_BEFORE+=("$(readlink -f "$_s/skills" 2>/dev/null)"); else REAL_BEFORE+=("<none>"); fi
done

# A REAL repo with a REAL worktree, so IN_WORKTREE detection is exercised
# rather than simulated (same fixture shape as the settings-symlink suite).
PROJ="$BASE/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
echo seed > "$PROJ/seed"; git -C "$PROJ" add seed; git -C "$PROJ" commit -qm seed
PROJ_WT="$PROJ/.claude/worktrees/agent-test"
git -C "$PROJ" worktree add -q -b worktree-agent-test "$PROJ_WT" >/dev/null
cleanup_proj() { git -C "$PROJ" worktree remove --force "$PROJ_WT" >/dev/null 2>&1; }

run_hook() { # <fakehome> [worktree] -> stdout
  local fh=$1 kind=${2:-plain} cwd
  if [ "$kind" = "worktree" ]; then cwd="$PROJ_WT"; else cwd="$PROJ"; fi
  ( cd "$cwd" && env HOME="$fh" HARNESS_SESSION_START_LOG="$fh/hook.log" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      bash "$HOOK" <<< "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$cwd\"}" )
}

# new_home builds a fake $HOME with ONE real settings.json symlink (so the
# unrelated symlink guard above stays quiet) and lets each case populate
# .claude / .claude-work / .claude-tick's hooks/skills links itself.
new_home() {
  local fh
  fh=$(mktemp -d "$BASE/home.XXXXXX")
  mkdir -p "$fh/dotfiles/claude" "$fh/.claude"
  printf '%s\n' '{}' > "$fh/dotfiles/claude/settings.json"
  ln -s "$fh/dotfiles/claude/settings.json" "$fh/.claude/settings.json"
  printf '%s' "$fh"
}

# seat_link <fh> <seat> <link> <targetdir> — makes <fh>/<seat>/<link> a
# symlink to <targetdir> (created as a real dir if it doesn't exist yet).
seat_link() {
  local fh=$1 seat=$2 link=$3 target=$4
  mkdir -p "$fh/$seat" "$target"
  ln -s "$target" "$fh/$seat/$link"
}

# --- 1. all three seats agree on both links -> SILENT ----------------------
FH=$(new_home)
TA="$FH/target-a"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
seat_link "$FH" .claude-work hooks "$TA/hooks"
seat_link "$FH" .claude-work skills "$TA/skills"
seat_link "$FH" .claude-tick hooks "$TA/hooks"
seat_link "$FH" .claude-tick skills "$TA/skills"
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -qi 'symlink triple'; then
  bad "all-same: must not warn (got: $(echo "$OUT" | grep -i 'symlink triple' | head -1))"
else
  ok
fi

# --- 2. one seat diverged (claude-tick's hooks points elsewhere) -> LOUD ---
FH=$(new_home)
TA="$FH/target-a"; TB="$FH/target-b"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
seat_link "$FH" .claude-work hooks "$TA/hooks"
seat_link "$FH" .claude-work skills "$TA/skills"
seat_link "$FH" .claude-tick hooks "$TB/hooks"
seat_link "$FH" .claude-tick skills "$TA/skills"
OUT=$(run_hook "$FH")
echo "$OUT" | grep -qi 'DIVERGED' \
  && ok || bad "one-diverged: warns with DIVERGED"
echo "$OUT" | grep -qF 'dotfiles-qvee' \
  && ok || bad "one-diverged: cites dotfiles-qvee"
echo "$OUT" | grep -qF '.claude-tick/hooks' \
  && ok || bad "one-diverged: names the diverged seat/link (.claude-tick/hooks)"
# The agreeing pair must NOT be mentioned as diverged.
if echo "$OUT" | grep -F '.claude-work/hooks' | grep -q '\->'; then
  bad "one-diverged: must not flag the agreeing seats too"
else
  ok
fi

# --- 3. only ~/.claude exists on this box (seat-absent) -> SILENT ----------
#     (a box with no work/tick tap — nothing to compare against.)
FH=$(new_home)
TA="$FH/target-a"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -qi 'symlink triple'; then
  bad "seat-absent: must not warn when only one seat exists (got: $(echo "$OUT" | grep -i 'symlink triple' | head -1))"
else
  ok
fi

# --- 4. a seat dir exists but hasn't been symlinked yet (fresh install,     -
#        pre-sync.sh) -> SILENT, not this guard's job ------------------------
FH=$(new_home)
TA="$FH/target-a"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
mkdir -p "$FH/.claude-work"   # dir exists, no hooks/skills links inside at all
OUT=$(run_hook "$FH")
if echo "$OUT" | grep -qi 'symlink triple'; then
  bad "seat-dir-no-links: must not warn (nothing to compare against)"
else
  ok
fi

# --- 5. skills diverges independently of hooks (both links checked) --------
FH=$(new_home)
TA="$FH/target-a"; TB="$FH/target-b"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
seat_link "$FH" .claude-work hooks "$TA/hooks"
seat_link "$FH" .claude-work skills "$TB/skills"
OUT=$(run_hook "$FH")
echo "$OUT" | grep -qF '.claude-work/skills' \
  && ok || bad "skills-diverged: names the diverged skills link independently of hooks"

# --- 6. worktree sessions are exempt (this fires on EVERY top-level session) -
FH=$(new_home)
TA="$FH/target-a"; TB="$FH/target-b"
seat_link "$FH" .claude hooks "$TA/hooks"
seat_link "$FH" .claude skills "$TA/skills"
seat_link "$FH" .claude-work hooks "$TB/hooks"
seat_link "$FH" .claude-work skills "$TA/skills"
OUT=$(run_hook "$FH" worktree)
if echo "$OUT" | grep -qi 'symlink triple'; then
  bad "worktree: must not run the seat-triple guard for a dispatched subagent"
else
  ok
fi

# --- 7. THE TEST'S OWN SAFETY PROPERTY --------------------------------------
REAL_AFTER=()
for _s in "${REAL_SEATS[@]}"; do
  if [ -L "$_s/hooks" ]; then REAL_AFTER+=("$(readlink -f "$_s/hooks" 2>/dev/null)"); else REAL_AFTER+=("<none>"); fi
  if [ -L "$_s/skills" ]; then REAL_AFTER+=("$(readlink -f "$_s/skills" 2>/dev/null)"); else REAL_AFTER+=("<none>"); fi
done
MATCH=true
for i in "${!REAL_BEFORE[@]}"; do
  [ "${REAL_BEFORE[$i]}" = "${REAL_AFTER[$i]}" ] || MATCH=false
done
if $MATCH; then
  ok
else
  bad "this test mutated one of the REAL seats' hooks/skills symlinks"
fi

# --- Summary ---
cleanup_proj
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
