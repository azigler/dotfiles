#!/usr/bin/env bash
#
# test_bench_matrix.sh — bash test harness for bench-matrix.sh driver.
#
# Covers spec dotfiles-ukx.13 test cases:
#   T-03: --candidates qwen3-coder --scenarios 01 emits exactly 1*1*N trial files
#   T-04: --resume skips already-completed (scenario × candidate × trial) tuples
#   T-05: Healthcheck H1 between candidate cohorts; failure aborts
#
# Additional driver-discipline tests:
#   - lightest-first ordering (OQ-04)
#   - --smoke flag (1 scenario × all candidates × N=1)
#   - ollama stop between Ollama candidates (OQ-05)
#
# Spec: dotfiles-ukx.13 §4.2
# Test bead: dotfiles-ukx.13.2
#
# Strategy: stub run-scenario.sh on PATH so bench-matrix.sh dispatches into
# our stub instead of the real runner. The stub logs invocations + emits a
# fake result file so we can verify driver behavior without actually
# touching local models on pico.
#
# Run via: bash tests/test_bench_matrix.sh

set -u

# DOTFILES_ROOT defaults to the worktree this test file lives in
# (tests/ → local-models/ → repo root). See test_run_scenario.sh for
# the Wave 2 dotfiles-ukx.13.4.2 /scrutiny finding #4 context.
DOTFILES_ROOT="${DOTFILES_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BENCH_MATRIX="$DOTFILES_ROOT/local-models/bench-matrix.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
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

# ---- Fixture setup ----

SCRATCH="$(mktemp -d -t bench-matrix-test.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

# Stub run-scenario.sh: logs invocation + writes a deterministic fake result.
STUB_DIR="$SCRATCH/stub-bin"
mkdir -p "$STUB_DIR"
INVOCATIONS_LOG="$SCRATCH/invocations.log"
: > "$INVOCATIONS_LOG"

cat > "$STUB_DIR/run-scenario.sh" <<STUB
#!/usr/bin/env bash
# Stub run-scenario.sh — logs args + writes a fake result file.
# Args expected: <scenario-file> <candidate> [--trials N] [--results-dir DIR] ...
set -u
SCENARIO_FILE="\$1"; shift
CANDIDATE="\$1"; shift

TRIALS=1
RESULTS_DIR="."
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --trials) TRIALS="\$2"; shift 2 ;;
    --results-dir) RESULTS_DIR="\$2"; shift 2 ;;
    --timeout|--quiet) shift ;;
    *) shift ;;
  esac
done

echo "INVOKED scenario=\$(basename "\$SCENARIO_FILE" .md) candidate=\$CANDIDATE trials=\$TRIALS results_dir=\$RESULTS_DIR" >> "$INVOCATIONS_LOG"

mkdir -p "\$RESULTS_DIR"
TS="\$(date -u +%Y%m%dT%H%M%SZ)"
SCEN="\$(basename "\$SCENARIO_FILE" .md)"
for t in \$(seq 1 "\$TRIALS"); do
  OUT="\$RESULTS_DIR/\${SCEN}-\${CANDIDATE}-\${t}-\${TS}.md"
  cat > "\$OUT" <<RESULT
