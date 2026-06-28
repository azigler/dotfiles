#!/bin/bash
# PreToolUse (Bash): git-discipline gate.
#   - Blocks `git add -A / --all / .` (selective staging only).
#   - Blocks `git push` from inside a worktree (the orchestrator merges
#     the worktree branch and pushes; a worktree push leaves stale
#     worktree-agent-* remote branches).
#   - On `git commit`: requires a `Bead:` trailer (beads projects only;
#     meta-commits exempt), syncs bead state, lints files headed into
#     the commit.
# Exit 2 = block the command and feed errors to the agent.
#
# Fast checks only — file-scoped linting that completes in seconds.
# Heavy checks (full-project tsc, cargo clippy, golangci-lint) live in
# task-completed.sh and CI, NOT here.
#
# PreToolUse hooks must not mutate user state: if the call is denied,
# nothing should have happened. (Changed 2026-06-09: we used to pre-run
# a chained `git add` here so `--staged` linting could see the files —
# that staged files before the permission layer approved the command.
# Now we lint the named files directly, unstaged.) The ONE mutation
# kept deliberately is `br sync` + auto-staging .beads/issues.jsonl:
# harness-owned state, idempotent, and required so commits carry
# current bead state.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Match command STRUCTURE against the skeleton (quoted-arg contents blanked)
# so verbs inside commit messages / quoted payloads don't false-trigger.
# Keep RAW $COMMAND only where we inspect argument CONTENT (the Bead: trailer
# and the gitmoji, which live inside the -m message).
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
SKEL=$(command_skeleton "$COMMAND" 2>/dev/null)
[ -z "$SKEL" ] && SKEL="$COMMAND"

# Block overly-broad git add at ANY time, not just when chained with commit.
if echo "$SKEL" | grep -qE '(^|[[:space:];&|])git add[[:space:]]+(-A([[:space:]]|$)|--all([[:space:]]|$)|\.([[:space:]]|$|[;&|]))'; then
  echo "Blocked: use 'git add <specific-files>', never 'git add .', 'git add -A', or 'git add --all'." >&2
  echo "Reason: selective staging prevents accidentally committing secrets, WIP, or gitignored state." >&2
  exit 2
fi

# Block `git push` from inside a worktree. Worktree subagents do not
# push — the orchestrator merges the worktree branch and pushes.
if echo "$SKEL" | grep -qE '(^|[[:space:];&|])git[[:space:]]+push([[:space:]]|$)'; then
  JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$JSON_CWD" ]; then
    CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
    [ -z "$CWD" ] && CWD="$JSON_CWD"
  else
    CWD=$(pwd -P)
  fi
  case "$CWD" in
    */.claude/worktrees/agent-*)
      cat >&2 <<'EOF'
Blocked: `git push` from inside a worktree.

Worktree subagents do not push. Finish your commits; the orchestrator
merges your worktree branch into the target branch and pushes from
there. Pushing from a worktree leaves stale worktree-agent-* remote
branches. See /commit ("Worktree exception").
EOF
      exit 2
      ;;
  esac
fi

# Only intercept git commit commands for the rest of the checks below
# (skeleton: a "git commit" inside a quoted arg/message is not a real commit)
case "$SKEL" in
  git\ commit*|*"&& git commit"*|*"; git commit"*) ;;
  *) exit 0 ;;
esac

# Files named in a chained `git add ... && git commit`: collect them so
# the lint step below can check them directly. Do NOT run the add —
# PreToolUse must stay side-effect-free on user state.
ADD_FILES=""
if echo "$SKEL" | grep -qE 'git add .+(&&|;)'; then
  ADD_CMD=$(echo "$SKEL" | grep -oE 'git add [^&;]+' | head -1)
  ADD_FILES=$(echo "$ADD_CMD" | sed 's/^git add //' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

set +e
FAILED=0
GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)

