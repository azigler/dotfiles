#!/bin/bash
# Test for the Layer-2 secret-alert logic in session-end.sh + session-start.sh
# (explore-ytms — the stale/false SECRET ALERT bug).
#
# Hook test convention (see test-session-end.sh, test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<name>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a one-line PASS/FAIL summary at the end
#
# Both hooks reference $HOME/.claude/... exclusively, so each case runs the
# REAL hook under a throwaway $HOME containing a stub scrub.py (exit code
# controlled by $SCRUB_RC) + a fake memory tier. vault-lib keys off $HOME and
# is inert without a bootstrapped vault, so the temp HOME is fully isolated.
#
# The three defects this guards (all in the session-end/session-start pair):
#   1. error === finding — scrub.py exit 2 (scan error) must NOT raise the
#      persistent .secret-alert (only exit 1 = a real finding does).
#   2. marker/log desync — the clean path clears BOTH marker and stale log;
#      a surfaced alert always has a readable log (no dangling "Details:").
#   3. no self-heal — session-start re-scans before crying wolf; a stale marker
#      over a clean tier self-heals silently on the first start.

set -u

HOOKDIR="$(cd "$(dirname "$0")/.." && pwd)"
END="$HOOKDIR/session-end.sh"
START="$HOOKDIR/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Stub `br` so `br sync` is a hermetic no-op.
STUB=$(mktemp -d)
cat > "$STUB/br" <<'STUBSH'
#!/bin/bash
exit 0
STUBSH
chmod +x "$STUB/br"
export PATH="$STUB:$PATH"

TRASH=("$STUB")
cleanup() { rm -rf "${TRASH[@]}"; }
trap cleanup EXIT

# Fresh temp $HOME with a stub scrub.py + a fake (clean) memory tier.
# The stub emulates scrub.py's contract: exit 0=clean, 1=found, 2=error.
new_home() {
  local h
  h=$(mktemp -d)
  mkdir -p "$h/.claude/skills/scrub-secrets" "$h/.claude/projects/proj1/memory"
  echo "# memory" > "$h/.claude/projects/proj1/memory/MEMORY.md"
  cat > "$h/.claude/skills/scrub-secrets/scrub.py" <<'PY'
import os, sys
rc = int(os.environ.get("SCRUB_RC", "0"))
if rc == 1:
    print("proj1/memory/MEMORY.md: 1  {'aws-secret-key': 1}")
elif rc == 2:
    sys.stderr.write("scrub: error: argument mode: invalid choice (simulated)\n")
sys.exit(rc)
PY
  TRASH+=("$h")
  echo "$h"
}

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

# --- session-end.sh ---

# 1. clean (rc0) clears BOTH a pre-existing stale marker AND a stale log (bug 2)
H=$(new_home)
touch "$H/.claude/.secret-alert" "$H/.claude/secret-scan.log"
( cd "$H" && HOME="$H" SCRUB_RC=0 bash "$END" <<<'{}' >/dev/null 2>&1 )
if [ ! -e "$H/.claude/.secret-alert" ] && [ ! -e "$H/.claude/secret-scan.log" ]; then
  ok; else bad "end: clean scan did not clear stale marker + log"; fi

# 2. found (rc1) raises the marker AND writes the log, together
H=$(new_home)
( cd "$H" && HOME="$H" SCRUB_RC=1 bash "$END" <<<'{}' >/dev/null 2>&1 )
if [ -e "$H/.claude/.secret-alert" ] && [ -s "$H/.claude/secret-scan.log" ]; then
  ok; else bad "end: real finding did not raise marker + log"; fi

# 3. scan error (rc2) does NOT raise the persistent marker; logs diagnostics (bug 1)
H=$(new_home)
( cd "$H" && HOME="$H" SCRUB_RC=2 bash "$END" <<<'{}' >/dev/null 2>&1 )
if [ ! -e "$H/.claude/.secret-alert" ] && [ -s "$H/.claude/secret-scan-error.log" ]; then
  ok; else bad "end: scan error wrongly raised .secret-alert (or wrote no diag log)"; fi

# --- session-start.sh ---

# 4. stale marker over a CLEAN tier (rc0) → self-heal: NO alert, marker cleared (bug 3, AC1)
H=$(new_home)
touch "$H/.claude/.secret-alert"
OUT=$( cd "$H" && HOME="$H" SCRUB_RC=0 bash "$START" <<<'{}' 2>/dev/null )
if ! grep -q "SECRET ALERT" <<<"$OUT" && [ ! -e "$H/.claude/.secret-alert" ]; then
  ok; else bad "start: stale marker over clean tier not self-healed"; fi

# 5. marker + still a real finding (rc1) → surface, with a FRESH (non-dangling) log (AC3)
H=$(new_home)
touch "$H/.claude/.secret-alert"
OUT=$( cd "$H" && HOME="$H" SCRUB_RC=1 bash "$START" <<<'{}' 2>/dev/null )
if grep -q "SECRET ALERT" <<<"$OUT" && [ -s "$H/.claude/secret-scan.log" ] && [ -e "$H/.claude/.secret-alert" ]; then
  ok; else bad "start: real finding not surfaced with a fresh log"; fi

# 6. marker + scan error (rc2) → no scary FOUND alert; soft notice; marker KEPT (AC2 @ start)
H=$(new_home)
touch "$H/.claude/.secret-alert"
OUT=$( cd "$H" && HOME="$H" SCRUB_RC=2 bash "$START" <<<'{}' 2>/dev/null )
if ! grep -q "found a secret" <<<"$OUT" && grep -q "could not verify" <<<"$OUT" && [ -e "$H/.claude/.secret-alert" ]; then
  ok; else bad "start: scan error mishandled (cried wolf or dropped the marker)"; fi

# 7. no marker → the whole block is skipped, no alert (baseline; scan not even run)
H=$(new_home)
OUT=$( cd "$H" && HOME="$H" SCRUB_RC=1 bash "$START" <<<'{}' 2>/dev/null )
if ! grep -q "SECRET ALERT" <<<"$OUT"; then
  ok; else bad "start: alerted with no marker present"; fi

# --- Summary ---

TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi

echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
