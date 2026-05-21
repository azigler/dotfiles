#!/bin/bash
# Test for post-gen-fanout-check.sh — the gamma/openrouter fan-out
# reminder (dotfiles-d35). WARN-only hook: always exits 0.
#
# Hook test convention (see test-worktree-guard.sh).

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/post-gen-fanout-check.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

SESSION="test-fanout-$$"
STATE="/tmp/claude-gen-fanout-$SESSION"
trap 'rm -f "$STATE"' EXIT

GAMMA="{\"tool_input\":{\"command\":\"~/.claude/skills/gamma/gamma-render.sh ./x.json\"},\"tool_response\":{\"exit_code\":0},\"session_id\":\"$SESSION\"}"
OROUTER="{\"tool_input\":{\"command\":\"openrouter-image.sh 'a prompt' out.png\"},\"tool_response\":{\"exit_code\":0},\"session_id\":\"$SESSION\"}"
GAMMA_FAIL="{\"tool_input\":{\"command\":\"gamma-render.sh ./x.json\"},\"tool_response\":{\"exit_code\":3},\"session_id\":\"$SESSION\"}"
UNREL="{\"tool_input\":{\"command\":\"ls -la\"},\"tool_response\":{\"exit_code\":0},\"session_id\":\"$SESSION\"}"

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

# Run the hook; capture stderr + exit code into STDERR / EXITC.
STDERR=""
EXITC=0
runh() {
  STDERR=$(echo "$1" | "$HOOK" 2>&1 >/dev/null)
  EXITC=$?
}

# 1. Unrelated command → exit 0, no reminder.
rm -f "$STATE"
runh "$UNREL"
{ [ "$EXITC" -eq 0 ] && ! echo "$STDERR" | grep -q "Hint:"; } && ok || bad "unrelated command stays quiet"

# 2. First generation → exit 0, no reminder.
rm -f "$STATE"
runh "$GAMMA"
{ [ "$EXITC" -eq 0 ] && ! echo "$STDERR" | grep -q "Hint:"; } && ok || bad "first generation: no reminder"

# 3. Second generation, same session → reminder.
runh "$GAMMA"
{ [ "$EXITC" -eq 0 ] && echo "$STDERR" | grep -q "Hint:"; } && ok || bad "second generation: reminder shown"

# 4. openrouter-image.sh is also recognised (3rd call → reminder).
runh "$OROUTER"
echo "$STDERR" | grep -q "Hint:" && ok || bad "openrouter-image.sh recognised"

# 5. A failed generation is not counted.
rm -f "$STATE"
runh "$GAMMA_FAIL"   # exit_code 3 → ignored, no state written
runh "$GAMMA"        # the first *successful* one → no reminder
{ ! echo "$STDERR" | grep -q "Hint:"; } && ok || bad "failed generation not counted"

# 6. Never blocks — exit code is always 0.
[ "$EXITC" -eq 0 ] && ok || bad "hook never blocks (exit 0)"

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
