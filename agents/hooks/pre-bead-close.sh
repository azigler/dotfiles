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
#   3. Scrutiny gate — closing a `-t impl` bead OR a bead labeled
#      `scrutinize-required` is blocked unless a SHIP (or OVERRIDE)
#      scrutiny verdict is recorded in its --notes. (The label lets any
#      finding-bead opt in — e.g. explore deliverables.)
#
# Exit 2 = block the call and feed errors to the agent.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Match against the skeleton (quoted-arg contents blanked) so `br close`/
# `br update` appearing inside a commit message, a -r reason, or a quoted
# test payload is not mistaken for a real command (recurring false-block).
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null)
[ -z "$SKEL" ] && SKEL="$COMMAND"

# --- 1. Worktree guard ---------------------------------------------------
if echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+(close|update)([[:space:]]|$)'; then
  JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$JSON_CWD" ]; then
    CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
    [ -z "$CWD" ] && CWD="$JSON_CWD"
  else
    CWD=$(pwd -P)
  fi
  case "$CWD" in
    */.claude/worktrees/agent-*)
      if echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+close([[:space:]]|$)' \
         || echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+update[[:space:]].*--status'; then
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
#
# This used to be a `case` glob:
#
#   case "$SKEL" in br\ close*|*"&& br close"*|*"; br close"*) ;; *) exit 0 ;; esac
#
# which fired ONLY when the command started with `br close` or contained a
# literal `&& br close` / `; br close`. The fleet's dominant idiom is two
# lines — `cd /home/ubuntu/<proj>` then `br close <id>` — and it matched NONE
# of them. Measured bypass rate rose 0% (Feb) -> 48% (May/Jun) -> 81% (Jul) as
# the fleet went multi-project and the `cd` preamble became standard; 1,043 of
# the 1,044 bypassed closes were that newline form. The gate reported itself
# installed the whole time, because the alarm IS the hook (dotfiles-cxle class:
# "exit code != effect" + "the probe tests a different path than the one that
# matters"). Fixed 2026-07-26 from the beads-lifecycle audit.
#
# The replacement is the SAME anchored grep Section 1 above already used and
# already proved — deliberately not a new matcher.
echo "$SKEL" | grep -qE '(^|[;&|[:space:]])br[[:space:]]+close([[:space:]]|$)' || exit 0

command -v br &>/dev/null || exit 0

# Extract bead IDs from `br close <id> [<id> ...]` off the SKELETON (quoted
# args already blanked), stopping at the first &&/;/| (chained commands)
# and the first flag (-r/--reason), so neither a reason string nor a
# `br close <x>` inside a commit message is mis-scraped as a bead ID
# (dotfiles-c7j "fleet-wide" + the live commit-message false-block).
# ( and ) join &;| as scrape terminators so a close inside a subshell or a
# command substitution — `(cd /x && br close bd-1)`, `$(br close bd-1)` — still
# yields a bare id instead of `bd-1)`, which the id regex below would reject.
BEAD_IDS=$(echo "$SKEL" | grep -oE 'br close [^&;|()]+' | sed 's/^br close //' \
  | awk '{for(i=1;i<=NF;i++){if($i ~ /^-/) break; print $i}}' \
  | grep -E '^[a-z0-9]+-[a-z0-9.]+$')

# Loop form: `for b in <id> <id>; do br close $b; done`. The verb now matches
# (see above), but the ids live in the LOOP HEADER, not after `br close` — so
# the scrape above yields only `$b` and the gate would wave the batch through.
# When the close argument is a variable, recover ids from the `for … in` list.
# Scoped to that one shape on purpose: a broader "scrape every id-shaped token"
# would start reading ids out of paths and flags.
if [ -z "$BEAD_IDS" ] && echo "$SKEL" | grep -qE 'br close +[$]'; then
  BEAD_IDS=$(echo "$SKEL" \
    | grep -oE 'for +[A-Za-z_][A-Za-z0-9_]* +in +[^;]*' \
    | sed -E 's/^for +[A-Za-z_][A-Za-z0-9_]* +in +//' \
    | tr ' \t' '\n' \
    | grep -E '^[a-z0-9]+-[a-z0-9.]+$' | sort -u)