# fake result: \$SCEN / \$CANDIDATE trial \$t
- **Candidate**: \`\$CANDIDATE\`
- **Trial**: \$t
- **Wall time**: 1s
- **wall_cap_seconds**: 60
- **cold_load_trial**: \$([ "\$t" = "1" ] && echo true || echo false)
- **scoring_tier**: 1
- **claude exit code**: 0
## flagged_log_excerpt
\`\`\`
\`\`\`
RESULT
  # Small sleep so timestamps differ (avoids filename collision)
  sleep 0.01 2>/dev/null || true
done
STUB
chmod +x "$STUB_DIR/run-scenario.sh"

# Stub ollama binary so 'ollama stop X' invocations can be observed.
OLLAMA_LOG="$SCRATCH/ollama.log"
: > "$OLLAMA_LOG"
cat > "$STUB_DIR/ollama" <<OLLAMA
#!/usr/bin/env bash
echo "OLLAMA \$*" >> "$OLLAMA_LOG"
exit 0
OLLAMA
chmod +x "$STUB_DIR/ollama"

# Stub healthcheck so we can flip it pass/fail per test.
HC_LOG="$SCRATCH/healthcheck.log"
: > "$HC_LOG"
cat > "$STUB_DIR/healthcheck.sh" <<HC
#!/usr/bin/env bash
echo "HEALTHCHECK called" >> "$HC_LOG"
# Honor a kill-switch env var so tests can flip H1 to fail.
if [[ "\${HEALTHCHECK_FORCE_FAIL:-0}" == "1" ]]; then
  exit 2
fi
exit 0
HC
chmod +x "$STUB_DIR/healthcheck.sh"

# Fixture scenarios (just enough that --scenarios 01 has a target).
SCEN_DIR="$SCRATCH/scenarios"
mkdir -p "$SCEN_DIR"
for n in 01 02; do
  cat > "$SCEN_DIR/${n}-fixture.md" <<S
# Scenario ${n} fixture
## Setup
\`\`\`bash
:
\`\`\`
## Prompt
hi
## Pass criteria
- Final model output contains \`DONE\`
## Cleanup
\`\`\`bash
:
\`\`\`
S
done

mk_results_dir() {
  mktemp -d -p "$SCRATCH" results.XXXXXX
}

# ---- Helper: run bench-matrix with PATH containing our stubs ----
run_bm() {
  PATH="$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$STUB_DIR/run-scenario.sh" \
  HEALTHCHECK_PATH="$STUB_DIR/healthcheck.sh" \
    "$BENCH_MATRIX" "$@"
}

# ---- TEST: T-03 (spec dotfiles-ukx.13 §5) — --candidates filter ----
test_candidate_scenario_filter() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  run_bm \
    --candidates qwen3-coder \
    --scenarios 01 \
    --trials 3 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1
  local code=$?
  if [[ $code -ne 0 ]]; then
    fail "T-03: --candidates qwen3-coder --scenarios 01 succeeds" \
      "bench-matrix.sh exited $code"
    return
  fi
  # 1 candidate × 1 scenario × 3 trials = 3 result files (per the spec
  # phrasing, "exactly 1 result file" really means "1 cell" — the cell
  # has N=3 trial files).
  local count
  count="$(find "$results_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  assert_eq "$count" "3" "T-03: 1 candidate × 1 scenario × 3 trials = 3 result files"

  # And run-scenario.sh should have been invoked exactly ONCE (the inner
  # runner handles --trials internally).
  local inv_count
  inv_count="$(wc -l < "$INVOCATIONS_LOG" | tr -d ' ')"
  assert_eq "$inv_count" "1" \
    "T-03: bench-matrix invokes run-scenario.sh once per (candidate, scenario) cell"
}

# ---- TEST: T-04 (spec dotfiles-ukx.13 §5) — --resume skips completed cells ----
test_resume_skips_completed() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  # First pass: complete the cell.
  run_bm \
    --candidates qwen3-coder \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1

  local first_count
  first_count="$(find "$results_dir" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
  if [[ "$first_count" != "1" ]]; then
    fail "T-04: first pass produces 1 result" "got $first_count"
    return
  fi
  # Snapshot invocation count after first pass.
  local invocations_after_first
  invocations_after_first="$(wc -l < "$INVOCATIONS_LOG" | tr -d ' ')"

  # Second pass with --resume: should SKIP the completed cell.
  run_bm \
    --candidates qwen3-coder \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    --resume \
    > /dev/null 2>&1

  local invocations_after_resume
  invocations_after_resume="$(wc -l < "$INVOCATIONS_LOG" | tr -d ' ')"

  if [[ "$invocations_after_resume" == "$invocations_after_first" ]]; then
    pass "T-04: --resume skips already-completed cell (no new invocations)"
  else
    fail "T-04: --resume skips already-completed cell" \
      "expected $invocations_after_first invocations after resume; got $invocations_after_resume"
  fi
}

# ---- TEST: T-05 (spec dotfiles-ukx.13 §5) — H1 failure aborts the matrix ----
test_healthcheck_failure_aborts() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  HEALTHCHECK_FORCE_FAIL=1 \
  PATH="$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$STUB_DIR/run-scenario.sh" \
  HEALTHCHECK_PATH="$STUB_DIR/healthcheck.sh" \
    "$BENCH_MATRIX" \
    --candidates qwen3-coder \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1
  local code=$?

  if [[ $code -ne 0 ]]; then
    pass "T-05: H1 failure aborts matrix (exit=$code)"
  else
    fail "T-05: H1 failure aborts matrix" "exit code was 0"
  fi
  # And NO run-scenario.sh invocations should have happened (the abort
  # fires before the first cell).
  local inv_count
  inv_count="$(wc -l < "$INVOCATIONS_LOG" | tr -d ' ')"
  if [[ "$inv_count" == "0" ]]; then
    pass "T-05: H1 failure aborts BEFORE any trial dispatches"
  else
    fail "T-05: H1 failure aborts BEFORE any trial dispatches" \
      "$inv_count invocations happened after H1 failure"
  fi
}

# ---- TEST: --smoke runs 1 scenario × all candidates × N=1 (OQ-04 hybrid) ----
test_smoke_pass_shape() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  run_bm \
    --smoke \
    --results-dir "$results_dir" \
    > /dev/null 2>&1
  local code=$?
  if [[ $code -ne 0 ]]; then
    fail "T-03-supporting: --smoke runs successfully" "exit=$code"
    return
  fi

  # Smoke = exactly 1 scenario (01), N=1 trial each. Number of invocations
  # equals number of candidates in the roster.
  local inv_count
  inv_count="$(wc -l < "$INVOCATIONS_LOG" | tr -d ' ')"
  if [[ "$inv_count" -ge 1 ]]; then
    pass "T-03-supporting: --smoke dispatches ≥1 candidate ($inv_count total)"
  else
    fail "T-03-supporting: --smoke dispatches ≥1 candidate" \
      "got $inv_count invocations"
  fi
  # All smoke invocations should be against scenario 01 ONLY.
  if grep -qE 'scenario=01' "$INVOCATIONS_LOG" && \
     ! grep -qE 'scenario=02' "$INVOCATIONS_LOG"; then
    pass "T-03-supporting: --smoke targets scenario 01 only"
  else
    fail "T-03-supporting: --smoke targets scenario 01 only" \
      "$(cat "$INVOCATIONS_LOG")"
  fi
  # And every smoke invocation should be trials=1.
  if ! grep -vE 'trials=1' "$INVOCATIONS_LOG" > /dev/null; then
    pass "T-03-supporting: --smoke uses N=1 trial per candidate"
  else
    fail "T-03-supporting: --smoke uses N=1 trial per candidate" \
      "$(cat "$INVOCATIONS_LOG")"
  fi
}

# ---- TEST: --candidates filter + lightest-first ordering (OQ-04) ----
test_lightest_first_ordering() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  # Specify multiple candidates in REVERSE-of-lightest-first order; the
  # driver should re-sort them so Trinity-Mini fires before GLM/Kimi.
  # We use names known to be in the spec §3.2 roster.
  run_bm \
    --candidates "kimi-linear,trinity-mini,qwen3-coder" \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1

  # Extract candidate-name order from invocation log.
  local first second third
  first="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^candidate=/) {sub(/^candidate=/, "", $i); print $i; exit}}' "$INVOCATIONS_LOG")"
  second="$(awk 'NR==2 {for (i=1;i<=NF;i++) if ($i ~ /^candidate=/) {sub(/^candidate=/, "", $i); print $i; exit}}' "$INVOCATIONS_LOG")"
  third="$(awk 'NR==3 {for (i=1;i<=NF;i++) if ($i ~ /^candidate=/) {sub(/^candidate=/, "", $i); print $i; exit}}' "$INVOCATIONS_LOG")"

  # Trinity-Mini is the lightest (4-bit, smallest); Kimi-Linear is heaviest
  # in the spec's lightest-first list. So order MUST start with trinity and
  # NOT start with kimi.
  if [[ "$first" == "trinity-mini" ]]; then
    pass "T-03-supporting: lightest-first ordering (trinity-mini fires first)"
  else
    fail "T-03-supporting: lightest-first ordering" \
      "expected trinity-mini first; got '$first' then '$second' then '$third'"
  fi
}

# ---- TEST: ollama stop between Ollama candidates (OQ-05) ----
test_ollama_stop_between_candidates() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"
  : > "$OLLAMA_LOG"

  # Two Ollama candidates back-to-back should trigger explicit `ollama stop`
  # of the first before launching the second (per OQ-05 decision).
  run_bm \
    --candidates "qwen3-coder-ollama,deepseek-coder-v2-lite-ollama" \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1

  # Expect at least one `ollama stop` invocation between the candidates.
  if grep -qE 'OLLAMA.*stop' "$OLLAMA_LOG"; then
    pass "T-03-supporting: ollama stop fires between Ollama candidates (OQ-05)"
  else
    fail "T-03-supporting: ollama stop fires between Ollama candidates" \
      "ollama log: $(cat "$OLLAMA_LOG"; echo "(end)")"
  fi
}

# ---- TEST: T-12 (spec dotfiles-ukx.13 §5) — Kimi-Linear smoke probe ----
test_kimi_smoke_gate() {
  # T-12: Kimi-Linear smoke probe MUST pass before Kimi is added as a candidate.
  # We model this by making the stub run-scenario.sh FAIL for kimi-linear,
  # and asserting the smoke pass surfaces a non-zero exit (so the full matrix
  # is gated on smoke-pass actually passing per OQ-06).
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  # Build a kimi-failing stub
  local fail_stub_dir="$SCRATCH/kimi-fail-stub"
  mkdir -p "$fail_stub_dir"
  cat > "$fail_stub_dir/run-scenario.sh" <<KSTUB
#!/usr/bin/env bash
SCENARIO_FILE="\$1"; shift
CANDIDATE="\$1"; shift
RESULTS_DIR="."
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --results-dir) RESULTS_DIR="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$RESULTS_DIR"
echo "INVOKED candidate=\$CANDIDATE" >> "$INVOCATIONS_LOG"
if [[ "\$CANDIDATE" == "kimi-linear" ]]; then
  # Simulate Kimi smoke failure
  exit 1
fi
TS="\$(date -u +%Y%m%dT%H%M%SZ)"
SCEN="\$(basename "\$SCENARIO_FILE" .md)"
echo "ok" > "\$RESULTS_DIR/\${SCEN}-\${CANDIDATE}-1-\${TS}.md"
exit 0
KSTUB
  chmod +x "$fail_stub_dir/run-scenario.sh"

  HEALTHCHECK_FORCE_FAIL=0 \
  PATH="$fail_stub_dir:$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$fail_stub_dir/run-scenario.sh" \
  HEALTHCHECK_PATH="$STUB_DIR/healthcheck.sh" \
    "$BENCH_MATRIX" \
    --smoke \
    --candidates "kimi-linear,qwen3-coder" \
    --results-dir "$results_dir" \
    > "$SCRATCH/smoke-output.log" 2>&1
  local code=$?
  # Either: non-zero exit (strict smoke gate), OR the kimi failure must
  # be surfaced visibly in output (so operator notices before full matrix).
  if [[ $code -ne 0 ]] || grep -qiE 'kimi.*(fail|smoke.*fail|not.*ready)' "$SCRATCH/smoke-output.log"; then
    pass "T-12: Kimi smoke failure surfaces (gate works)"
  else
    fail "T-12: Kimi smoke failure surfaces" \
      "exit=$code; output had no kimi-fail mention: $(cat "$SCRATCH/smoke-output.log")"
  fi
}

# ============================================================================
# Wave 2 (dotfiles-ukx.13.4) — production end-to-end coverage
# Bead: dotfiles-ukx.13.4.1
#
# Adds tests for:
#   T-W2-D-4: bench-matrix.sh --candidates qwen3-coder invokes run-scenario.sh
#             with --candidate qwen3-coder (delegation assertion)
#   T-W2-R-1: --dry-run roster snapshot matches OQ-04 canonical order
#   T-W2-R-2: roster iterates exactly 9 candidates lightest→heaviest (OQ-04)
#   T-W2-H-1: bench-matrix iterating N candidates fires healthcheck N+1 times
#             (1 at start + N between cohorts; OR N if start-of-each semantics)
#   T-W2-H-2: failed inter-cohort H1 aborts the matrix + writes failure marker
#   T-W2-H-3: --skip-healthcheck disables between-cohort H1 (operator escape)
# ============================================================================

# OQ-04 canonical roster order (lightest→heaviest, 9 entries per spec §3.3).
# Names match bench-matrix.sh ROSTER canonical-name field.
OQ04_CANONICAL_ORDER=(
  "trinity-mini"
  "qwen3-coder"
  "qwen3-coder-ollama"
  "devstral"
  "deepseek-coder-v2-lite-ollama"
  "laguna-xs2"
  "deepseek-r1-14b"
  "glm-4.5-air"
  "kimi-linear"
)

# ---- TEST: T-W2-D-4 — bench-matrix dispatches with --candidate <name> flag ----
test_w2_d_4_delegates_with_candidate_flag() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"

  # Replace the stub with one that records the FULL arg vector so we can
  # inspect whether --candidate <name> was passed (vs the legacy positional
  # candidate-as-model-tag form).
  local arg_stub_dir="$SCRATCH/argspy-stub"
  mkdir -p "$arg_stub_dir"
  local argspy_log="$SCRATCH/argspy.log"
  : > "$argspy_log"
  cat > "$arg_stub_dir/run-scenario.sh" <<ARGSPY
#!/usr/bin/env bash
# Argspy stub: record EVERY arg verbatim so the test can assert flag shape.
echo "ARGV: \$*" >> "$argspy_log"
# Find --results-dir to emit a fake result so bench-matrix completes.
RESULTS_DIR="."
SCEN="\$1"; shift
CAND_POSITIONAL="\$1"; shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --results-dir) RESULTS_DIR="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "\$RESULTS_DIR"
TS="\$(date -u +%Y%m%dT%H%M%SZ)"
SCEN_BASE="\$(basename "\$SCEN" .md)"
echo "fake" > "\$RESULTS_DIR/\${SCEN_BASE}-stubbed-1-\${TS}.md"
exit 0
ARGSPY
  chmod +x "$arg_stub_dir/run-scenario.sh"

  PATH="$arg_stub_dir:$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$arg_stub_dir/run-scenario.sh" \
  HEALTHCHECK_PATH="$STUB_DIR/healthcheck.sh" \
    "$BENCH_MATRIX" \
    --candidates qwen3-coder \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1

  # The recorded ARGV must contain `--candidate qwen3-coder` (the Wave 2
  # dispatch form). Accept either order: anywhere in the recorded line.
  if grep -qE '(^|[[:space:]])--candidate[[:space:]]+qwen3-coder([[:space:]]|$)' "$argspy_log"; then
    pass "T-W2-D-4: bench-matrix invokes run-scenario.sh with --candidate qwen3-coder"
  else
    fail "T-W2-D-4: bench-matrix invokes run-scenario.sh with --candidate qwen3-coder" \
      "recorded argv had no --candidate flag: $(cat "$argspy_log")"
  fi
}

# ---- TEST: T-W2-R-1 — --dry-run roster matches OQ-04 canonical order ----
test_w2_r_1_dry_run_roster_matches_oq04() {
  local results_dir output_capture
  results_dir="$(mk_results_dir)"
  output_capture="$(run_bm \
    --dry-run \
    --results-dir "$results_dir" \
    2>&1)"

  # Extract the candidate-name list from the "candidates:" line in plan summary.
  # bench-matrix prints e.g. "    candidates: trinity-mini qwen3-coder ..."
  local cand_line
  cand_line="$(echo "$output_capture" | grep -E '^[[:space:]]*candidates:' | head -1)"
  if [[ -z "$cand_line" ]]; then
    fail "T-W2-R-1: --dry-run emits a 'candidates:' line in the plan" \
      "no candidates: line in output: $output_capture"
    return
  fi

  # Strip prefix "    candidates: " to get the ordered list.
  local ordered
  ordered="$(echo "$cand_line" | sed -E 's/^[[:space:]]*candidates:[[:space:]]*//')"

  # The first candidate MUST be trinity-mini (lightest); the last must be
  # kimi-linear (heaviest per OQ-04). Both invariants together pin the order.
  local first last
  first="$(echo "$ordered" | awk '{print $1}')"
  last="$(echo "$ordered" | awk '{print $NF}')"
  if [[ "$first" == "trinity-mini" ]]; then
    pass "T-W2-R-1: roster lightest-first (trinity-mini is first per OQ-04)"
  else
    fail "T-W2-R-1: roster lightest-first" \
      "expected first=trinity-mini; got '$first'. Full ordered: $ordered"
  fi
  if [[ "$last" == "kimi-linear" ]]; then
    pass "T-W2-R-1: roster heaviest-last (kimi-linear is last per OQ-04)"
  else
    fail "T-W2-R-1: roster heaviest-last" \
      "expected last=kimi-linear; got '$last'. Full ordered: $ordered"
  fi
}

# ---- TEST: T-W2-R-2 — roster iterates exactly 9 candidates in OQ-04 order ----
test_w2_r_2_roster_full_count_and_order() {
  local results_dir output_capture
  results_dir="$(mk_results_dir)"
  output_capture="$(run_bm \
    --dry-run \
    --results-dir "$results_dir" \
    2>&1)"

  local cand_line ordered
  cand_line="$(echo "$output_capture" | grep -E '^[[:space:]]*candidates:' | head -1)"
  ordered="$(echo "$cand_line" | sed -E 's/^[[:space:]]*candidates:[[:space:]]*//')"

  # Exactly 9 candidates per OQ-04 (Trinity, Qwen3 MLX, Qwen3 Ollama,
  # Devstral, DeepSeek-V2, Laguna, DeepSeek-R1, GLM, Kimi).
  local count
  count="$(echo "$ordered" | tr -s ' ' '\n' | grep -c '^[a-z]' || true)"
  if [[ "$count" -eq 9 ]]; then
    pass "T-W2-R-2: roster has exactly 9 candidates per OQ-04 (got $count)"
  else
    fail "T-W2-R-2: roster has exactly 9 candidates per OQ-04" \
      "got $count: $ordered"
  fi

  # Pairwise ordering: assert deepseek-r1-14b appears AFTER laguna-xs2
  # (which is the OQ-04-specific reorder relative to Wave 1's roster).
  # The Wave 1 ROSTER places kimi-linear before glm-4.5-air, which is
  # backwards per OQ-04 ("Kimi last"). Assert glm appears BEFORE kimi.
  local glm_pos kimi_pos laguna_pos r1_pos
  glm_pos="$(echo "$ordered" | tr ' ' '\n' | grep -n '^glm-4.5-air$' | head -1 | cut -d: -f1)"
  kimi_pos="$(echo "$ordered" | tr ' ' '\n' | grep -n '^kimi-linear$' | head -1 | cut -d: -f1)"
  laguna_pos="$(echo "$ordered" | tr ' ' '\n' | grep -n '^laguna-xs2$' | head -1 | cut -d: -f1)"
  r1_pos="$(echo "$ordered" | tr ' ' '\n' | grep -n '^deepseek-r1-14b$' | head -1 | cut -d: -f1)"

  if [[ -n "$glm_pos" && -n "$kimi_pos" && "$glm_pos" -lt "$kimi_pos" ]]; then
    pass "T-W2-R-2: OQ-04 order — glm-4.5-air ($glm_pos) precedes kimi-linear ($kimi_pos)"
  else
    fail "T-W2-R-2: OQ-04 order — glm-4.5-air precedes kimi-linear" \
      "glm_pos=$glm_pos kimi_pos=$kimi_pos ordered=$ordered"
  fi
  if [[ -n "$laguna_pos" && -n "$r1_pos" && "$laguna_pos" -lt "$r1_pos" ]]; then
    pass "T-W2-R-2: OQ-04 order — laguna-xs2 ($laguna_pos) precedes deepseek-r1-14b ($r1_pos)"
  else
    fail "T-W2-R-2: OQ-04 order — laguna-xs2 precedes deepseek-r1-14b" \
      "laguna_pos=$laguna_pos r1_pos=$r1_pos ordered=$ordered"
  fi
}

# ---- TEST: T-W2-H-1 — healthcheck fires between candidate cohorts ----
test_w2_h_1_healthcheck_between_cohorts() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"
  : > "$HC_LOG"

  # Iterate 3 candidates; expect healthcheck.sh to fire AT LEAST 3 times
  # (one between each pair / once per cohort), and AT MOST 4 (start-of-run +
  # between-cohort). Either start-of-each-cohort (3 fires) or
  # start-of-run + between (4 fires) is acceptable; <3 means no between-cohort
  # H1 happens.
  run_bm \
    --candidates "trinity-mini,qwen3-coder,qwen3-coder-ollama" \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > /dev/null 2>&1

  local hc_count
  hc_count="$(wc -l < "$HC_LOG" | tr -d ' ')"
  # 3 candidates → 3 cohorts → expect 3 or 4 H1 invocations.
  if [[ "$hc_count" -ge 3 && "$hc_count" -le 4 ]]; then
    pass "T-W2-H-1: H1 fires between candidate cohorts (got $hc_count fires for 3 candidates)"
  else
    fail "T-W2-H-1: H1 fires between candidate cohorts" \
      "expected 3 or 4 fires for 3 candidates; got $hc_count. HC log: $(cat "$HC_LOG")"
  fi
}

# ---- TEST: T-W2-H-2 — H1 mid-matrix failure aborts + writes failure marker ----
test_w2_h_2_intercohort_h1_failure_aborts() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"
  : > "$HC_LOG"

  # Build a healthcheck stub that PASSES on first call (start of run) and
  # FAILS on subsequent calls (between-cohort). This simulates pico state
  # drift mid-matrix — bench-matrix MUST abort, not continue silently.
  local hc_state_file="$SCRATCH/hc-call-count"
  echo "0" > "$hc_state_file"
  local flaky_stub_dir="$SCRATCH/flaky-hc-stub"
  mkdir -p "$flaky_stub_dir"
  cat > "$flaky_stub_dir/healthcheck.sh" <<FLAKY
#!/usr/bin/env bash
N=\$(cat "$hc_state_file")
N=\$((N + 1))
echo "\$N" > "$hc_state_file"
echo "HC call \$N" >> "$HC_LOG"
# First call (start-of-run) passes; subsequent calls fail.
if [[ "\$N" -eq 1 ]]; then
  exit 0
fi
exit 2
FLAKY
  chmod +x "$flaky_stub_dir/healthcheck.sh"

  # Two candidates so there's at least one between-cohort transition.
  PATH="$flaky_stub_dir:$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$STUB_DIR/run-scenario.sh" \
  HEALTHCHECK_PATH="$flaky_stub_dir/healthcheck.sh" \
    "$BENCH_MATRIX" \
    --candidates "trinity-mini,qwen3-coder" \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > "$SCRATCH/h2-output.log" 2>&1
  local code=$?

  # Abort = either non-zero exit OR a clearly-labelled failure marker in
  # output. The matrix MUST NOT silently continue.
  local combined
  combined="$(cat "$SCRATCH/h2-output.log")"
  if [[ $code -ne 0 ]] || echo "$combined" | grep -qiE "(healthcheck.*fail|H1.*fail|aborting|abort.*matrix)"; then
    pass "T-W2-H-2: between-cohort H1 failure aborts matrix (exit=$code)"
  else
    fail "T-W2-H-2: between-cohort H1 failure aborts matrix" \
      "exit=$code and no failure marker in output: $combined"
  fi

  # The second candidate should NOT have completed any cells — verify by
  # counting result .md files for qwen3-coder.
  local qwen_results
  qwen_results="$(find "$results_dir" -maxdepth 1 -name '*qwen3-coder*' | wc -l | tr -d ' ')"
  # 0 = aborted before qwen ran; >0 = silently continued (BAD)
  if [[ "$qwen_results" -eq 0 ]]; then
    pass "T-W2-H-2: aborted matrix did NOT run qwen3-coder cohort after H1 failure"
  else
    fail "T-W2-H-2: aborted matrix did NOT run qwen3-coder cohort" \
      "$qwen_results qwen result files exist — matrix continued past H1 failure"
  fi
}

# ---- TEST: T-W2-H-3 — --skip-healthcheck disables between-cohort H1 ----
test_w2_h_3_skip_healthcheck_flag() {
  local results_dir
  results_dir="$(mk_results_dir)"
  : > "$INVOCATIONS_LOG"
  : > "$HC_LOG"

  # With --skip-healthcheck and a healthcheck that would FAIL if called,
  # the matrix should still complete successfully (operator's escape hatch
  # when pico state is known-good).
  HEALTHCHECK_FORCE_FAIL=1 \
  PATH="$STUB_DIR:$PATH" \
  SCENARIOS_DIR="$SCEN_DIR" \
  RUN_SCENARIO_PATH="$STUB_DIR/run-scenario.sh" \
  HEALTHCHECK_PATH="$STUB_DIR/healthcheck.sh" \
    "$BENCH_MATRIX" \
    --skip-healthcheck \
    --candidates "trinity-mini,qwen3-coder" \
    --scenarios 01 \
    --trials 1 \
    --results-dir "$results_dir" \
    > "$SCRATCH/h3-output.log" 2>&1
  local code=$?

  # Acceptable: exit 0 (matrix ran past would-fail H1 thanks to --skip-healthcheck).
  if [[ $code -eq 0 ]]; then
    pass "T-W2-H-3: --skip-healthcheck bypasses H1 (matrix completes despite would-fail HC)"
  else
    fail "T-W2-H-3: --skip-healthcheck bypasses H1" \
      "exit=$code; output: $(cat "$SCRATCH/h3-output.log")"
  fi
  # And the healthcheck script should NOT have been called at all.
  local hc_count
  hc_count="$(wc -l < "$HC_LOG" | tr -d ' ')"
  if [[ "$hc_count" -eq 0 ]]; then
    pass "T-W2-H-3: --skip-healthcheck prevents ANY HC invocation (count=0)"
  else
    fail "T-W2-H-3: --skip-healthcheck prevents ANY HC invocation" \
      "HC called $hc_count times despite --skip-healthcheck"
  fi
}

# ---- Run all tests ----

if [[ ! -x "$BENCH_MATRIX" ]]; then
  fail "PRECHECK: bench-matrix.sh exists and is executable" \
    "expected at $BENCH_MATRIX (Wave 1 impl will create it)"
else
  pass "PRECHECK: bench-matrix.sh exists and is executable"
fi

test_candidate_scenario_filter
test_resume_skips_completed
test_healthcheck_failure_aborts
test_smoke_pass_shape
test_lightest_first_ordering
test_ollama_stop_between_candidates
test_kimi_smoke_gate

# Wave 2 (dotfiles-ukx.13.4.1)
test_w2_d_4_delegates_with_candidate_flag
test_w2_r_1_dry_run_roster_matches_oq04
test_w2_r_2_roster_full_count_and_order
test_w2_h_1_healthcheck_between_cohorts
test_w2_h_2_intercohort_h1_failure_aborts
test_w2_h_3_skip_healthcheck_flag

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
