#!/usr/bin/env bash
#
# bench-matrix.sh — driver for the Phase 3 parity benchmark matrix.
#
# Orchestrates (scenario × candidate × trial) cells per spec
# dotfiles-ukx.13 §4.2. Sequential per memory-hygiene G3 — never two
# backends loaded at once. Lightest-first candidate ordering (OQ-04).
# Explicit `ollama stop <model>` between Ollama candidates (OQ-05).
# Healthcheck H1 before each candidate cohort (Wave 2: enforced + abort
# on failure between cohorts). Per-cell call into run-scenario.sh which
# handles per-trial wall caps + result-file emission.
#
# Usage:
#   ./bench-matrix.sh                           # full matrix
#   ./bench-matrix.sh --smoke                   # scenario 01 × all × N=1
#   ./bench-matrix.sh --candidates qwen3-coder,trinity-mini
#   ./bench-matrix.sh --scenarios 01,03,06
#   ./bench-matrix.sh --trials 3
#   ./bench-matrix.sh --timeout 45              # MINUTES per trial wall cap
#   ./bench-matrix.sh --resume                  # skip completed cells
#   ./bench-matrix.sh --state-file /path/to/state.json
#   ./bench-matrix.sh --dry-run                 # print plan, don't dispatch
#   ./bench-matrix.sh --results-dir DIR         # override default results dir
#   ./bench-matrix.sh --skip-healthcheck        # bypass H1 (operator escape)
#
# Env vars (mostly for testing):
#   RUN_SCENARIO_PATH   override path to run-scenario.sh (default: sibling)
#   HEALTHCHECK_PATH    override path to healthcheck.sh   (default: sibling)
#   SCENARIOS_DIR       override scenarios dir            (default: ../claude/sandbox/scenarios)
#
# Spec: dotfiles-ukx.13 §4.2
# Bead: dotfiles-ukx.13.3 (Wave 1), dotfiles-ukx.13.4.2 (Wave 2)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the verify-the-negation harness (MEMORY: feedback-silent-success-pattern #1).
# Provides safe_pkill_remote / safe_pgrep_remote that confirm absence after kill.
# shellcheck source=/home/ubuntu/dotfiles/local-models/lib/safe_remote.sh
source "$SCRIPT_DIR/lib/safe_remote.sh"

# Source the pico exclusive-access lock convention (MEMORY: feedback-silent-success-pattern #3).
# Provides pico_acquire / pico_release / pico_check. Bench-matrix takes the
# lock on entry and releases on exit so concurrent pico consumers (autonovel,
# LSRA, dev claude calls routed local) cannot silently contaminate results.
# shellcheck source=/home/ubuntu/dotfiles/local-models/lib/pico_lock.sh
source "$SCRIPT_DIR/lib/pico_lock.sh"
PICO_LOCK_OWNER="bench-matrix"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Defaults ---
RUN_SCENARIO_PATH="${RUN_SCENARIO_PATH:-$DOTFILES_ROOT/claude/sandbox/run-scenario.sh}"
HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-$SCRIPT_DIR/healthcheck.sh}"
SCENARIOS_DIR="${SCENARIOS_DIR:-$DOTFILES_ROOT/claude/sandbox/scenarios}"
RESULTS_DIR="$DOTFILES_ROOT/claude/sandbox/results"
STATE_FILE="/tmp/bench-matrix-state.json"
TRIALS=3
TIMEOUT_MIN=45     # global default per OQ-02
SMOKE=0
RESUME=0
DRY_RUN=0
SKIP_HEALTHCHECK=0
CANDIDATES_CSV=""
SCENARIOS_CSV=""

