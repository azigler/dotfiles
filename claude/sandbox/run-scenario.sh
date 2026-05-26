#!/usr/bin/env bash
#
# run-scenario.sh — execute one sandbox scenario against opus or local.
#
# Usage:
#   ./run-scenario.sh scenarios/01-trivial-rename.md opus
#   ./run-scenario.sh scenarios/01-trivial-rename.md local
#
# Parses the scenario file (5-section markdown — see scenarios/01-*.md for
# the schema). Runs Setup → captures `claude -p < prompt` for the chosen
# backend → runs Cleanup → writes a results markdown to results/.
#
# Backends:
#   opus  = the real Anthropic Opus model (uses normal claude CLI)
#   local = pico-mlx,qwen3-coder via CCR + llama-swap (uses ./claude-local)
#
# Refs:
#   - Sibling: ./claude-local (wrapper that injects CCR routing tag)
#   - Bead: dotfiles-ukx.3
#
set -euo pipefail

# --- Args ---
if [[ $# -lt 2 ]]; then
  echo "usage: $0 <scenario-file> <opus|local>" >&2
  exit 1
fi

SCENARIO_FILE="$1"
MODEL_TAG="$2"

if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "error: scenario file not found: $SCENARIO_FILE" >&2
  exit 1
fi

if [[ "$MODEL_TAG" != "opus" && "$MODEL_TAG" != "local" ]]; then
  echo "error: model tag must be 'opus' or 'local', got: $MODEL_TAG" >&2
  exit 1
fi

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

SCENARIO_BASENAME="$(basename "$SCENARIO_FILE" .md)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_FILE="$RESULTS_DIR/${SCENARIO_BASENAME}-${MODEL_TAG}-${TIMESTAMP}.md"

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

# --- Run Setup ---
echo "==> [$SCENARIO_BASENAME / $MODEL_TAG] running Setup..." >&2
if [[ -n "$SETUP_CODE" ]]; then
  bash -c "$SETUP_CODE"
fi

# --- Pick the claude command ---
case "$MODEL_TAG" in
  opus)
    CLAUDE_CMD=(claude --model claude-opus-4-7 -p --permission-mode bypassPermissions)
    ;;
  local)
    CLAUDE_CMD=("$SCRIPT_DIR/claude-local" -p --permission-mode bypassPermissions)
    ;;
esac

# --- Run the prompt against the chosen backend ---
echo "==> [$SCENARIO_BASENAME / $MODEL_TAG] invoking claude..." >&2
START_TS="$(date +%s)"
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Capture stdout + stderr; don't fail on non-zero exit (some scenarios may
# legitimately have the model exit non-zero, or `claude` itself may exit
# non-zero on edge cases). Record the exit code.
set +e
CLAUDE_OUTPUT="$(printf '%s\n' "$PROMPT_TEXT" | "${CLAUDE_CMD[@]}" 2>&1)"
EXIT_CODE=$?
set -e

END_TS="$(date +%s)"
WALL_SECONDS=$((END_TS - START_TS))

# --- Extract model identity from output (best-effort) ---
# Claude's `-p` output is just the text response; model info isn't echoed
# inline. For local runs, the routing PROOF lives in CCR's log — pull the
# most recent entry that references our request.
MODEL_FIELD="(not extracted from -p text output)"
if [[ "$MODEL_TAG" == "local" ]]; then
  # CCR rotates per-session logs into ~/.claude-code-router/logs/ccr-*.log
  # (and also has a legacy single-file ~/.claude-code-router/claude-code-router.log).
  # Find whichever is most recent.
  CCR_LOG=""
  if compgen -G "${HOME}/.claude-code-router/logs/ccr-*.log" > /dev/null; then
    # Pick the most-recently-modified log file. find+sort handles odd filenames better than ls.
    CCR_LOG="$(find "${HOME}/.claude-code-router/logs/" -maxdepth 1 -name 'ccr-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
  elif [[ -f "${HOME}/.claude-code-router/claude-code-router.log" ]]; then
    CCR_LOG="${HOME}/.claude-code-router/claude-code-router.log"
  fi

  if [[ -n "$CCR_LOG" && -f "$CCR_LOG" ]]; then
    # Grab the most recent log lines mentioning routing decisions, then
    # extract just the human-readable "msg" field via python+json so the
    # result file stays under a few KB. CCR logs are huge structured JSON.
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

# --- Capture final cwd state (which files exist / were modified) ---
SANDBOX_ROOT="${SANDBOX:-/tmp/claude-local-test}"
SANDBOX_STATE="(no sandbox dir found at $SANDBOX_ROOT)"
if [[ -d "$SANDBOX_ROOT" ]]; then
  # find | head can trigger SIGPIPE 141 under `set -e` when head closes
  # stdin. Defang with `|| true` on each stage and rely on awk for the
  # cap to avoid SIGPIPE entirely.
  SANDBOX_STATE="$(find "$SANDBOX_ROOT" -type f 2>/dev/null | awk 'NR<=20 {print "    "$0}' || true)"
  if [[ -z "$SANDBOX_STATE" ]]; then
    SANDBOX_STATE="    (no files found under $SANDBOX_ROOT)"
  fi
fi

# --- Run Cleanup ---
echo "==> [$SCENARIO_BASENAME / $MODEL_TAG] running Cleanup..." >&2
if [[ -n "$CLEANUP_CODE" ]]; then
  bash -c "$CLEANUP_CODE" || true
fi

# --- Write result ---
{
  echo "# Scenario result: $SCENARIO_BASENAME ($MODEL_TAG)"
  echo
  echo "- **Scenario file**: \`$SCENARIO_FILE\`"
  echo "- **Model tag**: \`$MODEL_TAG\`"
  echo "- **Started**: $START_ISO"
  echo "- **Wall time**: ${WALL_SECONDS}s"
  echo "- **claude exit code**: $EXIT_CODE"
  echo "- **Result file**: \`$RESULT_FILE\`"
  echo
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
} > "$RESULT_FILE"

echo "==> result written: $RESULT_FILE" >&2
echo "$RESULT_FILE"
