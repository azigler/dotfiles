#!/usr/bin/env bash
#
# test_run_scenario.sh — bash test harness for run-scenario.sh extensions.
#
# Covers spec dotfiles-ukx.13 test cases:
#   T-01: --trials 3 emits 3 result files
#   T-02: non-existent candidate fails fast with non-zero exit
#   T-06: trial exceeding wall cap is killed and logged as TIMEOUT
#   T-07: defensive pre-Setup rm -rf (OQ-07) — N-trial cross-contamination
#   T-10: outlier-capable output schema (wall_cap_seconds field present)
#
# Spec: dotfiles-ukx.13 §4.1
# Test bead: dotfiles-ukx.13.2
#
# Invokes run-scenario.sh with a fixture scenario .md + fake `claude` binary.
#
# Run via: bash tests/test_run_scenario.sh
# Exit 0 = all tests passed. Non-zero exit aborts the suite.

set -u  # NOT set -e: we want to count test failures, not abort.

DOTFILES_ROOT="${DOTFILES_ROOT:-/home/ubuntu/dotfiles}"
RUN_SCENARIO="$DOTFILES_ROOT/claude/sandbox/run-scenario.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# ---- Test framework primitives ----

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED_TESTS+=("$1")
  echo "FAIL: $1"
  [[ -n "${2:-}" ]] && echo "      $2"
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "expected='$expected' actual='$actual'"
  fi
}

assert_ne_zero() {
  local code="$1" label="$2"
  if [[ "$code" -ne 0 ]]; then
    pass "$label (exit=$code)"
  else
    fail "$label" "expected non-zero exit, got $code"
  fi
}

# ---- Fixture setup: scratch tmp + fake claude on PATH ----

SCRATCH="$(mktemp -d -t run-scenario-test.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# Build a fake `claude` binary that always succeeds with predictable stdout.
# Used so tests don't actually hit Anthropic.
FAKE_BIN="$SCRATCH/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'FAKE'
#!/usr/bin/env bash
# Fake claude: drains stdin, prints a fixed response, exits 0.
cat >/dev/null  # consume prompt
echo "I did the work. DONE"
exit 0
FAKE
chmod +x "$FAKE_BIN/claude"

# Build a fixture scenario .md (mirror real schema)
SCEN_DIR="$SCRATCH/scenarios"
mkdir -p "$SCEN_DIR"
SCEN_FILE="$SCEN_DIR/fix-trivial.md"
cat > "$SCEN_FILE" <<'SCEN'
# Scenario fix — trivial fixture

## Setup
```bash
mkdir -p /tmp/bench-rs-test/fix
echo "untouched" > /tmp/bench-rs-test/fix/marker.txt
```

## Prompt
Make a trivial change. Reply DONE.

## Pass criteria
- File `/tmp/bench-rs-test/fix/marker.txt` exists
- Final model output contains `DONE`

## Cleanup
```bash
rm -rf /tmp/bench-rs-test/fix
```
SCEN

# Each test runs in its own results dir so they don't see each other's files.
mk_results_dir() {
  local d
  d="$(mktemp -d -p "$SCRATCH" results.XXXXXX)"
  echo "$d"
}

# ---- TEST: T-01 (spec dotfiles-ukx.13 §5) — --trials 3 emits 3 result files ----
test_trials_flag_emits_3_results() {
  local results_dir
  results_dir="$(mk_results_dir)"
  PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 3 \
    --results-dir "$results_dir" \
    --quiet \
    > /dev/null 2>&1
  local code=$?
  if [[ $code -ne 0 ]]; then
    fail "T-01: --trials 3 emits 3 result files" "run-scenario.sh exited $code"
    return
  fi
  local count
  count="$(find "$results_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  assert_eq "$count" "3" "T-01: --trials 3 emits 3 result files"
}

# ---- TEST: T-02 (spec dotfiles-ukx.13 §5) — bogus candidate fails fast ----
test_bogus_candidate_fails_fast() {
  PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" "nonexistent-candidate-xyz" \
    > /dev/null 2>&1
  assert_ne_zero "$?" "T-02: bogus candidate exits non-zero"
}

# ---- TEST: T-06 (spec dotfiles-ukx.13 §5) — --timeout kills runaway trial ----
test_timeout_kills_runaway_trial() {
  local results_dir
  results_dir="$(mk_results_dir)"

  # Slow fake claude: sleeps 30s, prints DONE. With --timeout 1, must die.
  local slow_bin="$SCRATCH/slow-bin"
  mkdir -p "$slow_bin"
  cat > "$slow_bin/claude" <<'SLOW'
#!/usr/bin/env bash
cat >/dev/null
sleep 30
echo "DONE"
SLOW
  chmod +x "$slow_bin/claude"

  local t0 t1 elapsed
  t0=$(date +%s)
  PATH="$slow_bin:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 1 \
    --timeout 1 \
    --results-dir "$results_dir" \
    --quiet \
    > /dev/null 2>&1
  local code=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))

  # Should NOT take 30s — timeout must fire well before.
  if [[ $elapsed -lt 25 ]]; then
    pass "T-06: --timeout 1 kills runaway trial within ${elapsed}s"
  else
    fail "T-06: --timeout 1 kills runaway trial" \
      "elapsed=${elapsed}s (≥25s means timeout didn't fire)"
  fi

  # The trial result file should still be emitted and tagged as TIMEOUT.
  local result_file
  result_file="$(find "$results_dir" -maxdepth 1 -name '*.md' | head -1)"
  if [[ -z "$result_file" ]]; then
    fail "T-06: timeout writes a result file" "no result file produced"
    return
  fi
  if grep -qiE 'timeout|killed|exceeded.*cap' "$result_file"; then
    pass "T-06: TIMEOUT verdict appears in result file"
  else
    fail "T-06: TIMEOUT verdict appears in result file" \
      "no TIMEOUT/killed marker; exit code was $code"
  fi
}

