---
description: Code quality policy and linter reference for all supported languages (biome for JS/TS/JSON/CSS, ruff for Python, rustfmt+clippy for Rust, golangci-lint for Go). Documents what auto-runs on file write vs commit-time gates, when to disable rules, per-language gaps and how to compensate, and project-specific config conventions.
allowed-tools: Bash(biome *) Bash(ruff *) Bash(cargo fmt*) Bash(cargo clippy*) Bash(golangci-lint *) Bash(rustfmt *) Bash(gofmt *)
when_to_use: Reference for code-quality policy — which checks auto-run on file write vs gate at commit/task boundaries, and when rule-disabling is acceptable. The hooks run the actual checks.
---

# /lint — Code Quality

## What's automatic (on file write)

A `lint-on-write` hook runs on every file you write or edit. It silently
auto-fixes formatting and safe lint issues. You do NOT run these manually.

| Extension | Hook runs | What it fixes |
|---|---|---|
| `.js .ts .jsx .tsx .json .css` | `biome check --write` | Formatting, imports, safe lint fixes |
| `.py` | `ruff check --fix` + `ruff format` | Formatting, imports, safe lint fixes |
| `.rs` | `rustfmt` | Formatting only (clippy moved to commit-time / task-completed) |
| `.go` | `gofmt -w` | Formatting only (golangci-lint moved to commit-time / task-completed) |

If the hook encounters an unfixable error, it exits 2 and feeds the error
back to you. Fix the code and re-write the file.

## What's automatic at commit time

A `pre-commit-checks` hook intercepts `git commit` and runs FAST,
staged-only validators on the changes you're committing.

| Staged files | Validator | What it catches |
|---|---|---|
| `.js .ts .jsx .tsx` | `biome check --staged` | Final lint verification on staged files |
| `.py` | `ruff check <staged-files>` | Final lint verification on staged files |

**Heavy / slow checks have moved to `task-completed.sh`** — they run at
task boundaries (much less frequent than per-commit), so a 30-second
clippy/tsc/golangci-lint run doesn't break flow:

| Heavy validator | When it runs | Scope |
|---|---|---|
| `tsc --noEmit` | task-completed | full project (typescript needs full graph) |
| `cargo clippy -- -D warnings` | task-completed | crate root for the modified .rs file |
| `golangci-lint run` | task-completed | dirs containing modified .go files |

If the hook fails, it **blocks the action** and feeds errors back. Fix
the issues and try again.

## Investigating issues

Use check mode to audit without modifying files:

```bash
biome check .                            # JS/TS/JSON/CSS
biome check src/components/              # scoped to a dir (monorepo)
ruff check .                             # Python
cargo fmt --check && cargo clippy -- -D warnings    # Rust
golangci-lint run ./...                  # Go
```

Exit code `0` = clean. Non-zero = issues remain.

## Rules

- **Don't ignore lint errors to unblock yourself.** Fix them or ask.
- **Don't disable rules inline** unless the rule is genuinely wrong for
  this case (see decision tree below).
- **Don't run lint on files you didn't modify.** Scope to changed files
  or directories — committing cosmetic auto-fixes alongside functional
  changes pollutes the diff and obscures intent.

## When to disable a rule (decision tree)

```
Is the linter rule wrong for this code?
├─ Yes, this is a one-off pattern the rule shouldn't flag
│  → inline disable WITH a comment explaining why
│  → whole generated / vendored file: file-level disable
│    (e.g. `// biome-ignore-all lint/...: generated`)
├─ Yes, this rule is broken for THIS PROJECT systematically
│  → update biome.jsonc / ruff.toml / clippy.toml / .golangci.yml
│  → commit the config change separately from your code change
└─ No, the rule is right and the code should change
   → refactor to a pattern the rule allows (usually possible);
     don't reach for a disable
