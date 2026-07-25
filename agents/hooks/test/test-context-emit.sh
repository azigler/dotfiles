#!/bin/bash
# Test for lib/context-emit.sh — the shared branch/dirty + capped-bead
# emission used by pre-compact.sh (PreCompact) and session-start.sh
# (SessionStart/SubagentStart).
#
# Regression target (dotfiles-b9ii):
#   1. pre-compact.sh ran an UNBOUNDED `br list` and injected 31,484 bytes
#      (~7.9k tokens, 173 lines) in ~/explore at the moment context is
#      scarcest — 12x session-start's payload. The cap existed in
#      session-start.sh only.
#   2. The bead TOTAL counted deferred beads, so the banner read
#      "top 12 of 168" when only 144 were live.
#   3. `br list 2>/dev/null` made a BROKEN br indistinguishable from
#      "this project has no beads" — silent failure.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Hermetic: builds its own git repo + real `br` bead store in a temp dir.
# Skips (exit 0, reported) if `br` is unavailable.

set -u

HOOKDIR="$(cd "$(dirname "$0")/.." && pwd)"
PRECOMPACT="$HOOKDIR/pre-compact.sh"
LIB="$HOOKDIR/lib/context-emit.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "FAIL: $1"; }

check_contains() { # <name> <haystack> <needle>
  case "$2" in
    *"$3"*) ok ;;
    *) bad "$1 (expected to contain: $3)" ;;
  esac
}
check_not_contains() { # <name> <haystack> <needle>
  case "$2" in
    *"$3"*) bad "$1 (expected NOT to contain: $3)" ;;
    *) ok ;;
  esac
}

if ! command -v br >/dev/null 2>&1; then
  echo "SKIP: br not installed — context-emit bead cases need a real bead store."
  echo "PASS: 0/0 test cases (skipped)"
  exit 0
fi

# ---------------------------------------------------------------- fixtures
REPO=$(mktemp -d)
FAKEHOME=$(mktemp -d)
trap 'rm -rf "$REPO" "$FAKEHOME"' EXIT

git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" commit -qm seed
git -C "$REPO" checkout -qb ctx-test-branch

# Real bead store: 18 live (17 open + 1 in_progress) + 3 deferred = 21 listed.
( cd "$REPO" && br init --prefix ctxt >/dev/null 2>&1 ) || {
  echo "SKIP: br init failed in temp repo"; echo "PASS: 0/0 test cases (skipped)"; exit 0; }

for i in $(seq 1 20); do
  ( cd "$REPO" && br create -p 3 "ctx: bead number $i" >/dev/null 2>&1 )
done
LIVE_IDS=$( cd "$REPO" && br list --limit 0 2>/dev/null | grep -oE 'ctxt-[a-z0-9]+' )
set -- $LIVE_IDS
( cd "$REPO" && br update "$1" --status in_progress >/dev/null 2>&1 )
( cd "$REPO" && br defer "$2" --until "+30d" >/dev/null 2>&1 )
( cd "$REPO" && br defer "$3" --until "+30d" >/dev/null 2>&1 )

TOTAL_LIVE=$( cd "$REPO" && br list --status open --status in_progress --limit 0 2>/dev/null | grep -c . )
TOTAL_ALL=$( cd "$REPO" && br list --limit 0 2>/dev/null | grep -c . )

if [ "$TOTAL_ALL" -le "$TOTAL_LIVE" ]; then
  echo "SKIP: this br build does not list deferred beads; cannot test the deferred-count regression"
else
  ok  # fixture sanity: deferred beads ARE in the unfiltered list
fi

# A dirty file, so the branch/dirty half is exercised too.
echo dirty > "$REPO/dirty.txt"

run_precompact() { # env-assignments passed through; stdout captured
  ( cd "$REPO" && env HOME="$FAKEHOME" "$@" bash "$PRECOMPACT" < /dev/null 2>/dev/null )
}

# ---------------------------------------------------------------- cases

# 1. The cap applies at all (THE bug: pre-compact was unbounded).
OUT=$(run_precompact)
check_contains "cap applied in pre-compact" "$OUT" "top 12 of $TOTAL_LIVE by priority"

# 2. Only 12 bead lines are emitted, not all of them.
BEADLINES=$(printf '%s\n' "$OUT" | grep -cE '^[○◐❄] ctxt-')
if [ "$BEADLINES" -eq 12 ]; then ok; else bad "exactly 12 bead lines emitted (got $BEADLINES)"; fi

# 3. Deferred beads are NOT counted in the total (regression: counted 168 vs 144).
check_not_contains "deferred beads excluded from total" "$OUT" "of $TOTAL_ALL by priority"

