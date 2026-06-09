#!/bin/bash
# Test for toybox-usage.sh — cross-umbrella toybox reads logged,
# home-turf and non-toybox reads ignored.
#
# Hook test convention: executable bash, non-zero exit = failure,
# PASS/FAIL summary on the last line.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/toybox-usage.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
export TOYBOX_USAGE_LOG="$LOG"

TOYBOX_SKILL="$HOME/explore/.claude/skills/databases/SKILL.md"

fire() {
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' \
    "$1" "$2" "$3" | "$HOOK"
}

assert_lines() {
  local name=$1 want=$2
  local got
  got=$(grep -c . "$LOG" 2>/dev/null || echo 0)
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (want $want log lines, got $got)")
  fi
}

# 1. Toybox read from another umbrella → logged
fire Read "$TOYBOX_SKILL" "/home/ubuntu/linearb"
assert_lines "cross-umbrella read logged" 1

# 2. Logged line carries skill name + source project
if grep -q "databases <- /home/ubuntu/linearb" "$LOG"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("log line format (got: $(cat "$LOG"))")
fi

# 3. Toybox read from inside explore → NOT logged
fire Read "$TOYBOX_SKILL" "$HOME/explore"
assert_lines "home-turf read ignored" 1

# 4. Toybox read from an explore child → NOT logged
fire Read "$TOYBOX_SKILL" "$HOME/explore/autonovel"
assert_lines "explore-child read ignored" 1

# 5. Non-toybox read from another umbrella → NOT logged
fire Read "$HOME/dotfiles/agents/skills/beads/SKILL.md" "/home/ubuntu/linearb"
assert_lines "non-toybox read ignored" 1

# 6. Non-Read tool → NOT logged
fire Grep "$TOYBOX_SKILL" "/home/ubuntu/linearb"
assert_lines "non-Read tool ignored" 1

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
