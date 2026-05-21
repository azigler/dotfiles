#!/bin/bash
# PostToolUse (Bash): after `git submodule add`, check that the submodule
# was absorbed (its .git/ moved into the parent's .git/modules/).
#
# Why this exists:
# `git submodule add` registers the submodule entry in the parent's index
# and .gitmodules but DOES NOT move the local .git/ directory into the
# parent's .git/modules/. The result is an "unabsorbed submodule":
#
#   parent/<sub>/.git/         ← still a real directory (the local repo)
#   parent/.git/modules/<sub>  ← does NOT exist
#
# Claude Code's worktree-creation heuristic walks the git context and
# treats unabsorbed submodules as part of the parent's git universe.
# Subagent worktrees dispatched from inside the submodule then land in
# the PARENT's `.claude/worktrees/` instead of the submodule's — breaking
# the .beads/ symlink and the merge target. We hit this on 2026-05-18
# during the skills-library bootstrap.
#
# Fix: `git submodule absorbgitdirs <path>` from the parent. This moves
# the gitdir into parent/.git/modules/<sub>/ and replaces <sub>/.git with
# a one-line gitlink file. After absorption, subagent dispatch works.
#
# Informational only (never blocks). Exits 0 always.

INPUT=$(cat 2>/dev/null || echo '{}')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only fire on `git submodule add` operations
if ! echo "$COMMAND" | grep -qE 'git[[:space:]]+submodule[[:space:]]+add\b'; then
  exit 0
fi

# Only fire if the command succeeded — failed `git submodule add` doesn't
# need a follow-up reminder.
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0' 2>/dev/null)
[ "$EXIT_CODE" -ne 0 ] && exit 0

# We need to be in the parent project's working tree to see .gitmodules
# correctly. Find it from the current cwd.
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$TOPLEVEL" ] && exit 0
[ ! -f "$TOPLEVEL/.gitmodules" ] && exit 0

# Scan every submodule path in .gitmodules; flag any whose .git is a real
# directory (unabsorbed) instead of a gitlink file (absorbed).
UNABSORBED=()
while IFS= read -r path; do
  [ -z "$path" ] && continue
  sub_dotgit="$TOPLEVEL/$path/.git"
  if [ -d "$sub_dotgit" ]; then
    UNABSORBED+=("$path")
  fi
done < <(grep -h '^[[:space:]]*path' "$TOPLEVEL/.gitmodules" 2>/dev/null \
         | /usr/bin/awk -F'= *' '{print $2}')

if [ ${#UNABSORBED[@]} -eq 0 ]; then
  exit 0
fi

# Emit the reminder on stderr — the harness feeds this back to the agent
# as additional context.
{
  echo ""
  echo "⚠ Unabsorbed submodule(s) detected after \`git submodule add\`:"
  for p in "${UNABSORBED[@]}"; do
    echo "    $p (.git is a directory, not a gitlink file)"
  done
  echo ""
  echo "\`git submodule add\` does NOT move the local .git/ into the parent's"
  echo ".git/modules/. Subagent worktrees dispatched from inside this submodule"
  echo "will land in the parent's .claude/worktrees/ instead of the submodule's,"
  echo "breaking bead symlinks and merge targets."
  echo ""
  echo "Run this from the parent to complete the addition:"
  for p in "${UNABSORBED[@]}"; do
    echo "    git submodule absorbgitdirs $p"
  done
  echo ""
  echo "Verify: \`ls -l <submodule>/.git\` should show a small text file"
  echo "(a \`gitdir: ...\` gitlink), NOT a directory."
} >&2

exit 0
