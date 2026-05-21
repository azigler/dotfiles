#!/bin/bash
# WorktreeCreate hook — override Claude Code's default worktree placement
# so that subagent worktrees dispatched from inside a submodule land in
# that submodule's `.claude/worktrees/`, not the parent umbrella's.
#
# Why this is needed:
# Even after `git submodule absorbgitdirs <sub>` properly absorbs the
# submodule's gitdir, Claude Code's default placement heuristic still
# walks up to the parent umbrella's `.git/` and creates the worktree at
# `<parent>/.claude/worktrees/<name>`. The `pre-tool-use-worktree-guard.sh`
# hook then blocks the subagent from writing into `<parent>/<submodule>/`,
# so the agent can't do its work in the right place. Verified 2026-05-18
# during skills-library wave 2 (skills-library-0d5).
#
# This hook fixes the placement by running `git worktree add` from
# whichever git context `git rev-parse --show-toplevel` resolves to. When
# the orchestrator's cwd is inside an absorbed submodule, that's the
# submodule's toplevel — exactly what we want.
#
# Input protocol (stdin JSON, captured empirically — keys we try):
#   .tool_input.worktree_name
#   .tool_input.name
#   .worktree_name
#   .name
#   .hookSpecificOutput.worktreeName
# Whichever resolves is the agent's slug (e.g. "agent-XXXX").
#
# Output protocol: a single line on stdout = the absolute path of the
# newly-created worktree. The harness reads that and tells the subagent
# to start there.

set -uo pipefail

LOG=/tmp/worktree-create-hook.log

INPUT=$(cat 2>/dev/null || echo '{}')

{
  echo ""
  echo "===== WorktreeCreate hook $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  echo "PWD: $(pwd)"
  echo "INPUT JSON: $INPUT"
} >> "$LOG"

NAME=$(echo "$INPUT" | jq -r '
  .tool_input.worktree_name
  // .tool_input.name
  // .worktree_name
  // .name
  // .hookSpecificOutput.worktreeName
  // empty
' 2>/dev/null)

if [ -z "$NAME" ]; then
  echo "could not extract worktree name from input — falling back" >> "$LOG"
  echo "WorktreeCreate hook: missing worktree name in input" >&2
  exit 1
fi

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -z "$GIT_ROOT" ]; then
  echo "cwd is not a git repo — falling back" >> "$LOG"
  echo "WorktreeCreate hook: cwd is not in a git repository" >&2
  exit 1
fi

WT_PATH="$GIT_ROOT/.claude/worktrees/$NAME"
BRANCH="worktree-$NAME"

mkdir -p "$GIT_ROOT/.claude/worktrees"

# CRITICAL: redirect BOTH stdout and stderr of `git worktree add` into the
# log. `git worktree add` prints "HEAD is now at <hash> <subject>" to
# STDOUT (and "Preparing worktree (new branch ...)" to STDERR). If we let
# stdout reach the harness, that text gets concatenated with our final
# `echo "$WT_PATH"` and the harness reads the whole multi-line blob as
# the cwd. That mangled cwd then propagates to SubagentStart's `cwd`
# field, breaking the .beads/ symlink setup downstream.
# Only `echo "$WT_PATH"` at the end of this script should write to stdout.
if ! git -C "$GIT_ROOT" worktree add -B "$BRANCH" "$WT_PATH" HEAD >>"$LOG" 2>&1; then
  echo "git worktree add failed for $WT_PATH (branch $BRANCH)" >> "$LOG"
  echo "WorktreeCreate hook: git worktree add failed; see $LOG" >&2
  exit 1
fi

# Lock so the orchestrator's auto-cleanup paths can't yank it mid-run.
# Redirect both streams for the same reason as above.
git -C "$GIT_ROOT" worktree lock \
  --reason "claude agent $NAME (pid $$)" "$WT_PATH" >>"$LOG" 2>&1 || true

{
  echo "GIT_ROOT: $GIT_ROOT"
  echo "WT_PATH:  $WT_PATH"
  echo "BRANCH:   $BRANCH"
} >> "$LOG"

# Protocol: print the worktree path to stdout.
echo "$WT_PATH"
exit 0
