#!/usr/bin/env bash
#
# bench-matrix.sh — driver for the round-2 benchmark matrix (CC-native).
#
# Orchestrates (scenario × candidate × trial) cells. Sequential per
# memory-hygiene G3 — never two backends loaded at once. Serving is
# Claude-Code-native (the CCR chain is GONE — postmortem modes 1/2/6):
# per-model serving lives in serving.conf; bench-matrix starts/stops the
# right server per cohort and VERIFIES eviction between cohorts by probe.
#
# Round-2 hard rules (refs/matrix-postmortem-2026-06.md, twelve failure
# modes): every gate ABORTS with a non-zero exit — no warn-and-continue.
#
#   pre-flight (ALL blocking):
#     0. .claude/preflight tripwire — operator hold file; abort if present
#     1. pico exclusive-access lock (lib/pico_lock.sh)
#     2. healthcheck.sh green
#     3. full eviction + orphan audit (safe_pkill_remote + pgrep probe — u3y)
#     4. serving.conf validation + remote blob/manifest existence per
#        selected candidate
#     5. preregistration bead id required (provenance — postmortem #5)
#   per cohort (ALL blocking):
#     - stop-all serving + eviction VERIFIED by probe (ezu)
#     - launch the candidate's server per serving.conf; wait until healthy
#     - end-to-end routing probe: response.model must equal the candidate
#     - healthcheck between cohorts
#     - run-scenario exit 7 (routing mismatch mid-cohort) aborts the matrix
#     - ABSOLUTE SUCCESS FLOOR: ≥1 trial in the cohort with a success
#       artifact (verdict evidence artifact-match*) else SYSTEMIC_FAIL
#       marker + matrix abort (rw2 — the 270-garbage-trials lesson)
#     - analyze-variance.py --strict gates continuation
#   per run:
#     - run dir carries a version manifest + the preregistration bead id
#     - results sync: rsync to $BENCH_SYNC_DEST if set, else a loud
#       commit-to-git reminder (postmortem #5 — no more folklore dirs)
#
# Usage:
#   ./bench-matrix.sh --prereg-bead <id>            # full matrix
#   ./bench-matrix.sh --prereg-bead <id> --smoke    # scenario 01 × all × N=1
#   ./bench-matrix.sh --candidates qwen3-coder:30b,devstral-small-2 ...
#   ./bench-matrix.sh --scenarios 01,02,04,05,08,10 --trials 5 ...
#   ./bench-matrix.sh --timeout 45                  # MINUTES per trial cap
#   ./bench-matrix.sh --resume --results-dir <existing-run-dir> ...
#   ./bench-matrix.sh --dry-run                     # walk the full cohort
#                                                   # flow, print every
#                                                   # command, run nothing
#                                                   # (no ssh, no lock)
#
# Env vars:
#   BENCH_DRY_RUN=1     same as --dry-run
#   BENCH_PREREG_BEAD   default for --prereg-bead
#   BENCH_SYNC_DEST     rsync destination for the run dir (a tracked tree,
#                       e.g. ~/explore/local-coding-models/results/round-2/)
#   SERVING_CONF        override serving.conf path (default: sibling)
#   RUN_SCENARIO_PATH   override run-scenario.sh path (default: ../claude/sandbox/)
#   HEALTHCHECK_PATH    override healthcheck.sh path (default: sibling)
#   SCENARIOS_DIR       override scenarios dir (default: ../claude/sandbox/scenarios)
#   PICO_SSH_HOST       remote host alias (default: pico)
#
# Exit codes:
#   1 usage error / smoke gate failed
#   2 healthcheck failed
#   3 eviction / orphan audit failed
#   4 pico lock refused
#   5 pre-flight failed (tripwire / conf invalid / serving or routing probe)
#   6 cohort gate failed (success floor / analyze-variance --strict)
#   7 routing mismatch mid-cohort (propagated from run-scenario.sh)
#
# Smoke run instructions (no pico mutation, validates the whole flow):
#   BENCH_DRY_RUN=1 ./bench-matrix.sh --prereg-bead test --scenarios 01 --trials 1
#
# Spec: local-coding-models-517; Bead: dotfiles-6go
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verify-the-negation harness: safe_pkill_remote / safe_pgrep_remote.
# shellcheck source=/home/ubuntu/dotfiles/local-models/lib/safe_remote.sh
source "$SCRIPT_DIR/lib/safe_remote.sh"