fi

[ -z "$BEAD_IDS" ] && exit 0

# If the command chains `cd <path>` before `br close`, follow it so br
# runs against the same beads store the command will target (bd-8euh).
TARGET_CWD=$(echo "$COMMAND" | grep -oE '(^|[;&] *)cd +[^&;|]+' | head -1 | sed -E 's/^.*cd +//')

# `tr -d ' '` used to be applied here to trim the trailing space the grep
# picks up. It deleted EVERY space, so `cd "/home/me/my project"` became
# "/home/me/myproject" — a path that doesn't exist, so the cd was skipped
# and the lint/scrutiny gates below silently evaluated whatever bead store
# happened to be at the HOOK's cwd instead of the command's target. The
# observed result was a well-formed bead blocked with a doubly-wrong
# message: "incomplete template sections" followed by "Beads not
# initialized". Trim only the ends.
TARGET_CWD="${TARGET_CWD#"${TARGET_CWD%%[![:space:]]*}"}"
TARGET_CWD="${TARGET_CWD%"${TARGET_CWD##*[![:space:]]}"}"

# A path containing a space MUST be quoted in the real command, so strip one
# layer of matched surrounding quotes — otherwise the quoted form (the only
# form that can carry a space) still never resolves.
case "$TARGET_CWD" in
  \"*\") TARGET_CWD=${TARGET_CWD#\"}; TARGET_CWD=${TARGET_CWD%\"} ;;
  \'*\') TARGET_CWD=${TARGET_CWD#\'}; TARGET_CWD=${TARGET_CWD%\'} ;;
esac

TARGET_CWD="${TARGET_CWD/#\~/$HOME}"
if [ -n "$TARGET_CWD" ] && [ -d "$TARGET_CWD" ]; then
  cd "$TARGET_CWD" || true
fi

set +e
FAILED=0
for ID in $BEAD_IDS; do
  # `br show` once per bead — the type feeds the chained-update check below and
  # the body feeds the scrutiny gate at the bottom of the loop.
  SHOW=$(br show "$ID" 2>/dev/null)
  BTYPE=$(echo "$SHOW" | grep -oE 'Type:[[:space:]]+[A-Za-z_-]+' | head -1 | sed -E 's/.*Type:[[:space:]]+//')

  # The && trap: when the SAME command chains `br update <ID> --description`
  # before `br close <ID>`, the template is being set in this very command —
  # but PreToolUse fires BEFORE the update runs, so `br lint` sees the
  # pre-update state and false-blocks. Skip the lint gate for a bead whose
  # description is set by a chained update here, so
  # `br update X --description "...## Acceptance Criteria..." && br close X`
  # works without splitting into two commands (dotfiles-90s clunk audit).
  #
  # --acceptance-criteria and --design used to trigger this skip too. They
  # were a real bypass: `br lint` reads the DESCRIPTION body only, so chaining
  # either one cannot clear the warning it appears to answer, yet the skip let
  # the close through anyway. Same named-vs-accepted mismatch the block message
  # above now spells out, in bypass form (explore-yfn4). Narrowed to the one
  # flag whose chained update can actually satisfy the lint.
  #
  # The remaining half of that bypass, closed 2026-07-26 (beads-lifecycle audit
  # §3.4): the skip used to fire UNCONDITIONALLY on seeing --description and
  # never looked at the value, so `br update X --description "<prose>" &&
  # br close X` bought a free close on a bead that still fails lint. Now the
  # skip only fires when the command actually carries the sections `br lint`
  # will demand for THIS bead's type (bead_required_headings, verified against
  # br 0.2.16 — its own match is a case-insensitive phrase match on the
  # description body, so this mirrors it). Known limit: the phrases are matched
  # against the whole raw command, not against the --description value alone,
  # because the value can be a heredoc/substitution the skeleton has blanked.
  # If the helper lib is unavailable the loop reads nothing and the skip keeps
  # its old permissive behavior — a degraded helper must not false-block.
  SKIP_LINT=0
  if echo "$SKEL" | grep -qE "br update +$ID[[:space:]].*--description"; then
    SKIP_LINT=1
    while IFS= read -r NEEDED; do
      [ -z "$NEEDED" ] && continue
      printf '%s' "$COMMAND" | grep -qiF "$NEEDED" || SKIP_LINT=0
    done < <(bead_required_headings "$BTYPE" 2>/dev/null)
  fi

  if [ "$SKIP_LINT" -eq 1 ]; then
    : # chained `br update <ID> --description ...` satisfies the template
  else
    OUTPUT=$(br lint "$ID" 2>&1)
    LINT_RC=$?
    if [ $LINT_RC -ne 0 ] && [ -n "$OUTPUT" ]; then
    echo "Blocked: bead $ID has incomplete template sections." >&2
    echo "$OUTPUT" >&2
    echo "" >&2
    echo "'br lint' reads the --description body ONLY. A 'Missing: ## <section>'" >&2
    echo "warning clears when that literal markdown heading is present IN THE" >&2
    echo "DESCRIPTION — populating the same-named --acceptance-criteria field (or" >&2
    echo "--design, or --notes) does NOT clear it. Verified against br 0.2.16." >&2
    echo "" >&2
    echo "  br update $ID --description=\"## Context" >&2
    echo "  <why this exists>" >&2
    echo "" >&2
    echo "  ## Acceptance Criteria" >&2
    echo "  - [ ] <concrete deliverable>\"" >&2
    echo "" >&2
    echo "See /beads SKILL ('Mandatory: every bead has a description')." >&2
    FAILED=1
    fi
  fi

  # Scrutiny gate: a bead closes only after /scrutinize records a verdict
  # when it is EITHER (a) an -t impl bead OR (b) carries the
  # `scrutinize-required` label — the opt-in marker a finding-bead (e.g. an
  # explore deliverable) sets so its close is gated like an impl's.
  # Accept an anchored "Verdict: SHIP|OVERRIDE" line (the recorded format
  # under a "## Scrutiny" header) or the verdict directly after the scrutiny
  # marker ("## Scrutiny — OVERRIDE: ..."). Two independent greps over the
  # whole bead used to let prose like "needs scrutiny before we SHIP" pass
  # the gate with no verdict recorded (fixed 2026-06-09).
  # ($SHOW was captured once at the top of the loop.)
  NEEDS_SCRUTINY=0
  echo "$SHOW" | grep -qE 'Type:[[:space:]]+impl([[:space:]]|$)' && NEEDS_SCRUTINY=1
  echo "$SHOW" | grep -qE '^[[:space:]]*Labels:.*scrutinize-required' && NEEDS_SCRUTINY=1
  if [ "$NEEDS_SCRUTINY" -eq 1 ]; then
    if ! echo "$SHOW" | grep -qE '(^[[:space:]]*Verdict:[[:space:]]*(SHIP|OVERRIDE)|[Ss]crutin[a-z]*[^[:alnum:]]+(SHIP|OVERRIDE))'; then
      echo "Blocked: bead $ID has no recorded scrutiny verdict." >&2
      echo "An -t impl bead — or one labeled 'scrutinize-required' — closes" >&2
      echo "only after /scrutinize returns SHIP. Record the verdict in --notes" >&2
      echo "('## Scrutiny — <date>: Verdict: SHIP'), or an explicit" >&2
      echo "'## Scrutiny — OVERRIDE: <reason>'. See /scrutinize, /impl Step 5.0." >&2
      FAILED=1
    fi
  fi
done

[ $FAILED -ne 0 ] && exit 2
exit 0
