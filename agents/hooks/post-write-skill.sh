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

# 7. Cross-file heading citations resolve to a REAL heading.
#
# A skill that writes `AGENTS.md "Surfacing to Andrew"` points an agent at a
# heading that no longer exists: it greps, finds nothing, and moves on. The
# pointer still LOOKS authoritative — same failure class as a producer with no
# consumer, resolving to air rather than to a queue. That exact citation sat
# broken in pulse/SKILL.md from the day the heading was renamed until
# 2026-08-01 (`explore-cs5i`), and nothing could have noticed.
#
# The rule is PREFIX match on the heading text, because the house style cites
# the front of a heading and drops its em-dash tail — `AGENTS.md "Effort"`
# against `## Effort — a per-dispatch choice, not a session setting`.
AGENTS_MD=""
for _cand in \
  "$(dirname "$(dirname "$(dirname "$FILE_PATH")")")/AGENTS.md" \
  "$HOME/dotfiles/agents/AGENTS.md"; do
  if [ -f "$_cand" ]; then AGENTS_MD="$_cand"; break; fi
done

CITATIONS=$(grep -oE 'AGENTS\.md[^"]{0,4}"[^"]+"' "$FILE_PATH" 2>/dev/null \
            | sed 's/.*"\(.*\)"/\1/')

if [ -n "$CITATIONS" ] && [ -z "$AGENTS_MD" ]; then
  # "I could not check" must never be spelled the same way as "I checked and
  # it was fine" — say so rather than passing silently.
  WARNINGS="${WARNINGS}- this file cites AGENTS.md headings, but no AGENTS.md was found to check them against — the citations were NOT verified
"
elif [ -n "$CITATIONS" ]; then
  while IFS= read -r _cite; do
    [ -z "$_cite" ] && continue
    _norm=$(printf '%s' "$_cite" | sed 's/[[:space:].,;:]*$//')
    if ! awk -v c="$_norm" '
          /^#+ / { h = $0; sub(/^#+[[:space:]]*/, "", h)
                   if (index(h, c) == 1) { found = 1; exit } }
          END { exit found ? 0 : 1 }' "$AGENTS_MD"; then
      WARNINGS="${WARNINGS}- cites AGENTS.md \"$_cite\", but no heading in $AGENTS_MD starts with that text — a renamed heading leaves a silently broken cross-reference
"
    fi
  done <<EOF
$CITATIONS
EOF
fi

if [ -n "$WARNINGS" ]; then
  printf 'SKILL.md format check (warnings, not blocking):\n%s' "$WARNINGS" >&2
fi

exit 0
