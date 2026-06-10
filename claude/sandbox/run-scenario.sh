#!/usr/bin/env bash
#
# run-scenario.sh — execute one sandbox scenario against a serving.conf
# candidate via Claude Code NATIVE serving (round 2 — CCR chain dropped).
#
# Usage:
#   ./run-scenario.sh <scenario-file> <candidate> [options]
#   ./run-scenario.sh <scenario-file> --candidate <name> [options]
#
# Options:
#   --candidate NAME     Candidate name — must match a `model` field in
#                        serving.conf (env SERVING_CONF overrides path;
#                        default ../../local-models/serving.conf).
#   --dry-run-routing    Print the resolved serving entry + the FULL claude
#                        invocation (env pins + flags) and exit 0. No Setup,
#                        no claude run, no Cleanup, no ssh.
#   --trials N           Run the scenario N times (default 1). One result
#                        file is written per trial.
#   --timeout SECONDS    Per-trial wall cap (SECONDS). On cap fire the trial
#                        is killed; verdict is decided by ARTIFACT state
#                        (TIMEOUT_SUCCESS if the sandbox matches the
#                        scenario's Expected artifacts; TIMEOUT otherwise).
#                        NOTE: bench-matrix.sh exposes --timeout in MINUTES
#                        and converts on passthrough.
#   --quiet              Suppress live progress chatter on stderr; only
#                        print the result-file path on stdout per trial.
#   --results-dir DIR    Override the default results dir
#                        (claude/sandbox/results/).
#
# Invocation shape (verified live 2026-06-10, refs/eval-round-2-manifest.md
# in ~/explore/local-coding-models):
#
#   env -u ANTHROPIC_API_KEY \
#       ANTHROPIC_BASE_URL=<serving.conf base_url> \
#       ANTHROPIC_AUTH_TOKEN=bench-local \
#       ANTHROPIC_MODEL=<candidate> \
#       ANTHROPIC_DEFAULT_HAIKU_MODEL=<candidate> \
#       CLAUDE_CODE_SUBAGENT_MODEL=<candidate> \
#       claude -p --model <candidate> --output-format json --bare \
#              --allowedTools "<scenario tools>"
#
#   - --bare is MANDATORY: default system prompt is ~25.9k tokens → 184s
#     prefill/turn on a 30b local model; --bare cuts it to ~1.2k tokens.
#   - --allowedTools filters PERMISSION, not the offered roster.
#   - The JSON output's modelUsage keys verify which model actually served
#     (per-trial routing check — postmortem failure mode #2). A mismatch
#     tags the trial INVALID_ROUTING and exits 7 so bench-matrix aborts the
#     cohort.
#
# Scenario file schema (5 sections + 2 optional):
#   ## Setup / ## Prompt / ## Pass criteria / ## Cleanup / ## Notes
#   ## Expected artifacts (OPTIONAL, bash block) — assertions on sandbox
#      state run AFTER the claude run and BEFORE Cleanup. Exit 0 = the
#      expected artifacts exist. Gets $SANDBOX and $TRIAL_OUTPUT_FILE (path
#      to the model's extracted result text) in its env. THE PRIMARY
#      VERDICT EVIDENCE (postmortem #7 / bead e21): artifacts are compared
#      BEFORE exit codes are consulted.
#   ## Tools (OPTIONAL) — first non-empty line is the --allowedTools value.
#      Default: Bash,Edit,Read,Write
#
# Verdicts (verdict_tag / verdict_evidence in the result file):
#   OK              artifact-match                artifacts match, no timeout
#   TIMEOUT_SUCCESS artifact-match-after-timeout  wall cap hit, artifacts match
#   TIMEOUT         artifact-mismatch OR exit-code-only  cap hit, no match
#   ARTIFACT_FAIL   artifact-mismatch             run finished, no match
#   INVALID_ROUTING routing-mismatch              wrong model served (exit 7)
#   OK (legacy)     exit-code-only                scenario lacks an Expected
#                                                 artifacts section
#
# Exit codes: 0 = trials ran (per-trial failures live in the result files;
# the matrix decides), 1 = usage / scenario error, 7 = routing mismatch
# (cohort must abort).
#
# Smoke run (no pico needed):
#   ./run-scenario.sh scenarios/01-trivial-rename.md opus --dry-run-routing
#
# Spec: local-coding-models-517; Bead: dotfiles-6go
#
set -uo pipefail
# NOTE: we deliberately drop -e so a single failed trial inside the loop
# doesn't abort subsequent trials.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Serving registry (single source of truth: serving.conf) ---
SERVING_CONF="${SERVING_CONF:-$SCRIPT_DIR/../../local-models/serving.conf}"

