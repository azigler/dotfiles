#!/bin/bash
# PostToolUse (Bash): after the distribute script runs, verify the
# destination is in a sensible state. Warns to stderr; does not block.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null); [ -z "$SKEL" ] && SKEL="$COMMAND"

# Only fire on the distribute script
echo "$SKEL" | grep -q 'zig-computer.distribute.sh' || exit 0

# Skip if --dry-run
echo "$SKEL" | grep -q -- '--dry-run' && exit 0

# Resolve destination — default is ~/linearb/skills, override is the script's positional arg
DEST="$HOME/linearb/skills"
ARG=$(echo "$SKEL" | sed 's/.*zig-computer.distribute.sh//' | awk '{
  for (i=1; i<=NF; i++) {
    if ($i !~ /^-/) { print $i; exit }
  }
}')
[ -n "$ARG" ] && DEST="$ARG"

[ -d "$DEST" ] || exit 0  # not our problem; the script itself errors

WARNINGS=""

# 1. .claude/skills/ is non-empty (copy didn't fail)
SKILL_COUNT=$(find "$DEST/.claude/skills" -name SKILL.md 2>/dev/null | wc -l)
if [ "$SKILL_COUNT" -eq 0 ]; then
  WARNINGS="${WARNINGS}- $DEST/.claude/skills/ has 0 SKILL.md files (distribute may have failed)
"
fi

# 2. .claude/hooks/ is non-empty
HOOK_COUNT=$(find "$DEST/.claude/hooks" -type f 2>/dev/null | wc -l)
if [ "$HOOK_COUNT" -eq 0 ]; then
  WARNINGS="${WARNINGS}- $DEST/.claude/hooks/ has 0 files (distribute may have failed)
"
fi

# 3. CLAUDE.md exists at root
[ -f "$DEST/CLAUDE.md" ] || WARNINGS="${WARNINGS}- $DEST/CLAUDE.md missing (distribute may have failed)
"

# 4. No accidentally-staged files OUTSIDE .claude/ (the script touches .claude/ + CLAUDE.md only)
if [ -d "$DEST/.git" ]; then
  STRAY=$(git -C "$DEST" diff --name-only HEAD 2>/dev/null | grep -vE '^(\.claude/|CLAUDE\.md$)' | head -5)
  if [ -n "$STRAY" ]; then
    WARNINGS="${WARNINGS}- $DEST has unexpected dirty files outside .claude/ (review before commit):
$STRAY
"
  fi
fi

if [ -n "$WARNINGS" ]; then
  printf 'distribute post-check warnings:\n%s\n' "$WARNINGS" >&2
fi

exit 0
