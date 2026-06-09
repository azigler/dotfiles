#!/bin/bash
# PostToolUse (Read): usage-driven toybox graduation tracking.
#
# The documented toybox flow is "read ~/explore/.claude/skills/INDEX.md,
# then load a skill's SKILL.md by absolute path" — so the Read of a
# toybox SKILL.md from a session anchored OUTSIDE ~/explore IS the
# cross-umbrella usage event. We append one line per event to
# USAGE.log; /housekeeping reviews the log and proposes graduations to
# the global set.
#
# This replaces the never-exercised ">=3 projects" graduation heuristic
# (decided with Andrew 2026-06-09): promotion is triggered by observed
# cross-umbrella need, with this log as the evidence.
#
# Never blocks; always exits 0.

INPUT=$(cat 2>/dev/null || echo '{}')

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL" = "Read" ] || exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
TOYBOX="$HOME/explore/.claude/skills"
case "$FILE" in
  "$TOYBOX"/*/SKILL.md) ;;
  *) exit 0 ;;
esac

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd -P)
# Reads from inside the explore umbrella are home-turf, not usage.
case "$CWD" in
  "$HOME"/explore|"$HOME"/explore/*) exit 0 ;;
esac

SKILL=$(basename "$(dirname "$FILE")")
LOG="${TOYBOX_USAGE_LOG:-$TOYBOX/USAGE.log}"
echo "$(date -u +%F) $SKILL <- $CWD" >> "$LOG" 2>/dev/null

exit 0
