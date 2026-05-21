#!/bin/bash
# Test for pre-tool-use-worktree-guard.sh (bd-n47).
#
# Hook test convention (introduced by bd-n47):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - they are executable bash scripts
#   - they run with `bash test-<hook>.sh`; non-zero exit = test failed
#   - prints a one-line PASS/FAIL summary at the end
#
# Each test case constructs a JSON payload, pipes it to the hook, and
# asserts the exit code (and optionally that stderr contains an
# expected substring).

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-tool-use-worktree-guard.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Build a fake worktree layout under /tmp so the hook's MAIN_ROOT
# derivation has something realistic to chew on.
TMPROOT=$(mktemp -d)
MAIN="$TMPROOT/fake-project"
WORKTREE="$MAIN/.claude/worktrees/agent-deadbeef"
mkdir -p "$WORKTREE/sub"
trap 'rm -rf "$TMPROOT"' EXIT

# Helper: run hook with a payload + cwd, capture exit + stderr.
#   $1 = test name
#   $2 = expected exit code
#   $3 = JSON payload (with .cwd set to the test cwd)
#   $4 = optional substring required in stderr (only checked when expected exit != 0)
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

# 1. Worktree subagent writing to MAIN repo path → BLOCK (exit 2)
run_case "block: worktree write to main repo" 2 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      --arg fp "$MAIN/foo/bar.md" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:"x"}}')" \
  "Blocked: worktree subagent"

# 2. Worktree subagent writing to its own worktree path → ALLOW (exit 0)
run_case "allow: worktree write to worktree path" 0 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      --arg fp "$WORKTREE/sub/file.md" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:"x"}}')"

# 3. Edit (not just Write) is also intercepted → BLOCK
run_case "block: Edit tool also gated" 2 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      --arg fp "$MAIN/spec/spec.md" \
      '{tool_name:"Edit", cwd:$cwd, tool_input:{file_path:$fp, old_string:"a", new_string:"b"}}')" \
  "Blocked: worktree subagent"

# 4. Non-Write/Edit tool → no-op (exit 0)
run_case "allow: non-Write/Edit tool ignored" 0 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      '{tool_name:"Bash", cwd:$cwd, tool_input:{command:"echo hi"}}')"

# 5. cwd outside any worktree → no-op (exit 0)
run_case "allow: not in a worktree" 0 \
  "$(jq -nc \
      --arg cwd "$MAIN" \
      --arg fp "$MAIN/foo.md" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:"x"}}')"

# 6. Path traversal that escapes the worktree → BLOCK
#    (.../agent-deadbeef/../foo/bar.md normalizes to .../.claude/worktrees/foo/bar.md
#     which is inside MAIN but outside the worktree)
run_case "block: path traversal escapes worktree" 2 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      --arg fp "$WORKTREE/../foo/bar.md" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:"x"}}')" \
  "Blocked: worktree subagent"

# 7. Relative file path → ALLOW (the tool resolves it against cwd, which is the worktree)
run_case "allow: relative file path" 0 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:"sub/file.md", content:"x"}}')"

# 8. Absolute path entirely outside MAIN (e.g. /tmp/scratch) → ALLOW
run_case "allow: absolute path outside main repo" 0 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:"/tmp/scratch.txt", content:"x"}}')"

# 9. Stderr suggests a corrected worktree path
run_case "block: stderr surfaces corrected path" 2 \
  "$(jq -nc \
      --arg cwd "$WORKTREE" \
      --arg fp "$MAIN/spec/autoschool-spec.md" \
      '{tool_name:"Write", cwd:$cwd, tool_input:{file_path:$fp, content:"x"}}')" \
  "$WORKTREE/spec/autoschool-spec.md"

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