# 1. Sync bead state (beads projects only).
# In worktrees, .beads/ is a symlink to the main worktree — skip auto-staging
# to avoid committing symlinked/out-of-tree files that corrupt the branch.
if command -v br &>/dev/null && [ -n "$GIT_TOPLEVEL" ] && [ -e "$GIT_TOPLEVEL/.beads" ]; then
  br sync --flush-only 2>/dev/null || true
  case "$GIT_TOPLEVEL" in
    */.claude/worktrees/*) ;;  # in worktree, skip
    *) git -C "$GIT_TOPLEVEL" add .beads/issues.jsonl 2>/dev/null || true ;;
  esac
fi

# 2. Require a `Bead:` trailer — but ONLY in projects that use beads
#    (.beads exists at the repo root; -e covers the worktree symlink).
#    Repos without beads (fresh clones, scratch dirs, third-party
#    checkouts) commit freely — demanding trailers where no beads exist
#    just trains the agent to fabricate them. Meta-commits are exempt:
#    bead-state / triage / offboard / cost / distribute commits reference
#    beads in the subject rather than a trailer and carry a meta gitmoji.
if [ -n "$GIT_TOPLEVEL" ] && [ -e "$GIT_TOPLEVEL/.beads" ] && ! echo "$COMMAND" | grep -q 'Bead:'; then
  if echo "$COMMAND" | grep -qE ':card_file_box:|:broom:|:dollar:|:outbox_tray:'; then
    : # meta-commit (bead-state / triage / offboard / cost / distribute) — trailer not required
  else
    echo "Blocked: commit message has no 'Bead: <id>' trailer." >&2
    echo "Every commit maps to a bead — see /commit, /beads ('one bead = one commit')." >&2
    echo "Add a 'Bead: <id>' trailer. Exempt: bead-state / triage / offboard /" >&2
    echo "cost / distribute meta-commits (:card_file_box: :broom: :dollar: :outbox_tray:)." >&2
    FAILED=1
  fi
fi

# 2.5. pulse-ledger 'done' PROOF GATE (loop-engineering nodding-loop guard).
#   A pulse tick is the generator AND writes its own outcome:"done" — that's
#   the nodding loop (the doer grading its own homework). When a *pulse-ledger
#   .jsonl is part of this commit, every NEW `done` line must carry a
#   machine-verifiable `proof` token, and the proof must actually check out,
#   or the commit is blocked. quiet/blocked entries are exempt (they claim no
#   work); existing history (already in HEAD) is never re-validated. Proof
#   kinds: artifact (file exists) | commit (sha resolves) | scrutinize (bead
#   has SHIP) | cmd (hook RE-RUNS it, must exit 0 — the acting proof).
if command -v jq &>/dev/null && [ -n "$GIT_TOPLEVEL" ]; then
  LEDGERS=$(git -C "$GIT_TOPLEVEL" diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E 'pulse-ledger\.jsonl$')
  # commit-by-pathspec / chained-add cases: file may not be staged yet at PreToolUse
  if [ -z "$LEDGERS" ] && echo "$SKEL" | grep -q 'pulse-ledger\.jsonl'; then
    LEDGERS=$(git -C "$GIT_TOPLEVEL" ls-files '*pulse-ledger.jsonl' 2>/dev/null)
  fi
  for L in $LEDGERS; do
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line" | jq -e '.' &>/dev/null || continue        # skip non-JSON
      [ "$(echo "$line" | jq -r '.outcome // empty')" = "done" ] || continue
      KIND=$(echo "$line" | jq -r '.proof.kind // empty')
      case "$KIND" in
        artifact)
          P=$(echo "$line" | jq -r '.proof.path // empty')
          if [ -z "$P" ] || { [ ! -e "$GIT_TOPLEVEL/$P" ] && [ ! -e "$P" ]; }; then
            echo "Blocked: pulse 'done' proof artifact missing: '$P' (in $L)." >&2; FAILED=1; fi ;;
        commit)
          S=$(echo "$line" | jq -r '.proof.sha // empty')
          git -C "$GIT_TOPLEVEL" rev-parse --verify --quiet "${S}^{commit}" &>/dev/null || {
            echo "Blocked: pulse 'done' proof commit unresolvable: '$S' (in $L)." >&2; FAILED=1; } ;;
        scrutinize)
          B=$(echo "$line" | jq -r '.proof.bead // empty')
          if [ -z "$B" ] || ! { command -v br &>/dev/null && br show "$B" 2>/dev/null | grep -q 'SHIP'; }; then
            echo "Blocked: pulse 'done' proof scrutinize verdict not SHIP for bead '$B' (in $L)." >&2; FAILED=1; fi ;;
        cmd)
          C=$(echo "$line" | jq -r '.proof.cmd // empty')
          if [ -z "$C" ] || ! ( cd "$GIT_TOPLEVEL" && timeout 60 bash -c "$C" &>/dev/null ); then
            echo "Blocked: pulse 'done' proof cmd failed or empty: '$C' (in $L)." >&2; FAILED=1; fi ;;
        *)
          echo "Blocked: pulse 'done' entry has no verifiable proof token (kind: artifact|commit|scrutinize|cmd). See /pulse step 4.5 — log blocked/quiet if you can't prove it. Offending entry in $L:" >&2
          echo "  $(echo "$line" | jq -c '{ts,row,outcome,bead}' 2>/dev/null)" >&2
          FAILED=1 ;;
      esac
    done < <(git -C "$GIT_TOPLEVEL" diff HEAD -- "$L" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//')
  done
fi

# 3. Lint files headed into this commit: already-staged + chained-add.
#    (FAST checks only — named-file scope, no full-project runs.)
CANDIDATES=$(printf '%s\n%s\n' \
  "$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)" \
  "$ADD_FILES" | grep -v '^$' | sort -u)

if [ -n "$CANDIDATES" ]; then
  GIT_ROOT=${GIT_TOPLEVEL:-$(pwd)}
  JS_FILES=""
  PY_FILES=""

  while IFS= read -r file; do
    # Staged names are repo-root-relative; chained-add names are
    # cwd-relative — resolve against both, skip what doesn't exist.
    RESOLVED=""
    if [ -f "$file" ]; then
      RESOLVED="$file"
    elif [ -f "$GIT_ROOT/$file" ]; then
      RESOLVED="$GIT_ROOT/$file"
    fi
    [ -z "$RESOLVED" ] && continue
    case "$file" in
      *.js|*.ts|*.jsx|*.tsx) JS_FILES="$JS_FILES $RESOLVED" ;;
      *.py) PY_FILES="$PY_FILES $RESOLVED" ;;
    esac
  done <<< "$CANDIDATES"

  if [ -n "$JS_FILES" ] && command -v biome &>/dev/null; then
    # bd-no31: pin biome at the repo config (root:false makes bare biome resolve
    # the user-level ~/.config/biome instead, flagging the project's own style).
    if [ -f "$GIT_ROOT/biome.jsonc" ]; then
      export BIOME_CONFIG_PATH="$GIT_ROOT/biome.jsonc"
    elif [ -f "$GIT_ROOT/biome.json" ]; then
      export BIOME_CONFIG_PATH="$GIT_ROOT/biome.json"
    fi
    OUTPUT=$(biome check --error-on-warnings $JS_FILES 2>&1) || {
      echo "biome: $OUTPUT" >&2
      FAILED=1
    }
  fi

  if [ -n "$PY_FILES" ] && command -v ruff &>/dev/null; then
    OUTPUT=$(ruff check $PY_FILES 2>&1) || {
      echo "ruff: $OUTPUT" >&2
      FAILED=1
    }
  fi

  # Heavy checks (tsc / cargo clippy / golangci-lint) DELIBERATELY OMITTED.
  # They run on whole projects and can take 30s+. Use task-completed.sh + CI.
fi

if [ $FAILED -ne 0 ]; then
  echo "Pre-commit checks failed. Fix errors before committing." >&2
  exit 2
fi

exit 0
