#!/bin/bash
# PreToolUse (Bash): guards on bead-lifecycle commands.
#
#   1. Worktree guard — when cwd is inside .claude/worktrees/agent-*,
#      block `br close` and `br update --status`. Bead lifecycle is
#      orchestrator-only; the .beads/ symlink makes a stray subagent
#      close mutate the orchestrator's shared state immediately.
#      `br update --notes` stays allowed — /beads lets subagents log
#      investigation notes.
#   2. Lint gate — `br close` is blocked if the bead's template lints
#      fail (description mandatory).
#   3. Scrutiny gate — closing a `-t impl` bead is blocked unless a
#      SHIP (or OVERRIDE) scrutiny verdict is recorded in its --notes.
#
# Exit 2 = block the call and feed errors to the agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# --- 1. Worktree guard ---------------------------------------------------
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+(close|update)([[:space:]]|$)'; then
  JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$JSON_CWD" ]; then
    CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
    [ -z "$CWD" ] && CWD="$JSON_CWD"
  else
    CWD=$(pwd -P)
  fi
  case "$CWD" in
    */.claude/worktrees/agent-*)
      if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+close([[:space:]]|$)' \
         || echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+update[[:space:]].*--status'; then
        cat >&2 <<'EOF'
Blocked: `br close` / `br update --status` from inside a worktree.

Bead lifecycle is orchestrator-only and runs from the project root.
- Subagent: don't — reference `Bead: <id>` in your commit trailer; the
  orchestrator closes the bead after merging your worktree.
- Orchestrator: your cwd has drifted into a worktree. `cd` back to the
  project root, then close. See /orchestrator, /beads.
EOF
        exit 2
      fi
      ;;
  esac
fi

# --- 2 + 3. br close: lint gate + scrutiny gate --------------------------
case "$COMMAND" in
  br\ close*|*"&& br close"*|*"; br close"*) ;;
  *) exit 0 ;;
esac

command -v br &>/dev/null || exit 0

# Extract bead IDs from `br close <id> [<id> ...]`, stopping at the first
# &&, ;, or | so chained commands don't leak in — AND at the first flag
# (-r/--reason etc.), so hyphenated words or filenames inside the reason
# string don't get scraped as bead IDs (dotfiles-c7j: "fleet-wide" in a
# close reason false-positive blocked the close 3x).
# The awk stops at the first flag PER `br close` segment, so chained
# closes (`br close a -r "..." && br close b`) still lint every segment.
# Scrape `br close` IDs only from the part of the command BEFORE any
# `git commit` — a commit message can legitimately contain the literal
# text "br close <x>" (e.g. describing this very hook), and that prose
# must not be mis-scraped as bead IDs (it false-blocked a commit whose
# message described the && fix — caught live, dotfiles-ocy). Convention
# is close-before-commit, so the real `br close` precedes `git commit`.
SCAN="${COMMAND%%git commit*}"
BEAD_IDS=$(echo "$SCAN" | grep -oE 'br close [^&;|]+' | sed 's/^br close //' \
  | awk '{for(i=1;i<=NF;i++){if($i ~ /^-/) break; print $i}}' \
  | grep -E '^[a-z0-9]+-[a-z0-9.]+$')

[ -z "$BEAD_IDS" ] && exit 0

# If the command chains `cd <path>` before `br close`, follow it so br
# runs against the same beads store the command will target (bd-8euh).
TARGET_CWD=$(echo "$COMMAND" | grep -oE '(^|[;&] *)cd +[^&;|]+' | head -1 | sed -E 's/^.*cd +//' | tr -d ' ')
TARGET_CWD="${TARGET_CWD/#\~/$HOME}"
if [ -n "$TARGET_CWD" ] && [ -d "$TARGET_CWD" ]; then
  cd "$TARGET_CWD" || true
fi

set +e
FAILED=0
for ID in $BEAD_IDS; do
  # The && trap: when the SAME command chains `br update <ID> --description
  # /--acceptance-criteria/--design` before `br close <ID>`, the template is
  # being set in this very command — but PreToolUse fires BEFORE the update
  # runs, so `br lint` sees the pre-update state and false-blocks. Skip the
  # lint gate for a bead whose template is set by a chained update here, so
  # `br update X --description "...## Acceptance Criteria..." && br close X`
  # works without splitting into two commands (dotfiles-90s clunk audit).
  # Lint gate: template sections must be present — UNLESS a chained update
  # in this same command is setting them (skip avoids the false-block).
  if echo "$COMMAND" | grep -qE "br update +$ID[[:space:]].*(--description|--acceptance-criteria|--design)"; then
    : # chained `br update <ID> --description/...` sets the template; skip lint
  else
    OUTPUT=$(br lint "$ID" 2>&1)
    LINT_RC=$?
    if [ $LINT_RC -ne 0 ] && [ -n "$OUTPUT" ]; then
    echo "Blocked: bead $ID has incomplete template sections." >&2
    echo "$OUTPUT" >&2
    echo "" >&2
    echo "Fix the bead via 'br update $ID --description ...' (or --acceptance-criteria, --design)" >&2
    echo "before closing. See /beads SKILL." >&2
    FAILED=1
    fi
  fi

  # Scrutiny gate: an -t impl bead closes only after /scrutinize SHIPs.
  # Accept either (a) an anchored "Verdict: SHIP|OVERRIDE" line (the
  # recorded format under a "## Scrutiny" header) or (b) the verdict
  # directly after the scrutiny marker ("## Scrutiny — OVERRIDE: ...").
  # Two independent greps over the whole bead used to let prose like
  # "needs scrutiny before we SHIP" pass the gate with no verdict
  # recorded (fixed 2026-06-09).
  SHOW=$(br show "$ID" 2>/dev/null)
  if echo "$SHOW" | grep -qE 'Type:[[:space:]]+impl([[:space:]]|$)'; then
    if ! echo "$SHOW" | grep -qE '(^[[:space:]]*Verdict:[[:space:]]*(SHIP|OVERRIDE)|[Ss]crutin[a-z]*[^[:alnum:]]+(SHIP|OVERRIDE))'; then
      echo "Blocked: impl bead $ID has no recorded scrutiny verdict." >&2
      echo "An -t impl bead closes only after /scrutinize returns SHIP." >&2
      echo "Record the verdict in the bead --notes, or an explicit" >&2
      echo "'## Scrutiny — OVERRIDE: <reason>'. See /scrutinize, /impl Step 5.0." >&2
      FAILED=1
    fi
  fi
done

[ $FAILED -ne 0 ] && exit 2
exit 0
