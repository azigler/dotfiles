#!/bin/bash
# Stop-hook staleness detector for the ALWAYS-LOADED context tier
# (explore-6wwu; decision explore-0z6r chose (a) detection + (d) docs, and
# explicitly rejected per-tick re-read and session-recycle-on-edit).
#
# WHAT IT DOES. session-start.sh captured a manifest — content hash + mtime —
# of the always-loaded set (global CLAUDE.md, the project CLAUDE.md chain,
# MEMORY.md, every skill's frontmatter). On Stop this hook recomputes it and
# names, loudly and specifically, any file whose CONTENT changed since the
# session's snapshot, and how long ago.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   - It never repairs anything. There is nothing to repair from here: the
#     session's copy is in its context, not on disk.
#   - It never blocks. Always exit 0, never `decision: block`. A typo in
#     CLAUDE.md must not be able to interrupt a running tick — that is the
#     precise reason option (c), session-recycle-on-edit, was rejected.
#
# SURFACES: a `systemMessage` on stdout JSON (shown to Zig, non-blocking),
# stderr (transcript / --debug), and an append-only log at
# ${ALWAYS_LOADED_LOG:-/tmp/claude-always-loaded/stale.log}.
#
# NAG CONTROL: each (path, new-hash) pair is reported ONCE per session. A file
# edited again later reports again — new hash, new report. A file that stays
# changed does not re-nag every turn.

INPUT=$(cat 2>/dev/null || echo '{}')

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SESSION_ID" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] || CWD=$(pwd -P)

STATE_DIR="${ALWAYS_LOADED_STATE_DIR:-/tmp/claude-always-loaded}"
MANIFEST="$STATE_DIR/$SESSION_ID.manifest"
REPORTED="$STATE_DIR/$SESSION_ID.reported"

# No manifest -> this session started before the detector existed, or capture
# was skipped (worktree/subagent). Nothing to compare against: stay silent.
[ -f "$MANIFEST" ] || exit 0

LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")/lib/always-loaded.sh"
[ -r "$LIB" ] || exit 0
# shellcheck source=lib/always-loaded.sh
. "$LIB"

CURRENT=$(always_loaded_manifest "$CWD")
[ -n "$CURRENT" ] || exit 0

declare -A OLD_HASH=()
declare -A OLD_KIND=()
while IFS=$'\t' read -r kind hash mtime path; do
  [ -n "${path:-}" ] || continue
  OLD_HASH["$path"]=$hash
  OLD_KIND["$path"]=$kind
done < "$MANIFEST"

LINES=()
COUNT=0

_already_reported() { # <path> <hash>
  [ -f "$REPORTED" ] || return 1
  local key
  key=$(printf '%s\t%s' "$1" "$2")
  grep -qxF "$key" "$REPORTED"
}
_mark_reported() { printf '%s\t%s\n' "$1" "$2" >> "$REPORTED"; }

_label() { # <kind> <path>
  case "$1" in
    global-claude)  printf 'global CLAUDE.md' ;;
    project-claude) printf 'project CLAUDE.md' ;;
    memory)         printf 'MEMORY.md (auto-memory)' ;;
    skill)          printf 'skill description: /%s' "$(basename "$(dirname "$2")")" ;;
    *)              printf '%s' "$1" ;;
  esac
}

declare -A SEEN=()
while IFS=$'\t' read -r kind hash mtime path; do
  [ -n "${path:-}" ] || continue
  SEEN["$path"]=1
  old=${OLD_HASH["$path"]:-}
  if [ -z "$old" ]; then
    _already_reported "$path" "$hash" && continue
    _mark_reported "$path" "$hash"
    LINES+=("  • ADDED since session start — $(_label "$kind" "$path"): $(always_loaded_pretty_path "$path")")
    COUNT=$((COUNT + 1))
  elif [ "$old" != "$hash" ]; then
    _already_reported "$path" "$hash" && continue
    _mark_reported "$path" "$hash"
    LINES+=("  • $(_label "$kind" "$path") — CHANGED $(always_loaded_age "$mtime"): $(always_loaded_pretty_path "$path")")
    COUNT=$((COUNT + 1))
  fi
done <<< "$CURRENT"

for path in "${!OLD_HASH[@]}"; do
  [ -n "${SEEN[$path]:-}" ] && continue
  _already_reported "$path" "<removed>" && continue
  _mark_reported "$path" "<removed>"
  LINES+=("  • REMOVED since session start — $(_label "${OLD_KIND[$path]}" "$path"): $(always_loaded_pretty_path "$path")")
  COUNT=$((COUNT + 1))
done

[ "$COUNT" -eq 0 ] && exit 0

# Bound the output — a `sync.sh` run can touch every skill at once.
MAX=8
BODY=$(printf '%s\n' "${LINES[@]}" | head -n "$MAX")
if [ "$COUNT" -gt "$MAX" ]; then
  BODY="$BODY
  … and $(( COUNT - MAX )) more"
fi

MSG="⚠ ALWAYS-LOADED CONTEXT IS STALE — $COUNT file(s) changed on disk since this session started.
$BODY
These were injected into this session ONCE, at session start, and are NOT re-read.
This session is still acting on the OLD text; the disk and your context disagree.
Nothing was repaired and nothing is blocked. To pick the change up: /clear (or a
fresh session). To act correctly right now: re-READ the changed file before
relying on any rule it states."

LOG="${ALWAYS_LOADED_LOG:-$STATE_DIR/stale.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
{ date -u +%FT%TZ; printf 'session=%s cwd=%s\n%s\n\n' "$SESSION_ID" "$CWD" "$MSG"; } >> "$LOG" 2>/dev/null

printf '%s\n' "$MSG" >&2
jq -n --arg m "$MSG" '{continue: true, systemMessage: $m}' 2>/dev/null \
  || printf '%s\n' "$MSG"

exit 0
