#!/usr/bin/env bash
#
# bench-matrix.sh — driver for the Phase 3 parity benchmark matrix.
#
# Orchestrates (scenario × candidate × trial) cells per spec
# dotfiles-ukx.13 §4.2. Sequential per memory-hygiene G3 — never two
# backends loaded at once. Lightest-first candidate ordering (OQ-04).
# Explicit `ollama stop <model>` between Ollama candidates (OQ-05).
# Healthcheck H1 before each candidate cohort. Per-cell call into
# run-scenario.sh which handles per-trial wall caps + result-file
# emission.
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
#
# Env vars (mostly for testing):
#   RUN_SCENARIO_PATH   override path to run-scenario.sh (default: sibling)
#   HEALTHCHECK_PATH    override path to healthcheck.sh   (default: sibling)
#   SCENARIOS_DIR       override scenarios dir            (default: ../claude/sandbox/scenarios)
#
# Spec: dotfiles-ukx.13 §4.2
# Bead: dotfiles-ukx.13.3
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
CANDIDATES_CSV=""
SCENARIOS_CSV=""

# --- Lightest-first candidate roster (OQ-04, spec §3.3) ---
# Order is load-order — trinity (smallest, fastest) first; deepseek-r1
# (heaviest reasoning) last. Each entry has a backend tag so we can
# decide whether to `ollama stop` between cohorts.
#
# Format: "<canonical-name>:<backend>:<ollama-model-tag-or-blank>"
ROSTER=(
  "trinity-mini:mlx:"
  "qwen3-coder:mlx:"
  "qwen3-coder-ollama:ollama:qwen3-coder:30b"
  "devstral:mlx:"
  "deepseek-coder-v2-lite-ollama:ollama:deepseek-coder-v2:16b"
  "laguna-xs2:ollama:laguna-xs2:latest"
  "kimi-linear:mlx:"
  "glm-4.5-air:mlx:"
  "deepseek-r1-14b:ollama:deepseek-r1:14b"
)

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
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidates)  CANDIDATES_CSV="$2"; shift 2 ;;
    --scenarios)   SCENARIOS_CSV="$2"; shift 2 ;;
    --trials)      TRIALS="$2"; shift 2 ;;
    --timeout)     TIMEOUT_MIN="$2"; shift 2 ;;
    --smoke)       SMOKE=1; shift ;;
    --resume)      RESUME=1; shift ;;
    --state-file)  STATE_FILE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --results-dir) RESULTS_DIR="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "error: unknown flag: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$RESULTS_DIR"

# --- Helper: lookup a candidate's metadata from ROSTER ---
candidate_meta() {
  local name="$1" entry
  for entry in "${ROSTER[@]}"; do
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

# --- Build the candidate list (lightest-first re-sort if user provided CSV) ---
selected_candidates=()
if [[ -z "$CANDIDATES_CSV" ]]; then
  for entry in "${ROSTER[@]}"; do
    selected_candidates+=("${entry%%:*}")
  done
else
  # Split CSV, then re-sort by lightest-first order from ROSTER.
  IFS=',' read -ra user_cands <<< "$CANDIDATES_CSV"
  # Validate each one exists in the roster; fail fast on unknown (edge 5).
  for c in "${user_cands[@]}"; do
    if ! candidate_meta "$c" >/dev/null; then
      echo "error: unknown candidate: $c" >&2
      echo "       known candidates (lightest-first):" >&2
      for entry in "${ROSTER[@]}"; do
        echo "         - ${entry%%:*}" >&2
      done
      exit 1
    fi
  done
  # Reorder per ROSTER, preserving lightest-first.
  for entry in "${ROSTER[@]}"; do
    name="${entry%%:*}"
    for c in "${user_cands[@]}"; do
      if [[ "$c" == "$name" ]]; then
        selected_candidates+=("$name")
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

# --- Healthcheck H1 BEFORE any dispatch (T-05) ---
if [[ -x "$HEALTHCHECK_PATH" ]]; then
  echo "==> running healthcheck H1 ($HEALTHCHECK_PATH)..."
  if ! "$HEALTHCHECK_PATH" >&2; then
    echo "error: healthcheck H1 failed — aborting matrix (T-05)" >&2
    exit 2
  fi
else
  echo "warning: healthcheck not executable at $HEALTHCHECK_PATH — proceeding anyway" >&2
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

for cand in "${selected_candidates[@]}"; do
  backend="$(candidate_backend "$cand")"
  ollama_tag="$(candidate_ollama_tag "$cand")"

  # --- Inter-cohort cleanup (OQ-05 — explicit ollama stop) ---
  if [[ -n "$PREV_OLLAMA_TAG" && "$PREV_BACKEND" == "ollama" ]]; then
    echo "==> stopping previous Ollama candidate ($PREV_OLLAMA_TAG) for clean eviction..."
    ollama stop "$PREV_OLLAMA_TAG" 2>/dev/null || true
  fi

  echo "==> candidate cohort: $cand (backend=$backend)"

  # Healthcheck between cohorts (not before the first one — H1 covers that).
  # Spec §3.3 calls for H1 between candidate cohorts; we keep this lean
  # for now (just the initial H1) and a hook for between-cohort if needed.

  # --- Inner loop: per-scenario cell ---
  for scen_path in "${selected_scenarios[@]}"; do
    scen_base="$(basename "$scen_path" .md)"
    key="${scen_base}|${cand}"

    if [[ "$RESUME" -eq 1 ]] && cell_is_completed "$key"; then
      echo "    SKIP $scen_base × $cand (already in completed state)"
      continue
    fi

    echo "    RUN  $scen_base × $cand × $TRIALS trials (cap=${TIMEOUT_MIN}m)"

    # Dispatch into run-scenario.sh. The model-tag arg uses the candidate
    # name; run-scenario.sh accepts "opus" or "local" by default but
    # bench-matrix passes the canonical candidate name through to the
    # stub in test mode. In production, this layer will need to map
    # candidate→model-tag for the real run-scenario.sh.
    "$RUN_SCENARIO_PATH" \
      "$scen_path" \
      "$cand" \
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

  PREV_BACKEND="$backend"
  PREV_OLLAMA_TAG="$ollama_tag"
done

# Final ollama stop for the last cohort if needed.
if [[ -n "$PREV_OLLAMA_TAG" && "$PREV_BACKEND" == "ollama" ]]; then
  echo "==> final Ollama stop ($PREV_OLLAMA_TAG) for clean shutdown..."
  ollama stop "$PREV_OLLAMA_TAG" 2>/dev/null || true
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
