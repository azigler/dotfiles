#!/bin/bash
# Test for post-bash-beads-merge-check.sh (dotfiles-qq6).
#
# Hook test convention (bd-n47): executable bash, JSON payload piped to
# the hook, exit-code assertions via run_case, PASS: N/N summary.
#
# The hook detects silent duplicate-bead-id merge artifacts in
# .beads/issues.jsonl after merge-ish git commands.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/post-bash-beads-merge-check.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Fake git repos under /tmp: one with beads, one without.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

REPO="$TMPROOT/with-beads"
mkdir -p "$REPO/.beads"
git -C "$TMPROOT" init -q "$REPO" 2>/dev/null || git init -q "$REPO"

REPO_NOBEADS="$TMPROOT/no-beads"
mkdir -p "$REPO_NOBEADS"
git init -q "$REPO_NOBEADS"

CLEAN_JSONL='{"id":"bd-aaa","title":"one","status":"closed"}
{"id":"bd-bbb","title":"two","status":"open"}'

DUP_JSONL='{"id":"bd-aaa","title":"one","status":"in_progress"}
{"id":"bd-bbb","title":"two","status":"open"}
{"id":"bd-aaa","title":"one","status":"closed"}'

# Helper: run hook with a payload, capture exit + stderr.
#   $1 = test name
#   $2 = expected exit code
#   $3 = JSON payload
#   $4 = optional substring required in stderr (checked when expected exit != 0)
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

  if [ -n "$want_stderr" ] && [ "$want_exit" -ne 0 ]; then
    if ! echo "$stderr_out" | grep -qF "$want_stderr"; then
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$name (stderr missing: $want_stderr)")
      return
    fi
  fi

  PASS=$((PASS + 1))
}

payload() {
  # $1 = command, $2 = exit_code, $3 = cwd
  jq -cn --arg cmd "$1" --argjson ec "$2" --arg cwd "$3" \
    '{tool_input: {command: $cmd}, tool_response: {exit_code: $ec}, cwd: $cwd}'
}

# --- cases ---

# 1. Non-merge command, dup present → silent (not a merge moment)
echo "$DUP_JSONL" > "$REPO/.beads/issues.jsonl"
run_case "non-merge command ignored" 0 \
  "$(payload 'git status' 0 "$REPO")"

# 2. Merge command, repo without beads → silent
run_case "merge in beads-less repo ignored" 0 \
  "$(payload 'git merge feature-x --no-edit' 0 "$REPO_NOBEADS")"

# 3. Merge command, clean JSONL → silent
echo "$CLEAN_JSONL" > "$REPO/.beads/issues.jsonl"
run_case "merge with clean jsonl passes" 0 \
  "$(payload 'git merge feature-x --no-edit' 0 "$REPO")"

# 4. Merge command, duplicate id → exit 2, names the bead
echo "$DUP_JSONL" > "$REPO/.beads/issues.jsonl"
run_case "merge with duplicate id flags bd-aaa" 2 \
  "$(payload 'git merge feature-x --no-edit' 0 "$REPO")" \
  "bd-aaa"

# 5. FAILED merge command, dup present → silent (conflict markers path)
run_case "failed merge ignored" 0 \
  "$(payload 'git merge feature-x --no-edit' 1 "$REPO")"

# 6. gh pr merge, duplicate id → exit 2
run_case "gh pr merge with duplicate flags" 2 \
  "$(payload 'gh pr merge 9 --merge --delete-branch' 0 "$REPO")" \
  "bd-aaa"

# 7. git merge-base (read-only ancestry check), dup present → silent
run_case "git merge-base excluded" 0 \
  "$(payload 'git merge-base --is-ancestor worktree-agent-x HEAD' 0 "$REPO")"

# 8. git pull, duplicate id → exit 2
run_case "git pull with duplicate flags" 2 \
  "$(payload 'git pull' 0 "$REPO")" \
  "bd-aaa"

# 9. git -C form, duplicate id → exit 2
run_case "git -C <path> merge with duplicate flags" 2 \
  "$(payload "git -C $REPO merge origin/main --no-edit" 0 "$REPO")" \
  "bd-aaa"

# 10. Remediation guidance present (checkout + doctor mentioned)
run_case "remediation mentions br doctor" 2 \
  "$(payload 'git merge feature-x --no-edit' 0 "$REPO")" \
  "br doctor"

# 11. Anchor hint appears only when beads.base.jsonl exists
touch "$REPO/.beads/beads.base.jsonl"
run_case "anchor present: br sync --merge offered" 2 \
  "$(payload 'git merge feature-x --no-edit' 0 "$REPO")" \
  "br sync --merge"
rm -f "$REPO/.beads/beads.base.jsonl"

# 12. Empty payload → silent
run_case "empty payload ignored" 0 '{}'

# --- summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
else
  echo "FAIL: $FAIL/$TOTAL test cases failed:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
