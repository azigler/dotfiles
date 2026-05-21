#!/bin/bash
# Test for pre-bead-close.sh — lint gate (bd-8euh chained-cd, bd-w6sd
# dotted-ID), worktree guard, and scrutiny gate (dotfiles-m33).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Stubbed `br`:
#   - `br lint <id>`  → exit 1 if <id> contains "bogus", else exit 0
#   - `br show <id>`  → "Type: impl" if <id> has "impl" (else "task");
#                       a SHIP verdict line if it has "ship", an
#                       OVERRIDE line if it has "ovr"
#   - any other `br`  → exit 0

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
  show)
    case "${2:-}" in
      *impl*) echo "Owner: t · Type: impl" ;;
      *)      echo "Owner: t · Type: task" ;;
    esac
    case "${2:-}" in
      *ship*) echo "## Scrutiny — 2026-05-21"; echo "Verdict: SHIP" ;;
      *ovr*)  echo "## Scrutiny — OVERRIDE: trivial mechanical change" ;;
    esac
    exit 0
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

WT='/tmp/proj/.claude/worktrees/agent-test'

# --- Lint gate (original behaviour) ---

# 1. Plain valid id → lint passes → exit 0
run_case "allow: plain valid id" 0 \
  '{"tool_input":{"command":"br close bd-iq81"},"cwd":"/tmp"}'

# 2. Plain bogus id → lint fails → exit 2 with Blocked
run_case "block: plain bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 3. Dotted valid id (bd-w6sd fix) → exit 0
run_case "allow: dotted valid id" 0 \
  '{"tool_input":{"command":"br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 4. Dotted bogus id → exit 2
run_case "block: dotted bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus.99.99"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.99.99"

# 5. Chained cd + plain id (bd-8euh fix path) → exit 0
run_case "allow: chained cd + plain id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-iq81"},"cwd":"/tmp"}'

# 6. Chained cd + dotted id → exit 0
run_case "allow: chained cd + dotted id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 7. Chained cd + bogus dotted id → still blocks
run_case "block: chained cd + dotted bogus id" 2 \
  '{"tool_input":{"command":"cd /tmp && br close bd-bogus.1.2"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.1.2"

# 8. Not a br close command at all → no-op (exit 0)
run_case "allow: unrelated bash command" 0 \
  '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'

# 9. br close with no id arg → no-op
run_case "allow: br close with no id" 0 \
  '{"tool_input":{"command":"br close"},"cwd":"/tmp"}'

# 10. Multiple ids, one bogus → blocks the whole
run_case "block: multi-id with one bogus" 2 \
  '{"tool_input":{"command":"br close bd-iq81 bd-bogus bd-w6sd"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# --- Worktree guard (dotfiles-m33) ---

# 11. br close from inside a worktree → BLOCK
run_case "block: br close in a worktree" 2 \
  "{\"tool_input\":{\"command\":\"br close bd-iq81\"},\"cwd\":\"$WT\"}" \
  "orchestrator-only"

# 12. br update --status from inside a worktree → BLOCK
run_case "block: br update --status in a worktree" 2 \
  "{\"tool_input\":{\"command\":\"br update bd-iq81 --status open\"},\"cwd\":\"$WT\"}" \
  "orchestrator-only"

# 13. br update --notes from inside a worktree → ALLOW (notes is permitted)
run_case "allow: br update --notes in a worktree" 0 \
  "{\"tool_input\":{\"command\":\"br update bd-iq81 --notes log\"},\"cwd\":\"$WT\"}"

# 14. br update --status OUTSIDE a worktree → ALLOW (orchestrator)
run_case "allow: br update --status outside a worktree" 0 \
  '{"tool_input":{"command":"br update bd-iq81 --status open"},"cwd":"/tmp"}'

# --- Scrutiny gate (dotfiles-m33) ---

# 15. close an -t impl bead with a SHIP verdict → ALLOW
run_case "allow: impl bead with SHIP verdict" 0 \
  '{"tool_input":{"command":"br close bd-implship"},"cwd":"/tmp"}'

# 16. close an -t impl bead with no verdict → BLOCK
run_case "block: impl bead with no scrutiny verdict" 2 \
  '{"tool_input":{"command":"br close bd-implbad"},"cwd":"/tmp"}' \
  "no recorded scrutiny verdict"

# 17. close an -t impl bead with an OVERRIDE verdict → ALLOW
run_case "allow: impl bead with OVERRIDE verdict" 0 \
  '{"tool_input":{"command":"br close bd-implovr"},"cwd":"/tmp"}'

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
