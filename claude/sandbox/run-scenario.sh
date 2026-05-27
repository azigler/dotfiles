#!/usr/bin/env bash
#
# run-scenario.sh — execute one sandbox scenario against opus or local.
#
# Usage:
#   ./run-scenario.sh <scenario-file> <opus|local> [options]
#   ./run-scenario.sh <scenario-file> --candidate <name> [options]
#
# Options:
#   --candidate NAME     Wave 2 dispatch flag: select a roster candidate by
#                        name (e.g., qwen3-coder, trinity-mini, kimi-linear).
#                        Resolves to a CCR routing tag + HF model path via the
#                        CANDIDATE_DISPATCH table below. Use this OR the
#                        legacy positional <opus|local> arg, not both.
#   --dry-run-routing    Print the resolved CCR route + HF model path for the
#                        chosen candidate and exit 0. Does NOT run Setup /
#                        claude / Cleanup. Use to audit dispatch before going
#                        live. Requires --candidate (or accepts the positional
#                        opus|local form).
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
# captures sandbox state INCLUDING file contents (FILECONTENTS:<path>:<body>,
# cap 50KB/file) → runs Cleanup → writes results markdown to results/.
#
# Backends:
#   opus  = the real Anthropic Opus model (uses normal claude CLI)
#   local = pico-mlx,qwen3-coder via CCR + llama-swap (uses ./claude-local)
#
# Spec: dotfiles-ukx.13 §4.1
# Refs:
#   - Sibling: ./claude-local (wrapper that injects CCR routing tag)
#   - Bead: dotfiles-ukx.3 (original), dotfiles-ukx.13.3 (Wave 1), dotfiles-ukx.13.4.2 (Wave 2)
#
set -uo pipefail
# NOTE: we deliberately drop -e from `set -euo` so that a single failed
# trial inside the loop doesn't abort subsequent trials.

# --- Candidate dispatch table (Wave 2: candidate→model-tag + CCR route) ---
#
# Format: "<candidate-name>|<model-tag>|<ccr-route>|<hf-model-or-ollama-tag>"
#
# - model-tag is what the inner run uses to pick the claude binary
#   (opus|local). Local candidates all use 'local'; opus baseline uses 'opus'.
# - ccr-route is the value CCR's <CCR-SUBAGENT-MODEL> tag should carry
#   (provider,model — per G12). Empty for opus baseline (uses Anthropic
#   directly via the normal claude CLI).
# - hf-model is the canonical HuggingFace model path (mlx) OR Ollama tag,
#   surfaced in --dry-run-routing so the operator can audit which weights
#   would actually load.
#
# Names cover BOTH naming styles in active use:
#   - the canonical-roster style (run-scenario.sh's 8-roster test contract)
#   - the bench-matrix.sh ROSTER style (with -ollama suffixes / shorter tags)
# Both resolve to the same CCR routes — synonyms, not duplicates.
CANDIDATE_DISPATCH=(
  # Baseline
  "opus|opus||anthropic/claude-opus-4-7"

  # MLX-backed candidates (via pico-mlx provider → llama-swap :8090 per G16)
  "qwen3-coder|local|pico-mlx,qwen3-coder|mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
  "trinity-mini|local|pico-mlx,trinity-mini|mlx-community/Trinity-Mini-4bit"
  "devstral|local|pico-mlx,devstral|mlx-community/Devstral-Small-2507-5bit"
  "glm-4.5-air|local|pico-mlx,glm-4.5-air|mlx-community/GLM-4.5-Air-3bit"
  "glm-4.5-air-3bit|local|pico-mlx,glm-4.5-air|mlx-community/GLM-4.5-Air-3bit"
  "kimi-linear|local|pico-mlx,kimi-linear|mlx-community/Kimi-Linear-REAP-35B-4bit"
  "kimi-linear-reap-35b|local|pico-mlx,kimi-linear|mlx-community/Kimi-Linear-REAP-35B-4bit"

  # Ollama-backed candidates (via pico-ollama provider on :11434)
  "qwen3-coder-ollama|local|pico-ollama,qwen3-coder:30b|qwen3-coder:30b"
  "deepseek-coder-v2-lite|local|pico-ollama,deepseek-coder-v2:16b-lite-instruct-q4_K_M|deepseek-coder-v2:16b-lite-instruct-q4_K_M"
  "deepseek-coder-v2-lite-ollama|local|pico-ollama,deepseek-coder-v2:16b-lite-instruct-q4_K_M|deepseek-coder-v2:16b-lite-instruct-q4_K_M"
  "laguna-xs.2|local|pico-ollama,laguna-xs.2:latest|laguna-xs.2:latest"
  "laguna-xs2|local|pico-ollama,laguna-xs.2:latest|laguna-xs.2:latest"
  "deepseek-r1-14b|local|pico-ollama,deepseek-r1:14b|deepseek-r1:14b"
)

