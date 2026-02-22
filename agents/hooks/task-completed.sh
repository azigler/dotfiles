#!/bin/bash
# TaskCompleted: verify modified files are lint-clean before allowing task completion.
# Exit 2 to block and feed errors back.

set +e

DIRTY=$(git diff --name-only 2>/dev/null)
STAGED=$(git diff --cached --name-only 2>/dev/null)
MODIFIED=$(printf '%s\n%s' "$DIRTY" "$STAGED" | sort -u | grep -v '^$')

[ -z "$MODIFIED" ] && exit 0

ERRORS=""

JS_FILES=$(echo "$MODIFIED" | grep -E '\.(js|ts|jsx|tsx)$' | tr '\n' ' ')
PY_FILES=$(echo "$MODIFIED" | grep -E '\.py$' | tr '\n' ' ')
RS_FILES=$(echo "$MODIFIED" | grep -E '\.rs$' | tr '\n' ' ')
GO_FILES=$(echo "$MODIFIED" | grep -E '\.go$' | tr '\n' ' ')

if [ -n "$JS_FILES" ] && command -v biome &>/dev/null; then
  OUTPUT=$(biome check --error-on-warnings $JS_FILES 2>&1) || ERRORS="${ERRORS}biome:\n${OUTPUT}\n\n"
fi

if [ -n "$PY_FILES" ] && command -v ruff &>/dev/null; then
  OUTPUT=$(ruff check $PY_FILES 2>&1) || ERRORS="${ERRORS}ruff:\n${OUTPUT}\n\n"
fi

if [ -n "$RS_FILES" ] && command -v cargo &>/dev/null; then
  OUTPUT=$(cargo clippy -- -W clippy::pedantic -D warnings 2>&1) || ERRORS="${ERRORS}clippy:\n${OUTPUT}\n\n"
fi

if [ -n "$GO_FILES" ] && command -v golangci-lint &>/dev/null; then
  GOLANGCI_CFG=""
  for cfg in .golangci.yml .golangci.yaml configs/.golangci.yml "$HOME/.config/golangci-lint/.golangci.yml"; do
    [ -f "$cfg" ] && GOLANGCI_CFG="--config $cfg" && break
  done
  OUTPUT=$(golangci-lint run $GOLANGCI_CFG ./... 2>&1) || ERRORS="${ERRORS}golangci-lint:\n${OUTPUT}\n\n"
fi

if [ -n "$ERRORS" ]; then
  echo -e "Task has lint errors. Fix before marking complete:\n\n${ERRORS}" >&2
  exit 2
fi

exit 0
