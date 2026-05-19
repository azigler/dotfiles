#!/bin/bash
# PreToolUse (Bash): catch orchestrator cwd drift into a worktree.
#
# The bug: after a worktree subagent (subagent_type=subagent,
# isolation=worktree) completes and the harness returns control to the
# orchestrator, the orchestrator's persistent Bash-tool cwd is silently
# shifted from the project root to inside `.claude/worktrees/agent-<id>/`.
# The next `git merge worktree-agent-<id> --no-edit` then returns
# "Already up to date" because the orchestrator is "on" the subagent's
# branch instead of main — the merge silently no-ops.
#
# Discovered 2026-05-19 during skills-library-bc9 wave merges. Tracked as
# `skills-library-1vs`. We can't fix the harness-level cwd-shift from a
# user hook, but we CAN catch the dangerous downstream commands and force
# a clear recovery message.
#
# Strategy: when cwd matches `*/.claude/worktrees/agent-*/*` AND the
# command is one that would silently misbehave from that cwd (git merge
# of the same worktree, br close, br update, git commit on main, git push),
# block with exit 2 + stderr instructing the orchestrator to cd back to
# the inferred project root.
#
# Subagents legitimately operate inside their own worktree — we detect
# subagent context via the `agent_id` field on stdin and pass through.
#
# Conservative — does NOT block on inspection commands (ls, cat, head,
# tail, grep, rg, find, pwd, cd) so recovery is easy.

set -uo pipefail

INPUT=$(cat 2>/dev/null || echo '{}')

# Subagent context: stdin has agent_id. Their worktree cwd is correct;
# skip the guard entirely.
HAS_AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$HAS_AGENT_ID" ] && exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd 2>/dev/null || echo "")

# Only fire if cwd is inside a .claude/worktrees/agent-* path
case "$CWD" in
  */.claude/worktrees/agent-*) ;;
  *) exit 0 ;;
esac

# Infer the project root by stripping the worktree suffix.
PROJECT_ROOT=$(echo "$CWD" | sed -E 's|/\.claude/worktrees/agent-[^/]+/?.*$||')
[ -z "$PROJECT_ROOT" ] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Catch only commands that would silently misbehave from a worktree cwd.
# Inspection commands stay allowed so recovery is fast.
DANGEROUS=false
case "$COMMAND" in
  *git\ merge\ worktree-agent-*) DANGEROUS=true ;;
  *git\ commit*|*git\ push*|*git\ pull*) DANGEROUS=true ;;
  *git\ checkout\ main*|*git\ checkout\ master*) DANGEROUS=true ;;
  *br\ close*|*br\ update\ *--status*|*br\ sync*) DANGEROUS=true ;;
  *git\ worktree\ remove*|*git\ branch\ -D\ worktree-agent-*) DANGEROUS=true ;;
esac

[ "$DANGEROUS" = "false" ] && exit 0

cat >&2 <<EOF

⚠ Orchestrator cwd drifted into a worktree (skills-library-1vs guard)

  cwd:           $CWD
  inferred root: $PROJECT_ROOT

The command you're about to run will silently misbehave from this cwd:
  - git merge of a worktree-agent-* branch will say "Already up to date"
    because you're checked out on that branch (no-op)
  - br close / br update --status will write to the symlinked .beads/
    but the next git commit on main may miss the JSONL change
  - git commit will record against the worktree's branch, not main

Recover by cd-ing back to the project root, then re-run:

  cd $PROJECT_ROOT
  # then your original command

This guard is part of the harness fix for skills-library-1vs. To bypass
intentionally (rare — usually means you're doing something the guard is
exactly designed to prevent), use a non-matching command prefix or run
the command through a subshell that cd's first:
  ( cd $PROJECT_ROOT && <your command> )
EOF

exit 2
