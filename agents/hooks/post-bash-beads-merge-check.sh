#!/bin/bash
# PostToolUse (Bash): after a merge-ish git command succeeds, check the
# repo's .beads/issues.jsonl for duplicate top-level ids.
#
# Why this exists:
# git auto-merges .beads/issues.jsonl across branches "cleanly" (ort
# strategy, no conflict markers) while silently DUPLICATING a bead's line
# when both sides touched it — e.g. a feature branch carrying the bead as
# in_progress merged with main carrying it closed. A duplicate id makes
# the JSONL INVALID to br (ERROR jsonl.parse: Duplicate issue id) and
# bricks bead operations until repaired. Caught live 2026-06-09 in
# dashboard-dev-interrupted PR #9 (bd-dtz duplicated as in_progress +
# closed). br doctor has a matching detector (jsonl.duplicate_ids:
# "usually an unresolved merge artifact") — this hook runs the same check
# at the moment the artifact is created, before it gets committed/pushed.
#
# Exit 2 feeds the message back to the agent (PostToolUse cannot block —
# the merge already happened — but the agent gets told to fix it now).
# Bead: dotfiles-qq6

INPUT=$(cat 2>/dev/null || echo '{}')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Only fire on merge-ish operations: git merge / pull / rebase /
# cherry-pick, gh pr merge. `merge(\s|$|[^-])` deliberately excludes
# `git merge-base` (read-only ancestry check, fires constantly in the
# orchestrator merge flow).
if ! echo "$COMMAND" | grep -qE '(git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(merge([[:space:]]|$)|pull([[:space:]]|$)|rebase([[:space:]]|$)|cherry-pick([[:space:]]|$))|gh[[:space:]]+pr[[:space:]]+merge)'; then
  exit 0
fi

# Only fire if the command succeeded — a failed/conflicted merge gets
# git's own conflict markers, which br sync rejects loudly already.
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0' 2>/dev/null)
[ "$EXIT_CODE" != "0" ] && exit 0

# Resolve the repo root from the hook payload cwd (fallback: $PWD).
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
[ -z "$ROOT" ] && exit 0

JSONL="$ROOT/.beads/issues.jsonl"
[ -f "$JSONL" ] || exit 0

# Duplicate top-level ids. jq parses each JSONL record; malformed records
# are br's parse problem (and imply conflict markers git already flagged).
DUPS=$(jq -r '.id // empty' "$JSONL" 2>/dev/null | sort | uniq -d)
[ -z "$DUPS" ] && exit 0

ANCHOR_HINT=""
if [ -f "$ROOT/.beads/beads.base.jsonl" ]; then
  ANCHOR_HINT="  - OR run \`br sync --merge\` (three-way merge via the .beads/beads.base.jsonl anchor; semantic conflicts need --force-db/--force-jsonl/--force)
"
fi

cat >&2 <<EOF
BEADS MERGE ARTIFACT: $JSONL contains duplicate bead id(s) after that merge:
$(echo "$DUPS" | sed 's/^/  - /')

git merged the JSONL "cleanly" but kept BOTH sides' line for the same bead
(classic silent merge artifact — br doctor calls this jsonl.duplicate_ids).
A duplicate id makes the JSONL invalid to br. Fix BEFORE committing/pushing:

  - Take the authoritative branch's version wholesale:
      git checkout <authoritative-branch> -- .beads/issues.jsonl
    (bead state lives on the default branch; that side usually wins)
$ANCHOR_HINT  - Verify: jq -r '.id' .beads/issues.jsonl | sort | uniq -d   (must be empty)
  - Then: br doctor   (confirm jsonl.duplicate_ids is clean)

Root-cause reminder: never stage .beads/issues.jsonl in feature-branch
commits — bead-state commits belong on the default branch (see /commit).
EOF
exit 2
