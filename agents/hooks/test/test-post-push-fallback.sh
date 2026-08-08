#!/bin/bash
# Test for post-push-fallback.sh — the "Remote Control inactive" AskUserQuestion
# fallback (dotfiles-dpml adds a durable JSONL log alongside the injected
# guidance).
#
# Hook test convention (see test-worktree-guard.sh). Three regression cases
# for the log, plus the pre-existing inject/no-inject behavior.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/post-push-fallback.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TRIGGER='{"tool_response":"Remote Control inactive: no paired device","session_id":"sess-abc123"}'
NOTRIGGER='{"tool_response":"delivered ok","session_id":"sess-abc123"}'

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

# Run the hook; capture stdout/stderr/exit into globals.
STDOUT=""
STDERR=""
EXITC=0
runh() {
  local payload=$1
  local log=$2
  STDOUT=$(echo "$payload" | CLAUDE_PUSH_FAILURE_LOG="$log" "$HOOK" 2>"$TMPDIR/stderr")
  EXITC=$?
  STDERR=$(cat "$TMPDIR/stderr")
}

# --- 1. Trigger string -> the append happens, with the right shape ---------
LOG1="$TMPDIR/case1/push-failures.jsonl"
runh "$TRIGGER" "$LOG1"
{
  [ "$EXITC" -eq 0 ] \
    && [ -f "$LOG1" ] \
    && [ "$(wc -l < "$LOG1")" -eq 1 ] \
    && jq -e '.reason == "remote-control-inactive" and .session == "sess-abc123" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$LOG1" >/dev/null 2>&1
} && ok || bad "trigger appends one well-shaped JSONL line"

# additionalContext still emitted (pre-existing behavior unchanged).
echo "$STDOUT" | jq -e '.hookSpecificOutput.additionalContext | test("AskUserQuestion")' >/dev/null 2>&1 \
  && ok || bad "trigger still emits additionalContext"

# --- 2. Unwritable log file -> hook's normal exit code (0) is unchanged,
#        failure is reported on the hook's OWN stderr only, stdout unbroken.
UNWRITABLE_DIR="$TMPDIR/case2-readonly"
mkdir -p "$UNWRITABLE_DIR"
chmod 000 "$UNWRITABLE_DIR"
LOG2="$UNWRITABLE_DIR/nested/push-failures.jsonl"
runh "$TRIGGER" "$LOG2"
{
  [ "$EXITC" -eq 0 ] \
    && echo "$STDOUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
    && [ ! -e "$LOG2" ] \
    && echo "$STDERR" | grep -qF "could not append"
} && ok || bad "unwritable log: exit 0 unchanged, diagnostic on stderr, stdout still valid JSON"
chmod 755 "$UNWRITABLE_DIR"  # restore so the trap's rm -rf can clean up

# --- 3. Non-trigger invocation -> appends nothing (and doesn't even create
#        the log file/dir) ---
LOG3="$TMPDIR/case3/push-failures.jsonl"
runh "$NOTRIGGER" "$LOG3"
{
  [ "$EXITC" -eq 0 ] \
    && [ -z "$STDOUT" ] \
    && [ ! -e "$LOG3" ]
} && ok || bad "non-trigger: no log file created, no stdout, exit 0"

# --- 4. A second trigger appends a SECOND line (append-only, not overwrite) -
runh "$TRIGGER" "$LOG1"
{ [ "$(wc -l < "$LOG1")" -eq 2 ]; } && ok || bad "second trigger appends (does not overwrite)"

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
