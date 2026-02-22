#!/bin/bash
# PreToolUse (Bash): lint gate before git commit.
# Exit 2 = block the commit and feed errors to agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git commit commands
case "$COMMAND" in
  git\ commit*|*"&& git commit"*|*"; git commit"*) ;;
  *) exit 0 ;;
esac

# If git add is chained before git commit, run it now so staged files are visible
if echo "$COMMAND" | grep -qP 'git add .+&&'; then
  ADD_CMD=$(echo "$COMMAND" | grep -oP 'git add [^&;]+')
  # Block overly-broad staging (git add ., git add -A, git add --all)
  if echo "$ADD_CMD" | grep -qP 'git add\s+(-A|--all|\.\s*$)'; then
    echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
    exit 2
  fi
  eval "$ADD_CMD" 2>/dev/null
fi

set +e
FAILED=0

# 1. Sync bead state
if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null || true
  git add .beads/issues.jsonl 2>/dev/null || true
fi

if ! echo "$COMMAND" | grep -q 'Bead:'; then
  echo "Warning: commit message has no Bead: trailer." >&2
fi

# 2. Lint staged files by language
STAGED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)

if [ -n "$STAGED" ]; then
  HAS_JS=false
  HAS_PY=false
  HAS_RS=false
  HAS_GO=false

  while IFS= read -r file; do
    case "$file" in
      *.js|*.ts|*.jsx|*.tsx) HAS_JS=true ;;
      *.py) HAS_PY=true ;;
      *.rs) HAS_RS=true ;;
      *.go) HAS_GO=true ;;
    esac
  done <<< "$STAGED"

  if $HAS_JS && command -v biome &>/dev/null; then
    OUTPUT=$(biome check --staged --error-on-warnings 2>&1) || {
      echo "biome: $OUTPUT" >&2
      FAILED=1
    }
  fi

  if $HAS_JS && [ -f "tsconfig.json" ]; then
    OUTPUT=$(npx tsc --noEmit 2>&1) || {
      echo "tsc: $OUTPUT" >&2
      FAILED=1
    }
  fi

  if $HAS_PY && command -v ruff &>/dev/null; then
    PY_STAGED=$(echo "$STAGED" | grep -E '\.py$' | tr '\n' ' ')
    if [ -n "$PY_STAGED" ]; then
      OUTPUT=$(ruff check $PY_STAGED 2>&1) || {
        echo "ruff: $OUTPUT" >&2
        FAILED=1
      }
    fi
  fi

  if $HAS_RS && command -v cargo &>/dev/null; then
    OUTPUT=$(cargo clippy -- -W clippy::pedantic -D warnings 2>&1) || {
      echo "clippy: $OUTPUT" >&2
      FAILED=1
    }
  fi

  if $HAS_GO && command -v golangci-lint &>/dev/null; then
    # Use project config if available, fall back to configs/ dir
    GOLANGCI_CFG=""
    for cfg in .golangci.yml .golangci.yaml configs/.golangci.yml "$HOME/.config/golangci-lint/.golangci.yml"; do
      [ -f "$cfg" ] && GOLANGCI_CFG="--config $cfg" && break
    done
    OUTPUT=$(golangci-lint run $GOLANGCI_CFG ./... 2>&1) || {
      echo "golangci-lint: $OUTPUT" >&2
      FAILED=1
    }
  fi
fi

if [ $FAILED -ne 0 ]; then
  echo "Pre-commit checks failed. Fix errors before committing." >&2
  exit 2
fi

exit 0
