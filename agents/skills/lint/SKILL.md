---
name: lint
description: Code quality policy and linter reference for all supported languages
---

# /lint - Code Quality

## What's Automatic

A post-write hook runs on every file you write or edit. It silently auto-fixes formatting, import sorting, and safe lint issues. You do not need to run these manually:

| Extension | Hook runs | What it fixes |
|-----------|----------|---------------|
| `.js .ts .jsx .tsx .json .css` | `biome check --write` | Formatting, imports, safe lint fixes |
| `.py` | `ruff check --fix` + `ruff format` | Formatting, imports, safe lint fixes |
| `.rs` | `rustfmt` | Formatting only |
| `.go` | `gofmt -w` | Formatting only |

If the hook encounters an unfixable error, it feeds the error back to you. Fix the code and re-write the file.

## What's Automatic at Commit Time

A Claude Code PreToolUse hook intercepts `git commit` commands and runs deep linters on staged files before allowing the commit through. It only runs linters for languages that have staged changes:

| Staged files | Hook runs | What it catches |
|-------------|----------|-----------------|
| `.js .ts .jsx .tsx` | `biome check --staged` | Final lint verification |
| `.py` | `ruff check` | Final lint verification |
| `.rs` | `cargo clippy -- -D warnings` | Bugs, anti-patterns, perf issues |
| `.go` | `golangci-lint run` | Bugs, security, correctness, style |

If the hook fails, it **blocks the commit** and feeds the errors back to you. Fix the issues, re-stage, and try the commit again.

### When Investigating Issues

Use check mode to audit without modifying files:

```bash
biome check .                           # JS/TS
ruff check .                            # Python
cargo fmt --check && cargo clippy -- -D warnings  # Rust
golangci-lint run ./...                 # Go
```

Exit code `0` = clean. Non-zero = issues remain.

## Rules

- **Do not ignore lint errors** to unblock yourself. Fix them or ask for help.
- **Do not disable rules inline** (`// biome-ignore`, `# noqa`, `#[allow(...)]`) unless the rule is genuinely wrong for that line, and leave a comment explaining why.
- **Do not run lint on files you did not modify.** Scope to changed files or directories.

## Known Gaps

These are things the linters cannot catch. Be vigilant about them manually:

- **React hook dependencies** — Biome has no equivalent of ESLint's `react-hooks/exhaustive-deps`. When writing `useEffect`, `useMemo`, or `useCallback`, verify the dependency array is complete. Missing deps cause stale closure bugs.
- **Python type checking** — Ruff does not do type checking. If the project uses mypy or pyright, run those separately.
- **Unsafe fixes** — Auto-fix only applies safe fixes. For unsafe fixes (renames, behavior-changing rewrites), run manually with `biome check --write --unsafe` or `ruff check --fix --unsafe-fixes` and review the diff.

## Command Reference

### Biome (JS/TS)

```bash
biome check --write .                   # Fix all (format + lint + imports)
biome check .                           # Check only
biome check --write --unsafe .          # Fix including unsafe fixes
biome check --staged                    # Check git-staged files only
biome check --changed                   # Check files changed vs default branch
```

### Ruff (Python)

```bash
ruff check --fix . && ruff format .     # Fix all (lint + format)
ruff check .                            # Check only
ruff check --fix --unsafe-fixes .       # Fix including unsafe fixes
ruff format --check .                   # Check formatting only
```

### rustfmt + clippy (Rust)

```bash
cargo fmt                               # Format
cargo clippy --fix --allow-dirty        # Auto-fix lint issues
cargo clippy -- -D warnings             # Check (treat warnings as errors)
cargo clippy -- -W clippy::pedantic -D warnings  # Stricter checks
```

### golangci-lint (Go)

```bash
golangci-lint fmt ./...                 # Format (wraps goimports)
golangci-lint run --fix ./...           # Fix lint issues
golangci-lint run ./...                 # Check only
```
