#!/bin/bash
# Test for the jsonl-union merge-driver install block in session-start.sh.
#
# Regression target (dotfiles-b9ii, bug 7b):
# every command in that block ended in a blanket 2>/dev/null — exactly what
# pre-bash-stderr-guard.sh BLOCKS agents for doing, in the harness's own
# hook. A failed install was therefore completely invisible, while being
# precisely the condition the driver exists to prevent (bead resurrection
# through a union-merged JSONL, lin-eqh).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Hermetic: temp repos, temp HOME, temp $LOG.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

FAKEHOME=$(mktemp -d)
BASE=$(mktemp -d)
trap 'rm -rf "$FAKEHOME" "$BASE"' EXIT

new_repo() { # <identify?> -> repo path
  local r; r=$(mktemp -d "$BASE/repo.XXXXXX")
  git -C "$r" init -q
  if [ "$1" = "identified" ]; then
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
  else
    # No identity AND no fallback: `git commit` fails hard.
    git -C "$r" config user.useConfigOnly true
  fi
  echo seed > "$r/seed.txt"
  git -C "$r" -c user.email=s@s -c user.name=s add seed.txt
  git -C "$r" -c user.email=s@s -c user.name=s commit -qm seed
  mkdir "$r/.beads"
  printf '%s' "$r"
}

run_in() { # <repo> <logfile> -> stdout of the hook
  ( cd "$1" && env HOME="$FAKEHOME" HARNESS_SESSION_START_LOG="$2" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      bash "$HOOK" <<< '{"hook_event_name":"SessionStart"}' 2>/dev/null )
}

# --- 1. Happy path: driver installed, .gitattributes committed, quiet -----
R=$(new_repo identified)
L=$(mktemp)
OUT=$(run_in "$R" "$L")

if grep -q 'merge=jsonl-union' "$R/.gitattributes" 2>/dev/null; then ok
else bad "happy: .gitattributes gets the jsonl-union line"; fi

if [ "$(git -C "$R" config --get merge.jsonl-union.driver)" != "" ]; then ok
else bad "happy: merge.jsonl-union.driver is configured"; fi

if [ -z "$(git -C "$R" status --porcelain -- .gitattributes)" ]; then ok
else bad "happy: .gitattributes is committed, not left dirty"; fi

case "$OUT" in
  *"merge driver NOT fully installed"*) bad "happy: no warning on success" ;;
  *) ok ;;
esac
rm -f "$L"

# --- 2. Idempotent: a second run changes nothing and stays quiet ----------
L=$(mktemp)
OUT=$(run_in "$R" "$L")
case "$OUT" in
  *"merge driver NOT fully installed"*) bad "idempotent: second run stays quiet" ;;
  *) ok ;;
esac
if [ "$(grep -c 'merge=jsonl-union' "$R/.gitattributes")" -eq 1 ]; then ok
else bad "idempotent: the line is not duplicated"; fi
rm -f "$L"

# --- 3. THE REGRESSION: a failing install is VISIBLE, not silent ----------
# No git identity -> the pathspec commit fails. Pre-fix this vanished into
# 2>/dev/null and the session was told nothing.
R2=$(new_repo anonymous)
L=$(mktemp)
OUT=$(run_in "$R2" "$L")

case "$OUT" in
  *"merge driver NOT fully installed"*) ok ;;
  *) bad "failure: the session is warned (got: $(printf '%s' "$OUT" | tail -3))" ;;
esac
case "$OUT" in
  *"git commit"*) ok ;;
  *) bad "failure: the warning names the failing step" ;;
esac
if grep -q 'MERGE-DRIVER FAIL' "$L"; then ok
else bad "failure: detail is captured to the log (log: $(head -c 200 "$L"))"; fi
case "$OUT" in
  *"$L"*) ok ;;
  *) bad "failure: the warning points at the log path" ;;
esac
# Still non-fatal — a hook must never wedge a session.
( cd "$R2" && env HOME="$FAKEHOME" HARNESS_SESSION_START_LOG="$L" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    bash "$HOOK" <<< '{}' >/dev/null 2>&1 )
if [ $? -eq 0 ]; then ok; else bad "failure: hook still exits 0"; fi
rm -f "$L"

# --- 4. Legacy `merge=union` line is stripped ----------------------------
R3=$(new_repo identified)
printf '%s\n' '.beads/*.jsonl merge=union' > "$R3/.gitattributes"
L=$(mktemp)
run_in "$R3" "$L" >/dev/null
if ! grep -qE '^\.beads/\*\.jsonl[[:space:]]+merge=union[[:space:]]*$' "$R3/.gitattributes"; then ok
else bad "legacy: plain merge=union line is removed"; fi
if grep -q 'merge=jsonl-union' "$R3/.gitattributes"; then ok
else bad "legacy: jsonl-union line is present after the strip"; fi
rm -f "$L"

# --- 5. A repo with no .beads is untouched -------------------------------
R4=$(new_repo identified)
rm -rf "$R4/.beads"
L=$(mktemp)
run_in "$R4" "$L" >/dev/null
if [ ! -f "$R4/.gitattributes" ]; then ok
else bad "no-beads repo: .gitattributes is not created"; fi
rm -f "$L"

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
echo "FAIL: $FAIL/$TOTAL test cases failed"
exit 1
