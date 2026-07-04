#!/usr/bin/env bash
# Regression guard for bd-otl8: `br update --notes` is REPLACE-only, and the
# /beads + /check skills must document it as such. This test ties the doc
# claim to br's ACTUAL behavior — if a future `br` upgrade makes --notes
# append (or adds a --note-add flag), the behavior assertion fails, flagging
# that the skill docs are now stale. Run on demand or in a skills-CI sweep.
#
# Usage: bash test-notes-replace-behavior.sh
set -uo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"      # .../skills/beads
BEADS_SKILL="$SKILLS_DIR/SKILL.md"
CHECK_SKILL="$SKILLS_DIR/../check/SKILL.md"

pass=0
fail=0
note() { printf '  %s %s\n' "$1" "$2"; }
ok() { pass=$((pass + 1)); note "PASS" "$1"; }
bad() { fail=$((fail + 1)); note "FAIL" "$1"; }

# --- 1. Behavior: br update --notes REPLACES (does not append) ---
if ! command -v br >/dev/null 2>&1; then
  bad "br not on PATH — cannot verify behavior"
else
  TESTDIR="$(mktemp -d)"
  trap 'rm -rf "$TESTDIR"' EXIT
  (
    cd "$TESTDIR" || exit 1
    br init >/dev/null 2>&1
    ID="$(br create -t note -p 4 "scratch" --silent 2>/dev/null | tail -1)"
    br update "$ID" --notes "FIRST" >/dev/null 2>&1
    br update "$ID" --notes "SECOND" >/dev/null 2>&1
    br show "$ID" --json 2>/dev/null
  ) > "$TESTDIR/out.json"
  N2="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
d=d[0] if isinstance(d,list) else d
print(d.get("notes",""))' "$TESTDIR/out.json" 2>/dev/null)"
  if [ "$N2" = "SECOND" ]; then
    ok "br update --notes is REPLACE-only (SECOND wiped FIRST)"
  elif printf '%s' "$N2" | grep -q "FIRST"; then
    bad "br --notes APPENDED (got '$N2') — behavior CHANGED, skill docs are now STALE, update the caveat"
  else
    bad "br --notes produced unexpected notes: '$N2'"
  fi
fi

# --- 2. Docs: both skills must state REPLACE-only ---
if grep -q "REPLACE-only" "$BEADS_SKILL" 2>/dev/null; then
  ok "/beads SKILL documents --notes REPLACE-only"
else
  bad "/beads SKILL missing REPLACE-only caveat"
fi
if grep -q "REPLACE-only" "$CHECK_SKILL" 2>/dev/null; then
  ok "/check SKILL documents --notes REPLACE-only"
else
  bad "/check SKILL missing REPLACE-only caveat"
fi

# --- 3. No stale bare '0.2.5'-only version stamp without a current-version marker ---
if grep -q "on \`br 0.2.5\`" "$BEADS_SKILL" "$CHECK_SKILL" 2>/dev/null; then
  bad "stale 'on br 0.2.5' stamp remains — should read a verified version range"
else
  ok "no stale single-version 'on br 0.2.5' stamp"
fi

echo
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
  echo "PASS: $pass/$total test cases"
  exit 0
else
  echo "FAIL: $fail/$total test cases failed"
  exit 1
fi
