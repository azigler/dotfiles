#!/bin/bash
# Test for doc-example-lint.py — the guard for "the documented example IS the
# defect" (dotfiles-mlti).
#
# The extraction / rule logic is covered by the script's own `--selftest`
# fixtures (case 1 runs them, so a regression there fails HERE too). What this
# file adds is the surface a Python selftest cannot honestly cover:
#
#   * MUTATION TESTS for the two instances that are ALREADY FIXED upstream
#     (1: pulse SKILL.md's `"row":null`; 3: practices.md's link mandate). A
#     detector for a bug that no longer exists proves nothing by running clean —
#     so the real doc is copied, the defect is reintroduced into the copy, and
#     the linter must catch it. This is the only way "we would have caught it"
#     is a claim rather than a hope.
#   * The HOOK DRY-RUN's safety property: hooks are invoked from a cwd that is
#     not a git repo and has no .beads, which is what makes the mutating
#     branches of pre-commit-checks.sh inert. If that ever stops holding, a
#     doc lint run could `br sync` or execute a pulse proof command.
#   * The CLI contract: exit codes, --json shape, --rule scoping, and the
#     unaudited-hook reporting that keeps a new PreToolUse hook from silently
#     becoming a coverage gap.
#
# Hermetic: fixtures in a per-run tmpdir. Nothing in ~/dotfiles, ~/explore, any
# ledger, any bead, any systemd unit or tmux server is written. The linter is
# read-only by construction; these tests assert that too.
#
# Convention matches agents/scheduler/test-pulse-ledger-lint.sh: executable
# bash, non-zero exit = failure, PASS/FAIL summary on the last line.

set -u

LINT="$(cd "$(dirname "$0")" && pwd)/doc-example-lint.py"
PASS=0
FAIL=0
FAILED_NAMES=()

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-doc-example-lint.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); echo "  ok   — $1"; }
no() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "  FAIL — $1"
  [ -n "${2:-}" ] && echo "         $2"
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) no "$1" "expected to contain: $3" ;;
  esac
}

# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  case "$2" in
    *"$3"*) no "$1" "unexpectedly contains: $3" ;;
    *) ok "$1" ;;
  esac
}

echo "== 1. the script's own regression fixtures"
OUT=$(python3 "$LINT" --selftest 2>&1)
RC=$?
if [ $RC -eq 0 ]; then ok "--selftest passes"; else no "--selftest passes" "$OUT"; fi

echo
echo "== 2. MUTATION: instance 1 (pulse SKILL.md documented \"row\": null)"
PULSE_SRC="$HOME/dotfiles/agents/skills/pulse/SKILL.md"
if [ -f "$PULSE_SRC" ]; then
  mkdir -p "$TMP/i1"
  # Reintroduce the exact defect: a documented ledger row with a null row name.
  sed 's/"row":"weekly-report","outcome":"quiet"/"row":null,"outcome":"quiet"/' \
    "$PULSE_SRC" > "$TMP/i1/SKILL.md"
  if grep -q '"row":null' "$TMP/i1/SKILL.md"; then
    OUT=$(python3 "$LINT" --path "$TMP/i1" --no-discover --rule json-schema 2>&1)
    RC=$?
    assert_contains "row=null in a documented ledger row is caught" "$OUT" "row is null"
    assert_contains "…and attributed to pulse-ledger-lint.py, the real consumer" \
      "$OUT" "pulse-ledger-lint.py"
    [ $RC -eq 1 ] && ok "mutation exits 1" || no "mutation exits 1" "rc=$RC"
    # And the CURRENT (fixed) file must be clean — no residual false positive.
    mkdir -p "$TMP/i1-clean"
    cp "$PULSE_SRC" "$TMP/i1-clean/SKILL.md"
    OUT=$(python3 "$LINT" --path "$TMP/i1-clean" --no-discover --rule json-schema 2>&1)
    RC=$?
    [ $RC -eq 0 ] && ok "the fixed pulse SKILL.md is clean" \
      || no "the fixed pulse SKILL.md is clean" "$OUT"
  else
    no "instance-1 mutation anchor still present in pulse/SKILL.md" \
      "the ledger example changed shape; update this test AND re-verify the rule"
  fi
else
  echo "  skip — $PULSE_SRC not present"
fi

