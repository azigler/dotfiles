#!/bin/bash
# PreToolUse (Bash): git-discipline gate.
#   - Blocks `git add -A / --all / .` (selective staging only).
#   - Blocks `git push` from inside a worktree (the orchestrator merges
#     the worktree branch and pushes; a worktree push leaves stale
#     worktree-agent-* remote branches).
#   - On `git commit`: requires a `Bead:` trailer (meta-commits exempt),
#     syncs bead state, lints staged JS/PY.
# Exit 2 = block the command and feed errors to the agent.
#
# Fast checks only — staged-only linting that completes in seconds.
# Heavy checks (full-project tsc, cargo clippy, golangci-lint) live in
# task-completed.sh and CI, NOT here.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block overly-broad git add at ANY time, not just when chained with commit.
if echo "$COMMAND" | grep -qE '(^|[[:space:];&|])git add[[:space:]]+(-A([[:space:]]|$)|--all([[:space:]]|$)|\.([[:space:]]|$|[;&|]))'; then
  echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
  echo "Reason: selective staging prevents accidentally committing secrets, WIP, or gitignored state." >&2
  exit 2
fi

# Block `git push` from inside a worktree. Worktree subagents do not
# push — the orchestrator merges the worktree branch and pushes.
if echo "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+push([[:space:]]|$)'; then
  JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$JSON_CWD" ]; then
    CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
    [ -z "$CWD" ] && CWD="$JSON_CWD"
  else
    CWD=$(pwd -P)
  fi
  case "$CWD" in
    */.claude/worktrees/agent-*)
      cat >&2 <<'EOF'
Blocked: `git push` from inside a worktree.

Worktree subagents do not push. Finish your commits; the orchestrator
merges your worktree branch into the target branch and pushes from
there. Pushing from a worktree leaves stale worktree-agent-* remote
branches. See /commit ("Worktree exception").
EOF
      exit 2
      ;;
  esac
fi

# Only intercept git commit commands for the rest of the checks below
case "$COMMAND" in
  git\ commit*|*"&& git commit"*|*"; git commit"*) ;;
  *) exit 0 ;;
esac

# If git add is chained before git commit, run it now so staged files are visible.
if echo "$COMMAND" | grep -qE 'git add .+&&'; then
  ADD_CMD=$(echo "$COMMAND" | grep -oE 'git add [^&;]+' | head -1)
  if echo "$ADD_CMD" | grep -qE 'git add\s+(-A|--all|\.\s*$)'; then
    echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
    exit 2
  fi
  /bin/sh -c "$ADD_CMD" 2>/dev/null
fi

set +e
FAILED=0

# 1. Sync bead state.
# In worktrees, .beads/ is a symlink to the main worktree — skip auto-staging
# to avoid committing symlinked/out-of-tree files that corrupt the branch.
if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null || true
  GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  case "$GIT_TOPLEVEL" in
    */.claude/worktrees/*) ;;  # in worktree, skip
    *) git add .beads/issues.jsonl 2>/dev/null || true ;;
  esac
fi

# 2. Require a `Bead:` trailer — block, not warn. Meta-commits are exempt:
#    bead-state / triage / offboard / cost commits reference beads in the
#    subject rather than a trailer and carry a distinctive gitmoji.
if ! echo "$COMMAND" | grep -q 'Bead:'; then
  if echo "$COMMAND" | grep -qE ':card_file_box:|:broom:|:dollar:'; then
    : # meta-commit (bead-state / triage / offboard / cost) — trailer not required
  else
    echo "Blocked: commit message has no 'Bead: <id>' trailer." >&2
    echo "Every commit maps to a bead — see /commit, /beads ('one bead = one commit')." >&2
    echo "Add a 'Bead: <id>' trailer. Exempt: bead-state / triage / offboard /" >&2
    echo "cost meta-commits (:card_file_box: / :broom: / :dollar: gitmoji)." >&2
    FAILED=1
  fi
fi

# 3. Lint staged files by language (FAST checks only — staged scope, no full-project)
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