# 4. Deferred beads are not DISPLAYED either.
check_not_contains "deferred beads not displayed" "$OUT" "❄"

# 5. The "+ N more" line reconciles with the total.
check_contains "remainder line present" "$OUT" "+ $((TOTAL_LIVE - 12)) more not shown"

# 6. The partial-view notice (load-bearing: the agent's recourse) survives.
check_contains "partial-view notice" "$OUT" "this is a PARTIAL view"

# 7. Branch + dirty still emitted by the shared lib.
check_contains "branch emitted" "$OUT" "Branch: ctx-test-branch"
check_contains "dirty emitted" "$OUT" "dirty.txt"

# 8. Total injected size stays small. The pre-fix hook emitted 31,484 bytes in
#    ~/explore; with a 12-cap the payload is bounded by the cap, not the backlog.
BYTES=$(printf '%s\n' "$OUT" | wc -c)
if [ "$BYTES" -lt 4000 ]; then ok; else bad "injected payload under 4000 bytes (got $BYTES)"; fi

# 9. The cap is overridable per-project.
OUT3=$(run_precompact HARNESS_ONBOARD_BEAD_CAP=3)
check_contains "cap override honored" "$OUT3" "top 3 of $TOTAL_LIVE by priority"
B3=$(printf '%s\n' "$OUT3" | grep -cE '^[○◐❄] ctxt-')
if [ "$B3" -eq 3 ]; then ok; else bad "override emits 3 bead lines (got $B3)"; fi

# 10. Cap >= total: no truncation notice, full list, header without "top N of".
OUTBIG=$(run_precompact HARNESS_ONBOARD_BEAD_CAP=500)
check_contains "no-truncation header" "$OUTBIG" "Open beads:"
check_not_contains "no remainder line when under cap" "$OUTBIG" "more not shown"

# 11. No bead store: silent about beads, still exits 0 with the onboard nudge.
NOBEADS=$(mktemp -d)
git -C "$NOBEADS" init -q
OUTNB=$( cd "$NOBEADS" && env HOME="$FAKEHOME" bash "$PRECOMPACT" < /dev/null 2>/dev/null )
RCNB=$?
rm -rf "$NOBEADS"
if [ "$RCNB" -eq 0 ]; then ok; else bad "exit 0 with no bead store (got $RCNB)"; fi
check_not_contains "no bead banner without a store" "$OUTNB" "Open beads"
check_contains "onboard nudge still emitted" "$OUTNB" "Run /onboard"

# 12. BROKEN br must NOT read as "no beads" (silent-failure regression).
BRSTUB=$(mktemp -d)
cat > "$BRSTUB/br" <<'STUB'
#!/bin/bash
echo "error: bead database is corrupt" >&2
exit 3
STUB
chmod +x "$BRSTUB/br"
OUTBROKE=$( cd "$REPO" && env HOME="$FAKEHOME" PATH="$BRSTUB:$PATH" bash "$PRECOMPACT" < /dev/null 2>/dev/null )
rm -rf "$BRSTUB"
check_contains "broken br surfaces, not silent" "$OUTBROKE" "Open beads: UNAVAILABLE"
check_contains "broken br reports the error" "$OUTBROKE" "bead database is corrupt"

# 13. Missing lib degrades LOUDLY, not silently.
TMPHOOK=$(mktemp -d)/hooks
mkdir -p "$TMPHOOK"
cp "$PRECOMPACT" "$TMPHOOK/pre-compact.sh"   # no lib/ next to it
OUTNOLIB=$( cd "$REPO" && env HOME="$FAKEHOME" bash "$TMPHOOK/pre-compact.sh" < /dev/null 2>/dev/null )
RCNOLIB=$?
rm -rf "$(dirname "$TMPHOOK")"
check_contains "missing lib is loud" "$OUTNOLIB" "hook lib missing"
if [ "$RCNOLIB" -eq 0 ]; then ok; else bad "missing lib is non-fatal (got rc=$RCNOLIB)"; fi

# 14. The lib is sourceable standalone and defines both emitters.
SRCOUT=$(bash -c ". '$LIB' && declare -F emit_git_context emit_bead_context" 2>&1)
check_contains "emit_git_context defined" "$SRCOUT" "emit_git_context"
check_contains "emit_bead_context defined" "$SRCOUT" "emit_bead_context"

# ---------------------------------------------------------------- summary
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: ${FAILED_NAMES[*]}"
  echo "FAIL: $PASS/$((PASS + FAIL)) test cases"
  exit 1
fi
echo "PASS: $PASS/$((PASS + FAIL)) test cases"
exit 0
