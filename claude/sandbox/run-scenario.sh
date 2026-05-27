#!/usr/bin/env bash
#
# run-scenario.sh — execute one sandbox scenario against opus or local.
#
# Usage:
#   ./run-scenario.sh <scenario-file> <opus|local> [options]
#
# Options:
#   --trials N           Run the scenario N times (default 1). One result
#                        file is written per trial.
#   --timeout SECONDS    Per-trial wall cap (in SECONDS). If a trial does
#                        not finish in time, it is killed with SIGTERM and
#                        the result file is tagged TIMEOUT. No cap by
#                        default. NOTE: bench-matrix.sh exposes --timeout
#                        in MINUTES and converts to seconds on passthrough.
#   --quiet              Suppress live progress chatter on stderr; only
#                        print the result-file path on stdout per trial.
#   --results-dir DIR    Override the default results dir
#                        (claude/sandbox/results/).
#
# Parses the scenario file (5-section markdown — see scenarios/01-*.md for
# the schema). For each trial: defensive `rm -rf` of any sandbox subdirs
# referenced in Setup (OQ-07 — prevents N-trial cross-contamination), then
# runs Setup → captures `claude -p < prompt` for the chosen backend →
# runs Cleanup → writes a results markdown to results/.
#
# Backends:
#   opus  = the real Anthropic Opus model (uses normal claude CLI)
#   local = pico-mlx,qwen3-coder via CCR + llama-swap (uses ./claude-local)
#
# Spec: dotfiles-ukx.13 §4.1
# Refs:
#   - Sibling: ./claude-local (wrapper that injects CCR routing tag)
#   - Bead: dotfiles-ukx.3 (original), dotfiles-ukx.13.3 (Phase 3 extensions)
#
set -uo pipefail
# NOTE: we deliberately drop -e from `set -euo` so that a single failed
# trial inside the loop doesn't abort subsequent trials.

# --- Arg parsing ---
TRIALS=1
TIMEOUT_SECONDS=""    # empty = no cap
QUIET=0
RESULTS_DIR_OVERRIDE=""

usage() {
  echo "usage: $0 <scenario-file> <opus|local> [--trials N] [--timeout SECONDS] [--quiet] [--results-dir DIR]" >&2
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

SCENARIO_FILE="$1"
MODEL_TAG="$2"
shift 2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trials)
      TRIALS="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --results-dir)
      RESULTS_DIR_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "error: scenario file not found: $SCENARIO_FILE" >&2
  exit 1
fi

if [[ "$MODEL_TAG" != "opus" && "$MODEL_TAG" != "local" ]]; then
  echo "error: model tag must be 'opus' or 'local', got: $MODEL_TAG" >&2
  exit 1
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
  echo "error: --trials must be a positive integer, got: $TRIALS" >&2
  exit 1
fi

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "$RESULTS_DIR_OVERRIDE" ]]; then
  RESULTS_DIR="$RESULTS_DIR_OVERRIDE"
else
  RESULTS_DIR="$SCRIPT_DIR/results"
fi
mkdir -p "$RESULTS_DIR"

SCENARIO_BASENAME="$(basename "$SCENARIO_FILE" .md)"

# Helper: log to stderr unless --quiet
log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$@" >&2
  fi
}

# --- Parse scenario sections ---
# A scenario file has ## Setup / ## Prompt / ## Pass criteria / ## Cleanup
# / ## Notes. Each section runs to the next ## or EOF.
extract_section() {
  local file="$1"
  local section="$2"
  awk -v section="## $section" '
    $0 == section { capture = 1; next }
    /^## / && capture { capture = 0 }
    capture { print }
  ' "$file"
}

# Setup / Cleanup are wrapped in ```bash fences — strip them to get the code.
extract_bash_block() {
  awk '
    /^```bash/ { capture = 1; next }
    /^```/ && capture { capture = 0 }
    capture { print }
  '
}

