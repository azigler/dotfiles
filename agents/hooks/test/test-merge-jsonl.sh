#!/bin/bash
# Test for merge-jsonl.sh — the jsonl-union git merge driver (lin-eqh).
#
# Hook test convention (bd-n47): executable bash, exit-code assertions,
# PASS: N/N summary.
#
# Covers the driver two ways:
#   1. Direct invocation (%O %A %B temp files) — unit-level behavior.
#   2. A real git merge in a scratch repo with the driver configured —
#      the exact worktree-branch resurrection scenario from 2026-06-09.

set -u

DRIVER="$(cd "$(dirname "$0")/.." && pwd)/merge-jsonl.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

check() { # $1 name, $2 condition result (0=ok)
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
  fi
}

# ---------- 1. Direct invocation ----------

# Same bead on both sides: OURS has the stale "open" (older updated_at),
# THEIRS has the newer "closed". Closed must win.
BASE="$TMPROOT/base"; OURS="$TMPROOT/ours"; THEIRS="$TMPROOT/theirs"
printf '%s\n' '{"id":"x-1","status":"open","updated_at":"2026-06-01T00:00:00Z"}' > "$BASE"
printf '%s\n' '{"id":"x-1","status":"open","updated_at":"2026-06-01T00:00:00Z"}' > "$OURS"
printf '%s\n' '{"id":"x-1","status":"closed","updated_at":"2026-06-09T12:00:00Z"}' > "$THEIRS"
"$DRIVER" "$BASE" "$OURS" "$THEIRS"
check "direct: driver exits 0" $?
grep -q '"status":"closed"' "$OURS"
check "direct: newer (closed) wins" $?
[ "$(wc -l < "$OURS")" -eq 1 ]
check "direct: deduped to one line" $?

# Disjoint beads union: each side adds its own bead, both survive.
printf '%s\n' '{"id":"x-1","status":"open","updated_at":"2026-06-01T00:00:00Z"}' > "$BASE"
{ printf '%s\n' '{"id":"x-1","status":"open","updated_at":"2026-06-01T00:00:00Z"}'
  printf '%s\n' '{"id":"x-2","status":"open","updated_at":"2026-06-02T00:00:00Z"}'; } > "$OURS"
{ printf '%s\n' '{"id":"x-1","status":"open","updated_at":"2026-06-01T00:00:00Z"}'
  printf '%s\n' '{"id":"x-3","status":"open","updated_at":"2026-06-03T00:00:00Z"}'; } > "$THEIRS"
"$DRIVER" "$BASE" "$OURS" "$THEIRS"
check "union: driver exits 0" $?
[ "$(wc -l < "$OURS")" -eq 3 ] && grep -q 'x-2' "$OURS" && grep -q 'x-3' "$OURS"
check "union: both sides' new beads kept" $?

# Malformed JSONL: driver must exit 1 (visible conflict), not corrupt.
printf 'not json at all\n' > "$OURS"
printf '%s\n' '{"id":"x-1","status":"closed","updated_at":"2026-06-09T00:00:00Z"}' > "$THEIRS"
"$DRIVER" "$BASE" "$OURS" "$THEIRS" 2>/dev/null
[ $? -eq 1 ]
check "malformed: exits 1 (falls back to real conflict)" $?

# ---------- 2. Real git merge (the resurrection scenario) ----------

REPO="$TMPROOT/repo"
git init -q "$REPO"
cd "$REPO" || exit 1
git config user.email t@t && git config user.name t
git config merge.jsonl-union.name "test"
git config merge.jsonl-union.driver "$DRIVER %O %A %B"
mkdir .beads
printf '%s\n' '.beads/*.jsonl merge=jsonl-union' > .gitattributes
printf '%s\n' '{"id":"lin-bgd","status":"open","updated_at":"2026-06-01T00:00:00Z"}' > .beads/issues.jsonl
git add -A && git commit -qm init

# Worktree branch: commits a touch to the jsonl (stale "open" snapshot).
git checkout -qb worktree-agent-test
printf '%s\n' '{"id":"lin-bgd","status":"open","updated_at":"2026-06-01T00:00:01Z"}' > .beads/issues.jsonl
git commit -qam "stale touch"

# Main: bead gets closed AFTER the branch point.
git checkout -q -
printf '%s\n' '{"id":"lin-bgd","status":"closed","updated_at":"2026-06-09T12:00:00Z"}' > .beads/issues.jsonl
git commit -qam "close lin-bgd"

# The merge that used to resurrect. Must succeed AND keep closed.
git merge -q worktree-agent-test --no-edit 2>/dev/null
check "git merge: completes cleanly" $?
grep -q '"status":"closed"' .beads/issues.jsonl
check "git merge: closed bead stays closed (no resurrection)" $?
[ "$(wc -l < .beads/issues.jsonl)" -eq 1 ]
check "git merge: no duplicate lines (built-in union would leave 2)" $?

# ---------- summary ----------

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL"
  exit 0
else
  echo "FAIL: $FAIL/$TOTAL — ${FAILED_NAMES[*]}"
  exit 1
fi
