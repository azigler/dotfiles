#!/bin/bash
# PostToolUse (Edit|Write): validate SKILL.md format after write.
# Catches drift in the harness itself: missing frontmatter, missing
# description field, body over 500 lines, redundant `name:` field.
# Warns to stderr; does not block (the file is already written).

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE_PATH" ] && exit 0

# Only validate SKILL.md files
case "$FILE_PATH" in
  */skills/*/SKILL.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

WARNINGS=""

# 1. Frontmatter present?
if ! head -1 "$FILE_PATH" | grep -q '^---$'; then
  WARNINGS="${WARNINGS}- missing YAML frontmatter (file should start with '---')
"
fi

# 2. description: field present and non-empty?
DESC_LINE=$(awk '/^---$/{c++; next} c==1 && /^description:/{print; exit}' "$FILE_PATH")
if [ -z "$DESC_LINE" ]; then
  WARNINGS="${WARNINGS}- missing 'description:' frontmatter field
"
elif echo "$DESC_LINE" | grep -qE 'description:[[:space:]]*$'; then
  WARNINGS="${WARNINGS}- 'description:' field is empty
"
fi

# 3. Body under 500 lines?
LINE_COUNT=$(wc -l < "$FILE_PATH")
if [ "$LINE_COUNT" -gt 500 ]; then
  WARNINGS="${WARNINGS}- body is $LINE_COUNT lines (Claude Code recommends <500; move detail to reference/ subfiles)
"
fi

# 4. Redundant `name:` field? (omit it if it matches the directory name)
SKILL_NAME=$(basename "$(dirname "$FILE_PATH")")
NAME_FIELD=$(awk '/^---$/{c++; next} c==1 && /^name:/{print; exit}' "$FILE_PATH" | sed 's/^name:[[:space:]]*//')
if [ -n "$NAME_FIELD" ] && [ "$NAME_FIELD" = "$SKILL_NAME" ]; then
  WARNINGS="${WARNINGS}- 'name: $NAME_FIELD' is redundant (matches directory name; omit it — frontmatter spec says directory-name is the default)
"
fi

# 5. when_to_use present? The routing layer fires skills off the
# description + when_to_use; a skill without trigger guidance is the
# least discoverable one in the library.
WTU_LINE=$(awk '/^---$/{c++; next} c==1 && /^when_to_use:/{print; exit}' "$FILE_PATH")
if [ -z "$WTU_LINE" ]; then
  WARNINGS="${WARNINGS}- missing 'when_to_use:' frontmatter field (trigger guidance for the routing layer)
"
fi

# 6. TOOLKIT.md freshness — the skills-dir digest /onboard reads instead
# of every body. If you changed a skill's behavior, update its entry.
TOOLKIT="$(dirname "$(dirname "$FILE_PATH")")/TOOLKIT.md"
if [ -f "$TOOLKIT" ]; then
  WARNINGS="${WARNINGS}- if this change altered the skill's job / trigger / anti-pattern, update its digest entry in skills/TOOLKIT.md
"
fi

if [ -n "$WARNINGS" ]; then
  printf 'SKILL.md format check (warnings, not blocking):\n%s' "$WARNINGS" >&2
fi

exit 0