SETUP_CODE="$(extract_section "$SCENARIO_FILE" "Setup" | extract_bash_block)"
PROMPT_TEXT="$(extract_section "$SCENARIO_FILE" "Prompt")"
CLEANUP_CODE="$(extract_section "$SCENARIO_FILE" "Cleanup" | extract_bash_block)"

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "error: could not extract Prompt section from $SCENARIO_FILE" >&2
  exit 1
fi

# Extract sandbox subdirs from Setup's `mkdir -p ...` lines so we can
# defensively rm -rf them before each trial (OQ-07 — prevents N-trial
# cross-contamination from prior-trial state, even when a previous trial's
# Cleanup crashed or left residue outside SANDBOX_ROOT).
#
# Captures both quoted and unquoted paths from `mkdir -p` invocations.
# Variable references like "$SANDBOX/s01" are expanded by piping through
# `bash -c` with a benign no-op env.
extract_sandbox_dirs() {
  # Find all `mkdir -p <path>` invocations; each path becomes a candidate
  # for the defensive rm. We use a subshell to expand any variables (e.g.
  # ${SANDBOX:-/tmp/claude-local-test}/s01) using the same env the Setup
  # itself would see.
  echo "$SETUP_CODE" \
    | grep -E '^\s*mkdir\s+-p' \
    | sed -E 's/^\s*mkdir\s+-p\s+//' \
    | while IFS= read -r line; do
        # Strip trailing comments
        line="${line%%#*}"
        # Expand variables via bash printf %s (single arg form)
        bash -c "printf '%s\n' $line" 2>/dev/null || true
      done
}

# --- Pick the claude command ---
case "$MODEL_TAG" in
  opus)
    CLAUDE_CMD=(claude --model claude-opus-4-7 -p --permission-mode bypassPermissions)
    ;;
  local)
    CLAUDE_CMD=("$SCRIPT_DIR/claude-local" -p --permission-mode bypassPermissions)
    ;;
esac