```

Inline disable comments by language (always include the *why*):

```typescript
// biome-ignore lint/suspicious/noExplicitAny: callback signature comes from external API typed as `any`; refining here would require fork
function handler(arg: any) { ... }
```

```python
# noqa: E501 - intentional 100-char comment to align with ASCII art header
```

```rust
#[allow(clippy::needless_pass_by_value)] // ownership transfer is intentional; caller's copy is unsafe to share
fn consume(x: Vec<u8>) { ... }
```

```go
//nolint:gosec // crypto/md5 acceptable: hashing for cache key, not security
hash := md5.Sum(data)
```

An inline disable on a single line is rarely the right answer — it's
where lazy disables hide. A disable without a justifying comment is a
code smell; reviewers should push back.

## Known gaps + remedies

These are gaps in the auto-checking. Mind them manually OR set up a
project-level supplement.

### React hook dependencies

Biome **does** catch stale-closure bugs in `useEffect` / `useMemo` /
`useCallback` — its `useExhaustiveDependencies` rule (`lint/correctness`)
is a port of ESLint's `react-hooks/exhaustive-deps` and is recommended
(on by default). `biome check` covers this.

**Caveat**: it diverges from ESLint on some edge cases (custom-hook
stable results, certain `useEffect` semantics). For React-heavy
projects, sanity-check a surprising lint result against the React
docs. The newer React Compiler rules live in `eslint-plugin-react-hooks`
and are out of Biome's scope — add that plugin only if you need them.

### Python type checking

Ruff does not type-check. If the project uses `mypy` or `pyright`,
they're separate.

**Remedy**: each Python project's CLAUDE.md should declare its type
checker. Run before commit:

```bash
mypy <changed-files>     # OR
pyright <changed-files>
```

### Rust clippy auto-fixes

`cargo clippy --fix` applies clippy's machine-applicable suggestions
via rustfix. "Machine-applicable" is not "semantics-preserving" — a
fix can occasionally alter behavior or produce code that doesn't
compile. Always review the diff:

```bash
cargo clippy --fix --allow-dirty       # review every hunk before keeping it
```

There is no separate `--unsafe-fixes` flag for `cargo clippy --fix` —
every suggestion gets the same scrutiny. Never run it as a blind
pre-commit step.

### Go full-project lint scope

`golangci-lint run ./...` scans the whole module. In monorepos with
multiple modules this is slow and can lint code unrelated to your
changes. Scope it:

```bash
golangci-lint run ./pkg/auth/...         # one package tree
```

The `task-completed.sh` hook auto-scopes to dirs with modified `.go`
files; manual runs should do the same.

## Project-specific configs

| Tool | Config files | Where they live |
|---|---|---|
| biome | `biome.json` or `biome.jsonc` | Repo root or workspace root |
| ruff | `ruff.toml` or `pyproject.toml [tool.ruff]` | Repo root |
| clippy | `clippy.toml` | Repo root |
| golangci-lint | `.golangci.yml` or `.golangci.yaml` | Repo root or `configs/` |

### Pin the linter EXACTLY, or its config will drift out from under it

**The failure mode:** biome's `biome.json` hardcodes a *versioned* schema URL —
`https://biomejs.dev/schemas/2.4.16/schema.json` — while `package.json` usually
declares a **caret range** (`"@biomejs/biome": "^2.4.0"`). The schema is pinned;
the CLI is not. Any `bun install` / `npm install` can resolve the CLI to a
different version, and biome then refuses the config:

```
biome.json:2:13 deserialize
  i The configuration schema version does not match the CLI version 2.4.6
  i   Expected: 2.4.6   Found: 2.4.13
```

That error is **counted as an error by `biome check`**, so the whole `check`
gate goes red for a config reason — and a real lint regression can no longer be
distinguished from the standing noise. It degrades silently: nobody upgraded
anything, a lockfile simply resolved somewhere else.

**The rule: pin formatters and linters to an EXACT version** — no caret, no
tilde — and keep `$schema` on that same version. You want byte-identical
formatting across every machine and CI anyway; a range buys you nothing and
costs you this. Same reasoning applies to ruff (`ruff.toml` has no schema
version, but a range still means two machines format differently) and to
`golangci-lint`.

**When you do bump, measure the cost before choosing the target.** Run the
candidate versions against the repo and count, rather than assuming a minor bump
is free:

```bash
# no install needed — run a candidate directly
bunx --bun @biomejs/biome@<version> check . 2>&1 | grep -E '^(Checked|Found)'
```

Real numbers from a 2026-07-27 fix on a twelve-package TypeScript monorepo, same
code, only the biome version varying: **2.4.6 → 8 errors** (plus the
deserialize), **2.4.16 → 8 errors** (deserialize gone), **2.5.5 → 12 errors**.
Moving within the minor was free; the next minor added four new findings *per
package*. That is the difference between a config fix and a work item, and you
only see it by measuring.

**Check for drift with:**

```bash
# declared schema vs actually-installed CLI, for every biome.json in a tree
for f in $(find . -name biome.json -not -path '*/node_modules/*'); do
  d=$(dirname "$f")
  printf '%-50s schema=%-8s installed=%s\n' "$d" \
    "$(grep -oP '(?<=schemas/)[0-9.]+' "$f")" \
    "$(jq -r .version "$d/node_modules/@biomejs/biome/package.json" 2>/dev/null || echo -)"
done
```

**Commit configs.** Don't ignore them. Configs are source of truth for
"which rules apply to this project." If you find yourself disabling
the same rule inline three times, that's a config change.

When you change config: do it in a separate commit, with `:wrench:
config: <what changed and why>`. Mixing config changes with code
changes makes review harder.

## Real-world recovery patterns

### "The auto-fix broke behavior"

biome / ruff occasionally apply fixes that pass tests but change
semantics in subtle ways (e.g., import order affecting side-effect
modules). When this happens:

1. `git diff` the auto-fix to identify what changed
2. Revert only the broken hunk
3. Add an inline disable for the offending rule (with the bug
   reproducer in the comment)
4. File a bug upstream if it's a tool issue

### "The rule fails on monorepo structure"

Cross-package imports flagged as "unresolved" usually mean the linter
isn't seeing the workspace. Check:

- biome: `"linter": { "rules": { ... } }` and per-workspace `biome.json`
- ruff: `[tool.ruff.lint.per-file-ignores]` for workspace boundaries

If the project has a workspace setup, configs go in the workspace root,
not per-package.

## Anti-patterns

- ❌ **Disabling rules to unblock yourself** without addressing the
  root cause
- ❌ **Disable comments without justification** (no `// biome-ignore: <why>`)
- ❌ **Committing cosmetic + functional changes together** — splits
  review attention; commit lint fixes separately
- ❌ **Running lint on files you didn't modify** — scope to changes
- ❌ **Editing project lint config in the same commit as code** — split
  into separate `:wrench: config:` commit
