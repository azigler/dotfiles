#!/usr/bin/env bash
# claude/scripts/nightly-digest.sh
#
# Headless nightly digest of recent commits + open beads across active repos.
# POSTs directly to CCR (127.0.0.1:3456) so the work hits a local pico model
# (Qwen3-Coder via llama-swap) instead of the Anthropic API.
#
# Invoked by claude-nightly-digest.service (systemd user unit, daily 03:00).
# Safe to run manually:
#
#     bash claude/scripts/nightly-digest.sh
#
# Output: appended to ~/.local/share/claude-digests/YYYY-MM-DD.md
# On failure: appends a `-t note` bead to ~/dotfiles/.beads/ via `br create`.
#
# ---
#
# WHY curl-direct instead of `claude -p`:
#
# The spec (dotfiles-ukx.4 + dotfiles-ukx.6 §3.4) called for `claude -p` as
# the transport. Empirically validated 2026-05-26 that does not work:
#
#   1. `claude -p` defaults to `claude-opus-4-7`, which CCR routes to
#      Anthropic via the `default` route — defeating the whole point.
#   2. `claude --model haiku` is rejected by Claude Code's own client-side
#      model validation (the local CLI doesn't know haiku exists, even
#      though CCR would happily route it to background → pico-mlx).
#   3. CCR's `<CCR-SUBAGENT-MODEL>` per-request routing tag is parsed from
#      `body.system[1].text.startsWith(...)`, but `claude -p` hard-codes
#      `system[0]` (billing header) + `system[1]` (CC/SDK identifier) and
#      shoves any `--append-system-prompt` / `--system-prompt` content into
#      `system[2]`. The tag mechanism is unreachable from stock claude -p.
#
# CCR speaks Anthropic Messages API natively. Setting `"model":
# "claude-haiku-4-5-20251001"` in the POST body triggers CCR's `background`
# route → `pico-mlx,qwen3-coder` → local Qwen3 via llama-swap on :8090.
# Verified end-to-end: response.model = "mlx-community/Qwen3-Coder-..."
#
# If/when claude -p exposes a way to inject the SUBAGENT-MODEL tag at
# system[1], or accepts arbitrary --model strings to forward to CCR
# unmangled, this script can switch back. The prompt + routing intent
# remain unchanged.

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

# Resolve script dir → repo root (script lives at $REPO/claude/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROMPT_FILE="$REPO_ROOT/claude/prompts/nightly-digest.md"
DIGEST_DIR="${CLAUDE_DIGEST_DIR:-$HOME/.local/share/claude-digests}"
LOG_DIR="${CLAUDE_DIGEST_LOG_DIR:-$HOME/.local/share/claude-digests/logs}"

DATE="$(date -u +%F)"
DIGEST_FILE="$DIGEST_DIR/$DATE.md"
LOG_FILE="$LOG_DIR/$DATE.log"

# CCR endpoint. The default value is the localhost CCR daemon.
CCR_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:3456}"
# Token CCR forwards downstream; not used for local routes but must be set.
CCR_TOKEN="${ANTHROPIC_AUTH_TOKEN:-ccr-passthrough}"
# Model name that triggers CCR's `background` route. Override only if
# the operator's CCR config maps a different model to a local route.
CCR_BACKGROUND_MODEL="${CLAUDE_NIGHTLY_DIGEST_MODEL:-claude-haiku-4-5-20251001}"
# Cap output tokens — the digest is one-page, no need for more. Set high
# enough that finish_reason isn't "length" (which truncates mid-bullet),
# but low enough that Qwen3's prose-mode-collapse tendency (G13) is bounded.
CCR_MAX_TOKENS="${CLAUDE_NIGHTLY_DIGEST_MAX_TOKENS:-3000}"

# Repos to digest. Skipped silently if missing.
REPOS=(
  "$HOME/dotfiles"
  "$HOME/explore"
  "$HOME/explore/autonovel"
)

# Where to file the failure-bead. Hard-coded to dotfiles because that's where
# this script lives + where the operator looks for infra failures.
DOTFILES_BEADS_DB="$HOME/dotfiles/.beads/beads.db"

mkdir -p "$DIGEST_DIR" "$LOG_DIR"

# -----------------------------------------------------------------------------
# Failure handler — file a bead so silent breakage doesn't accumulate.
# Triggered by ERR trap (set -e) when any command in main() fails.
# -----------------------------------------------------------------------------

