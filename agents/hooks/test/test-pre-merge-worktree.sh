#!/bin/bash
# Test for pre-merge-worktree.sh — the pre-merge gate on worktree-agent-*
# branches (no commits / missing Bead: trailer).
#
# Regression targets (dotfiles-b9ii, bug 6):
#   a) :26,33 hardcoded `main` as the merge base. On a master-default repo
#      `git log main..$BRANCH` fails, COMMIT_COUNT lands at 0, and EVERY
#      worktree merge was blocked with "no commits beyond main" — naming a
#      branch that does not exist there.
#   b) :8-26 this was the only Bash PreToolUse hook that never read `.cwd`
#      from stdin, so it evaluated the HOOK PROCESS's cwd rather than the
#      session's. Pointed at the wrong repository the branch is not found,
#      the hook exits 0, and the gate silently checks nothing.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-merge-worktree.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

ELSEWHERE=$(mktemp -d)
REPOS=$(mktemp -d)
trap 'rm -rf "$ELSEWHERE" "$REPOS"' EXIT

# Build a repo whose default branch is $1, with a worktree-agent branch
# carrying $2 ("bead" | "nobead" | "empty") on top of it.
make_repo() { # <default-branch> <kind> -> prints path
  local def=$1 kind=$2
  local r; r=$(mktemp -d "$REPOS/repo.XXXXXX")
  git -C "$r" init -q -b "$def"
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  echo seed > "$r/seed.txt"
  git -C "$r" add seed.txt
  git -C "$r" commit -qm "seed"
  git -C "$r" branch worktree-agent-test1
  case "$kind" in
    bead)
      git -C "$r" checkout -q worktree-agent-test1
      echo work > "$r/work.txt"; git -C "$r" add work.txt
      git -C "$r" commit -qm "feat: work

Bead: demo-1"
      git -C "$r" checkout -q "$def" ;;
    nobead)
      git -C "$r" checkout -q worktree-agent-test1
      echo work > "$r/work.txt"; git -C "$r" add work.txt
      git -C "$r" commit -qm "feat: work with no trailer"
      git -C "$r" checkout -q "$def" ;;
    empty) : ;;   # branch exists but has no commits beyond the base
  esac
  printf '%s' "$r"
}

# Run the hook FROM $ELSEWHERE with `cwd` pointing at the repo — this is the
# real shape: the hook process cwd is not necessarily the session's.
run() { # <repo> -> "rc<TAB>stderr"
  local payload out rc
  payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"git merge worktree-agent-test1 --no-edit"},"cwd":%s}' \
            "$(printf '%s' "$1" | jq -Rs .)")
  out=$( cd "$ELSEWHERE" && printf '%s' "$payload" | bash "$HOOK" 2>&1 >/dev/null )
  rc=$?
  printf '%s\t%s' "$rc" "$out"
}

expect() { # <name> <repo> <want-rc> [want-stderr-substring]
  local r rc err
  r=$(run "$2"); rc=${r%%$'\t'*}; err=${r#*$'\t'}
  if [ "$rc" -ne "$3" ]; then
    bad "$1 (exit: want $3, got $rc; stderr: ${err:-<empty>})"; return
  fi
  if [ -n "${4:-}" ] && ! printf '%s' "$err" | grep -qF "$4"; then
    bad "$1 (stderr missing: $4; got: ${err:-<empty>})"; return
  fi
  ok
}

# --- main-default repos: today's working path must not regress ------------
expect "main-default: good branch allowed"        "$(make_repo main bead)"   0
expect "main-default: missing trailer blocked"    "$(make_repo main nobead)" 2 "without a Bead: trailer"
expect "main-default: empty branch blocked"       "$(make_repo main empty)"  2 "no commits beyond"

# --- master-default repos: bug 6a ----------------------------------------
# Pre-fix ALL THREE of these were blocked with "no commits beyond main".
expect "master-default: good branch allowed"      "$(make_repo master bead)"   0
expect "master-default: missing trailer blocked"  "$(make_repo master nobead)" 2 "without a Bead: trailer"
expect "master-default: empty branch blocked"     "$(make_repo master empty)"  2 "no commits beyond"

# The block message must name the ACTUAL base, not a hardcoded "main".
R=$(run "$(make_repo master empty)"); ERR=${R#*$'\t'}
case "$ERR" in
  *"beyond master"*) ok ;;
  *) bad "master-default: message names master as the base (got: ${ERR:-<empty>})" ;;
esac

# --- trunk-default repo: neither main nor master exists ------------------
expect "trunk-default: good branch allowed"       "$(make_repo trunk bead)"   0
expect "trunk-default: missing trailer blocked"   "$(make_repo trunk nobead)" 2 "without a Bead: trailer"

# --- bug 6b: the session cwd is what gets inspected ----------------------
# The hook process runs in $ELSEWHERE (not a git repo at all). If it ignored
# the stdin cwd, the branch would not resolve and it would exit 0 — passing
# a branch that should be blocked.
BADREPO=$(make_repo main nobead)
expect "session cwd honored: blocks from a foreign process cwd" "$BADREPO" 2 "without a Bead: trailer"

# A cwd that doesn't exist must not wedge anything.
r=$(run "/nonexistent/path/xyz"); rc=${r%%$'\t'*}
if [ "$rc" -eq 0 ]; then ok; else bad "nonexistent cwd is a no-op (got rc=$rc)"; fi

# --- non-merge commands are untouched ------------------------------------
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/tmp"}'
OUT=$( cd "$ELSEWHERE" && printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1 >/dev/null ); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "unrelated command is a no-op (rc=$RC out=$OUT)"; fi

# A merge of a NON-worktree branch is untouched.
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git merge feature/x"},"cwd":"/tmp"}'
OUT=$( cd "$ELSEWHERE" && printf '%s' "$PAYLOAD" | bash "$HOOK" 2>&1 >/dev/null ); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "non-worktree merge is a no-op (rc=$RC out=$OUT)"; fi

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
echo "FAIL: $FAIL/$TOTAL test cases failed"
exit 1