# Canonical 8-roster (the names the spec calls out as "the 8 candidates").
# Used in error messages so the operator sees the official names, not every
# alias. Order is intentional (lightest-first, kimi last per OQ-04).
CANONICAL_ROSTER_NAMES=(
  "opus"
  "trinity-mini"
  "qwen3-coder"
  "devstral"
  "deepseek-coder-v2-lite"
  "laguna-xs.2"
  "glm-4.5-air-3bit"
  "kimi-linear-reap-35b"
)

# resolve_candidate <name> → echoes "<model-tag>|<ccr-route>|<hf-model>"
# Returns 0 on hit, 1 on unknown.
resolve_candidate() {
  local name="$1" entry
  for entry in "${CANDIDATE_DISPATCH[@]}"; do
    if [[ "${entry%%|*}" == "$name" ]]; then
      # Drop the leading "<name>|" and print the rest.
      echo "${entry#*|}"
      return 0
    fi
  done
  return 1
}

print_unknown_candidate_help() {
  local name="$1"
  echo "error: unknown candidate: $name" >&2
  echo "       known candidates (canonical 8-roster):" >&2
  local c
  for c in "${CANONICAL_ROSTER_NAMES[@]}"; do
    echo "         - $c" >&2
  done
  echo "       (additional aliases: qwen3-coder-ollama, deepseek-coder-v2-lite-ollama," >&2
  echo "        laguna-xs2, deepseek-r1-14b, glm-4.5-air, kimi-linear)" >&2
}

# --- Arg parsing ---
TRIALS=1
TIMEOUT_SECONDS=""    # empty = no cap
QUIET=0
RESULTS_DIR_OVERRIDE=""
CANDIDATE_NAME=""
DRY_RUN_ROUTING=0
# Per-file FILECONTENTS size cap (bytes). Files larger than this get
# truncated with a "<<truncated:NN-bytes-exceeded-50KB-cap>>" marker per
# T-W2-F-3 contract.
FILECONTENTS_CAP_BYTES=${FILECONTENTS_CAP_BYTES:-51200}

usage() {
  cat >&2 <<USAGE
usage:
  $0 <scenario-file> <opus|local> [options]
  $0 <scenario-file> --candidate <name> [options]

Options:
  --candidate NAME        Roster candidate name (Wave 2 dispatch form).
                          See CANDIDATE_DISPATCH for the full list.
  --dry-run-routing       Print resolved CCR route + HF model + exit 0.
  --trials N              Run scenario N times (default 1).
  --timeout SECONDS       Per-trial wall cap in SECONDS (default: unbounded).
  --quiet                 Suppress live stderr chatter.
  --results-dir DIR       Override results dir.
USAGE
}

# Early help-check: -h / --help must fire BEFORE arg-count validation so
# `run-scenario.sh --help` works without the operator first passing a
# scenario-file just to discover usage. (/scrutiny finding #5.)
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

SCENARIO_FILE="$1"
shift

# The second positional arg may be the legacy model-tag (opus|local) OR the
# first --flag of the Wave 2 dispatch form. Sniff.
MODEL_TAG=""
if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then
  MODEL_TAG="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate)
      CANDIDATE_NAME="$2"
      shift 2
      ;;
    --dry-run-routing)
      DRY_RUN_ROUTING=1
      shift
      ;;
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

