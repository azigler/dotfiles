#!/bin/bash
# PostToolUse (Edit|Write): auto-fix formatting and safe lint issues.
# Silent on success. Exit 2 on unfixable errors (feeds back to agent).

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

case "$FILE_PATH" in
  *.js|*.ts|*.jsx|*.tsx|*.json|*.css)
    command -v biome &>/dev/null || exit 0
    OUTPUT=$(biome check --write --error-on-warnings "$FILE_PATH" 2>&1) || {
      echo "$OUTPUT" >&2
      exit 2
    }
    ;;
  *.py)
    command -v ruff &>/dev/null || exit 0
    ruff check --fix "$FILE_PATH" 2>/dev/null
    ruff format "$FILE_PATH" 2>/dev/null
    OUTPUT=$(ruff check "$FILE_PATH" 2>&1) || {
      echo "$OUTPUT" >&2
      exit 2
    }
    ;;
  *.rs)
    # rustfmt only — fast, file-local. cargo clippy runs the whole crate
    # which is too slow for every file write. clippy lives in task-completed.sh.
    command -v rustfmt &>/dev/null || exit 0
    rustfmt "$FILE_PATH" 2>/dev/null
    ;;
  *.go)
    # gofmt only — fast, file-local. golangci-lint runs the whole module
    # which is too slow for every file write. It lives in task-completed.sh.
    command -v gofmt &>/dev/null || exit 0
    gofmt -w "$FILE_PATH" 2>/dev/null
    ;;
esac

exit 0