# --- OQ-04 canonical roster (lightest → heaviest, 9 entries) ---
# Order is load-order — trinity (smallest, fastest) first; kimi-linear
# (heaviest) last per OQ-04 RESOLVED. Each entry has a backend tag so we
# can decide whether to `ollama stop` between cohorts.
#
# Format: "<canonical-name>:<backend>:<ollama-model-tag-or-blank>"
#
# Order MUST match OQ-04 RESOLVED:
#   1. Trinity-Mini (MLX)
#   2. Qwen3-Coder MLX
#   3. Qwen3-Coder Ollama
#   4. Devstral (MLX, PARTIAL per G18)
#   5. DeepSeek-Coder-V2-Lite Ollama (G15: MLX blocked)
#   6. Laguna XS.2 Ollama (G7: MLX needs fork)
#   7. DeepSeek-R1:14b Ollama
#   8. GLM-4.5-Air 3-bit MLX
#   9. Kimi-Linear-REAP-35B last (heaviest)
#
# NOTE: the SHORT names below (`laguna-xs2`, `glm-4.5-air`, `kimi-linear`)
# are the BENCH-MATRIX-LAYER identifiers — chosen to be backend-bucket
# variants in the OQ-04 reconciliation. The spec's 8-roster CANONICAL
# names (`laguna-xs.2`, `glm-4.5-air-3bit`, `kimi-linear-reap-35b`)
# resolve to these via ALIAS_MAP below. Same model, two naming layers:
# bench-matrix iterates the 9-row OQ-04 reconciliation, run-scenario.sh
# exposes the 8-roster canonical names — ALIAS_MAP bridges the two.
ROSTER=(
  "trinity-mini:mlx:"
  "qwen3-coder:mlx:"
  "qwen3-coder-ollama:ollama:qwen3-coder:30b"
  "devstral:mlx:"
  "deepseek-coder-v2-lite-ollama:ollama:deepseek-coder-v2:16b"
  "laguna-xs2:ollama:laguna-xs.2:latest"
  "deepseek-r1-14b:ollama:deepseek-r1:14b"
  "glm-4.5-air:mlx:"
  "kimi-linear:mlx:"
)

# --- Baseline (out-of-roster but accepted via --candidates) ---
# `opus` is the Anthropic Opus baseline — NOT iterated in the default
# matrix loop (the default roster is the 9 local candidates), but accepted
# as a --candidates value so operators can dispatch the baseline through
# bench-matrix uniformly. run-scenario.sh handles routing.
BASELINE_DISPATCH=(
  "opus:opus:"
)

# --- Alias map: spec-canonical → bench-matrix-roster names ---
# /scrutiny finding #1: bench-matrix.sh --candidates <name> was rejecting
# 5/9 spec-canonical names. We resolve them via this alias map BEFORE
# looking them up in ROSTER. Identity aliases are included for clarity
# (so a single lookup path covers all valid inputs).
#
# Format: "<input-name>=<roster-name>"
ALIAS_MAP=(
  # Identity (no-op aliases for direct roster names — keeps lookup uniform)
  "trinity-mini=trinity-mini"
  "qwen3-coder=qwen3-coder"
  "qwen3-coder-ollama=qwen3-coder-ollama"
  "devstral=devstral"
  "deepseek-coder-v2-lite-ollama=deepseek-coder-v2-lite-ollama"
  "laguna-xs2=laguna-xs2"
  "deepseek-r1-14b=deepseek-r1-14b"
  "glm-4.5-air=glm-4.5-air"
  "kimi-linear=kimi-linear"
  # Baseline
  "opus=opus"
  # Spec-canonical → bench-matrix-layer (per scrutiny #1)
  "deepseek-coder-v2-lite=deepseek-coder-v2-lite-ollama"
  "laguna-xs.2=laguna-xs2"
  "glm-4.5-air-3bit=glm-4.5-air"
  "kimi-linear-reap-35b=kimi-linear"
)

# resolve_alias <input-name> → echoes roster name; returns 0 on hit, 1 on miss
resolve_alias() {
  local name="$1" entry
  for entry in "${ALIAS_MAP[@]}"; do
    if [[ "${entry%%=*}" == "$name" ]]; then
      echo "${entry#*=}"
      return 0
    fi
  done
  return 1
}

# --- Arg parsing ---
usage() {
  cat >&2 <<USAGE
usage: $0 [options]

Options:
  --candidates CSV        comma-separated candidate names from the roster
                          (default: all candidates lightest-first)
  --scenarios CSV         comma-separated scenario prefixes (e.g., "01,03")
                          or full names (e.g., "01-trivial-rename")
                          (default: all 10 scenarios)
  --trials N              trials per cell (default: 3; --smoke forces 1)
  --timeout MIN           per-trial wall cap in MINUTES (default: 45)
  --smoke                 1 scenario (01) × all candidates × N=1
                          (catches GLM OOM / Kimi smoke-fail cheaply)
  --resume                skip cells that already have result files
  --state-file PATH       override state file path
                          (default: /tmp/bench-matrix-state.json)
  --dry-run               print plan; do not dispatch run-scenario.sh
  --results-dir DIR       override results dir
  --skip-healthcheck      bypass H1 entirely (operator escape hatch for
                          when pico state is known-good despite a flaky
                          healthcheck — use sparingly)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidates)        CANDIDATES_CSV="$2"; shift 2 ;;
    --scenarios)         SCENARIOS_CSV="$2"; shift 2 ;;
    --trials)            TRIALS="$2"; shift 2 ;;
    --timeout)           TIMEOUT_MIN="$2"; shift 2 ;;
    --smoke)             SMOKE=1; shift ;;
    --resume)            RESUME=1; shift ;;
    --state-file)        STATE_FILE="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
    --skip-healthcheck)  SKIP_HEALTHCHECK=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$RESULTS_DIR"