# --- Trial loop ---
run_one_trial() {
  local trial_num="$1"
  local is_cold_load="$2"   # "true" or "false"

  local TIMESTAMP RESULT_FILE
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  RESULT_FILE="$RESULTS_DIR/${SCENARIO_BASENAME}-${MODEL_TAG}-trial${trial_num}-${TIMESTAMP}.md"

  # --- Defensive pre-Setup rm -rf (OQ-07) ---
  # Wipe any sandbox subdirs referenced by Setup's mkdir lines before
  # running Setup. This guarantees a clean slate even when prior-trial
  # Cleanup didn't fire (crashed, killed, etc).
  local dirs
  dirs="$(extract_sandbox_dirs)"
  if [[ -n "$dirs" ]]; then
    while IFS= read -r d; do
      # Refuse to nuke root, $HOME, or other suspicious paths.
      [[ -z "$d" ]] && continue
      [[ "$d" == "/" || "$d" == "$HOME" || "$d" == "$HOME/" ]] && continue
      # Only rm under /tmp/ or other safely-disposable parents to avoid
      # catastrophic mistakes. The spec calls for rm of the scenario
      # subdir specifically; we lean conservative.
      case "$d" in
        /tmp/*|/var/tmp/*|/private/tmp/*)
          rm -rf -- "$d" 2>/dev/null || true
          ;;
        *)
          # Outside /tmp — skip to be safe; caller's Setup should ensure
          # a clean baseline themselves for non-tmp sandboxes.
          ;;
      esac
    done <<< "$dirs"
  fi

  # --- Run Setup ---
  log "==> [$SCENARIO_BASENAME / $MODEL_TAG / trial $trial_num] running Setup..."
  if [[ -n "$SETUP_CODE" ]]; then
    bash -c "$SETUP_CODE" || true
  fi

  # --- Run the prompt against the chosen backend ---
  log "==> [$SCENARIO_BASENAME / $MODEL_TAG / trial $trial_num] invoking claude..."
  local START_TS START_ISO END_TS WALL_SECONDS EXIT_CODE CLAUDE_OUTPUT TIMED_OUT
  START_TS="$(date +%s)"
  START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TIMED_OUT=0

  # Wrap in `timeout` if a cap was given. exit code 124 = SIGTERM,
  # 137 = SIGKILL (`timeout --kill-after`); both indicate timeout fire.
  if [[ -n "$TIMEOUT_SECONDS" ]]; then
    # `timeout` (no --preserve-status) returns 124 on wall-cap fire and
    # 137 if it then had to SIGKILL after --kill-after. Either way we
    # tag the trial TIMEOUT and let analyze-bench mark the cell incomplete.
    CLAUDE_OUTPUT="$(printf '%s\n' "$PROMPT_TEXT" \
      | timeout --kill-after=5s "${TIMEOUT_SECONDS}s" \
        "${CLAUDE_CMD[@]}" 2>&1)"
    EXIT_CODE=$?
    # GNU coreutils timeout: 124 on TERM, 137 if KILL escalated.
    # uutils coreutils timeout (Ubuntu 26.04+): emits 125 when --kill-after is set.
    # 143 = 128+SIGTERM, can leak through pipe in some shells.
    if [[ "$EXIT_CODE" -eq 124 || "$EXIT_CODE" -eq 125 || "$EXIT_CODE" -eq 137 || "$EXIT_CODE" -eq 143 ]]; then
      TIMED_OUT=1
    fi
  else
    CLAUDE_OUTPUT="$(printf '%s\n' "$PROMPT_TEXT" | "${CLAUDE_CMD[@]}" 2>&1)"
    EXIT_CODE=$?
  fi

  END_TS="$(date +%s)"
  WALL_SECONDS=$((END_TS - START_TS))

  # --- Extract model identity from output (best-effort) ---
  local MODEL_FIELD
  MODEL_FIELD="(not extracted from -p text output)"
  if [[ "$MODEL_TAG" == "local" ]]; then
    local CCR_LOG=""
    if compgen -G "${HOME}/.claude-code-router/logs/ccr-*.log" > /dev/null; then
      CCR_LOG="$(find "${HOME}/.claude-code-router/logs/" -maxdepth 1 -name 'ccr-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
    elif [[ -f "${HOME}/.claude-code-router/claude-code-router.log" ]]; then
      CCR_LOG="${HOME}/.claude-code-router/claude-code-router.log"
    fi

    if [[ -n "$CCR_LOG" && -f "$CCR_LOG" ]]; then
      local EVIDENCE
      EVIDENCE="$( { tail -500 "$CCR_LOG" 2>/dev/null \
        | grep -iE 'Using.*model|qwen3-coder|pico-mlx|pico-ollama|mlx-community|provider_response_error' \
        | tail -5 \
        | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        obj = json.loads(line)
        msg = obj.get("msg", "").replace("\n", " ").strip()
        if msg:
            print(f"    {msg[:300]}")
    except json.JSONDecodeError:
        print(f"    {line.strip()[:300]}")
' 2>/dev/null; } || true)"
      if [[ -n "$EVIDENCE" ]]; then
        MODEL_FIELD="(CCR log: $CCR_LOG)
$EVIDENCE"
      else
        MODEL_FIELD="(no recent routing entries in $CCR_LOG — check manually)"
      fi
    else
      MODEL_FIELD="(CCR log not found under ${HOME}/.claude-code-router/)"
    fi
  fi

  # --- Capture final sandbox state ---
  local SANDBOX_ROOT SANDBOX_STATE
  SANDBOX_ROOT="${SANDBOX:-/tmp/claude-local-test}"
  SANDBOX_STATE="(no sandbox dir found at $SANDBOX_ROOT)"
  # Also collect from any scenario-specific dirs (test fixture uses
  # /tmp/bench-rs-test/fix; real scenarios use $SANDBOX/s01).
  local extra_dirs=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && extra_dirs="$extra_dirs $d"
  done <<< "$(extract_sandbox_dirs)"

  if [[ -d "$SANDBOX_ROOT" || -n "$extra_dirs" ]]; then
    # shellcheck disable=SC2086  # we want word splitting on extra_dirs
    SANDBOX_STATE="$(find "$SANDBOX_ROOT" $extra_dirs -type f 2>/dev/null | awk 'NR<=20 {print "    "$0}' || true)"
    if [[ -z "$SANDBOX_STATE" ]]; then
      SANDBOX_STATE="    (no files found under sandbox dirs)"
    fi
  fi

  # --- Determine TIMEOUT verdict / scoring tier placeholder ---
  local VERDICT_TAG="OK"
  if [[ "$TIMED_OUT" -eq 1 ]]; then
    VERDICT_TAG="TIMEOUT"
  fi

  # --- Run Cleanup ---
  log "==> [$SCENARIO_BASENAME / $MODEL_TAG / trial $trial_num] running Cleanup..."
  if [[ -n "$CLEANUP_CODE" ]]; then
    bash -c "$CLEANUP_CODE" || true
  fi

  # --- Write result (§3.4 extended schema) ---
  {
    echo "# Scenario result: $SCENARIO_BASENAME ($MODEL_TAG) trial $trial_num"
    echo
    echo "- **Scenario file**: \`$SCENARIO_FILE\`"
    echo "- **Model tag**: \`$MODEL_TAG\`"
    echo "- **Candidate**: \`$MODEL_TAG\`"
    echo "- **Trial**: $trial_num"
    echo "- **Started**: $START_ISO"
    echo "- **Wall time**: ${WALL_SECONDS}s"
    echo "- **wall_cap_seconds**: ${TIMEOUT_SECONDS:-unbounded}"
    echo "- **cold_load_trial**: $is_cold_load"
    echo "- **scoring_tier**: 1"
    echo "- **claude exit code**: $EXIT_CODE"
    echo "- **verdict_tag**: $VERDICT_TAG"
    echo "- **Result file**: \`$RESULT_FILE\`"
    echo
    if [[ "$TIMED_OUT" -eq 1 ]]; then
      echo "> NOTE: trial killed by --timeout (TIMEOUT — exceeded wall cap of ${TIMEOUT_SECONDS}s)."
      echo
    fi
    echo "## Model routing evidence"
    echo
    echo "$MODEL_FIELD"
    echo
    echo "## Sandbox state after run (pre-cleanup snapshot)"
    echo
    echo '```'
    echo "$SANDBOX_STATE"
    echo '```'
    echo
    echo "## Prompt sent"
    echo
    echo '```'
    echo "$PROMPT_TEXT"
    echo '```'
    echo
    echo "## Claude output"
    echo
    echo '```'
    echo "$CLAUDE_OUTPUT"
    echo '```'
    echo
    echo "## flagged_log_excerpt"
    echo
    echo '```'
    # Wave 1: empty placeholder; Wave 4 (Tier 3 escalation) fills this
    # with the last 50 lines of the CCR log on human-flagged trials
    # per OQ-09.
    echo '```'
  } > "$RESULT_FILE"

  log "==> result written: $RESULT_FILE"
  # Always print result file path on stdout (machine-readable handoff to
  # bench-matrix.sh + ad-hoc shell pipelines).
  echo "$RESULT_FILE"
}

# Iterate trials. Trial 1 is cold-load (per OQ-05); trials 2..N are warm.
TRIAL_FAILURES=0
for t in $(seq 1 "$TRIALS"); do
  if [[ "$t" -eq 1 ]]; then
    cold="true"
  else
    cold="false"
  fi
  if ! run_one_trial "$t" "$cold"; then
    TRIAL_FAILURES=$((TRIAL_FAILURES + 1))
  fi
done

# Exit 0 even on per-trial failures — result files document the failure;
# the matrix driver decides whether to abort.
exit 0