# ---- TEST: T-07 (spec dotfiles-ukx.13 §4.1 + OQ-07) — defensive pre-Setup rm -rf ----
test_defensive_rm_before_setup() {
  local results_dir
  results_dir="$(mk_results_dir)"

  # Seed contamination: a stale file in the scenario subdir before run.
  mkdir -p /tmp/bench-rs-test/fix
  echo "STALE_FROM_PRIOR_TRIAL" > /tmp/bench-rs-test/fix/stale.txt

  PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 1 \
    --results-dir "$results_dir" \
    --quiet \
    > /dev/null 2>&1

  # The fixture scenario's Setup writes marker.txt but does NOT write stale.txt.
  # If the defensive rm fired, stale.txt is gone after Setup — i.e., the
  # post-trial sandbox snapshot must NOT contain stale.txt.
  local result_file
  result_file="$(find "$results_dir" -maxdepth 1 -name '*.md' | head -1)"
  if [[ -z "$result_file" ]]; then
    fail "T-07: defensive pre-Setup rm -rf" "no result file produced"
    rm -rf /tmp/bench-rs-test/fix
    return
  fi
  if grep -q "stale.txt" "$result_file"; then
    fail "T-07: defensive pre-Setup rm -rf" \
      "stale.txt survived Setup — pre-Setup rm did NOT fire"
  else
    pass "T-07: defensive pre-Setup rm -rf clears prior trial residue"
  fi
  rm -rf /tmp/bench-rs-test/fix
}

# ---- TEST: T-10 supporting (spec §3.4) — wall_cap_seconds in result schema ----
test_wall_cap_seconds_recorded() {
  local results_dir
  results_dir="$(mk_results_dir)"
  PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 1 \
    --timeout 5 \
    --results-dir "$results_dir" \
    --quiet \
    > /dev/null 2>&1
  local result_file
  result_file="$(find "$results_dir" -maxdepth 1 -name '*.md' | head -1)"
  if [[ -z "$result_file" ]]; then
    fail "T-10: wall_cap_seconds recorded" "no result file produced"
    return
  fi
  if grep -q "wall_cap_seconds" "$result_file"; then
    pass "T-10: wall_cap_seconds field present in result schema"
  else
    fail "T-10: wall_cap_seconds field present in result schema" \
      "field missing from $result_file"
  fi
}

# ---- TEST: --results-dir flag honored ----
test_results_dir_flag_honored() {
  local results_dir
  results_dir="$(mk_results_dir)"
  PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 1 \
    --results-dir "$results_dir" \
    --quiet \
    > /dev/null 2>&1
  local count
  count="$(find "$results_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  if [[ $count -ge 1 ]]; then
    pass "T-01-supporting: --results-dir flag honored (result lands in custom dir)"
  else
    fail "T-01-supporting: --results-dir flag honored" \
      "no .md files in $results_dir"
  fi
}

# ---- TEST: --quiet suppresses live stdout ----
test_quiet_suppresses_stdout() {
  local results_dir stdout_capture
  results_dir="$(mk_results_dir)"
  stdout_capture="$(PATH="$FAKE_BIN:$PATH" "$RUN_SCENARIO" \
    "$SCEN_FILE" opus \
    --trials 1 \
    --results-dir "$results_dir" \
    --quiet \
    2>/dev/null)"
  # With --quiet, stdout should only be the result-file path (single line)
  # or empty — NOT the live "==>" progress chatter.
  local line_count
  line_count="$(echo -n "$stdout_capture" | wc -l | tr -d ' ')"
  if [[ $line_count -le 1 ]]; then
    pass "T-01-supporting: --quiet keeps stdout terse (line count $line_count)"
  else
    fail "T-01-supporting: --quiet keeps stdout terse" \
      "stdout had $line_count lines: $stdout_capture"
  fi
}

# ---- Run all tests ----

# Sanity: the script under test must exist
if [[ ! -x "$RUN_SCENARIO" ]]; then
  fail "PRECHECK: run-scenario.sh exists and is executable" \
    "expected at $RUN_SCENARIO"
else
  pass "PRECHECK: run-scenario.sh exists and is executable"
fi

test_trials_flag_emits_3_results
test_bogus_candidate_fails_fast
test_timeout_kills_runaway_trial
test_defensive_rm_before_setup
test_wall_cap_seconds_recorded
test_results_dir_flag_honored
test_quiet_suppresses_stdout

# ---- Summary ----

echo
echo "================================================================"
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "================================================================"
exit 0
