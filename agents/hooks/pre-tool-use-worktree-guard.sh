#!/bin/bash
# PreToolUse (Write|Edit): block worktree subagents from writing files to
# the MAIN repo absolute path instead of their own worktree.
#
# Background (bd-n47):
# Worktree subagents occasionally use the main repo absolute path
# (e.g. /home/ubuntu/hackathon-gemma/foo) when calling Write/Edit, even
# though their cwd is the worktree
# (/home/ubuntu/hackathon-gemma/.claude/worktrees/agent-XXXX/foo). The
# main-repo write leaks files outside the subagent's branch.
#
# Behavior:
#   - exit 0 = allow the tool call
#   - exit 2 = BLOCK and surface stderr to the agent
#
# We BLOCK rather than silently remap. A silent remap could mask other
# bugs and gives the agent zero feedback; an explicit block surfaces in
# the agent's transcript so the agent can correct on the next turn.
#
# cwd-detection mechanism:
# Claude Code passes the session cwd as the top-level `cwd` field on
# stdin JSON. We prefer that, and fall back to `pwd` if the field is
# absent (older runtimes). Both anchor to the agent's actual working
# directory.
#
# Test convention (new): hook tests live in
#   ~/.claude/hooks/test/test-<hook-name>.sh
# (mirrored to dotfiles/agents/hooks/test/...) and are plain bash
# scripts that pipe a JSON payload into the hook and assert the exit
# code + stderr.
#
# Edge cases handled:
#   - file_path with `..` traversal: we normalize the file_path with
#     `realpath -m` (no requirement that the file exist) before the
#     prefix comparison, so `<main>/../foo` no longer slips through
#   - symlinks in cwd: we resolve `cwd` with `pwd -P` / `realpath` so
#     symlink shenanigans don't fool the prefix check
#   - non-absolute file paths: we let those through (the Write tool
#     resolves them against the agent's cwd, which is the worktree)
#   - hook running OUTSIDE a worktree: exit 0 immediately, no-op
#
# bd-n47

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only act on Write or Edit; ignore everything else (Bash, Read, etc.)
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Non-absolute paths get resolved by the tool against agent cwd → safe.
case "$FILE_PATH" in
  /*) ;;
  *) exit 0 ;;
esac

# Resolve cwd: prefer Claude Code's JSON-supplied `cwd`, fall back to
# `pwd -P` (resolves symlinks) so the prefix comparison is canonical.
JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -n "$JSON_CWD" ]; then
  CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
  [ -z "$CWD" ] && CWD="$JSON_CWD"
else
  CWD=$(pwd -P)
fi

# Only act if cwd is inside a worktree under .claude/worktrees/agent-*
case "$CWD" in
  */.claude/worktrees/agent-*) ;;
  *) exit 0 ;;
esac

# Determine the main project root: strip /.claude/worktrees/agent-* and
# everything after.
MAIN_ROOT=$(echo "$CWD" | sed -E 's|/\.claude/worktrees/agent-[^/]+(/.*)?$||')
[ -z "$MAIN_ROOT" ] && exit 0

# Normalize file_path so traversal sequences (`..`) can't bypass the
# prefix check. `realpath -m` doesn't require the path to exist.
NORM_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Allow: path is inside the worktree.
case "$NORM_PATH" in
  "$CWD"/*|"$CWD") exit 0 ;;
esac

# Block: path is inside the main repo but NOT inside the worktree.
case "$NORM_PATH" in
  "$MAIN_ROOT"/*)
    SUGGESTED="${NORM_PATH/$MAIN_ROOT/$CWD}"
    cat >&2 <<EOF
Blocked: worktree subagent attempted to Write/Edit a MAIN repo path:

  $FILE_PATH

You are working in the worktree at:

  $CWD

File writes must use worktree-relative paths or absolute paths anchored
at your worktree, NOT the main project root. The corrected path is:

  $SUGGESTED

This is the recurring bd-n47 bug. See ~/.claude/hooks/pre-tool-use-worktree-guard.sh
for the full guard logic and ~/.claude/skills/dispatch/SKILL.md for the
dispatch-time warning.
EOF
    exit 2
    ;;
esac

# Path is absolute but outside both worktree AND main repo (e.g.
# /tmp/scratch). That's not bd-n47; let it through.
exit 0