# Pico exclusive-access lock convention: pico_acquire / pico_release.
# shellcheck source=/home/ubuntu/dotfiles/local-models/lib/pico_lock.sh
source "$SCRIPT_DIR/lib/pico_lock.sh"
PICO_LOCK_OWNER="bench-matrix"
DOTFILES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Defaults ---
SERVING_CONF="${SERVING_CONF:-$SCRIPT_DIR/serving.conf}"
RUN_SCENARIO_PATH="${RUN_SCENARIO_PATH:-$DOTFILES_ROOT/claude/sandbox/run-scenario.sh}"
HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-$SCRIPT_DIR/healthcheck.sh}"
SCENARIOS_DIR="${SCENARIOS_DIR:-$DOTFILES_ROOT/claude/sandbox/scenarios}"
RESULTS_DIR="$DOTFILES_ROOT/claude/sandbox/results"
PICO_SSH_HOST="${PICO_SSH_HOST:-pico}"
STATE_FILE="/tmp/bench-matrix-state.json"
TRIALS=5            # round-2 pre-registration: N=5
TIMEOUT_MIN=45
SMOKE=0
RESUME=0
DRY_RUN="${BENCH_DRY_RUN:-0}"
SKIP_HEALTHCHECK=0
CANDIDATES_CSV=""
SCENARIOS_CSV=""
PREREG_BEAD="${BENCH_PREREG_BEAD:-}"

# --- Arg parsing ---
usage() {
  cat >&2 <<USAGE
usage: $0 --prereg-bead <id> [options]

Options:
  --prereg-bead ID        preregistration bead id recorded in the run
                          manifest (REQUIRED for live runs; env
                          BENCH_PREREG_BEAD also works)
  --candidates CSV        comma-separated candidate names from serving.conf
                          (default: all active entries, conf order =
                          lightest-first; 'opus' baseline only when named)
  --scenarios CSV         comma-separated scenario prefixes (e.g. "01,02")
                          or full names (default: all scenarios on disk —
                          the round-2 pre-registered set is 01,02,04,05,08,10)
  --trials N              trials per cell (default: 5; --smoke forces 1)
  --timeout MIN           per-trial wall cap in MINUTES (default: 45)
  --smoke                 scenario 01 × selected candidates × N=1
  --resume                skip cells that already have result files; point
                          --results-dir at the EXISTING run dir
  --state-file PATH       override state file (default: $STATE_FILE)
  --dry-run               walk the full cohort flow printing every command
                          that WOULD run; no ssh, no lock, no dispatch
  --results-dir DIR       parent results dir (a run-<UTC> dir is created
                          inside) OR an existing run dir when --resume
  --skip-healthcheck      bypass healthcheck (operator escape hatch; the
                          rest of pre-flight still gates)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prereg-bead)       PREREG_BEAD="$2"; shift 2 ;;
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

# --- serving.conf access helpers ---
# Entries: model|server|base_url|launch|stop|blob  (see serving.conf header)
serving_entry() {
  # serving_entry <name> → echoes the full conf line; 1 on miss.
  local name="$1" line
  [[ -f "$SERVING_CONF" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ "${line%%|*}" == "$name" ]]; then
      echo "$line"
      return 0
    fi
  done < "$SERVING_CONF"
  return 1
}

serving_field() {
  # serving_field <name> <field#> (1-based) → echoes the field.
  local entry
  entry="$(serving_entry "$1")" || return 1
  echo "$entry" | cut -d'|' -f"$2"
}