# resolve_serving <name> — echoes the full conf line for the candidate.
# Returns 0 on hit, 1 on miss.
resolve_serving() {
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

print_unknown_candidate_help() {
  local name="$1" line
  echo "error: unknown candidate: $name" >&2
  echo "       active candidates in $SERVING_CONF:" >&2
  if [[ -f "$SERVING_CONF" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line//[[:space:]]/}" ]] && continue
      echo "         - ${line%%|*}" >&2
    done < "$SERVING_CONF"
  else
    echo "         (serving.conf not found at $SERVING_CONF)" >&2
  fi
}

# --- Arg parsing ---
TRIALS=1
TIMEOUT_SECONDS=""    # empty = no cap
QUIET=0
RESULTS_DIR_OVERRIDE=""
CANDIDATE_NAME=""
DRY_RUN_ROUTING=0
# Per-file FILECONTENTS size cap (bytes) — see emit_filecontents.
FILECONTENTS_CAP_BYTES=${FILECONTENTS_CAP_BYTES:-51200}

usage() {
  cat >&2 <<USAGE
usage:
  $0 <scenario-file> <candidate> [options]
  $0 <scenario-file> --candidate <name> [options]

Options:
  --candidate NAME        Candidate name from serving.conf.
  --dry-run-routing       Print resolved serving entry + claude invocation, exit 0.
  --trials N              Run scenario N times (default 1).
  --timeout SECONDS       Per-trial wall cap in SECONDS (default: unbounded).
  --quiet                 Suppress live stderr chatter.
  --results-dir DIR       Override results dir.
USAGE
}

# Early help-check: -h / --help must fire BEFORE arg-count validation.
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

# The second positional arg may be a candidate name (bench-matrix sends it
# positionally for stub-compat AND as --candidate).
POSITIONAL_CAND=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  POSITIONAL_CAND="$1"
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

# --candidate wins over positional; warn if they differ (operator typo).
if [[ -n "$CANDIDATE_NAME" ]]; then
  if [[ -n "$POSITIONAL_CAND" && "$POSITIONAL_CAND" != "$CANDIDATE_NAME" ]]; then
    echo "warning: positional '$POSITIONAL_CAND' differs from --candidate '$CANDIDATE_NAME'; --candidate wins" >&2
  fi
elif [[ -n "$POSITIONAL_CAND" ]]; then
  CANDIDATE_NAME="$POSITIONAL_CAND"
else
  echo "error: missing candidate — pass it positionally or via --candidate <name>" >&2
  usage
  exit 1
fi

if ! serving_line="$(resolve_serving "$CANDIDATE_NAME")"; then
  print_unknown_candidate_help "$CANDIDATE_NAME"
  exit 1
fi
IFS='|' read -r _ SERVER BASE_URL _LAUNCH _STOP BLOB <<< "$serving_line"

# --- Validate scenario file ---
if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "error: scenario file not found: $SCENARIO_FILE" >&2
  exit 1
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
  echo "error: --trials must be a positive integer, got: $TRIALS" >&2
  exit 1
fi

# --- Parse scenario sections ---
# A scenario file has ## Setup / ## Prompt / ## Pass criteria / ## Cleanup
# / ## Notes (+ optional ## Expected artifacts / ## Tools). Each section
# runs to the next ## or EOF.
extract_section() {
  local file="$1"
  local section="$2"
  awk -v section="## $section" '
    $0 == section { capture = 1; next }
    /^## / && capture { capture = 0 }
    capture { print }
  ' "$file"
}

# Setup / Cleanup / Expected artifacts are wrapped in ```bash fences.
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
EXPECTED_CODE="$(extract_section "$SCENARIO_FILE" "Expected artifacts" | extract_bash_block)"
DEFAULT_ALLOWED_TOOLS="Bash,Edit,Read,Write"
ALLOWED_TOOLS="$(extract_section "$SCENARIO_FILE" "Tools" | grep -v '^[[:space:]]*$' | head -1 || true)"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-$DEFAULT_ALLOWED_TOOLS}"

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "error: could not extract Prompt section from $SCENARIO_FILE" >&2
  exit 1
fi

# --- Build the claude command (CC-native serving; no CCR anywhere) ---
# Array form so --dry-run-routing prints EXACTLY what would exec.
if [[ "$SERVER" == "anthropic" ]]; then
  # Baseline: real Anthropic API, normal credentials, opus model.
  CLAUDE_CMD=(claude -p --model claude-opus-4-7 --output-format json --bare
              --allowedTools "$ALLOWED_TOOLS")
  EXPECTED_MODEL_SUBSTR="opus"   # modelUsage keys carry versioned ids
else
  CLAUDE_CMD=(env -u ANTHROPIC_API_KEY
              "ANTHROPIC_BASE_URL=$BASE_URL"
              "ANTHROPIC_AUTH_TOKEN=bench-local"
              "ANTHROPIC_MODEL=$CANDIDATE_NAME"
              "ANTHROPIC_DEFAULT_HAIKU_MODEL=$CANDIDATE_NAME"
              "CLAUDE_CODE_SUBAGENT_MODEL=$CANDIDATE_NAME"
              claude -p --model "$CANDIDATE_NAME" --output-format json --bare
              --allowedTools "$ALLOWED_TOOLS")
  EXPECTED_MODEL_SUBSTR="$CANDIDATE_NAME"   # exact-match for local serving
fi

# --- --dry-run-routing: print serving entry + invocation, exit 0 ---
if [[ "$DRY_RUN_ROUTING" -eq 1 ]]; then
  echo "candidate:     $CANDIDATE_NAME"
  echo "server:        $SERVER"
  echo "base-url:      ${BASE_URL:-<anthropic default>}"
  echo "blob:          ${BLOB:-<n/a>}"
  echo "allowed-tools: $ALLOWED_TOOLS"
  echo "serving-conf:  $SERVING_CONF"
  printf 'claude-cmd:   '
  printf ' %q' "${CLAUDE_CMD[@]}"
  printf '\n'
  exit 0
fi

# --- Paths ---
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

# Extract sandbox subdirs from Setup's `mkdir -p ...` lines so we can
# defensively rm -rf them before each trial (OQ-07 — prevents N-trial
# cross-contamination).
extract_sandbox_dirs() {
  echo "$SETUP_CODE" \
    | grep -E '^\s*mkdir\s+-p' \
    | sed -E 's/^\s*mkdir\s+-p\s+//' \
    | while IFS= read -r line; do
        line="${line%%#*}"
        bash -c "printf '%s\n' $line" 2>/dev/null || true
      done
}

# --- FILECONTENTS emission helper ---
# Emits `FILECONTENTS:<path>:<body>` lines for each file under the given
# dirs (analyze-bench contract). Skips binaries (NUL in first 8KB) and
# emits truncation markers for files over FILECONTENTS_CAP_BYTES.
# NOTE: uses `declare -A` (bash 4+); shebang is env-bash so Homebrew bash
# is picked up on macOS.
emit_filecontents() {
  local d f size
  local -A seen=()
  for d in "$@"; do
    [[ -z "$d" ]] && continue
    [[ ! -d "$d" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -n "${seen[$f]:-}" ]] && continue
      seen[$f]=1
      [[ ! -f "$f" ]] && continue
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

  local TIMESTAMP RESULT_FILE
  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  RESULT_FILE="$RESULTS_DIR/${SCENARIO_BASENAME}-${CANDIDATE_NAME}-trial${trial_num}-${TIMESTAMP}.md"

  # --- Defensive pre-Setup rm -rf (OQ-07) ---
  local dirs d
  dirs="$(extract_sandbox_dirs)"
  if [[ -n "$dirs" ]]; then
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      [[ "$d" == "/" || "$d" == "$HOME" || "$d" == "$HOME/" ]] && continue
      case "$d" in
        /tmp/*|/var/tmp/*|/private/tmp/*)
          rm -rf -- "$d" 2>/dev/null || true
          ;;
        *)
          # Outside /tmp — skip to be safe.
          ;;
      esac
    done <<< "$dirs"
  fi

  # --- Run Setup ---
  log "==> [$SCENARIO_BASENAME / $CANDIDATE_NAME / trial $trial_num] running Setup..."
  if [[ -n "$SETUP_CODE" ]]; then
    bash -c "$SETUP_CODE" || true
  fi

  # --- Run the prompt against the candidate (CC-native) ---
  log "==> [$SCENARIO_BASENAME / $CANDIDATE_NAME / trial $trial_num] invoking claude ($SERVER @ ${BASE_URL:-anthropic})..."
  local START_TS START_ISO END_TS WALL_SECONDS EXIT_CODE CLAUDE_OUTPUT TIMED_OUT
  START_TS="$(date +%s)"
  START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  TIMED_OUT=0

  if [[ -n "$TIMEOUT_SECONDS" ]]; then
    CLAUDE_OUTPUT="$(printf '%s\n' "$PROMPT_TEXT" \
      | timeout --kill-after=5s "${TIMEOUT_SECONDS}s" \
        "${CLAUDE_CMD[@]}" 2>&1)"
    EXIT_CODE=$?
    # GNU timeout: 124 TERM / 137 KILL-escalated; uutils: 125 with
    # --kill-after; 143 = 128+SIGTERM can leak through pipes.
    if [[ "$EXIT_CODE" -eq 124 || "$EXIT_CODE" -eq 125 || "$EXIT_CODE" -eq 137 || "$EXIT_CODE" -eq 143 ]]; then
      TIMED_OUT=1
    fi
  else
    CLAUDE_OUTPUT="$(printf '%s\n' "$PROMPT_TEXT" | "${CLAUDE_CMD[@]}" 2>&1)"
    EXIT_CODE=$?
  fi

  END_TS="$(date +%s)"
  WALL_SECONDS=$((END_TS - START_TS))

  # --- Parse the CC JSON envelope (result text, turns, modelUsage) ---
  local TMP_JSON TMP_RESULT_TEXT CC_PARSE CC_NUM_TURNS CC_DURATION_MS CC_MODELS CC_IS_ERROR
  TMP_JSON="$(mktemp /tmp/bench-rs-json.XXXXXX)"
  TMP_RESULT_TEXT="$(mktemp /tmp/bench-rs-result.XXXXXX)"
  printf '%s' "$CLAUDE_OUTPUT" > "$TMP_JSON"
  CC_PARSE="fail"; CC_NUM_TURNS=""; CC_DURATION_MS=""; CC_MODELS=""; CC_IS_ERROR=""
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PARSE)       CC_PARSE="$v" ;;
      NUM_TURNS)   CC_NUM_TURNS="$v" ;;
      DURATION_MS) CC_DURATION_MS="$v" ;;
      MODELS)      CC_MODELS="$v" ;;
      IS_ERROR)    CC_IS_ERROR="$v" ;;
    esac
  done < <(python3 - "$TMP_JSON" "$TMP_RESULT_TEXT" <<'PYEOF'
import json
import sys

p_json, p_out = sys.argv[1], sys.argv[2]
try:
    with open(p_json) as fh:
        d = json.load(fh)
except Exception:
    print("PARSE=fail")
    sys.exit(0)
result = d.get("result") or ""
with open(p_out, "w") as fh:
    fh.write(result)
models = ",".join((d.get("modelUsage") or {}).keys())
print("PARSE=ok")
print(f"NUM_TURNS={d.get('num_turns', '')}")
print(f"DURATION_MS={d.get('duration_ms', '')}")
print(f"MODELS={models}")
print(f"IS_ERROR={d.get('is_error', '')}")
PYEOF
)
  # On parse failure (timeout kill mid-stream, hard CLI error) the raw
  # output IS the best "result text" we have for output-dependent checks.
  if [[ "$CC_PARSE" != "ok" ]]; then
    printf '%s' "$CLAUDE_OUTPUT" > "$TMP_RESULT_TEXT"
  fi

  # --- Routing verification (postmortem #2; mismatch = INVALID + abort) ---
  # modelUsage keys must name the intended candidate. Unverifiable (no JSON,
  # e.g. timeout kill) is NOT a mismatch — the artifact verdict decides.
  local ROUTING_STATUS="unverifiable"
  if [[ "$CC_PARSE" == "ok" && -n "$CC_MODELS" ]]; then
    ROUTING_STATUS="mismatch"
    local m
    IFS=',' read -ra _mu <<< "$CC_MODELS"
    for m in "${_mu[@]}"; do
      if [[ "$SERVER" == "anthropic" ]]; then
        [[ "$m" == *"$EXPECTED_MODEL_SUBSTR"* ]] && ROUTING_STATUS="ok"
      else
        [[ "$m" == "$EXPECTED_MODEL_SUBSTR" ]] && ROUTING_STATUS="ok"
      fi
    done
  fi

  # --- Artifact check (PRIMARY verdict evidence — postmortem #7 / e21) ---
  # Runs BEFORE Cleanup and BEFORE exit codes are consulted.
  local ARTIFACT_STATUS="no-spec"
  if [[ -n "$EXPECTED_CODE" ]]; then
    if SANDBOX="${SANDBOX:-/tmp/claude-local-test}" \
       TRIAL_OUTPUT_FILE="$TMP_RESULT_TEXT" \
       bash -c "$EXPECTED_CODE" >/dev/null 2>&1; then
      ARTIFACT_STATUS="match"
    else
      ARTIFACT_STATUS="mismatch"
    fi
  fi

  # --- Verdict (artifact-first; exit code is secondary evidence) ---
  local VERDICT_TAG VERDICT_EVIDENCE
  if [[ "$ROUTING_STATUS" == "mismatch" ]]; then
    VERDICT_TAG="INVALID_ROUTING"
    VERDICT_EVIDENCE="routing-mismatch"
  elif [[ "$ARTIFACT_STATUS" == "match" ]]; then
    if [[ "$TIMED_OUT" -eq 1 ]]; then
      VERDICT_TAG="TIMEOUT_SUCCESS"
      VERDICT_EVIDENCE="artifact-match-after-timeout"
    else
      VERDICT_TAG="OK"
      VERDICT_EVIDENCE="artifact-match"
    fi
  elif [[ "$ARTIFACT_STATUS" == "mismatch" ]]; then
    if [[ "$TIMED_OUT" -eq 1 ]]; then
      VERDICT_TAG="TIMEOUT"
    else
      VERDICT_TAG="ARTIFACT_FAIL"
    fi
    VERDICT_EVIDENCE="artifact-mismatch"
  else
    # Legacy scenario without an Expected artifacts section.
    if [[ "$TIMED_OUT" -eq 1 ]]; then
      VERDICT_TAG="TIMEOUT"
    else
      VERDICT_TAG="OK"
    fi
    VERDICT_EVIDENCE="exit-code-only"
  fi

  # --- Capture final sandbox state (path list + FILECONTENTS) ---
  local SANDBOX_ROOT SANDBOX_STATE
  SANDBOX_ROOT="${SANDBOX:-/tmp/claude-local-test}"
  SANDBOX_STATE="(no sandbox dir found at $SANDBOX_ROOT)"
  local -a snapshot_dirs=()
  if [[ -d "$SANDBOX_ROOT" ]]; then
    snapshot_dirs+=("$SANDBOX_ROOT")
  fi
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    [[ -d "$d" ]] && snapshot_dirs+=("$d")
  done <<< "$(extract_sandbox_dirs)"

  if [[ "${#snapshot_dirs[@]}" -gt 0 ]]; then
    local path_listing fc_listing
    path_listing="$(find "${snapshot_dirs[@]}" -type f 2>/dev/null | awk 'NR<=20 {print "    "$0}' || true)"
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

  # --- Run Cleanup ---
  # Snapshot + artifact check above happen BEFORE this — evidence is
  # captured while the files still exist on disk.
  log "==> [$SCENARIO_BASENAME / $CANDIDATE_NAME / trial $trial_num] running Cleanup..."
  if [[ -n "$CLEANUP_CODE" ]]; then
    bash -c "$CLEANUP_CODE" || true
  fi

  # --- Write result ---
  local RESULT_TEXT
  RESULT_TEXT="$(cat "$TMP_RESULT_TEXT" 2>/dev/null || true)"
  {
    echo "# Scenario result: $SCENARIO_BASENAME ($CANDIDATE_NAME) trial $trial_num"
    echo
    echo "- **Scenario file**: \`$SCENARIO_FILE\`"
    echo "- **Candidate**: \`$CANDIDATE_NAME\`"
    echo "- **Server**: \`$SERVER\`"
    echo "- **Base URL**: \`${BASE_URL:-<anthropic default>}\`"
    echo "- **Allowed tools**: \`$ALLOWED_TOOLS\`"
    echo "- **Trial**: $trial_num"
    echo "- **Started**: $START_ISO"
    echo "- **Wall time**: ${WALL_SECONDS}s"
    echo "- **wall_cap_seconds**: ${TIMEOUT_SECONDS:-unbounded}"
    echo "- **cold_load_trial**: $is_cold_load"
    echo "- **scoring_tier**: 1"
    echo "- **claude exit code**: $EXIT_CODE"
    echo "- **num_turns**: ${CC_NUM_TURNS:-n/a}"
    echo "- **duration_ms**: ${CC_DURATION_MS:-n/a}"
    echo "- **is_error**: ${CC_IS_ERROR:-n/a}"
    echo "- **routing_status**: $ROUTING_STATUS"
    echo "- **artifact_status**: $ARTIFACT_STATUS"
    echo "- **verdict_tag**: $VERDICT_TAG"
    echo "- **verdict_evidence**: $VERDICT_EVIDENCE"
    echo "- **Result file**: \`$RESULT_FILE\`"
    echo
    if [[ "$TIMED_OUT" -eq 1 ]]; then
      echo "> NOTE: trial killed by --timeout (exceeded wall cap of ${TIMEOUT_SECONDS}s); verdict decided by artifact state, not the kill."
      echo
    fi
    echo "## Model routing evidence"
    echo
    echo "- expected: \`$EXPECTED_MODEL_SUBSTR\` ($SERVER)"
    echo "- modelUsage keys: \`${CC_MODELS:-<none — CC JSON unparseable>}\`"
    echo "- routing_status: $ROUTING_STATUS"
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
    echo "$RESULT_TEXT"
    echo '```'
    echo
    echo "## Raw CC JSON"
    echo
    echo '```'
    echo "$CLAUDE_OUTPUT"
    echo '```'
  } > "$RESULT_FILE"

  rm -f "$TMP_JSON" "$TMP_RESULT_TEXT"

  log "==> result written: $RESULT_FILE (verdict=$VERDICT_TAG, evidence=$VERDICT_EVIDENCE)"
  # Always print result file path on stdout (machine-readable handoff).
  echo "$RESULT_FILE"

  if [[ "$VERDICT_TAG" == "INVALID_ROUTING" ]]; then
    echo "error: routing mismatch — expected '$EXPECTED_MODEL_SUBSTR', modelUsage was '${CC_MODELS}'. Trial INVALID; cohort must abort." >&2
    return 7
  fi
  return 0
}

# Iterate trials. Trial 1 is cold-load; trials 2..N are warm.
for t in $(seq 1 "$TRIALS"); do
  if [[ "$t" -eq 1 ]]; then
    cold="true"
  else
    cold="false"
  fi
  run_one_trial "$t" "$cold"
  rc=$?
  if [[ "$rc" -eq 7 ]]; then
    # Routing mismatch: every subsequent trial would hit the same misroute.
    # Stop immediately and propagate so bench-matrix aborts the cohort.
    exit 7
  fi
done

# Exit 0 — per-trial verdicts live in the result files; the matrix's
# cohort gates (success floor + analyze-variance --strict) decide.
exit 0
