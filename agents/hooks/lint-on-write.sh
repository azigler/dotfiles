#!/bin/bash
# PostToolUse (Edit|Write): auto-fix formatting and safe lint issues.
# Silent on success. Exit 2 on unfixable errors (feeds back to agent).

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

# Exempt throwaway / scratch paths from the style gate. One-off compute
# scripts shouldn't be hard-blocked on non-auto-fixable style nits (e.g.
# SIM115) mid-flow. Escape hatch: put throwaways under /tmp, a scratch/
# sandbox dir, or name them *.scratch.<ext>. Real committed source still
# gets the full gate.
case "$FILE_PATH" in
  /tmp/*|/var/tmp/*|*/scratch/*|*/.scratch/*|*/sandbox/*|*.scratch.*) exit 0 ;;
esac

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

    # These two are the MUTATING commands, and their stderr used to be
    # blanket-discarded — so a ruff that could not do its job reported
    # "formatted fine" (same silent-failure class as the rustfmt/gofmt
    # branches; dotfiles-2mm, dotfiles-b9ii).
    #
    # ruff's exit codes: 0 = clean, 1 = violations remain, 2+ = ruff ITSELF
    # failed (bad config, unreadable/unwritable file, internal error). Only
    # >=2 is a tool failure: rc 1 from `--fix` is the NORMAL "some violations
    # aren't auto-fixable" path, and the verify step at the end reports those
    # properly. `ruff format` has no violations concept, so any nonzero there
    # is a failure.
    #
    # The case this actually catches: a read-only file with no lint findings.
    # `ruff format` fails with "Failed to write <f>: Permission denied" (rc 2)
    # while both `check` runs pass — so the old code exited 0 having formatted
    # nothing at all, silently.
    RUFF_OUT=$(ruff check --fix "$FILE_PATH" 2>&1)
    RUFF_RC=$?
    if [ "$RUFF_RC" -ge 2 ]; then
      echo "ruff check --fix failed on $FILE_PATH (exit $RUFF_RC; file may be unfixed):" >&2
      echo "$RUFF_OUT" >&2
      exit 2
    fi

    if ! RUFF_OUT=$(ruff format "$FILE_PATH" 2>&1); then
      echo "ruff format failed on $FILE_PATH (file left unformatted):" >&2
      echo "$RUFF_OUT" >&2
      exit 2
    fi

    OUTPUT=$(ruff check "$FILE_PATH" 2>&1) || {
      echo "$OUTPUT" >&2
      exit 2
    }
    ;;
  *.rs)
    # rustfmt only — fast, file-local. cargo clippy runs the whole crate
    # which is too slow for every file write. clippy lives in task-completed.sh.
    command -v rustfmt &>/dev/null || exit 0

    # Derive --edition from the crate's Cargo.toml. Bare rustfmt defaults to
    # edition 2015, which cannot parse edition-2024 syntax (let-chains):
    #   error: let chains are only allowed in Rust 2024 or later
    # It exits 1 — so with stderr discarded AND the exit code unchecked, this
    # hook used to report success having formatted nothing at all, silently,
    # on every edition-2024 file (dotfiles-2mm).
    #
    # Walk up from the file to the nearest Cargo.toml that states a literal
    # edition. A workspace MEMBER usually says `edition.workspace = true`
    # (no literal), so finding nothing there and continuing up to the
    # workspace root — which carries [workspace.package] edition — is the
    # correct behavior, not a failure.
    RS_EDITION=""
    RS_DIR=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P)
    while [ -n "$RS_DIR" ] && [ "$RS_DIR" != "/" ]; do
      if [ -f "$RS_DIR/Cargo.toml" ]; then
        RS_EDITION=$(grep -m1 -E '^[[:space:]]*edition[[:space:]]*=[[:space:]]*"[0-9]{4}"' \
          "$RS_DIR/Cargo.toml" 2>/dev/null | grep -oE '[0-9]{4}')
        [ -n "$RS_EDITION" ] && break
      fi
      RS_DIR=$(dirname "$RS_DIR")
    done
    # Fallback for loose .rs files with no crate around them. 2021 rather
    # than 2024 deliberately: every rustfmt since Rust 1.56 accepts it,
    # whereas `--edition 2024` on an older toolchain is a hard "unknown
    # edition" error that would block every write. Crates that really are
    # 2024 are covered by the detection above — which is the case this bug
    # was actually about.
    RS_EDITION="${RS_EDITION:-2021}"

    # Keep stderr: a parse/format failure must surface, not vanish. (The
    # repo's own rule — "Don't blanket-suppress stderr" — is what this
    # branch was violating.) Exit 2 feeds the error back to the agent,
    # matching the biome / ruff branches above.
    if ! RUSTFMT_OUT=$(rustfmt --edition "$RS_EDITION" "$FILE_PATH" 2>&1); then
      echo "rustfmt --edition $RS_EDITION failed on $FILE_PATH (file left unformatted):" >&2
      echo "$RUSTFMT_OUT" >&2
      exit 2
    fi
    ;;
  *.go)
    # gofmt only — fast, file-local. golangci-lint runs the whole module
    # which is too slow for every file write. It lives in task-completed.sh.
    command -v gofmt &>/dev/null || exit 0

    # Keep stderr and CHECK the exit code — exactly the fix the rustfmt
    # branch above already got (dotfiles-2mm). `gofmt -w` exits 2 and prints
    # `file.go:4:1: expected operand, found '}'` on a parse error; with the
    # stderr discarded and the exit code unchecked, this hook reported
    # success having formatted nothing, on every unparseable Go file.
    # Exit 2 feeds the error back to the agent, matching every other branch.
    if ! GOFMT_OUT=$(gofmt -w "$FILE_PATH" 2>&1); then
      echo "gofmt -w failed on $FILE_PATH (file left unformatted):" >&2
      echo "$GOFMT_OUT" >&2
      exit 2
    fi
    ;;
esac

exit 0