active_candidates() {
  # All non-comment conf entries, in conf order (= lightest-first),
  # EXCLUDING the anthropic baseline (only dispatched when named).
  local line server
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    server="$(echo "$line" | cut -d'|' -f2)"
    [[ "$server" == "anthropic" ]] && continue
    echo "${line%%|*}"
  done < "$SERVING_CONF"
}

print_roster_help() {
  echo "       active candidates in $SERVING_CONF (conf order = cohort order):" >&2
  local c
  while IFS= read -r c; do
    echo "         - $c" >&2
  done < <(active_candidates)
  echo "         - opus (anthropic baseline; only when named via --candidates)" >&2
}

if [[ ! -f "$SERVING_CONF" ]]; then
  echo "error: serving.conf not found: $SERVING_CONF" >&2
  exit 5
fi

# --- Build the candidate list ---
selected_candidates=()
if [[ -z "$CANDIDATES_CSV" ]]; then
  while IFS= read -r c; do
    [[ -n "$c" ]] && selected_candidates+=("$c")
  done < <(active_candidates)
else
  IFS=',' read -ra user_cands <<< "$CANDIDATES_CSV"
  # Preserve conf order for local candidates; append opus last if named.
  declare -A requested=()
  for c in "${user_cands[@]}"; do
    if ! serving_entry "$c" >/dev/null; then
      echo "error: unknown candidate: $c" >&2
      print_roster_help
      exit 1
    fi
    requested["$c"]=1
  done
  while IFS= read -r c; do
    [[ -n "${requested[$c]:-}" ]] && selected_candidates+=("$c")
  done < <(active_candidates)
  for c in "${user_cands[@]}"; do
    if [[ "$(serving_field "$c" 2)" == "anthropic" ]]; then
      selected_candidates+=("$c")
    fi
  done
fi

if [[ "${#selected_candidates[@]}" -eq 0 ]]; then
  echo "error: no candidates selected (serving.conf has no active entries?)" >&2
  print_roster_help
  exit 1
fi

# --- Build the scenario list ---
selected_scenarios=()
if [[ ! -d "$SCENARIOS_DIR" ]]; then
  echo "error: scenarios dir not found: $SCENARIOS_DIR" >&2
  exit 1
fi

all_scenarios=()
while IFS= read -r f; do
  [[ -n "$f" ]] && all_scenarios+=("$f")
done < <(find "$SCENARIOS_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

if [[ "$SMOKE" -eq 1 ]]; then
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

# --- Preregistration gate (postmortem #5: provenance, not folklore) ---
if [[ -z "$PREREG_BEAD" ]]; then
  echo "ABORT: --prereg-bead is required (or env BENCH_PREREG_BEAD)." >&2
  echo "       Every run records which pre-registration it executes." >&2
  exit 5
fi

# --- Run dir: results land in a per-run dir carrying its manifest ---
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ "$RESUME" -eq 1 && -f "$RESULTS_DIR/run-manifest.txt" ]]; then
  RUN_DIR="$RESULTS_DIR"            # operator pointed at an existing run dir
else
  RUN_DIR="$RESULTS_DIR/run-$RUN_TS"
fi

# --- Resume state ---
completed_cells=()  # array of "scenario|candidate" strings

cells_from_state_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
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
  # Infer completed cells from result files:
  #   <scenario>-<candidate>-trial<N>-<TS>.md
  local f base scen cand
  for f in "$RUN_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    scen=""
    for s in "${selected_scenarios[@]}"; do
      sbase="$(basename "$s" .md)"
      if [[ "$base" == "$sbase"-* ]]; then
        scen="$sbase"
        break
      fi
    done
    [[ -z "$scen" ]] && continue
    rest="${base#"${scen}"-}"
    rest="$(echo "$rest" | sed -E 's/-[0-9]{8}T[0-9]{6}Z$//')"
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
      echo "warning: state file $STATE_FILE is corrupted/invalid — rebuilding from run dir" >&2
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

