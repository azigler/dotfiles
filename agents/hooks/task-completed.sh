#!/bin/bash
# TaskCompleted: verify modified files are lint-clean before allowing task completion.
# Exit 2 to block and feed errors back.
#
# Heavier than pre-commit-checks because it runs on task boundaries (less
# frequent). Cargo clippy and golangci-lint scope to detected workspace dirs
# rather than full ./... when possible.

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
  OUTPUT=$(biome check --error-on-warnings $JS_FILES 2>&1) || ERRORS="${ERRORS}biome:
${OUTPUT}

"
fi

if [ -n "$PY_FILES" ] && command -v ruff &>/dev/null; then
  OUTPUT=$(ruff check $PY_FILES 2>&1) || ERRORS="${ERRORS}ruff:
${OUTPUT}

"
fi

# cargo clippy: cd to the workspace root closest to the first modified .rs file
# so we lint the right crate (not whatever the cwd happens to be).
if [ -n "$RS_FILES" ] && command -v cargo &>/dev/null; then
  FIRST_RS=$(echo "$RS_FILES" | awk '{print $1}')
  RS_ROOT=$(dirname "$FIRST_RS")
  while [ "$RS_ROOT" != "/" ] && [ "$RS_ROOT" != "." ] && [ ! -f "$RS_ROOT/Cargo.toml" ]; do
    RS_ROOT=$(dirname "$RS_ROOT")
  done
  [ -f "$RS_ROOT/Cargo.toml" ] || RS_ROOT="."
  OUTPUT=$(cd "$RS_ROOT" && cargo clippy -- -W clippy::pedantic -D warnings 2>&1) || ERRORS="${ERRORS}clippy ($RS_ROOT):
${OUTPUT}

"
fi

if [ -n "$GO_FILES" ] && command -v golangci-lint &>/dev/null; then
  GOLANGCI_CFG=""
  for cfg in .golangci.yml .golangci.yaml configs/.golangci.yml "$HOME/.config/golangci-lint/.golangci.yml"; do
    [ -f "$cfg" ] && GOLANGCI_CFG="--config $cfg" && break
  done
  # Scope to dirs containing modified .go files instead of full ./...
  GO_DIRS=$(echo "$GO_FILES" | tr ' ' '\n' | xargs -n1 dirname 2>/dev/null | sort -u | sed 's|^|./|;s|$|/...|' | tr '\n' ' ')
  OUTPUT=$(golangci-lint run $GOLANGCI_CFG $GO_DIRS 2>&1) || ERRORS="${ERRORS}golangci-lint:
${OUTPUT}

"
fi

if [ -n "$ERRORS" ]; then
  printf 'Task has lint errors. Fix before marking complete:\n\n%s' "$ERRORS" >&2
  exit 2
fi

exit 0
