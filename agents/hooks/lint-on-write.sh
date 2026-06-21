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
    # Respect the project's own formatter: if the repo has no biome
    # config but DOES have a prettier config, don't impose biome
    # defaults on a prettier-formatted codebase (third-party clones,
    # team repos). Our own projects either have biome.json or no
    # formatter config at all — both still get biome (added 2026-06-09).
    FILE_ROOT=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$FILE_ROOT" ] && [ ! -f "$FILE_ROOT/biome.json" ] && [ ! -f "$FILE_ROOT/biome.jsonc" ]; then
      if ls "$FILE_ROOT"/.prettierrc* "$FILE_ROOT"/prettier.config.* &>/dev/null; then
        exit 0
      fi
    fi
    # bd-no31: with root:false (needed for agent worktrees), bare biome walks up
    # and resolves the user-level ~/.config/biome instead of the repo config —
    # reformatting repo files to the wrong style. Pin biome at the repo config
    # when one exists so it stops fighting the project's own settings.
    if [ -f "$FILE_ROOT/biome.jsonc" ]; then
      export BIOME_CONFIG_PATH="$FILE_ROOT/biome.jsonc"
    elif [ -f "$FILE_ROOT/biome.json" ]; then
      export BIOME_CONFIG_PATH="$FILE_ROOT/biome.json"
    fi
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