# =====================================================================
# Dry-run plumbing: in dry-run mode every side-effecting step is printed
# instead of executed, but the FULL cohort flow is walked so the
# orchestrator can validate sequencing without pico.
# =====================================================================
dry() {
  # dry <description> <command...> — print in dry-run, execute otherwise.
  local desc="$1"
  shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY  %-28s :' "$desc"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

remote() {
  # remote <description> <remote-shell-string> — ssh wrapper with dry-run.
  local desc="$1" cmd="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY  %-28s : ssh %s %q\n' "$desc" "$PICO_SSH_HOST" "$cmd"
    return 0
  fi
  ssh -o ConnectTimeout=10 "$PICO_SSH_HOST" "$cmd"
}

# --- Serving lifecycle -------------------------------------------------

stop_all_serving() {
  # Definitive eviction (ezu): kill EVERY serving process on pico and
  # VERIFY absence (safe_pkill_remote retries once then fails loudly).
  # Catches the u3y orphan-runner class too — `ollama runner` children
  # match the 'ollama' pattern.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  stop-all-serving            : safe_pkill_remote $PICO_SSH_HOST llama-server && safe_pkill_remote $PICO_SSH_HOST ollama"
    echo "DRY  eviction-probe              : safe_pgrep_remote $PICO_SSH_HOST 'llama-server|ollama' (must be empty)"
    return 0
  fi
  safe_pkill_remote "$PICO_SSH_HOST" "llama-server" || return 1
  safe_pkill_remote "$PICO_SSH_HOST" "ollama" || return 1
  # Belt-and-suspenders probe: BOTH patterns must report zero survivors.
  safe_pgrep_remote "$PICO_SSH_HOST" "llama-server" || return 1
  safe_pgrep_remote "$PICO_SSH_HOST" "ollama" || return 1
  return 0
}

launch_serving() {
  # launch_serving <candidate> — start the candidate's server per
  # serving.conf, wait until the endpoint answers, then verify routing
  # end-to-end. ALL failures return non-zero (caller aborts).
  local cand="$1" server base_url launch blob
  server="$(serving_field "$cand" 2)"
  base_url="$(serving_field "$cand" 3)"
  launch="$(serving_field "$cand" 4)"
  blob="$(serving_field "$cand" 6)"

  if [[ "$server" == "anthropic" ]]; then
    echo "==> $cand is the anthropic baseline — no local serving to launch"
    return 0
  fi

  # Blob/manifest must exist on pico (also asserted in pre-flight; cheap
  # to re-assert here in case of mid-run state drift).
  if [[ -n "$blob" ]]; then
    if ! remote "blob-check $cand" "test -e '$blob'"; then
      echo "ABORT: blob/manifest missing on pico for $cand: $blob" >&2
      return 1
    fi
  fi

  echo "==> launching $server for cohort $cand..."
  remote "launch $cand" "$launch" || true   # nohup+disown returns immediately

  # Wait until the serving endpoint answers (cold starts: model mmap).
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  wait-healthy                : curl --max-time 5 $base_url/v1/models (retry up to 120s)"
  else
    local ok=0
    for _ in $(seq 1 60); do
      if curl -sS --max-time 5 -o /dev/null "$base_url/v1/models" 2>/dev/null; then
        ok=1
        break
      fi
      sleep 2
    done
    if [[ "$ok" -ne 1 ]]; then
      echo "ABORT: $server for $cand did not become healthy at $base_url within 120s" >&2
      return 1
    fi
  fi

  # End-to-end routing probe (postmortem #2 — the probe that caught 8ti):
  # a real /v1/messages completion whose response model field must name
  # the candidate. Long max-time absorbs the first-request cold load.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  routing-probe               : POST $base_url/v1/messages model=$cand; assert response.model == $cand"
    return 0
  fi
  local probe_resp probe_model
  probe_resp="$(curl -sS --max-time 300 -X POST "$base_url/v1/messages" \
    -H 'Content-Type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -H 'x-api-key: bench-local' \
    -H 'Authorization: Bearer bench-local' \
    -d "{\"model\":\"$cand\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" 2>&1)"
  probe_model="$(printf '%s' "$probe_resp" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("model", ""))
except Exception:
    print("")
' 2>/dev/null)"
  if [[ "$probe_model" != "$cand" ]]; then
    echo "ABORT: routing probe failed for $cand — response model was '${probe_model:-<unparseable>}'" >&2
    echo "       raw response (first 300 chars): ${probe_resp:0:300}" >&2
    return 1
  fi
  echo "==> routing probe OK: $base_url serves '$probe_model'"
  return 0
}

# --- Healthcheck helper (blocking — no warn-and-continue) ---
run_healthcheck() {
  local phase="$1"
  if [[ "$SKIP_HEALTHCHECK" -eq 1 ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  healthcheck ($phase) : $HEALTHCHECK_PATH"
    return 0
  fi
  if [[ ! -x "$HEALTHCHECK_PATH" ]]; then
    # Postmortem cross-cutting pattern #2: a gate that cannot run is a
    # FAILED gate, not a skipped one.
    echo "ABORT: healthcheck not executable at $HEALTHCHECK_PATH ($phase)" >&2
    return 2
  fi
  echo "==> running healthcheck ($phase)..."
  if ! "$HEALTHCHECK_PATH" >&2; then
    echo "error: healthcheck failed ($phase) — aborting matrix" >&2
    local marker
    marker="$RUN_DIR/HEALTHCHECK_FAIL-$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
      echo "Healthcheck failed at phase: $phase"
      echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "Healthcheck script: $HEALTHCHECK_PATH"
    } > "$marker" 2>/dev/null || true
    return 2
  fi
  return 0
}

# --- Cohort gates ------------------------------------------------------

cohort_success_floor() {
  # ABSOLUTE SUCCESS FLOOR (postmortem #1/#10 — rw2): at least one trial
  # in the cohort must carry a SUCCESS ARTIFACT (verdict evidence
  # artifact-match or artifact-match-after-timeout). Uniform failure is
  # statistically indistinguishable from uniform success to a variance
  # check; this is the absolute check it cannot do.
  local cand="$1" n
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  success-floor ($cand) : grep -lE 'verdict_evidence.*: (artifact-match|artifact-match-after-timeout)\$' $RUN_DIR/*-$cand-trial*.md (need >=1)"
    return 0
  fi
  n="$(grep -lE '^\- \*\*verdict_evidence\*\*: (artifact-match|artifact-match-after-timeout)$' \
        "$RUN_DIR"/*-"$cand"-trial*.md 2>/dev/null | wc -l)"
  if [[ "$n" -lt 1 ]]; then
    local marker
    marker="$RUN_DIR/SYSTEMIC_FAIL-$cand-$(date -u +%Y%m%dT%H%M%SZ).txt"
    {
      echo "SYSTEMIC_FAIL: cohort $cand produced ZERO trials with a success artifact."
      echo "Every trial failed the artifact comparison — this is the rw2 uniform-failure"
      echo "signature. Matrix aborted; do not trust any verdict from this run until the"
      echo "root cause is diagnosed."
      echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$marker"
    echo "ABORT: SYSTEMIC_FAIL — cohort $cand has zero success artifacts (marker: $marker)" >&2
    return 1
  fi
  echo "==> success floor OK for $cand ($n trial(s) with success artifacts)"
  return 0
}

cohort_variance_gate() {
  # analyze-variance.py --strict is BLOCKING (was advisory in round 1 —
  # postmortem cross-cutting pattern #2: observability without enforcement).
  local cand="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY  variance-gate ($cand) : python3 $SCRIPT_DIR/analyze-variance.py --results-dir $RUN_DIR --cohort $cand --scenarios-dir $SCENARIOS_DIR --strict"
    return 0
  fi
  echo "==> variance + PASS-rate gate for cohort $cand (--strict)..."
  if ! python3 "$SCRIPT_DIR/analyze-variance.py" \
      --results-dir "$RUN_DIR" \
      --cohort "$cand" \
      --scenarios-dir "$SCENARIOS_DIR" \
      --strict; then
    echo "ABORT: analyze-variance --strict flagged cohort $cand" >&2
    return 1
  fi
  return 0
}

sync_results() {
  # Postmortem #5: results must reach version control, not folklore dirs.
  if [[ -n "${BENCH_SYNC_DEST:-}" ]]; then
    dry "rsync results" rsync -a "$RUN_DIR" "$BENCH_SYNC_DEST/" || \
      echo "WARN: rsync to $BENCH_SYNC_DEST failed — sync manually" >&2
  else
    echo "REMINDER: results live in $RUN_DIR (gitignored)." >&2
    echo "          Copy them into a TRACKED tree and commit, e.g.:" >&2
    echo "          rsync -a $RUN_DIR ~/explore/local-coding-models/results/round-2/ && git -C ~/explore/local-coding-models add results/ && commit" >&2
  fi
}

# --- Plan summary ---
echo "==> bench-matrix plan (round 2, CC-native):"
echo "    prereg bead: $PREREG_BEAD"
echo "    candidates:  ${selected_candidates[*]}"
echo "    scenarios:   $(printf '%s ' "${selected_scenarios[@]##*/}" | sed 's/\.md//g')"
echo "    trials:      $TRIALS"
echo "    timeout:     ${TIMEOUT_MIN}m per trial"
echo "    smoke:       $SMOKE"
echo "    resume:      $RESUME"
echo "    dry-run:     $DRY_RUN"
echo "    serving:     $SERVING_CONF"
echo "    run dir:     $RUN_DIR"
echo "    sync dest:   ${BENCH_SYNC_DEST:-<unset — reminder printed at end>}"
echo "    skip-hc:     $SKIP_HEALTHCHECK"

# =====================================================================
# PRE-FLIGHT — every check blocking (yev; postmortem #11)
# =====================================================================

# 0. Operator tripwire: a `.claude/preflight` file at the dotfiles root is
#    a HOLD order — abort and surface its contents. Remove the file to
#    launch. (Lets a human or another agent block unattended runs without
#    hunting down the process.)
TRIPWIRE="$DOTFILES_ROOT/.claude/preflight"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY  tripwire-check              : test ! -e $TRIPWIRE"
elif [[ -e "$TRIPWIRE" ]]; then
  echo "ABORT: pre-flight tripwire present at $TRIPWIRE:" >&2
  sed 's/^/       /' "$TRIPWIRE" >&2 2>/dev/null || true
  echo "       Remove the file to allow bench runs." >&2
  exit 5
fi

# 1. Pico exclusive-access lock.
PICO_LOCK_DURATION=$(( ${#selected_candidates[@]} * ${#selected_scenarios[@]} * TRIALS * TIMEOUT_MIN * 60 ))
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY  pico-lock                   : pico_acquire $PICO_LOCK_OWNER ${PICO_LOCK_DURATION}s"
else
  echo "==> acquiring pico exclusive-access lock (duration ${PICO_LOCK_DURATION}s upper bound)..."
  if ! pico_acquire "$PICO_LOCK_OWNER" "$PICO_LOCK_DURATION" \
      "round-2 bench matrix ($PREREG_BEAD): ${#selected_candidates[@]} candidates × ${#selected_scenarios[@]} scenarios × $TRIALS trials"; then
    echo "ABORT: another consumer holds the pico lock (bash $SCRIPT_DIR/lib/pico_lock.sh check)." >&2
    exit 4
  fi
  trap 'pico_release "$PICO_LOCK_OWNER" 2>/dev/null || true' EXIT
fi

# 2. Healthcheck.
if ! run_healthcheck "pre-flight"; then
  exit 2
fi

# 3. Clean-slate eviction + orphan audit (u3y / ezu): kill every serving
#    process and verify ZERO survivors before the first cohort.
echo "==> pre-flight eviction + orphan audit..."
if ! stop_all_serving; then
  echo "ABORT: pre-flight eviction failed — orphan serving processes survive on pico" >&2
  exit 3
fi

# 4. serving.conf validation for every selected candidate: entry shape +
#    remote blob/manifest existence.
echo "==> pre-flight serving.conf validation..."
for cand in "${selected_candidates[@]}"; do
  entry="$(serving_entry "$cand")" || { echo "ABORT: no serving.conf entry for $cand" >&2; exit 5; }
  nfields="$(awk -F'|' '{print NF}' <<< "$entry")"
  if [[ "$nfields" -ne 6 ]]; then
    echo "ABORT: malformed serving.conf entry for $cand ($nfields fields, want 6): $entry" >&2
    exit 5
  fi
  server="$(serving_field "$cand" 2)"
  case "$server" in
    llama-server|ollama|anthropic) ;;
    *)
      echo "ABORT: unknown server type '$server' for $cand in serving.conf" >&2
      exit 5
      ;;
  esac
  if [[ "$server" != "anthropic" ]]; then
    blob="$(serving_field "$cand" 6)"
    if [[ -z "$blob" ]]; then
      echo "ABORT: serving.conf entry for $cand has no blob/manifest path" >&2
      exit 5
    fi
    if ! remote "preflight-blob $cand" "test -e '$blob'"; then
      echo "ABORT: blob/manifest for $cand missing on pico: $blob (pull the model first)" >&2
      exit 5
    fi
  fi
done
echo "==> serving.conf OK for: ${selected_candidates[*]}"

# --- Run dir + version manifest (postmortem #6: pinned manifest per run) ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY  mkdir-run-dir               : mkdir -p $RUN_DIR"
  echo "DRY  write-run-manifest          : $RUN_DIR/run-manifest.txt (versions + prereg bead $PREREG_BEAD)"
else
  mkdir -p "$RUN_DIR"
  if [[ ! -f "$RUN_DIR/run-manifest.txt" ]]; then
    {
      echo "# bench-matrix run manifest"
      echo "run_started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "preregistration_bead: $PREREG_BEAD"
      echo "driver_host: $(hostname)"
      echo "claude_code_version: $(claude --version 2>/dev/null || echo unknown)"
      echo "serving_conf_sha256: $(sha256sum "$SERVING_CONF" 2>/dev/null | cut -d' ' -f1)"
      echo "pico_ollama_version: $(ssh -o ConnectTimeout=10 "$PICO_SSH_HOST" '/Users/pico/ollama-0.30.7/ollama --version' 2>/dev/null | head -1 || echo unknown)"
      echo "pico_macos: $(ssh -o ConnectTimeout=10 "$PICO_SSH_HOST" 'sw_vers -productVersion' 2>/dev/null || echo unknown)"
      echo "candidates: ${selected_candidates[*]}"
      echo "scenarios: $(printf '%s ' "${selected_scenarios[@]##*/}" | sed 's/\.md//g')"
      echo "trials_per_cell: $TRIALS"
      echo "timeout_minutes: $TIMEOUT_MIN"
    } > "$RUN_DIR/run-manifest.txt"
  fi
fi

# --- Convert MINUTES → SECONDS for run-scenario.sh passthrough ---
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))

# =====================================================================
# COHORT LOOP
# =====================================================================
SMOKE_FAILED=0
SMOKE_FAILED_CANDIDATES=()
COHORT_IDX=0

for cand in "${selected_candidates[@]}"; do
  COHORT_IDX=$((COHORT_IDX + 1))
  server="$(serving_field "$cand" 2)"

  echo "==> cohort $COHORT_IDX/${#selected_candidates[@]}: $cand (server=$server)"

  # --- Inter-cohort eviction, VERIFIED (ezu / u3y) ---
  # Always stop everything first — even before cohort 1 the pre-flight
  # already cleared the slate, but mid-run drift is exactly what bit v3.
  if [[ "$COHORT_IDX" -gt 1 ]]; then
    if ! stop_all_serving; then
      echo "ABORT: inter-cohort eviction failed before $cand" >&2
      exit 3
    fi
    if ! run_healthcheck "before-cohort-$cand"; then
      exit 2
    fi
  fi

  # --- Launch + wait-healthy + routing probe (all blocking) ---
  if ! launch_serving "$cand"; then
    exit 5
  fi

  # --- Inner loop: per-scenario cell ---
  for scen_path in "${selected_scenarios[@]}"; do
    scen_base="$(basename "$scen_path" .md)"
    key="${scen_base}|${cand}"

    if [[ "$RESUME" -eq 1 ]] && cell_is_completed "$key"; then
      echo "    SKIP $scen_base × $cand (already in completed state)"
      continue
    fi

    echo "    RUN  $scen_base × $cand × $TRIALS trials (cap=${TIMEOUT_MIN}m)"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY  run-scenario                :'
      printf ' %q' "$RUN_SCENARIO_PATH" "$scen_path" "$cand" \
        --candidate "$cand" --trials "$TRIALS" --timeout "$TIMEOUT_SEC" \
        --results-dir "$RUN_DIR" --quiet
      printf '\n'
      completed_cells+=("$key")
      continue
    fi

    # Candidate passed positionally AND via --candidate (stub compat).
    "$RUN_SCENARIO_PATH" \
      "$scen_path" \
      "$cand" \
      --candidate "$cand" \
      --trials "$TRIALS" \
      --timeout "$TIMEOUT_SEC" \
      --results-dir "$RUN_DIR" \
      --quiet \
      > /dev/null
    rs_rc=$?
    if [[ "$rs_rc" -eq 7 ]]; then
      echo "ABORT: routing mismatch reported by run-scenario.sh for $scen_base × $cand — cohort invalid" >&2
      exit 7
    fi
    if [[ "$rs_rc" -ne 0 ]]; then
      echo "    FAIL run-scenario.sh exited $rs_rc for $scen_base × $cand" >&2
      if [[ "$SMOKE" -eq 1 ]]; then
        # Smoke mode keeps going so the operator sees the full smoke
        # matrix, then fails the run at the end (still a blocking gate).
        SMOKE_FAILED=1
        SMOKE_FAILED_CANDIDATES+=("$cand")
        echo "    [SMOKE] $cand smoke-fail recorded" >&2
      else
        echo "ABORT: dispatcher error is an infra failure, not a model verdict" >&2
        exit 6
      fi
    fi

    completed_cells+=("$key")
  done

  # --- Cohort-end blocking gates ---
  if [[ "$SMOKE" -eq 1 ]]; then
    # Smoke is the cheap pre-gate: N=1, scenario 01. Floor + variance are
    # meaningless at N=1; the smoke verdict is the per-candidate result
    # files + the end-of-run smoke gate.
    echo "==> smoke cohort $cand done (gates run in full-matrix mode)"
  else
    if ! cohort_success_floor "$cand"; then
      sync_results
      exit 6
    fi
    if ! cohort_variance_gate "$cand"; then
      sync_results
      exit 6
    fi
  fi

  sync_results
done

# Final eviction: leave pico clean + verified.
if ! stop_all_serving; then
  echo "WARN: final eviction had survivors — clean pico manually (ssh $PICO_SSH_HOST pgrep -af 'ollama|llama-server')" >&2
fi

# --- Persist state ---
if [[ "$DRY_RUN" -ne 1 ]] && command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, sys
cells = sys.stdin.read().splitlines()
with open('$STATE_FILE', 'w') as fh:
    json.dump({'completed': [c for c in cells if c]}, fh, indent=2)
" <<< "$(printf '%s\n' "${completed_cells[@]:-}")" || true
fi

echo "==> bench-matrix complete: ${#completed_cells[@]} cells touched"
echo "==> run dir: $RUN_DIR (manifest: run-manifest.txt, prereg: $PREREG_BEAD)"

if [[ "$SMOKE" -eq 1 && "$SMOKE_FAILED" -eq 1 ]]; then
  echo "==> SMOKE GATE FAILED for: ${SMOKE_FAILED_CANDIDATES[*]} — DO NOT advance to full matrix" >&2
  exit 1
fi

exit 0