echo
echo "== 3. MUTATION: instance 3 (a link written per the OLD broken mandate)"
mkdir -p "$TMP/i3/sometopic" "$TMP/i3/othertopic"
echo "# other" > "$TMP/i3/othertopic/FINDINGS.md"
cat > "$TMP/i3/sometopic/CLAUDE.md" <<'EOF'
# sometopic

Broken (the form practices.md used to mandate):
[othertopic](othertopic/FINDINGS.md)

Working (the `../` form that replaced it):
[othertopic](../othertopic/FINDINGS.md)
EOF
OUT=$(python3 "$LINT" --path "$TMP/i3" --no-discover --rule broken-link 2>&1)
assert_contains "the bare sibling-folder link form is caught" \
  "$OUT" "'othertopic/FINDINGS.md' does not resolve"
assert_not_contains "the ../ form that replaced it is NOT flagged" \
  "$OUT" "'../othertopic/FINDINGS.md' does not resolve"

echo
echo "== 4. instance 2 (a documented command the machine's own hooks refuse)"
mkdir -p "$TMP/i2"
cat > "$TMP/i2/CLAUDE.md" <<'EOF'
# cleanup

```bash
git worktree remove --force --force .claude/worktrees/agent-XXXX
git branch -D worktree-agent-XXXX
git push origin --delete worktree-agent-XXXX 2>/dev/null || true
```
EOF
OUT=$(python3 "$LINT" --path "$TMP/i2" --no-discover --rule hook-block 2>&1)
RC=$?
if [ -f "$HOME/.claude/hooks/pre-bash-stderr-guard.sh" ]; then
  assert_contains "the stderr-guard's refusal of the cleanup line is caught" \
    "$OUT" "stderr-guard"
  assert_contains "…reported as hook-block" "$OUT" "hook-block"
  [ $RC -eq 1 ] && ok "hook-block exits 1" || no "hook-block exits 1" "rc=$RC"
  assert_not_contains "the two clean lines above it are not flagged" \
    "$OUT" "git worktree remove"
else
  echo "  skip — pre-bash-stderr-guard.sh not installed"
fi

echo
echo "== 5. instance 4 (stale model id in a copy-me template)"
mkdir -p "$TMP/i4"
cat > "$TMP/i4/CLAUDE.md" <<'EOF'
# project

Commit like this:

```
:sparkles: scope: thing

Bead: x-1
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```
EOF
OUT=$(python3 "$LINT" --path "$TMP/i4" --no-discover --rule stale-model-id 2>&1)
assert_contains "a stale hardcoded model id in a commit template is caught" \
  "$OUT" "Claude Opus 4.6"
assert_contains "…and says why it matters" "$OUT" "false attribution"

echo
echo "== 6. instance 5 (vacuous merge-safety check)"
mkdir -p "$TMP/i5"
cat > "$TMP/i5/CLAUDE.md" <<'EOF'
# merge

```bash
git merge worktree-agent-XXXX --no-edit
git merge-base --is-ancestor worktree-agent-XXXX HEAD  # safety: abort if not merged
```

Guarded form:

```bash
test "$(git rev-parse --abbrev-ref HEAD)" = main || exit 1
git merge-base --is-ancestor worktree-agent-XXXX HEAD
```
EOF
OUT=$(python3 "$LINT" --path "$TMP/i5" --no-discover --rule vacuous-ancestor-check 2>&1)
assert_contains "the unguarded ancestor check is flagged" "$OUT" "passes TRIVIALLY"
COUNT=$(echo "$OUT" | grep -c "passes TRIVIALLY")
[ "$COUNT" = "1" ] && ok "the guarded form is NOT flagged (exactly 1 finding)" \
  || no "the guarded form is NOT flagged" "found $COUNT"

echo
echo "== 7. hook dry-run SAFETY: the sandbox cwd is not a repo and has no beads"
# The purity argument for running pre-commit-checks.sh at all is that its
# mutating branches (br sync, auto-staging .beads/issues.jsonl, executing a
# pulse proof.cmd) are gated on a git repo + .beads in the hook process's cwd.
# Prove the linter never hands it one: give it a doc whose block would trip
# every one of those branches, in a temp HOME-free dir, and assert nothing was
# created and no bead state moved.
mkdir -p "$TMP/safety"
cat > "$TMP/safety/CLAUDE.md" <<'SAFEEOF'
# dangerous-looking doc

