#!/bin/bash
# Test for pre-bead-close.sh (covers bd-8euh chained-cd fix, bd-w6sd
# dotted-ID regex fix).
#
# Hook test convention (introduced by bd-n47, see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints PASS/FAIL summary on the last line
#
# This test stubs `br` so it does not depend on a live beads DB:
#   - `br lint <id>` exits 1 (issue not found) if <id> contains "bogus"
#   - `br lint <id>` exits 0 otherwise
#   - any other `br` invocation exits 0
# That gives the hook a deterministic surface to exercise its regex,
# chained-cd parsing, and block/allow decisions against.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-bead-close.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# --- Stub `br` ---
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/br" <<'STUB'
#!/bin/bash
case "${1:-}" in
  lint)
    case "${2:-}" in
      *bogus*) echo "Error: Issue not found: ${2:-}" >&2; exit 1 ;;
      *)       exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/br"
trap 'rm -rf "$STUB_DIR"' EXIT
export PATH="$STUB_DIR:$PATH"

# Helper: run hook with payload, capture exit + stderr.
run_case() {
  local name=$1
  local want_exit=$2
  local payload=$3
  local want_stderr=${4:-}

  local stderr_out
  stderr_out=$(echo "$payload" | "$HOOK" 2>&1 >/dev/null)
  local got_exit=$?

  if [ "$got_exit" -ne "$want_exit" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (exit: want $want_exit, got $got_exit)")
    return
  fi

  if [ -n "$want_stderr" ]; then
    if ! echo "$stderr_out" | grep -qF "$want_stderr"; then
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$name (stderr missing: $want_stderr)")
      return
    fi
  fi

  PASS=$((PASS + 1))
}

# --- Test cases ---

# 1. Plain valid id → lint passes → exit 0
run_case "allow: plain valid id" 0 \
  '{"tool_input":{"command":"br close bd-iq81"},"cwd":"/tmp"}'

# 2. Plain bogus id → lint fails → exit 2 with Blocked
run_case "block: plain bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 3. Dotted valid id (the bd-w6sd fix) → lint passes → exit 0
#    Pre-fix: hook regex did not match dotted IDs, hook silently
#    skipped lint and exited 0. Post-fix: regex matches, lint runs.
run_case "allow: dotted valid id" 0 \
  '{"tool_input":{"command":"br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 4. Dotted bogus id → lint fails → exit 2 with Blocked
#    Confirms the dotted path now actually gates instead of skipping.
run_case "block: dotted bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus.99.99"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.99.99"

# 5. Chained cd + plain id (the bd-8euh fix path) → exit 0
run_case "allow: chained cd + plain id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-iq81"},"cwd":"/tmp"}'

# 6. Chained cd + dotted id (both fixes combined) → exit 0
run_case "allow: chained cd + dotted id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 7. Chained cd + bogus dotted id → still blocks
run_case "block: chained cd + dotted bogus id" 2 \
  '{"tool_input":{"command":"cd /tmp && br close bd-bogus.1.2"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.1.2"

# 8. Not a br close command at all → no-op (exit 0)
run_case "allow: unrelated bash command" 0 \
  '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'

# 9. br close with no id arg → no-op (regex extracts nothing)
run_case "allow: br close with no id" 0 \
  '{"tool_input":{"command":"br close"},"cwd":"/tmp"}'

# 10. Multiple ids on one close → all must lint; one bogus blocks the whole
run_case "block: multi-id with one bogus" 2 \
  '{"tool_input":{"command":"br close bd-iq81 bd-bogus bd-w6sd"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

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