on_failure() {
  local exit_code=$?
  local lineno=$1
  local last_cmd="${BASH_COMMAND:-<unknown>}"

  {
    echo "----- nightly-digest FAILURE at $(date -u +%FT%TZ) -----"
    echo "exit_code=$exit_code lineno=$lineno"
    echo "last_command: $last_cmd"
    echo "CCR_URL=$CCR_URL"
    echo "CCR_BACKGROUND_MODEL=$CCR_BACKGROUND_MODEL"
  } >> "$LOG_FILE"

  # Bead filing is best-effort. If `br` itself is missing/broken, we still
  # want the systemd unit to exit non-zero so journalctl tells the operator.
  if command -v br >/dev/null 2>&1 && [[ -f "$DOTFILES_BEADS_DB" ]]; then
    local stderr_tail
    stderr_tail="$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo '(no log)')"

    local title="nightly-digest: failure on $DATE — see $LOG_FILE"
    # `--silent` makes `br create` print only the new ID, nothing else.
    # Best-effort: swallow errors from br itself.
    local new_id
    new_id="$(br --db "$DOTFILES_BEADS_DB" create -t note -p 3 --silent "$title" 2>>"$LOG_FILE" || true)"
    new_id="${new_id//[[:space:]]/}"
    if [[ -n "$new_id" ]]; then
      br --db "$DOTFILES_BEADS_DB" update "$new_id" --description "$(cat <<EOF
## Context
The systemd user unit \`claude-nightly-digest.service\` exited non-zero on $DATE.

- exit_code: $exit_code
- lineno: $lineno
- last_command: \`$last_cmd\`
- CCR_URL: $CCR_URL
- CCR_BACKGROUND_MODEL: $CCR_BACKGROUND_MODEL
- log: $LOG_FILE
- digest_file (may be empty/missing): $DIGEST_FILE

## Stderr tail (last 30 lines)
\`\`\`
$stderr_tail
\`\`\`

## Next
Check CCR daemon (\`curl -s $CCR_URL/health\`), pico tailnet,
and llama-swap on :8090. See ~/dotfiles/local-models/GUARDRAILS.md H1.
EOF
)" 2>>"$LOG_FILE" || true
    fi
  fi

  exit "$exit_code"
}

trap 'on_failure $LINENO' ERR

# -----------------------------------------------------------------------------
# Gather source data: git logs + open beads per repo.
# Each section is wrapped in a fenced block so the model can parse it
# unambiguously even when commits/beads contain backticks or hashes.
# -----------------------------------------------------------------------------

gather_input() {
  local repo
  echo "# Source data for $DATE"
  echo

  echo "## Git activity (last 24h)"
  for repo in "${REPOS[@]}"; do
    if [[ ! -d "$repo/.git" ]]; then
      continue
    fi
    local name
    name="$(basename "$repo")"
    echo
    echo "### $name (\`$repo\`)"
    echo '```'
    git -C "$repo" log --oneline --since="1 day ago" 2>/dev/null || echo "(git log failed)"
    echo '```'
  done

  echo
  echo "## Open beads (top 20 per repo)"
  for repo in "${REPOS[@]}"; do
    local db="$repo/.beads/beads.db"
    if [[ ! -f "$db" ]]; then
      continue
    fi
    local name
    name="$(basename "$repo")"
    echo
    echo "### $name beads (\`$db\`)"
    echo '```'
    br --db "$db" list --status open 2>/dev/null | head -n 20 || echo "(br list failed)"
    echo '```'
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "prompt file missing: $PROMPT_FILE" >&2
  exit 1
fi

# Compose: prompt template + gathered source data → single user message.
COMPOSED="$(mktemp)"
RESPONSE_FILE="$(mktemp)"
# shellcheck disable=SC2064  # we want the trap to expand vars NOW, not at exit
trap "rm -f '$COMPOSED' '$RESPONSE_FILE'" EXIT
{
  cat "$PROMPT_FILE"
  echo
  echo "---"
  echo
  gather_input
} > "$COMPOSED"

# Build JSON body. `jq -Rs .` reads stdin raw + slurps + JSON-encodes,
# which safely escapes newlines/quotes/backticks in the prompt + git
# output. The model name is what triggers CCR's `background` route.
REQUEST="$(jq -n \
  --arg model "$CCR_BACKGROUND_MODEL" \
  --argjson max_tokens "$CCR_MAX_TOKENS" \
  --rawfile content "$COMPOSED" \
  '{model: $model, max_tokens: $max_tokens,
    messages: [{role: "user", content: $content}]}')"

# POST to CCR. Anthropic Messages endpoint. `--fail-with-body` makes
# curl exit non-zero on 4xx/5xx so the ERR trap fires.
HTTP_STATUS="$(curl -sS --fail-with-body \
  -X POST "$CCR_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $CCR_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST" \
  -o "$RESPONSE_FILE" \
  -w '%{http_code}' 2>>"$LOG_FILE")"

echo "http_status=$HTTP_STATUS" >> "$LOG_FILE"

# CCR may return either shape depending on whether the upstream transformer
# fully wrapped the response back to Anthropic Messages format:
#   - Anthropic Messages: {"content": [{"type":"text","text":"..."}], ...}
#   - OpenAI Chat (raw upstream passthrough): {"choices":[{"message":{"content":"..."}}]}
# Empirically (2026-05-26) CCR's `transformer: ["Anthropic"]` config returns
# the OpenAI shape on direct curl POSTs — likely because the transformer
# only kicks in when the request originated from an Anthropic client.
# Handle both for robustness.
RESPONSE_TEXT="$(jq -r '
  if (.content | type) == "array" then
    (.content | map(select(.type == "text") | .text) | join("\n"))
  elif (.choices | type) == "array" and (.choices | length) > 0 then
    (.choices[0].message.content // "")
  elif .error.message then
    "ERROR: " + .error.message
  else
    ""
  end' "$RESPONSE_FILE" 2>>"$LOG_FILE")"

# Capture the served model so we can prove local routing.
SERVED_MODEL="$(jq -r '.model // "unknown"' "$RESPONSE_FILE" 2>/dev/null || echo unknown)"
echo "served_model=$SERVED_MODEL" >> "$LOG_FILE"

if [[ -z "${RESPONSE_TEXT//[[:space:]]/}" ]]; then
  echo "empty response from CCR; raw body:" >> "$LOG_FILE"
  head -c 4000 "$RESPONSE_FILE" >> "$LOG_FILE"
  exit 2
fi

# Append (don't overwrite) so multi-run-per-day preserves history.
{
  echo
  echo "<!-- run: $(date -u +%FT%TZ) ccr=$CCR_URL served_model=$SERVED_MODEL -->"
  echo "$RESPONSE_TEXT"
} >> "$DIGEST_FILE"

echo "wrote digest: $DIGEST_FILE (model=$SERVED_MODEL)" >> "$LOG_FILE"
