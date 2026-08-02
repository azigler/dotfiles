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
# ⚠️ NORMALIZATION IS THE GUARD (dotfiles-5vz2). For most of this hook's life
# the normalization step was:
#
#     NORM_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
#
# `realpath -m` is GNU-only. On macOS it fails on EVERY call (`realpath:
# illegal option -- m`, exit 1), the blanket `2>/dev/null` hid the usage error,
# and the `||` handed back the RAW path — so the prefix comparison ran against
# an UNNORMALIZED string on every Mac, and a path with `..` or through a
# symlink was never caught. The guard reported success the entire time.
#
# So: normalization comes from lib/portable.sh, which returns NON-ZERO rather
# than a plausible-looking wrong answer, and this hook FAILS CLOSED on that —
# it blocks and says it could not normalize. That direction is deliberate.
# Every path that reaches the normalizer here is (a) absolute and (b) inside a
# worktree session, so a fail-closed block is scoped to exactly the agents this
# guard exists for, and it is LOUD: the agent gets the reason on stderr and can
# re-issue with a worktree-relative path. A guard that answers "I could not
# check, carry on" is the defect, not the safe default.
#
# Edge cases handled:
#   - file_path with `..` traversal: we normalize the file_path with
#     `_p_realpath` (no requirement that the file exist) before the
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

# The portability shim. If it is missing, `_p_realpath` is undefined, every
# call returns 127, and the fail-closed branch below blocks with a message —
# which is the correct outcome for "the guard's normalizer is gone".
_WG_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/portable.sh"
[ -r "$_WG_LIB" ] && . "$_WG_LIB"

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

# Normalize file_path so traversal sequences (`..`) and symlinks can't bypass
# the prefix check. `_p_realpath` does not require the path to exist, and it
# returns non-zero rather than a fallback when it cannot answer.
NORM_PATH=$(_p_realpath "$FILE_PATH")
if [ -z "$NORM_PATH" ]; then
  # FAIL CLOSED. Without a normalized path the two `case` tests below are
  # comparing an attacker-shaped string; "allow" would be a guess dressed as a
  # verdict. See the NORMALIZATION IS THE GUARD note at the top.
  cat >&2 <<EOF
Blocked: the worktree guard could not NORMALIZE this path, so it cannot
certify the write lands inside your worktree:

  $FILE_PATH

You are working in the worktree at:

  $CWD

This is a fail-closed refusal, not a detection: normalization is the whole
guard (dotfiles-5vz2), and a guard that cannot normalize is a guard that can
be walked around with \`..\` or a symlink. Re-issue the write with a plain
worktree-relative path, or an absolute path anchored at the worktree above.

If \$(dirname \$0)/lib/portable.sh is missing or unreadable, that is the real
bug — repair it rather than working around this message.
EOF
  exit 2
fi

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
