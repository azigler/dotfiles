#!/bin/bash
# Test for pulse-ledger-lint.py — the fleet-wide pulse-ledger attribution gate.
#
# The gate's CORE logic (row=null, missing keys, unknown row names, outcome/ts
# validation, malformed lines, routing-table discovery) is covered two ways
# already: the script's own `--selftest` fixtures, and the 28-case suite in
# ~/explore/bin/test_pulse_ledger_lint.py that was written with the original.
# Case 1 below runs `--selftest` so a regression there fails HERE too.
#
# What this file adds is coverage of the surface that is NEW in the canonical
# copy and exists in no other suite: PROJECT-ANCHORED path resolution. The
# explore original resolved its defaults from `__file__/..`; living in
# ~/dotfiles that would resolve to ~/dotfiles/agents/refs/*, so the canonical
# copy resolves against `--project` (default cwd) instead. That change is
# exactly the kind of silent path bug the /pulse SKILL warns about (bare
# relative ledger paths crossing projects), so it gets real tests.
#
# Hermetic: fixture routing tables + ledgers in a per-run tmpdir. No real
# project, ledger, systemd unit, or tmux server is touched.
#
# Convention matches test-pulse-inject.sh / test-pulse-retry.sh: executable
# bash, non-zero exit = failure, PASS/FAIL summary on the last line.

set -u

LINT="$(cd "$(dirname "$0")" && pwd)/pulse-ledger-lint.py"
PASS=0
FAIL=0
FAILED_NAMES=()

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() {
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("$1")
  echo "FAIL $1: $2"
}

# --- Fixture project ---------------------------------------------------------
# Two rows in the routing table so "row names come from the TABLE" is testable
# (a hardcoded row list would pass a one-row fixture by accident).
mk_project() { # $1 = project dir
  mkdir -p "$1/refs"
  cat > "$1/refs/pulse.md" <<'EOMD'
# pulse routing — fixture

| priority | name | trigger | check | action | cap |
|---|---|---|---|---|---|
| 1 | fixture-row | time: Mon | `true` | do the thing | 1/day |
| 2 | other-row | state | `true` | other thing | 4/day |

An unrelated table, which must NOT contribute row names:

| column | other |
|---|---|
| nope | nah |
EOMD
}

GOOD='{"ts":"2026-07-25T01:21:32Z","row":"fixture-row","outcome":"done","proof":{"kind":"cmd","cmd":"true"}}'
QUIET='{"ts":"2026-07-25T02:00:00Z","row":"other-row","outcome":"quiet","note":"cap exhausted"}'
NULLROW='{"ts":"2026-07-25T03:00:00Z","row":null,"outcome":"quiet","note":"no row satisfied"}'
UNATTR='{"ts":"2026-07-25T04:00:00Z","row":"unattributed","outcome":"quiet","note":"cannot recover"}'

P="$ROOT/proj"
mk_project "$P"
printf '%s\n%s\n' "$GOOD" "$QUIET" > "$P/refs/pulse-ledger.jsonl"

# --- 1. the built-in fixtures still pass ------------------------------------
if out=$(python3 "$LINT" --selftest 2>&1) && [[ "$out" == *PASS* ]]; then
  ok "selftest_fixtures_pass"
else
  no "selftest_fixtures_pass" "$out"
fi

# --- 2. --project anchors both default paths --------------------------------
out=$(python3 "$LINT" --project "$P" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"verdict: CLEAN"* ]] \
  && [[ "$out" == *"$P/refs/pulse-ledger.jsonl"* ]]; then
  ok "project_flag_anchors_defaults"
else
  no "project_flag_anchors_defaults" "rc=$rc $out"
fi

# --- 3. defaults follow CWD when --project is omitted ------------------------
# The whole point of the canonical copy: paths must NOT resolve relative to the
# script's own location in ~/dotfiles.
out=$(cd "$P" && python3 "$LINT" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"$P/refs/pulse-ledger.jsonl"* ]]; then
  ok "cwd_is_the_default_project"
else
  no "cwd_is_the_default_project" "rc=$rc $out"
fi

# --- 4. a project that is NOT cwd is unaffected by cwd -----------------------
# Guards the cross-ledger bug class the /pulse SKILL calls out: a drifted cwd
# must never redirect an explicitly-anchored lint at another project.
Q="$ROOT/other"
mk_project "$Q"
printf '%s\n' "$NULLROW" > "$Q/refs/pulse-ledger.jsonl"
out=$(cd "$P" && python3 "$LINT" --project "$Q" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *"row is null"* ]] \
  && [[ "$out" == *"$Q/refs/pulse-ledger.jsonl"* ]]; then
  ok "explicit_project_beats_cwd"
else
  no "explicit_project_beats_cwd" "rc=$rc $out"
fi

# --- 5. THE BUG GUARD: row=null is a hard failure ----------------------------
if [ "$rc" -eq 1 ] && [[ "$out" == *'"unattributed"'* ]]; then
  ok "null_row_fails_and_names_the_escape_hatch"
else
  no "null_row_fails_and_names_the_escape_hatch" "rc=$rc $out"
fi

# --- 6. the honest gap marker is accepted ------------------------------------
printf '%s\n' "$UNATTR" > "$Q/refs/pulse-ledger.jsonl"
out=$(python3 "$LINT" --project "$Q" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"verdict: CLEAN"* ]]; then
  ok "unattributed_is_accepted"
else
  no "unattributed_is_accepted" "rc=$rc $out"
fi

# --- 7. row names come from the routing TABLE, not from code -----------------
printf '%s\n' '{"ts":"2026-07-25T05:00:00Z","row":"invented","outcome":"quiet"}' \
  > "$Q/refs/pulse-ledger.jsonl"
out=$(python3 "$LINT" --project "$Q" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [[ "$out" == *"not in any routing table"* ]] \
  && [[ "$out" == *"fixture-row"* ]] && [[ "$out" != *nope* ]]; then
  ok "row_names_discovered_from_table_only"
else
  no "row_names_discovered_from_table_only" "rc=$rc $out"
fi

# --- 8. --allow extends the set (cross-project rows, e.g. the elevate sweep) --
out=$(python3 "$LINT" --project "$Q" --allow invented 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "allow_extends_valid_rows"
else
  no "allow_extends_valid_rows" "rc=$rc $out"
fi

# --- 9. explicit --ledger / --routing override the project anchor ------------
out=$(python3 "$LINT" --project "$P" \
  --ledger "$Q/refs/pulse-ledger.jsonl" \
  --routing "$Q/refs/pulse.md" --allow invented --json 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == *"\"ledger\": \"$Q/refs/pulse-ledger.jsonl\""* ]]; then
  ok "explicit_paths_override_project"
else
  no "explicit_paths_override_project" "rc=$rc $out"
fi

# --- 10. a project with no ledger / no table exits 2 (usage), not 0 ----------
# Exit 2 must stay distinct from 1: a wiring mistake is not "clean".
EMPTY="$ROOT/empty"
mkdir -p "$EMPTY/refs"
out=$(python3 "$LINT" --project "$EMPTY" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"routing table not found"* ]]; then
  ok "missing_routing_exits_2"
else
  no "missing_routing_exits_2" "rc=$rc $out"
fi

mk_project "$EMPTY"
out=$(python3 "$LINT" --project "$EMPTY" 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && [[ "$out" == *"ledger not found"* ]]; then
  ok "missing_ledger_exits_2"
else
  no "missing_ledger_exits_2" "rc=$rc $out"
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: ${FAILED_NAMES[*]}"
fi
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