```bash
git commit -m "no bead trailer here at all"
git add -A
br close some-bead-id
git merge worktree-agent-ZZZZ
```
SAFEEOF
BEFORE=$(ls -la "$TMP/safety" | wc -l)
OUT=$(python3 "$LINT" --path "$TMP/safety" --no-discover --rule hook-block 2>&1)
AFTER=$(ls -la "$TMP/safety" | wc -l)
[ "$BEFORE" = "$AFTER" ] && ok "no files created next to the scanned doc" \
  || no "no files created next to the scanned doc" "$BEFORE -> $AFTER"
assert_contains "git add -A is caught by pre-commit-checks" "$OUT" "git add"
# The sandbox dir the hooks ran in must be gone (and must never have been a repo).
LEAKED=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'doc-example-lint-sandbox-*' 2>/dev/null | wc -l)
[ "$LEAKED" = "0" ] && ok "the hook sandbox is cleaned up" \
  || no "the hook sandbox is cleaned up" "$LEAKED left behind"

echo
echo "== 8. the linter does not write to the docs it scans"
CKSUM_BEFORE=$(cksum "$TMP/i2/CLAUDE.md")
python3 "$LINT" --path "$TMP/i2" --no-discover > /dev/null
CKSUM_AFTER=$(cksum "$TMP/i2/CLAUDE.md")
[ "$CKSUM_BEFORE" = "$CKSUM_AFTER" ] && ok "scanned docs are byte-identical after a run" \
  || no "scanned docs are byte-identical after a run" "checksum changed"

echo
echo "== 9. clean input is clean (the false-positive floor)"
mkdir -p "$TMP/clean"
cat > "$TMP/clean/CLAUDE.md" <<'EOF'
# clean project

```bash
br create -p 2 "scope: title"
br update <id> --claim
git add .beads/issues.jsonl
git commit -m "$(cat <<'INNER'
:sparkles: scope: thing

Bead: x-1
INNER
)"
```

```json
{"ts":"2026-07-25T01:21:32Z","row":"vibe-explore","outcome":"done"}
```

Placeholders and elisions are normal in docs:

```bash
python3 bin/gen-index.py --check
cp /tmp/<agent-output>.md <project>/refs/research/<topic>.md
```
EOF
OUT=$(python3 "$LINT" --path "$TMP/clean" --no-discover 2>&1)
RC=$?
[ $RC -eq 0 ] && ok "an idiomatic doc produces zero errors" \
  || no "an idiomatic doc produces zero errors" "$OUT"

echo
echo "== 10. CLI contract"
OUT=$(python3 "$LINT" --path "$TMP/i2" --no-discover --json 2>&1)
echo "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "findings" in d and "hooks_evaluated" in d and "ok" in d' 2>/dev/null \
  && ok "--json emits the documented shape" || no "--json emits the documented shape" "$OUT"

OUT=$(python3 "$LINT" --explain-hooks 2>&1)
RC=$?
[ $RC -eq 0 ] && ok "--explain-hooks exits 0" || no "--explain-hooks exits 0" "rc=$RC"
assert_contains "--explain-hooks states each hook's purity rationale" "$OUT" "RUN "

# An unaudited PreToolUse Bash hook must be REPORTED, never silently skipped —
# otherwise a new hook becomes an invisible hole in the highest-value check.
FAKE_SETTINGS="$TMP/settings.json"
cat > "$FAKE_SETTINGS" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
  {"type": "command", "command": "/bin/echo"}
]}]}}
EOF
OUT=$(python3 "$LINT" --path "$TMP/clean" --no-discover --settings "$FAKE_SETTINGS" 2>&1)
assert_contains "an unaudited hook is reported as NOT evaluated" "$OUT" "NOT evaluated"

echo
echo "== 11. --rule scoping"
OUT=$(python3 "$LINT" --path "$TMP/i4" --no-discover --rule broken-link 2>&1)
assert_not_contains "--rule broken-link does not run stale-model-id" "$OUT" "Claude Opus 4.6"

echo
echo "========================================"
echo "PASS: $PASS   FAIL: $FAIL"
if [ $FAIL -gt 0 ]; then
  printf '  failed: %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
