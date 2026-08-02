#!/bin/bash
# Test for the self-referential .beads/.beads detector in session-start.sh.
#
# Regression target (dotfiles bd-8uqr):
# the cross-repo recovery snippet's `ln -s "$repo/.beads" .beads`, run from a
# repo ROOT rather than a fresh worktree, nests the link INSIDE the store as
# .beads/.beads -> .beads. Symlink-following tree walkers hit ELOOP. One of
# these sat in andrewzigler3 from 2026-07-17 to 2026-08-02, flaking a font
# spec, because nothing ever looked for it.
#
# The NEGATIVE control is the load-bearing half: a worktree's legitimate
# .beads symlink (-> the MAIN repo's store) must survive untouched. Deleting
# those would break bead sharing on every worktree on the machine — worse
# than the bug being fixed.
#
# Hook test convention (see test-session-start-merge-driver.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Hermetic: temp repos, temp HOME, temp $LOG.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

FAKEHOME=$(mktemp -d)
BASE=$(mktemp -d)
trap 'rm -rf "$FAKEHOME" "$BASE"' EXIT

new_repo() { # -> repo path, with a populated .beads store
  local r
  r=$(mktemp -d "$BASE/repo.XXXXXX")
  git -C "$r" init -q
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  echo seed > "$r/seed.txt"
  mkdir "$r/.beads"
  echo '{"id":"x-1"}' > "$r/.beads/issues.jsonl"
  git -C "$r" add seed.txt .beads/issues.jsonl
  git -C "$r" commit -qm seed
  printf '%s' "$r"
}

run_in() { # <dir> <logfile> -> stdout of the hook
  ( cd "$1" && env HOME="$FAKEHOME" HARNESS_SESSION_START_LOG="$2" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      bash "$HOOK" <<< '{"hook_event_name":"SessionStart"}' 2>/dev/null )
}

# --- POSITIVE CONTROL: the loop is created, then caught + healed ----------
# Built with the exact pre-fix snippet, so the test reproduces the defect
# rather than asserting against a hand-made approximation.
R=$(new_repo)
( cd "$R" && ln -s "$R/.beads" .beads )   # the pre-fix `ln -s TARGET .beads`

if [ -L "$R/.beads/.beads" ]; then ok
else bad "positive control: the pre-fix snippet actually creates the loop"; fi

L=$(mktemp)
OUT=$(run_in "$R" "$L")

if [ ! -e "$R/.beads/.beads" ]; then ok
else bad "positive: the loop symlink is removed"; fi

case "$OUT" in
  *"self-referential .beads/.beads"*) ok ;;
  *) bad "positive: the session is told (got: $(printf '%s' "$OUT" | tail -3))" ;;
esac

if grep -q 'BEADS LOOP HEALED' "$L"; then ok
else bad "positive: the heal is logged"; fi

# The STORE must survive — the whole point of `rm <link>` over `rm -rf`.
if [ -s "$R/.beads/issues.jsonl" ]; then ok
else bad "positive: the live bead store is NOT collateral damage"; fi

# Idempotent: a second run is silent and changes nothing.
L2=$(mktemp)
OUT2=$(run_in "$R" "$L2")
case "$OUT2" in
  *".beads/.beads"*) bad "positive: second run stays quiet" ;;
  *) ok ;;
esac
rm -f "$L" "$L2"

# --- NEGATIVE CONTROL: a legitimate worktree .beads symlink is untouched --
# <worktree>/.beads -> <main>/.beads is correct and expected. It must survive
# both the detector AND the resolve-through-the-symlink path (the detector
# runs after the worktree symlink step, so it sees the MAIN store from here).
R2=$(new_repo)
WT="$R2/.claude/worktrees/agent-neg"
mkdir -p "$R2/.claude/worktrees"
git -C "$R2" worktree add -q "$WT" -b worktree-agent-neg

L=$(mktemp)
run_in "$WT" "$L" > /dev/null

if [ -L "$WT/.beads" ]; then ok
else bad "negative: the worktree's own .beads symlink still exists"; fi

if [ "$(readlink -f "$WT/.beads")" = "$(readlink -f "$R2/.beads")" ]; then ok
else bad "negative: it still points at the MAIN repo's store"; fi

if [ -s "$R2/.beads/issues.jsonl" ]; then ok
else bad "negative: the main store is intact"; fi

if ! grep -q 'BEADS LOOP' "$L"; then ok
else bad "negative: the detector did not fire on a legitimate symlink"; fi
rm -f "$L"

# --- Worktree session HEALS the main repo's loop through the symlink ------
( cd "$R2" && ln -s "$R2/.beads" .beads )   # loop in MAIN, session in worktree
L=$(mktemp)
run_in "$WT" "$L" > /dev/null
if [ ! -e "$R2/.beads/.beads" ]; then ok
else bad "worktree: a main-repo loop is healed from a worktree session"; fi
if [ -L "$WT/.beads" ] && [ -s "$R2/.beads/issues.jsonl" ]; then ok
else bad "worktree: heal did not disturb the symlink or the store"; fi
rm -f "$L"

# --- A NON-self-referential .beads/.beads is reported, never deleted ------
R3=$(new_repo)
OTHER=$(new_repo)
ln -s "$OTHER/.beads" "$R3/.beads/.beads"
L=$(mktemp)
OUT=$(run_in "$R3" "$L")
if [ -L "$R3/.beads/.beads" ]; then ok
else bad "foreign link: NOT deleted (only self-referential ones are)"; fi
case "$OUT" in
  *"not self-referential"*) ok ;;
  *) bad "foreign link: reported to the session" ;;
esac
rm -f "$L"

# --- A real .beads/.beads DIRECTORY is never touched, and never described -
# The `-L` test (not `-e`) is what keeps this out of the branch entirely.
# Relaxing it to `-e` leaves the dir on disk but tells the session a real
# directory "is a symlink to ..." — a false statement, so assert silence too.
R4=$(new_repo)
mkdir "$R4/.beads/.beads"
echo data > "$R4/.beads/.beads/keep.txt"
L=$(mktemp)
OUT=$(run_in "$R4" "$L")
if [ -f "$R4/.beads/.beads/keep.txt" ]; then ok
else bad "real dir: a non-symlink .beads/.beads is left alone"; fi
# NB: match the detector's own phrasings, not the bare path — the untracked
# dir also shows up in this hook's ordinary `git status` context emission.
case "$OUT" in
  *"self-referential"* | *"is a symlink to"*)
    bad "real dir: detector stays silent (got: $(printf '%s' "$OUT" | grep -F '.beads/.beads'))" ;;
  *) ok ;;
esac
if ! grep -q 'BEADS LOOP' "$L"; then ok
else bad "real dir: nothing logged either"; fi
rm -f "$L"

# --- A repo with no .beads at all is unaffected (hook still exits 0) ------
R5=$(new_repo)
git -C "$R5" rm -rq --cached .beads > /dev/null
rm -rf "$R5/.beads"
L=$(mktemp)
run_in "$R5" "$L" > /dev/null
if [ $? -eq 0 ]; then ok; else bad "no-beads repo: hook still exits 0"; fi
rm -f "$L"

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
echo "FAIL: $FAIL/$TOTAL test cases failed"
exit 1
