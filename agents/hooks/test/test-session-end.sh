#!/bin/bash
# Test for session-end.sh — the .offboard-pending marker logic (dotfiles-xwo).
#
# Hook test convention (see test-worktree-guard.sh, test-pre-bead-close.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a one-line PASS/FAIL summary at the end
#
# session-end.sh doesn't parse stdin — it acts on the cwd's git repo. So
# each case builds a throwaway git repo, runs the hook from inside it, and
# asserts whether .offboard-pending was created.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-end.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Stub `br` so `br sync` is a hermetic no-op.
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/br" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_DIR/br"
export PATH="$STUB_DIR:$PATH"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$STUB_DIR" "$TMPROOT"' EXIT

# Build a git repo with one commit that touches the given repo-relative path.
make_repo() {
  local dir=$1 touched=$2
  mkdir -p "$dir/$(dirname "$touched")"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  echo x > "$dir/$touched"
  git -C "$dir" add "$touched"
  git -C "$dir" -c commit.gpgsign=false commit -qm "commit $touched"
}

# Run the hook from inside $repo; assert presence/absence of the marker.
#   $1 name  $2 repo dir  $3 want_marker (yes|no)
run_case() {
  local name=$1 repo=$2 want_marker=$3
  rm -f "$repo/.offboard-pending"
  ( cd "$repo" && echo '{}' | "$HOOK" >/dev/null 2>&1 )
  local got=no
  [ -f "$repo/.offboard-pending" ] && got=yes
  if [ "$got" = "$want_marker" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (marker: want $want_marker, got $got)")
  fi
}

# --- Test cases ---

# 1. Session ended without /offboard (HEAD touched a normal file) → marker
R1="$TMPROOT/no-offboard"
make_repo "$R1" "foo.txt"
run_case "marker dropped when /offboard did not run" "$R1" yes

# 2. /offboard ran (HEAD committed the handoff note) → no marker
R2="$TMPROOT/with-offboard"
make_repo "$R2" ".claude/plans/session-handoff.md"
run_case "no marker when /offboard committed the handoff note" "$R2" no

# 3. refs/ variant of the handoff note also counts → no marker
R3="$TMPROOT/refs-offboard"
make_repo "$R3" "refs/session-handoff.md"
run_case "no marker for the refs/ handoff-note variant" "$R3" no

# 4. cwd inside a worktree → skip (offboard is orchestrator-only)
R4="$TMPROOT/proj/.claude/worktrees/agent-test"
make_repo "$R4" "foo.txt"
run_case "skipped inside a worktree" "$R4" no

# --- Summary ---

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi

echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
