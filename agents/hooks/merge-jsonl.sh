#!/bin/bash
# Custom git merge driver for beads JSONL files (.beads/*.jsonl).
# Usage (set by session-start.sh): merge-jsonl.sh %O %A %B
#
# Union of both sides, deduped by bead ID, keeping the newer version
# (by updated_at) when the same ID appears on both. This is the fix for
# the beads-resurrection bug (lin-eqh, observed 3x 2026-06-09): git's
# BUILT-IN `merge=union` driver keeps BOTH sides' lines on conflict, so
# a stale "open" line from a worktree branch survives next to main's
# "closed" line and br's auto-import can flip the bead back open.
#
# Exit codes:
#   0 - merged cleanly (result written to %A)
#   1 - cannot merge safely (missing jq / malformed JSONL) -> git falls
#       back to a visible conflict, never a silent resurrection

set -uo pipefail

BASE="$1"   # %O - ancestor (unused: beads are never deleted, union is correct)
OURS="$2"   # %A - current side; git expects the result here
THEIRS="$3" # %B - other side

# Without jq we cannot dedupe-by-newer. Surface a conflict instead of
# guessing.
command -v jq >/dev/null 2>&1 || exit 1

MERGED=$(mktemp)
trap 'rm -f "$MERGED"' EXIT

# Slurp both sides, group by bead ID, keep the entry with the newest
# updated_at (stable sort: on a tie, THEIRS wins since it's read last).
if ! cat "$OURS" "$THEIRS" 2>/dev/null | jq -s -c '
      group_by(.id)
      | map(sort_by(.updated_at) | last)
      | sort_by(.id)
      | .[]
    ' > "$MERGED" 2>/dev/null; then
  # Malformed line somewhere -> let git show a real conflict.
  exit 1
fi

mv "$MERGED" "$OURS"
trap - EXIT
exit 0