# --- Resolve dispatch: --candidate takes precedence over positional ---
# When BOTH are supplied (e.g., bench-matrix.sh dispatch which sends both
# the positional candidate for stub-compat AND --candidate for the W2
# contract): the --candidate flag wins. We warn if they DIFFER — that
# would indicate an operator typo. Same value is the common case
# (bench-matrix sends both for compat) and stays silent.
CCR_ROUTE=""
HF_MODEL=""

if [[ -n "$CANDIDATE_NAME" ]]; then
  if [[ -n "$MODEL_TAG" && "$MODEL_TAG" != "$CANDIDATE_NAME" \
        && "$MODEL_TAG" != "opus" && "$MODEL_TAG" != "local" ]]; then
    echo "warning: positional '$MODEL_TAG' differs from --candidate '$CANDIDATE_NAME'; --candidate wins" >&2
  fi
  if ! dispatch="$(resolve_candidate "$CANDIDATE_NAME")"; then
    print_unknown_candidate_help "$CANDIDATE_NAME"
    exit 1
  fi
  MODEL_TAG="${dispatch%%|*}"
  rest="${dispatch#*|}"
  CCR_ROUTE="${rest%%|*}"
  HF_MODEL="${rest#*|}"
else
  if [[ -z "$MODEL_TAG" ]]; then
    echo "error: missing model-tag — pass <opus|local> positionally or use --candidate <name>" >&2
    usage
    exit 1
  fi
  # The positional arg may be:
  #   - opus|local (legacy form — validate + look up dispatch metadata)
  #   - a candidate name from CANDIDATE_DISPATCH (Wave 2 — treat as if
  #     --candidate was supplied; this lets bench-matrix.sh's stubs pass
  #     candidate-as-positional without breaking T-02's bogus-candidate
  #     gate)
  #   - anything else (bogus — T-02: fail fast with the roster listed)
  if [[ "$MODEL_TAG" == "opus" || "$MODEL_TAG" == "local" ]]; then
    # Legacy form — fill in dispatch metadata so --dry-run-routing works.
    if dispatch="$(resolve_candidate "$MODEL_TAG")"; then
      rest="${dispatch#*|}"
      CCR_ROUTE="${rest%%|*}"
      HF_MODEL="${rest#*|}"
    fi
  elif dispatch="$(resolve_candidate "$MODEL_TAG")"; then
    # Wave 2: positional candidate-name form (synonym for --candidate).
    CANDIDATE_NAME="$MODEL_TAG"
    MODEL_TAG="${dispatch%%|*}"
    rest="${dispatch#*|}"
    CCR_ROUTE="${rest%%|*}"
    HF_MODEL="${rest#*|}"
  else
    print_unknown_candidate_help "$MODEL_TAG"
    exit 1
  fi
fi

# --- --dry-run-routing: print the resolved route + HF model, exit 0 ---
if [[ "$DRY_RUN_ROUTING" -eq 1 ]]; then
  # Use the requested name in the audit line (so the test can find it via
  # grep on the original input). Fall back to MODEL_TAG if --candidate wasn't
  # specified.
  AUDIT_NAME="${CANDIDATE_NAME:-$MODEL_TAG}"
  PROVIDER_LABEL="anthropic"
  if [[ "$CCR_ROUTE" == pico-mlx* ]]; then
    PROVIDER_LABEL="pico-mlx (llama-swap :8090)"
  elif [[ "$CCR_ROUTE" == pico-ollama* ]]; then
    PROVIDER_LABEL="pico-ollama (:11434)"
  fi
  echo "candidate: $AUDIT_NAME"
  echo "model-tag: $MODEL_TAG"
  echo "ccr-route: ${CCR_ROUTE:-<none — opus uses Anthropic directly>}"
  echo "hf-model:  $HF_MODEL"
  echo "provider:  $PROVIDER_LABEL"

  # Per /scrutiny finding #3 (belt-and-suspenders): cross-check that the
  # resolved CCR route is actually registered in the project's
  # claude-code-router/config.json. Pre-Wave-2.1, this script printed
  # routes for glm-4.5-air + kimi-linear that didn't exist in CCR config,
  # so a live run would 404. The Wave 2.1 commit adds them to config —
  # this check guards against future drift.
  RS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  CCR_CONFIG="$RS_SCRIPT_DIR/../../claude-code-router/config.json"
  if [[ -n "$CCR_ROUTE" && -f "$CCR_CONFIG" ]]; then
    PROVIDER_NAME="${CCR_ROUTE%%,*}"
    MODEL_NAME="${CCR_ROUTE#*,}"
    if python3 -c "
