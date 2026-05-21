#!/bin/bash
# Test for pre-commit-checks.sh — git-add-A block, worktree-push guard,
# and the Bead-trailer block + meta-commit carve-out (dotfiles-5q1).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# The hook runs real `git` in its process cwd, so cases run from a
# NON-git temp dir — `git diff --cached` then fails cleanly, the staged
# lint is skipped, and each case exercises the command-parsing logic in
# isolation. `br` is stubbed to a no-op.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-commit-checks.sh"
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

# A non-git working dir to run the hook from.
NONGIT=$(mktemp -d)
trap 'rm -rf "$STUB_DIR" "$NONGIT"' EXIT

WT='/tmp/proj/.claude/worktrees/agent-test'

# Run the hook from the non-git dir; capture exit + stderr.
run_case() {
  local name=$1 want_exit=$2 payload=$3 want_stderr=${4:-}
  local stderr_out
  stderr_out=$( cd "$NONGIT" && echo "$payload" | "$HOOK" 2>&1 >/dev/null )
  local got_exit=$?

  if [ "$got_exit" -ne "$want_exit" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (exit: want $want_exit, got $got_exit)")
    return
  fi
  if [ -n "$want_stderr" ] && ! echo "$stderr_out" | grep -qF "$want_stderr"; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (stderr missing: $want_stderr)")
    return
  fi
  PASS=$((PASS + 1))
}

# --- git add discipline ---

# 1. git add -A → BLOCK
run_case "block: git add -A" 2 \
  '{"tool_input":{"command":"git add -A"},"cwd":"/tmp"}' \
  "never 'git add ."

# 2. git add . → BLOCK
run_case "block: git add ." 2 \
  '{"tool_input":{"command":"git add ."},"cwd":"/tmp"}' \
  "never 'git add ."

# 3. git add <specific file> → ALLOW (not a commit, not broad)
run_case "allow: git add specific file" 0 \
  '{"tool_input":{"command":"git add foo.md"},"cwd":"/tmp"}'

# --- worktree push guard ---

# 4. git push from inside a worktree → BLOCK
run_case "block: git push from a worktree" 2 \
  "{\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$WT\"}" \
  "from inside a worktree"

# 5. git push from project root → ALLOW
run_case "allow: git push from project root" 0 \
  '{"tool_input":{"command":"git push"},"cwd":"/tmp"}'

# --- Bead-trailer block + meta-commit carve-out ---

# 6. commit WITH a Bead: trailer → ALLOW
run_case "allow: commit with Bead trailer" 0 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\" -m \"Bead: bd-x\""},"cwd":"/tmp"}'

# 7. commit with NO trailer and a normal gitmoji → BLOCK
run_case "block: commit with no Bead trailer" 2 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\""},"cwd":"/tmp"}' \
  "no 'Bead: <id>' trailer"

# 8. :card_file_box: bead-state meta-commit (no trailer) → ALLOW (exempt)
run_case "allow: card_file_box meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":card_file_box: beads: close bd-x\""},"cwd":"/tmp"}'

# 9. :broom: triage meta-commit (no trailer) → ALLOW (exempt)
run_case "allow: broom triage meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":broom: triage: 3 closed\""},"cwd":"/tmp"}'

# 10. :outbox_tray: distribute meta-commit (no trailer) → ALLOW (exempt)
run_case "allow: outbox_tray distribute meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":outbox_tray: distribute: sync from dotfiles\""},"cwd":"/tmp"}'

# 11. unrelated command → no-op
run_case "allow: unrelated command" 0 \
  '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'

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
