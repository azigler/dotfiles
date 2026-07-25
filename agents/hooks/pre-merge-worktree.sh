#!/bin/bash
# PreToolUse (Bash): block `git merge worktree-agent-*` if the worktree
# branch's last commit looks broken (no Bead: trailer, no actual content).
# Catches cases where the orchestrator merges a subagent before its
# /handoff cleared.
# Exit 2 = block and feed error to agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null); [ -z "$SKEL" ] && SKEL="$COMMAND"

# Only intercept git merge of worktree-agent-* branches
echo "$SKEL" | grep -qE 'git merge[[:space:]]+worktree-agent-' || exit 0

# Extract the worktree branch name
BRANCH=$(echo "$SKEL" | grep -oE 'worktree-agent-[a-zA-Z0-9_-]+' | head -1)
[ -z "$BRANCH" ] && exit 0

# Resolve the SESSION's cwd from the stdin JSON — the same block
# pre-commit-checks.sh, pre-bead-close.sh and pre-tool-use-worktree-guard.sh
# all use. This was the only Bash PreToolUse hook that never read `.cwd`, so
# it evaluated the HOOK PROCESS's cwd: whenever those differ it inspected a
# DIFFERENT REPOSITORY than the one the merge would run in — where the
# branch usually doesn't exist at all, making the hook silently exit 0 and
# gate nothing.
JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -n "$JSON_CWD" ]; then
  CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
  [ -z "$CWD" ] && CWD="$JSON_CWD"
else
  CWD=$(pwd -P)
fi
[ -d "$CWD" ] || CWD=$(pwd -P)

# Verify the branch exists in THAT repo
if ! git -C "$CWD" rev-parse --verify "$BRANCH" &>/dev/null; then
  exit 0  # let git's own error fire
fi

# Derive the merge base instead of hardcoding `main`. On a master-default
# repo `git log main..$BRANCH` fails outright, COMMIT_COUNT lands at 0, and
# EVERY worktree merge was blocked with "no commits beyond main" — a branch
# that doesn't exist there. (Latent on this host: all 11 repos are on main.)
# Order: origin/HEAD's target, then its remote-tracking ref, then the two
# conventional names, then HEAD as a last resort.
resolve_base() {
  local c
  for c in "$@"; do
    [ -n "$c" ] || continue
    if git -C "$CWD" rev-parse --verify --quiet "$c^{commit}" >/dev/null 2>&1; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}
ORIGIN_HEAD=$(git -C "$CWD" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
BASE=$(resolve_base "${ORIGIN_HEAD#origin/}" "$ORIGIN_HEAD" main master HEAD) || exit 0

# Check 1: the branch has commits beyond the base
COMMIT_COUNT=$(git -C "$CWD" log "$BASE..$BRANCH" --oneline 2>/dev/null | wc -l)
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "Blocked: $BRANCH has no commits beyond $BASE. Nothing to merge." >&2
  exit 2
fi

# Check 2: every commit on the branch has a Bead: trailer.
#
# `tformat`, NOT `format` — and this was NOT cosmetic. `--pretty=format:`
# omits the trailing newline, so `while read` hit EOF without a delimiter on
# the LAST line and skipped its loop body entirely. On a single-commit
# branch — the normal shape of a subagent worktree — that meant check 2
# examined ZERO commits and the trailer gate never fired at all. Found by
# the new test-pre-merge-worktree.sh (dotfiles-b9ii); it predates this
# change and is not part of the reported audit.
MISSING_BEAD=$(git -C "$CWD" log "$BASE..$BRANCH" --pretty=tformat:'%H %s' 2>/dev/null | while read -r hash subject; do
  if ! git -C "$CWD" show -s --format=%B "$hash" 2>/dev/null | grep -q '^Bead:'; then
    echo "$hash  $subject"
  fi
done)

if [ -n "$MISSING_BEAD" ]; then
  echo "Blocked: $BRANCH has commits without a Bead: trailer:" >&2
  echo "$MISSING_BEAD" >&2
  echo "" >&2
  echo "Subagents must include 'Bead: <id>' in commit trailers (see /commit, /handoff)." >&2
  echo "Fix the trailer (e.g., git rebase + reword) before merging." >&2
  exit 2
fi

exit 0