import json, sys
with open('$CCR_CONFIG') as f:
    cfg = json.load(f)
for p in cfg.get('Providers', []):
    if p.get('name') == '$PROVIDER_NAME':
        sys.exit(0 if '$MODEL_NAME' in p.get('models', []) else 2)
sys.exit(1)
" 2>/dev/null; then
      echo "config-check: OK (provider=$PROVIDER_NAME has model=$MODEL_NAME)"
    else
      rc=$?
      case "$rc" in
        1) echo "config-check: WARN provider '$PROVIDER_NAME' not in $CCR_CONFIG" ;;
        2) echo "config-check: WARN model '$MODEL_NAME' not registered under '$PROVIDER_NAME' in $CCR_CONFIG" ;;
        *) echo "config-check: WARN unexpected validator exit ($rc)" ;;
      esac
    fi
  fi
  exit 0
fi

# --- Validate scenario file ---
if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "error: scenario file not found: $SCENARIO_FILE" >&2
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

# --- FILECONTENTS emission helper (Wave 2 / T-W2-F-1, T-W2-F-3) ---
#
# Emits `FILECONTENTS:<path>:<body>` lines for each file under the given
# dirs. Skips:
#   - binary files (heuristic: NUL byte in first 8KB)
#   - files larger than FILECONTENTS_CAP_BYTES (emits a truncation marker)
#
# The marker format includes the byte count + cap so analyze-bench can
# surface the truncation reason. Per T-W2-F-3, the marker substring
# "truncated" MUST appear.
#
# NOTE: uses `declare -A` (associative array), which requires bash 4+.
# macOS ships bash 3.2 at /bin/bash; this script's shebang is
# `#!/usr/bin/env bash` so it picks up Homebrew/MacPorts bash 5+ on
# typical dev macs. If a future deployment needs bash 3 portability,
# replace the assoc array with a sorted-paths sentinel list.
emit_filecontents() {
  local d f size
  # Collect all files across all candidate dirs (single pass, dedup by
  # file path to avoid double-emission if dirs overlap).
  local -A seen=()
  for d in "$@"; do
    [[ -z "$d" ]] && continue
    [[ ! -d "$d" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -n "${seen[$f]:-}" ]] && continue
      seen[$f]=1
      # Skip non-regular files (symlinks-to-dirs, sockets, fifos).
      [[ ! -f "$f" ]] && continue
      # 8KB heuristic for binary detection: if the first 8KB contains a
      # NUL byte, treat the file as binary and skip the body (analyzers
      # don't grep binary blobs). NOT a definitive binary-vs-text classifier
      # (won't catch e.g. UTF-16 BOMs without NULs early); good enough to
      # filter the common .o/.so/.png/.zip cases that bench scenarios may
      # produce. grep can't reliably search for NUL bytes across variants
      # (treats $'\0' as empty pattern); python3 (already a dep for
      # routing-evidence parsing) does it correctly.
      if python3 -c 'import sys
sys.exit(0 if b"\x00" in open(sys.argv[1], "rb").read(8192) else 1)' \
          "$f" 2>/dev/null; then
        echo "FILECONTENTS:$f:<<truncated:binary-file-skipped>>"
        continue
      fi
      size=$(stat -c%s -- "$f" 2>/dev/null || stat -f%z -- "$f" 2>/dev/null || echo 0)
      if [[ "$size" -gt "$FILECONTENTS_CAP_BYTES" ]]; then
        echo "FILECONTENTS:$f:<<truncated:${size}-bytes-exceeded-50KB-cap>>"
        continue
      fi
      # Emit content as ONE line: literal newlines collapsed to \n so the
      # FILECONTENTS regex `^FILECONTENTS:<path>:<body>$` matches one line
      # per file. analyze-bench's _check_grep_count splits the body on
      # `\n` for grep -c line semantics.
      # NOTE: awk does NOT honor `--` arg separator like coreutils; pass
      # the filename directly (the find loop is safe — paths come from
      # `find -type f` and won't contain shell-meta surprises).
      local body
      body="$(awk 'BEGIN{ORS=""} {if (NR>1) printf("\\n"); printf("%s",$0)}' "$f" 2>/dev/null || true)"
      echo "FILECONTENTS:$f:$body"
    done < <(find "$d" -type f 2>/dev/null)
  done
}

