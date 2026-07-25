#!/bin/bash
# Test for post-orchestrator-action.sh — the /triage nudge after
# `br close` / worktree merge.
#
# Regression target (dotfiles-b9ii, bug 2):
#   READY_COUNT=$(br ready | grep -cE '^[○●]' || echo 0)
# `grep -c` PRINTS "0" and EXITS 1 on no-match, so `|| echo 0` appended a
# SECOND "0". READY_COUNT became the two-line string "0\n0" and the
# following `[ "$READY_COUNT" -gt 30 ]` emitted
#   post-orchestrator-action.sh: line 28: [: 0\n0: integer expression expected
# on stderr for EVERY `br close` / worktree merge in a repo with no ready
# beads — i.e. a live shell error injected into the orchestrator's
# transcript on a routine action.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Hermetic: `br` and `bv` are stubbed; no real bead store is touched.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/post-orchestrator-action.sh"

PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "FAIL: $1"; }

STUB=$(mktemp -d)
WORKDIR=$(mktemp -d)
mkdir -p "$WORKDIR/.beads"
trap 'rm -rf "$STUB" "$WORKDIR"' EXIT

# `bv` stub: silent no-op, so the bv next-pick block can't add noise.
cat > "$STUB/bv" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$STUB/bv"

# `br` stub: `br ready` emits $BR_READY_LINES bead-shaped lines (default 0).
cat > "$STUB/br" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "ready" ]; then
  n=${BR_READY_LINES:-0}
  i=0
  while [ "$i" -lt "$n" ]; do
    echo "○ stub-$i [● P2] [task] - stub bead $i"
    i=$((i + 1))
  done
fi
exit 0
STUB
chmod +x "$STUB/br"

run() { # <json-payload>; echoes "rc<TAB>stderr"
  local out rc
  out=$( cd "$WORKDIR" && printf '%s' "$1" \
        | env PATH="$STUB:$PATH" bash "$HOOK" 2>&1 >/dev/null )
  rc=$?
  printf '%s\t%s' "$rc" "$out"
}

payload() { # <command> [exit_code]
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"tool_response":{"exit_code":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "${2:-0}"
}

# --- 1. THE REGRESSION: zero ready beads must produce NO shell error -------
R=$(BR_READY_LINES=0 run "$(payload 'br close bd-123')")
RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
case "$ERR" in
  *"integer expression expected"*)
    bad "zero ready beads: no 'integer expression expected' (got: $ERR)" ;;
  *) ok ;;
esac
if [ -z "$ERR" ]; then ok; else bad "zero ready beads: stderr is empty (got: $ERR)"; fi
if [ "$RC" -eq 0 ]; then ok; else bad "zero ready beads: exit 0 (got $RC)"; fi

# --- 2. Under threshold: no hint ------------------------------------------
R=$(BR_READY_LINES=30 run "$(payload 'br close bd-123')")
ERR=${R#*$'\t'}
case "$ERR" in
  *"consider running /triage"*) bad "30 ready beads (== threshold): no hint" ;;
  *) ok ;;
esac

# --- 3. Over threshold: hint fires with the RIGHT count -------------------
R=$(BR_READY_LINES=42 run "$(payload 'br close bd-123')")
ERR=${R#*$'\t'}
case "$ERR" in
  *"'br ready' has 42 items"*) ok ;;
  *) bad "42 ready beads: hint names the count (got: $ERR)" ;;
esac

# --- 4. Fires on a worktree merge too ------------------------------------
R=$(BR_READY_LINES=42 run "$(payload 'git merge worktree-agent-abc123 --no-edit')")
ERR=${R#*$'\t'}
case "$ERR" in
  *"'br ready' has 42 items"*) ok ;;
  *) bad "worktree merge fires the hint (got: $ERR)" ;;
esac

# --- 5. Unrelated command: no-op -----------------------------------------
R=$(BR_READY_LINES=42 run "$(payload 'ls -la')")
RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
if [ -z "$ERR" ] && [ "$RC" -eq 0 ]; then ok; else bad "unrelated command is a no-op (rc=$RC err=$ERR)"; fi

# --- 6. Failed action: no-op ---------------------------------------------
R=$(BR_READY_LINES=42 run "$(payload 'br close bd-123' 1)")
ERR=${R#*$'\t'}
if [ -z "$ERR" ]; then ok; else bad "failed br close is a no-op (got: $ERR)"; fi

# --- 7. `br close` INSIDE a quoted commit message must not fire ----------
R=$(BR_READY_LINES=42 run "$(payload 'git commit -m "note: remember to br close bd-9"')")
ERR=${R#*$'\t'}
if [ -z "$ERR" ]; then ok; else bad "br close inside a quoted message is a no-op (got: $ERR)"; fi

# --- 8. Non-numeric `br ready` output can't crash the test ---------------
cat > "$STUB/br" <<'STUB'
#!/bin/bash
echo "Error: Beads not initialized: run 'br init' first" >&2
exit 2
STUB
chmod +x "$STUB/br"
R=$(run "$(payload 'br close bd-123')")
RC=${R%%$'\t'*}; ERR=${R#*$'\t'}
case "$ERR" in
  *"integer expression"*|*"unary operator"*) bad "broken br: no shell error (got: $ERR)" ;;
  *) ok ;;
esac
if [ "$RC" -eq 0 ]; then ok; else bad "broken br: exit 0 (got $RC)"; fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  echo "FAIL: $PASS/$((PASS + FAIL)) test cases"
  exit 1
fi
echo "PASS: $PASS/$((PASS + FAIL)) test cases"
exit 0
