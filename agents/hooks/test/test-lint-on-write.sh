#!/bin/bash
# Test for lint-on-write.sh — the PostToolUse(Edit|Write) auto-formatter.
#
# Regression target (dotfiles-b9ii, bug 3) — the SILENT-FAILURE class:
# a formatter that could not do its job reported success.
#   - :106 `gofmt -w "$FILE" 2>/dev/null` with the exit code unchecked.
#     gofmt exits 2 on a parse error; the hook exited 0. The agent was told
#     its Go file was formatted when gofmt never touched it.
#   - :50-51 `ruff check --fix` / `ruff format` blanket-suppressed on the
#     MUTATING commands. A read-only file with no lint findings made
#     `ruff format` fail ("Failed to write: Permission denied", rc 2) while
#     both `check` runs passed — hook exit 0, file never formatted.
# The rustfmt branch was fixed for exactly this in dotfiles-2mm; these two
# are the same bug in the other two branches.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Cases needing a formatter that isn't installed are skipped, not failed.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/lint-on-write.sh"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

# NOT under /tmp: the hook deliberately exempts /tmp, /var/tmp, */scratch/*,
# */sandbox/* and *.scratch.* from the style gate, so a fixture there would
# make every case vacuously "pass".
D=$(mktemp -d "$HOME/.lint-on-write-test.XXXXXX")
trap 'chmod -R u+w "$D" >/dev/null 2>&1; rm -rf "$D"' EXIT

run() { # <file>; echoes "rc<TAB>stderr"
  local out rc
  out=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
        | bash "$HOOK" 2>&1 >/dev/null)
  rc=$?
  printf '%s\t%s' "$rc" "$out"
}

# ---------------------------------------------------------------- go
if command -v gofmt >/dev/null 2>&1; then
  cat > "$D/broken.go" <<'EOF'
package main
func main() {
  x := ((1 +
}
EOF
  R=$(run "$D/broken.go"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  if [ "$RC" -eq 2 ]; then ok; else bad "go parse error blocks (expected exit 2, got $RC)"; fi
  case "$ERR" in
    *"expected operand"*) ok ;;
    *) bad "go parse error surfaces gofmt's message (got: ${ERR:-<empty>})" ;;
  esac
  case "$ERR" in
    *"gofmt -w failed"*) ok ;;
    *) bad "go failure names the failing tool (got: ${ERR:-<empty>})" ;;
  esac

  # A VALID go file must still pass, silently, and actually get formatted.
  printf 'package main\n\nfunc  main( ) {\n}\n' > "$D/ok.go"
  R=$(run "$D/ok.go"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok; else bad "valid go passes silently (rc=$RC err=$ERR)"; fi
  if grep -q '^func main() {' "$D/ok.go"; then ok; else bad "valid go actually got formatted"; fi
else
  skip "gofmt not installed — go branch untested"
fi

# ---------------------------------------------------------------- python
if command -v ruff >/dev/null 2>&1; then
  # THE regression: unwritable file, no lint findings. `ruff format` fails
  # to write; both `ruff check` runs pass. Pre-fix this exited 0.
  printf 'x  =  1\nprint(x)\n' > "$D/ro.py"
  BEFORE=$(cat "$D/ro.py")
  chmod 444 "$D/ro.py"
  R=$(run "$D/ro.py"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  chmod 644 "$D/ro.py"
  if [ "$RC" -eq 2 ]; then ok; else bad "unwritable py blocks (expected exit 2, got $RC)"; fi
  case "$ERR" in
    *"ruff format failed"*) ok ;;
    *) bad "unwritable py names ruff format (got: ${ERR:-<empty>})" ;;
  esac
  case "$ERR" in
    *"Permission denied"*) ok ;;
    *) bad "unwritable py surfaces ruff's stderr (got: ${ERR:-<empty>})" ;;
  esac
  if [ "$(cat "$D/ro.py")" = "$BEFORE" ]; then ok; else bad "fixture sanity: file really was left unformatted"; fi

  # A py file with a real, non-auto-fixable violation still blocks (rc 1
  # from `ruff check --fix` must NOT be mistaken for a tool crash).
  printf 'import os\n\n\ndef f():\n    return undefined_name\n' > "$D/viol.py"
  R=$(run "$D/viol.py"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  if [ "$RC" -eq 2 ]; then ok; else bad "py violation blocks (expected exit 2, got $RC)"; fi
  case "$ERR" in
    *"ruff check --fix failed"*) bad "py violation must NOT be reported as a --fix tool failure (got: $ERR)" ;;
    *) ok ;;
  esac

  # A clean, badly-formatted py file passes AND gets formatted.
  printf 'x  =  1\nprint(x)\n' > "$D/clean.py"
  R=$(run "$D/clean.py"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok; else bad "clean py passes silently (rc=$RC err=$ERR)"; fi
  if grep -q '^x = 1$' "$D/clean.py"; then ok; else bad "clean py actually got formatted"; fi
else
  skip "ruff not installed — python branch untested"
fi

# ---------------------------------------------------------------- rust
# The dotfiles-2mm fix, guarded: an unparseable .rs file must block.
if command -v rustfmt >/dev/null 2>&1; then
  printf 'fn main( {\n' > "$D/broken.rs"
  R=$(run "$D/broken.rs"); RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
  if [ "$RC" -eq 2 ]; then ok; else bad "rs parse error blocks (expected exit 2, got $RC)"; fi
  case "$ERR" in
    *"rustfmt"*) ok ;;
    *) bad "rs failure names rustfmt (got: ${ERR:-<empty>})" ;;
  esac
else
  skip "rustfmt not installed — rust branch untested"
fi

# ---------------------------------------------------------------- exemptions
# Scratch paths bypass the gate entirely — even when broken.
if command -v gofmt >/dev/null 2>&1; then
  mkdir -p "$D/scratch"
  cp "$D/broken.go" "$D/scratch/broken.go" 2>/dev/null || printf 'package main\nfunc main() { ((\n' > "$D/scratch/broken.go"
  R=$(run "$D/scratch/broken.go"); RC=${R%%$'\t'*}
  if [ "$RC" -eq 0 ]; then ok; else bad "scratch/ path is exempt (got rc=$RC)"; fi
fi

# A nonexistent path is a no-op.
R=$(run "$D/does-not-exist.py"); RC=${R%%$'\t'*}
if [ "$RC" -eq 0 ]; then ok; else bad "nonexistent file is a no-op (got rc=$RC)"; fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  echo "FAIL: $PASS/$((PASS + FAIL)) test cases ($SKIP skipped)"
  exit 1
fi
echo "PASS: $PASS/$((PASS + FAIL)) test cases ($SKIP skipped)"
exit 0