# --- Trial loop ---
run_one_trial() {
  local trial_num="$1"
  local is_cold_load="$2"   # "true" or "false"

  local TIMESTAMP RESULT_FILE FILENAME_CAND
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  # Use the candidate name (not just MODEL_TAG which is always "local"
  # for the 7 non-opus candidates) so different cohorts produce distinct
  # result filenames. /scrutiny #2 fix: pre-Wave-2.1 the filename used
  # ${MODEL_TAG} alone, collapsing qwen3-coder + trinity-mini + ... into
  # a single namespace, breaking rebuild_state_from_results_dir AND
  # making same-second cells overwrite each other.
  FILENAME_CAND="${CANDIDATE_NAME:-$MODEL_TAG}"
  RESULT_FILE="$RESULTS_DIR/${SCENARIO_BASENAME}-${FILENAME_CAND}-trial${trial_num}-${TIMESTAMP}.md"

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
  # Wave 2: emits BOTH the path list (legacy) AND FILECONTENTS:<path>:<body>
  # lines so analyze-bench's grep_runner can resolve `grep -c PAT PATH`
  # assertions even after Cleanup nukes the sandbox dir (T-W2-F-1, T-W2-F-2).
  local SANDBOX_ROOT SANDBOX_STATE
  SANDBOX_ROOT="${SANDBOX:-/tmp/claude-local-test}"
  SANDBOX_STATE="(no sandbox dir found at $SANDBOX_ROOT)"
  # Also collect from any scenario-specific dirs (test fixture uses
  # /tmp/bench-rs-test/fix; real scenarios use $SANDBOX/s01).
  local -a snapshot_dirs=()
  if [[ -d "$SANDBOX_ROOT" ]]; then
    snapshot_dirs+=("$SANDBOX_ROOT")
  fi
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && snapshot_dirs+=("$d")
  done <<< "$(extract_sandbox_dirs)"

  if [[ "${#snapshot_dirs[@]}" -gt 0 ]]; then
    # Path list (legacy compatibility for analyze-bench's path-only path).
    local path_listing
    path_listing="$(find "${snapshot_dirs[@]}" -type f 2>/dev/null | awk 'NR<=20 {print "    "$0}' || true)"
    # FILECONTENTS (Wave 2 — content survives sandbox-nuke Cleanup).
    local fc_listing
    fc_listing="$(emit_filecontents "${snapshot_dirs[@]}" 2>/dev/null || true)"
    if [[ -z "$path_listing" && -z "$fc_listing" ]]; then
      SANDBOX_STATE="    (no files found under sandbox dirs)"
    else
      SANDBOX_STATE="${path_listing}"
      if [[ -n "$fc_listing" ]]; then
        if [[ -n "$SANDBOX_STATE" ]]; then
          SANDBOX_STATE="${SANDBOX_STATE}"$'\n'"${fc_listing}"
        else
          SANDBOX_STATE="${fc_listing}"
        fi
      fi
    fi
  fi

  # --- Determine TIMEOUT verdict / scoring tier placeholder ---
  local VERDICT_TAG="OK"
  if [[ "$TIMED_OUT" -eq 1 ]]; then
    VERDICT_TAG="TIMEOUT"
  fi

  # --- Run Cleanup ---
  # IMPORTANT: snapshot above happens BEFORE this Cleanup — FILECONTENTS
  # is captured into a variable while the files still exist on disk. After
  # this point the sandbox dir may be `rm -rf`'d.
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
    # Use the candidate name if --candidate was given; falls back to model-tag.
    echo "- **Candidate**: \`${CANDIDATE_NAME:-$MODEL_TAG}\`"
    echo "- **CCR route**: \`${CCR_ROUTE:-<anthropic>}\`"
    echo "- **HF model**: \`${HF_MODEL:-<unknown>}\`"
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
