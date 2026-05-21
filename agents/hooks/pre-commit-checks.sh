#!/bin/bash
# PreToolUse (Bash): lint gate before git commit.
# Exit 2 = block the commit and feed errors to agent.
#
# Fast checks only — staged-only linting that completes in seconds.
# Heavy/slow checks (full-project tsc, cargo clippy, golangci-lint) live in
# task-completed.sh and CI, NOT here. A pre-commit hook that blocks for
# 30+ seconds breaks flow.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block overly-broad git add at ANY time, not just when chained with commit.
# Matches `git add -A`, `git add --all`, and `git add .` (bare dot).
if echo "$COMMAND" | grep -qE '(^|[[:space:];&|])git add[[:space:]]+(-A([[:space:]]|$)|--all([[:space:]]|$)|\.([[:space:]]|$|[;&|]))'; then
  echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
  echo "Reason: selective staging prevents accidentally committing secrets, WIP, or gitignored state." >&2
  exit 2
fi

# Only intercept git commit commands for the rest of the checks below
case "$COMMAND" in
  git\ commit*|*"&& git commit"*|*"; git commit"*) ;;
  *) exit 0 ;;
esac

# If git add is chained before git commit, run it now so staged files are visible.
# Use POSIX grep -E (no PCRE), and run via direct shell invocation (not eval).
if echo "$COMMAND" | grep -qE 'git add .+&&'; then
  ADD_CMD=$(echo "$COMMAND" | grep -oE 'git add [^&;]+' | head -1)
  # Sanity check: nothing fancy in $ADD_CMD beyond git add + paths.
  if echo "$ADD_CMD" | grep -qE 'git add\s+(-A|--all|\.\s*$)'; then
    echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
    exit 2
  fi
  # Execute via /bin/sh -c (not eval): defangs trailing ; & | even if grep missed them.
  /bin/sh -c "$ADD_CMD" 2>/dev/null
fi

set +e
FAILED=0

# 1. Sync bead state
# In worktrees, .beads/ is a symlink to the main worktree — skip auto-staging
# to avoid committing symlinked/out-of-tree files that corrupt the branch
if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null || true
  GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  case "$GIT_TOPLEVEL" in
    */.claude/worktrees/*) ;;  # in worktree, skip
    *) git add .beads/issues.jsonl 2>/dev/null || true ;;
  esac
fi

if ! echo "$COMMAND" | grep -q 'Bead:'; then
  echo "Warning: commit message has no Bead: trailer." >&2
fi

# 2. Lint staged files by language (FAST checks only — staged scope, no full-project)
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

if [ -n "$STAGED" ]; then
  HAS_JS=false
  HAS_PY=false

  while IFS= read -r file; do
    case "$file" in
      *.js|*.ts|*.jsx|*.tsx) HAS_JS=true ;;
      *.py) HAS_PY=true ;;
    esac
  done <<< "$STAGED"

  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # JS/TS: biome --staged is fast (analyzes only the staged subset)
  if $HAS_JS && command -v biome &>/dev/null; then
    OUTPUT=$(cd "$GIT_ROOT" && biome check --staged --error-on-warnings 2>&1) || {
      echo "biome: $OUTPUT" >&2
      FAILED=1
    }
  fi

  # Python: ruff on staged .py files only
  if $HAS_PY && command -v ruff &>/dev/null; then
    PY_STAGED=$(echo "$STAGED" | grep -E '\.py$' | tr '\n' ' ')
    if [ -n "$PY_STAGED" ]; then
      OUTPUT=$(ruff check $PY_STAGED 2>&1) || {
        echo "ruff: $OUTPUT" >&2
        FAILED=1
      }
    fi
  fi

  # Heavy checks (tsc / cargo clippy / golangci-lint) DELIBERATELY OMITTED.
  # They run on whole projects and can take 30s+. Use task-completed.sh + CI.
fi

if [ $FAILED -ne 0 ]; then
  echo "Pre-commit checks failed. Fix errors before committing." >&2
  exit 2
fi

exit 0