# --- Helper: lookup a candidate's metadata from ROSTER (or BASELINE_DISPATCH) ---
# Accepts the roster name directly; for spec-canonical aliases, call
# resolve_alias first.
candidate_meta() {
  local name="$1" entry
  for entry in "${ROSTER[@]}"; do
    if [[ "${entry%%:*}" == "$name" ]]; then
      echo "$entry"
      return 0
    fi
  done
  for entry in "${BASELINE_DISPATCH[@]}"; do
    if [[ "${entry%%:*}" == "$name" ]]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

# --- Helper: backend tag for a candidate ---
candidate_backend() {
  local entry
  entry="$(candidate_meta "$1")" || return 1
  # entry format: name:backend:tag
  echo "$entry" | cut -d: -f2
}

# --- Helper: ollama model tag for a candidate (empty if not ollama) ---
candidate_ollama_tag() {
  local entry
  entry="$(candidate_meta "$1")" || return 1
  # everything after the second colon is the ollama tag (may contain :)
  echo "$entry" | cut -d: -f3-
}

# --- Helper: print known-candidate roster (used in error msgs) ---
print_roster_help() {
  echo "       known candidates (OQ-04 canonical order, lightest-first):" >&2
  local entry
  for entry in "${ROSTER[@]}"; do
    echo "         - ${entry%%:*}" >&2
  done
  echo "       baseline:" >&2
  for entry in "${BASELINE_DISPATCH[@]}"; do
    echo "         - ${entry%%:*}" >&2
  done
  echo "       accepted spec-canonical aliases:" >&2
  echo "         - deepseek-coder-v2-lite (-> deepseek-coder-v2-lite-ollama)" >&2
  echo "         - laguna-xs.2            (-> laguna-xs2)" >&2
  echo "         - glm-4.5-air-3bit       (-> glm-4.5-air)" >&2
  echo "         - kimi-linear-reap-35b   (-> kimi-linear)" >&2
}

# --- Build the candidate list (lightest-first re-sort if user provided CSV) ---
selected_candidates=()
if [[ -z "$CANDIDATES_CSV" ]]; then
  # Default: iterate the OQ-04 roster (9 local candidates, lightest-first).
  # NOTE: opus baseline is NOT in the default iteration — it's only dispatched
  # when the operator explicitly names it via --candidates.
  for entry in "${ROSTER[@]}"; do
    selected_candidates+=("${entry%%:*}")
  done
else
  # Split CSV, alias-resolve each name, then re-sort by ROSTER order
  # (lightest-first). opus is appended to the END since it's not in
  # ROSTER — preserves the lightest-first invariant for local candidates
  # while still allowing the baseline through.
  IFS=',' read -ra user_cands <<< "$CANDIDATES_CSV"
  resolved_cands=()
  for c in "${user_cands[@]}"; do
    if rosname="$(resolve_alias "$c")"; then
      # Validate the resolved name exists (catch alias map → ROSTER drift).
      if ! candidate_meta "$rosname" >/dev/null; then
        echo "error: alias '$c' resolves to '$rosname' but no such entry in ROSTER/BASELINE — bench-matrix.sh config bug" >&2
        exit 1
      fi
      resolved_cands+=("$rosname")
    else
      echo "error: unknown candidate: $c" >&2
      print_roster_help
      exit 1
    fi
  done
  # Reorder per ROSTER, preserving lightest-first (local candidates).
  for entry in "${ROSTER[@]}"; do
    name="${entry%%:*}"
    for c in "${resolved_cands[@]}"; do
      if [[ "$c" == "$name" ]]; then
        selected_candidates+=("$name")
        break
      fi
    done
  done
  # Append baseline (opus) at the end if requested (NOT in ROSTER iteration).
  for entry in "${BASELINE_DISPATCH[@]}"; do
    bname="${entry%%:*}"
    for c in "${resolved_cands[@]}"; do
      if [[ "$c" == "$bname" ]]; then
        selected_candidates+=("$bname")
        break
      fi
    done
  done
fi

# --- Build the scenario list ---
selected_scenarios=()
if [[ ! -d "$SCENARIOS_DIR" ]]; then
  echo "error: scenarios dir not found: $SCENARIOS_DIR" >&2
  exit 1
fi

# Collect all scenario files (sorted).
all_scenarios=()
while IFS= read -r f; do
  [[ -n "$f" ]] && all_scenarios+=("$f")
done < <(find "$SCENARIOS_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

if [[ "$SMOKE" -eq 1 ]]; then
  # --smoke = scenario 01 only, N=1 trial per candidate.
  for f in "${all_scenarios[@]}"; do
    base="$(basename "$f" .md)"
    if [[ "$base" == 01* ]]; then
      selected_scenarios+=("$f")
      break
    fi
  done
  TRIALS=1
elif [[ -z "$SCENARIOS_CSV" ]]; then
  selected_scenarios=("${all_scenarios[@]}")
else
  IFS=',' read -ra user_scens <<< "$SCENARIOS_CSV"
  for s in "${user_scens[@]}"; do
    # Match scenario by full name OR by prefix (e.g., "01" matches "01-trivial-rename")
    matched=""
    for f in "${all_scenarios[@]}"; do
      base="$(basename "$f" .md)"
      if [[ "$base" == "$s" || "$base" == "$s"-* || "$base" == "$s".* ]]; then
        matched="$f"
        break
      fi
    done
    if [[ -z "$matched" ]]; then
      echo "error: scenario not found in $SCENARIOS_DIR: $s" >&2
      exit 1
    fi
    selected_scenarios+=("$matched")
  done
fi

if [[ "${#selected_scenarios[@]}" -eq 0 ]]; then
  echo "error: no scenarios selected (smoke needs scenario 01; check $SCENARIOS_DIR)" >&2
  exit 1
fi

# --- Load resume state if requested ---
# State file format (JSON):
#   {"completed": ["scenario|candidate|trial", ...]}
# We rebuild from results-dir if state file is corrupted/missing.
completed_cells=()  # array of "scenario|candidate" strings

cells_from_state_file() {
  # Returns 0 if state was loaded cleanly, non-zero otherwise.
  local f="$1"
  [[ -f "$f" ]] || return 1
  # Validate JSON; on parse failure, signal caller to rebuild.
  if ! python3 -c "
import json, sys
try:
    with open('$f') as fh:
        data = json.load(fh)
    for c in data.get('completed', []):
        print(c)
except Exception:
    sys.exit(2)
" 2>/dev/null; then
    return 2
  fi
}

rebuild_state_from_results_dir() {
  # Scan results-dir for *.md result files and infer completed cells.
  # File naming convention from run-scenario.sh:
  #   <scenario>-<candidate>-trial<N>-<TS>.md
  # OR from the test stub:
  #   <scenario>-<candidate>-<N>-<TS>.md
  # Either way, the scenario+candidate prefix is what we want.
  local f base scen cand
  for f in "$RESULTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    # Try to extract scenario and candidate. We know all scenarios start
    # with NN- (NN being two digits). Strip the trailing timestamp + trial.
    # Pattern: <scen>-<cand>-(trial)?<N>-<TS>
    # Simpler: take scenario by matching against known scenario names.
    scen=""
    for s in "${selected_scenarios[@]}"; do
      sbase="$(basename "$s" .md)"
      if [[ "$base" == "$sbase"-* ]]; then
        scen="$sbase"
        break
      fi
    done
    [[ -z "$scen" ]] && continue
    # Strip "<scen>-" prefix
    rest="${base#${scen}-}"
    # Strip the timestamp suffix (e.g., -20260527T120000Z)
    rest="$(echo "$rest" | sed -E 's/-[0-9]{8}T[0-9]{6}Z$//')"
    # Strip the trial number (e.g., -trial1 or -1)
    rest="$(echo "$rest" | sed -E 's/-(trial)?[0-9]+$//')"
    cand="$rest"
    [[ -z "$cand" ]] && continue
    completed_cells+=("${scen}|${cand}")
  done
}

if [[ "$RESUME" -eq 1 ]]; then
  state_loaded=0
  if [[ -f "$STATE_FILE" ]]; then
    state_output="$(cells_from_state_file "$STATE_FILE" 2>/dev/null)"
    state_rc=$?
    if [[ "$state_rc" -eq 0 ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && completed_cells+=("$line")
      done <<< "$state_output"
      state_loaded=1
    else
      echo "warning: state file $STATE_FILE is corrupted/invalid — rebuilding from results-dir" >&2
    fi
  fi
  if [[ "$state_loaded" -eq 0 ]]; then
    rebuild_state_from_results_dir
  fi
fi

cell_is_completed() {
  local key="$1"
  for done_cell in "${completed_cells[@]:-}"; do
    [[ "$done_cell" == "$key" ]] && return 0
  done
  return 1
}

# --- Plan summary (dry-run + always-on header) ---
echo "==> bench-matrix plan:"
echo "    candidates: ${selected_candidates[*]}"
echo "    scenarios:  $(printf '%s ' "${selected_scenarios[@]##*/}" | sed 's/\.md//g')"
echo "    trials:     $TRIALS"
echo "    timeout:    ${TIMEOUT_MIN}m per trial"
echo "    smoke:      $SMOKE"
echo "    resume:     $RESUME"
echo "    dry-run:    $DRY_RUN"
echo "    results:    $RESULTS_DIR"
echo "    skip-hc:    $SKIP_HEALTHCHECK"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> DRY RUN — planning only, no dispatches"
  for cand in "${selected_candidates[@]}"; do
    for scen_path in "${selected_scenarios[@]}"; do
      scen_base="$(basename "$scen_path" .md)"
      key="${scen_base}|${cand}"
      if [[ "$RESUME" -eq 1 ]] && cell_is_completed "$key"; then
        echo "    SKIP  $scen_base × $cand (already completed)"
      else
        echo "    PLAN  $scen_base × $cand × $TRIALS trials"
      fi
    done
  done
  exit 0
fi

# --- Pico exclusive-access lock (MEMORY: feedback-silent-success-pattern #3) ---
# Estimate upper-bound duration: candidates × scenarios × trials × per-trial cap.
# This is generous (real avg is ~3 min/trial); the lock auto-expires so a
# crashed matrix doesn't block pico forever.
PICO_LOCK_DURATION=$(( ${#selected_candidates[@]} * ${#selected_scenarios[@]} * TRIALS * TIMEOUT_MIN * 60 ))
echo "==> acquiring pico exclusive-access lock (duration ${PICO_LOCK_DURATION}s upper bound)..."
if ! pico_acquire "$PICO_LOCK_OWNER" "$PICO_LOCK_DURATION" \
    "Phase 3 bench matrix: ${#selected_candidates[@]} candidates × ${#selected_scenarios[@]} scenarios × $TRIALS trials"; then
  echo "ABORT: another consumer holds the pico lock. Either wait for them or `bash $SCRIPT_DIR/lib/pico_lock.sh check`." >&2
  exit 4
fi
# Release on ANY exit (normal completion, error, SIGINT, etc.)
trap 'pico_release "$PICO_LOCK_OWNER" 2>/dev/null || true' EXIT

# --- Healthcheck helper (Wave 2: invoked at start AND between cohorts) ---
# Args: <phase-label> (e.g., "start-of-run" or "before $cand cohort").
# On failure: writes a failure marker to RESULTS_DIR and exits 2 unless
# --skip-healthcheck was requested.
run_healthcheck() {
  local phase="$1"
  if [[ "$SKIP_HEALTHCHECK" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -x "$HEALTHCHECK_PATH" ]]; then
    echo "warning: healthcheck not executable at $HEALTHCHECK_PATH ($phase) — proceeding anyway" >&2
    return 0
  fi
  echo "==> running healthcheck H1 ($phase, $HEALTHCHECK_PATH)..."
  if ! "$HEALTHCHECK_PATH" >&2; then
    echo "error: healthcheck H1 failed ($phase) — aborting matrix" >&2
    # Failure marker file in results dir so a human / downstream tool
    # can see WHY the matrix stopped mid-run. Filename is HEALTHCHECK_FAIL-
    # prefixed (NOT containing candidate names) so analyze-bench's
    # scenario-by-prefix-match doesn't accidentally treat the marker as
    # a result file.
    local marker="$RESULTS_DIR/HEALTHCHECK_FAIL-$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
      echo "Healthcheck H1 failed at phase: $phase"
      echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "Healthcheck script: $HEALTHCHECK_PATH"
      echo "Aborted matrix mid-run. See healthcheck stderr above for diagnostics."
    } > "$marker" 2>/dev/null || true
    return 2
  fi
  return 0
}

# --- Healthcheck H1 BEFORE any dispatch (T-05) ---
if ! run_healthcheck "start-of-run"; then
  exit 2
fi

# --- Convert MINUTES → SECONDS for the run-scenario.sh passthrough ---
# run-scenario.sh's --timeout flag is in SECONDS (test contract); the
# operator-facing flag at this level is in MINUTES per spec.
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))

# --- Outer loop: per-candidate cohort ---
PREV_BACKEND=""
PREV_OLLAMA_TAG=""
SMOKE_FAILED=0
SMOKE_FAILED_CANDIDATES=()
COHORT_IDX=0

for cand in "${selected_candidates[@]}"; do
  COHORT_IDX=$((COHORT_IDX + 1))
  backend="$(candidate_backend "$cand")"
  ollama_tag="$(candidate_ollama_tag "$cand")"

  # --- Inter-cohort cleanup (OQ-05 + ezu extension — definitive eviction via server restart) ---
  # ALWAYS evict the prior backend's resident model at EVERY cohort transition,
  # regardless of what the next backend is. Per local-coding-models-ezu
  # (2026-05-30): the previous "only ollama stop if same backend" rule left
  # the prior model resident during cross-backend transitions (MLX→Ollama /
  # Ollama→MLX), violating G3 memory hygiene and causing OOM wedges on pico's
  # ~30GB Metal cliff.
  #
  # Why kill+restart instead of `ollama stop` / `mlx_lm.server` API:
  # - mlx_lm.server has NO unload API (auto-evict only on new-model request)
  # - `ollama stop $tag` and `POST /api/generate {keep_alive:0}` both return
  #   success but empirically (2026-05-30) leave the model in /api/ps with
  #   24 GB VRAM still committed. Eviction is async / unreliable.
  # - Server restart is the only definitive path; cost ~5s + the next cohort's
  #   first-request cold-load (~30-60s for 30b models, sub-second for small).
  if [[ "$PREV_BACKEND" == "ollama" ]]; then
    echo "==> evicting prior Ollama model ($PREV_OLLAMA_TAG) — kill+verify, then restart..."
    safe_pkill_remote pico "ollama" || {
      echo "ABORT: failed to fully evict ollama processes from pico" >&2
      exit 3
    }
    ssh pico 'cd /opt/homebrew/var && nohup env OLLAMA_HOST=100.72.47.4:11434 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=24h OLLAMA_CONTEXT_LENGTH=131072 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=2 /opt/homebrew/opt/ollama/bin/ollama serve >> /opt/homebrew/var/log/ollama.log 2>&1 & disown' 2>/dev/null || true
    sleep 6
  elif [[ "$PREV_BACKEND" == "mlx" ]]; then
    echo "==> evicting prior MLX model — kill+verify, then restart mlx_lm.server..."
    safe_pkill_remote pico "mlx" || {
      echo "ABORT: failed to fully evict mlx processes from pico" >&2
      exit 3
    }
    ssh pico 'cd /Users/pico && nohup /Users/pico/.local/bin/mlx_lm.server --host 100.72.47.4 --port 8081 --log-level INFO >> /tmp/mlx.log 2>&1 & disown' 2>/dev/null || true
    sleep 6
  fi

  # --- Healthcheck BETWEEN cohorts (Wave 2 / T-W2-H-1, T-W2-H-2) ---
  # Skip on the FIRST cohort — the start-of-run H1 above already covered
  # that. From cohort 2 onward, gate each cohort with a fresh H1 to catch
  # pico state drift mid-run.
  if [[ "$COHORT_IDX" -gt 1 ]]; then
    if ! run_healthcheck "before-cohort-$cand"; then
      # Abort cleanly with a clear failure marker (already written by
      # run_healthcheck). The inter-cohort eviction above already ran;
      # nothing more to clean up here. Exit.
      exit 2
    fi
  fi

  echo "==> candidate cohort: $cand (backend=$backend)"

  # --- Inner loop: per-scenario cell ---
  for scen_path in "${selected_scenarios[@]}"; do
    scen_base="$(basename "$scen_path" .md)"
    key="${scen_base}|${cand}"

    if [[ "$RESUME" -eq 1 ]] && cell_is_completed "$key"; then
      echo "    SKIP $scen_base × $cand (already in completed state)"
      continue
    fi

    echo "    RUN  $scen_base × $cand × $TRIALS trials (cap=${TIMEOUT_MIN}m)"

    # Dispatch into run-scenario.sh. Wave 2 uses --candidate <name> as
    # the canonical form (per T-W2-D-4). We ALSO pass the candidate name
    # positionally so legacy test stubs that grab `$1=scenario; $2=candidate`
    # still see the right value — run-scenario.sh now accepts candidate
    # names positionally as well (Wave 2 widening of the legacy opus|local
    # gate).
    "$RUN_SCENARIO_PATH" \
      "$scen_path" \
      "$cand" \
      --candidate "$cand" \
      --trials "$TRIALS" \
      --timeout "$TIMEOUT_SEC" \
      --results-dir "$RESULTS_DIR" \
      --quiet \
      > /dev/null
    rs_rc=$?
    if [[ "$rs_rc" -ne 0 ]]; then
      echo "    FAIL run-scenario.sh exited $rs_rc for $scen_base × $cand" >&2
      if [[ "$SMOKE" -eq 1 ]]; then
        # Smoke-pass gate (T-12 / OQ-06): record candidate as failed but
        # keep going so the operator sees the full smoke matrix.
        SMOKE_FAILED=1
        SMOKE_FAILED_CANDIDATES+=("$cand")
        echo "    [SMOKE] $cand smoke-fail recorded (gate for full matrix)" >&2
      fi
    fi

    # Mark cell completed (for in-process resume awareness).
    completed_cells+=("$key")
  done

  # --- Cohort-end variance check (harness: silent-success habit #2) ---
  # MEMORY: feedback-silent-success-pattern + local-coding-models-u3y.
  # Catches contamination BEFORE the operator scrolls past it.
  # Non-strict for now (advisory); flip --strict to abort the run on flag
  # once we trust the thresholds.
  echo "==> variance check for cohort $cand..."
  python3 "$SCRIPT_DIR/analyze-variance.py" \
    --results-dir "$RESULTS_DIR" \
    --cohort "$cand" || true

  PREV_BACKEND="$backend"
  PREV_OLLAMA_TAG="$ollama_tag"
done

# Final backend cleanup (matrix exit): leave pico in a known-clean state.
# Per ezu: use server-restart for definitive eviction, not `ollama stop` (which
# is async/unreliable per empirical 2026-05-30 observation).
if [[ "$PREV_BACKEND" == "ollama" ]]; then
  echo "==> final Ollama eviction on pico (last cohort: $PREV_OLLAMA_TAG)..."
  safe_pkill_remote pico "ollama" || echo "WARN: final ollama eviction had survivors (matrix run still complete)" >&2
  ssh pico 'cd /opt/homebrew/var && nohup env OLLAMA_HOST=100.72.47.4:11434 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=24h OLLAMA_CONTEXT_LENGTH=131072 OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=2 /opt/homebrew/opt/ollama/bin/ollama serve >> /opt/homebrew/var/log/ollama.log 2>&1 & disown' 2>/dev/null || true
elif [[ "$PREV_BACKEND" == "mlx" ]]; then
  echo "==> final mlx_lm.server eviction on pico..."
  safe_pkill_remote pico "mlx" || echo "WARN: final mlx eviction had survivors (matrix run still complete)" >&2
  ssh pico 'cd /Users/pico && nohup /Users/pico/.local/bin/mlx_lm.server --host 100.72.47.4 --port 8081 --log-level INFO >> /tmp/mlx.log 2>&1 & disown' 2>/dev/null || true
fi

# --- Persist state ---
if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, sys
cells = sys.stdin.read().splitlines()
with open('$STATE_FILE', 'w') as fh:
    json.dump({'completed': [c for c in cells if c]}, fh, indent=2)
" <<< "$(printf '%s\n' "${completed_cells[@]:-}")" || true
fi

echo "==> bench-matrix complete: ${#completed_cells[@]} cells touched"

if [[ "$SMOKE" -eq 1 && "$SMOKE_FAILED" -eq 1 ]]; then
  echo "==> SMOKE GATE FAILED for: ${SMOKE_FAILED_CANDIDATES[*]} — DO NOT advance to full matrix" >&2
  exit 1
fi

exit 0
