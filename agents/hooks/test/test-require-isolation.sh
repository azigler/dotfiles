#!/bin/bash
# Tests for pre-tool-use-require-isolation.sh
# Pipes a PreToolUse JSON payload into the hook and asserts the exit code.
set -u
HOOK="$(dirname "$0")/../pre-tool-use-require-isolation.sh"
fail=0

check() {
  local desc="$1" expected="$2" payload="$3"
  echo "$payload" | "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expected" ]; then
    echo "PASS: $desc (exit $got)"
  else
    echo "FAIL: $desc — expected exit $expected, got $got"
    fail=1
  fi
}

# BLOCK (exit 2): subagent with no isolation
check "subagent, no isolation -> BLOCK" 2 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"subagent","prompt":"x"}}'

# BLOCK (exit 2): subagent with a bogus isolation value
check "subagent, bad isolation -> BLOCK" 2 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"subagent","isolation":"none"}}'

# ALLOW (exit 0): subagent with worktree isolation
check "subagent + worktree -> ALLOW" 0 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"subagent","isolation":"worktree"}}'

# ALLOW (exit 0): subagent with remote isolation
check "subagent + remote -> ALLOW" 0 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"subagent","isolation":"remote"}}'

# ALLOW (exit 0): read-only built-in type, no isolation needed
check "Explore, no isolation -> ALLOW" 0 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}'

check "general-purpose, no isolation -> ALLOW" 0 \
  '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}'

# ALLOW (exit 0): a different tool entirely
check "Bash tool -> ALLOW" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"ls"}}'

# ALLOW (exit 0, fail-open): malformed / empty input
check "empty input -> ALLOW (fail-open)" 0 '{}'
check "garbage input -> ALLOW (fail-open)" 0 'not json'

exit $fail
