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

# ---------------------------------------------------------------------------
# `git push` gate (dotfiles-5a46).
#
# Keyed on the BRANCH BEING PUSHED, in the REPO being pushed — NOT on the
# agent's cwd. The harm this gate exists to prevent is a stale
# `worktree-agent-*` branch on the remote, and that is a property of the
# refspec, not of where the agent happens to be standing.
#
# The old cwd `case` on */.claude/worktrees/agent-* was wrong in BOTH
# directions:
#   - it BLOCKED `git push origin main` from a worktree cwd even when the
#     push targeted another repo — the now-normal cross-repo dispatch — which
#     taught agents to route around it with `git -C <path> push`. That form
#     only slipped through because the old trigger regex demanded `git`
#     immediately followed by `push`; the bug and its workaround shared one
#     line, so any tightening of the regex would have silently re-blocked
#     every cross-repo dispatch.
#   - it ALLOWED `git push origin worktree-agent-abc123` from a normal
#     project root — the exact outcome the gate exists to prevent.
#
# Resolution order for the ref being pushed:
#   1. explicit refspecs on the command line (BOTH sides of `src:dst`);
#   2. otherwise the current branch of the target repo (`-C` / `--git-dir`
#      honored, else the session cwd);
#   3. if neither resolves — e.g. the branch is a quoted `"$BRANCH"` that
#      command_skeleton blanks by design — fall back to the old cwd rule.
#      That is the conservative direction: a worktree's HEAD is a
#      worktree-agent-* branch essentially always.
#
# Deletions are ALWAYS allowed (`--delete`, or a `:branch` refspec with an
# empty source): deleting the stale branch is the orchestrator's own
# documented cleanup step (AGENTS.md).
# ---------------------------------------------------------------------------

# Strip one layer of matching surrounding quotes from a skeleton token.
# A token that was fully quoted in the source command arrives here as the
# EMPTY pair `""` / `''` (its contents are blanked) — which unquotes to the
# empty string and is what marks a value as unresolvable.
push_gate_unquote() {
  local v=$1
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
    "'"*"'") v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

push_gate_block() {
  cat >&2 <<EOF
Blocked: \`git push\` would publish the worktree branch '$1'.

Worktree subagents do not push. Finish your commits; the orchestrator
merges your worktree branch into the target branch and pushes from
there. Pushing a worktree-agent-* branch leaves a stale remote branch.
See /commit ("Worktree exception").

Deleting one is fine — \`git push origin --delete <branch>\` is the
orchestrator's cleanup step and is never blocked by this gate.
EOF
  exit 2
}

push_gate_block_cwd() {
  cat >&2 <<'EOF'
Blocked: `git push` from inside a worktree.

The branch being pushed could not be read from the command (a quoted
"$BRANCH" refspec, or a repo this hook cannot open), so the gate falls
back to the cwd rule. Worktree subagents do not push — the orchestrator
merges your worktree branch and pushes from there. Name the branch
explicitly (`git push origin my-branch`) if it is genuinely not a
worktree-agent-* branch. See /commit ("Worktree exception").
EOF
  exit 2
}

case "$SKEL" in
*push*)
  JSON_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$JSON_CWD" ]; then
    CWD=$(cd "$JSON_CWD" 2>/dev/null && pwd -P)
    [ -z "$CWD" ] && CWD="$JSON_CWD"
  else
    CWD=$(pwd -P)
  fi

  # Split the skeleton into simple commands. Quoted CONTENTS are already
  # blanked by command_skeleton, so every operator left here is real code.
  while IFS= read -r SEG; do
    set -f
    # shellcheck disable=SC2206  # deliberate word-split of a blanked skeleton
    TOKS=($SEG)
    set +f
    [ "${#TOKS[@]}" -ge 2 ] || continue

    # `cd <dir> && git push …` is the other half of the cwd bug: the repo
    # being pushed is the one the command WALKS INTO, not the one the session
    # started in. Segments arrive in execution order, so tracking `cd` here
    # gives later segments the effective cwd. (Caught the hard way: this very
    # hook, freshly fixed, blocked `cd ~/dotfiles && git push` from a worktree
    # session — the exact false block it was being fixed for.)
    if [ "${TOKS[0]}" = "cd" ]; then
      V=$(push_gate_unquote "${TOKS[1]}")
      if [ -n "$V" ]; then
        NEWCWD=$( cd "$CWD" 2>/dev/null && cd "$V" 2>/dev/null && pwd -P )
        [ -n "$NEWCWD" ] && CWD=$NEWCWD
      fi
      continue
    fi

    [ "${TOKS[0]}" = "git" ] || continue

    # --- walk git's GLOBAL options up to the subcommand -------------------
    REPO_LOC=()
    REPO_UNRESOLVED=0
    IS_PUSH=0
    i=1
    n=${#TOKS[@]}
    while [ "$i" -lt "$n" ]; do
      T=${TOKS[$i]}
      case "$T" in
        push) IS_PUSH=1; i=$((i + 1)); break ;;
        -C)
          V=$(push_gate_unquote "${TOKS[$((i + 1))]:-}")
          if [ -z "$V" ]; then REPO_UNRESOLVED=1; else REPO_LOC=(-C "$V"); fi
          i=$((i + 2)) ;;
        --git-dir=*)
          V=$(push_gate_unquote "${T#--git-dir=}")
          if [ -z "$V" ]; then REPO_UNRESOLVED=1; else REPO_LOC=(--git-dir "$V"); fi
          i=$((i + 1)) ;;
        --git-dir)
          V=$(push_gate_unquote "${TOKS[$((i + 1))]:-}")
          if [ -z "$V" ]; then REPO_UNRESOLVED=1; else REPO_LOC=(--git-dir "$V"); fi
          i=$((i + 2)) ;;
        # value-taking globals we don't interpret, and bare flags
        -c|--work-tree|--namespace|--exec-path|--config-env) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;   # a different subcommand — not a push
      esac
    done
    [ "$IS_PUSH" = 1 ] || continue

    # --- walk `push`'s own arguments --------------------------------------
    DELETE=0
    ALLREFS=0
    REMOTE_SEEN=0
    REF_UNRESOLVED=0
    REFS=()
    while [ "$i" -lt "$n" ]; do
      T=${TOKS[$i]}
      case "$T" in
        --delete|-d) DELETE=1; i=$((i + 1)) ;;
        --all|--mirror) ALLREFS=1; i=$((i + 1)) ;;
        -o|--push-option|--receive-pack|--exec|--repo) i=$((i + 2)) ;;
        --) i=$((i + 1)) ;;
        -*) i=$((i + 1)) ;;
        *)
          V=$(push_gate_unquote "$T")
          if [ "$REMOTE_SEEN" = 0 ]; then
            REMOTE_SEEN=1
          elif [ -z "$V" ]; then
            REF_UNRESOLVED=1   # a blanked "$BRANCH" — content is not knowable
          else
            REFS+=("$V")
          fi
          i=$((i + 1)) ;;
      esac
    done

    # Deleting a remote branch is the cleanup path, never the harm.
    [ "$DELETE" = 1 ] && continue

    # --all / --mirror publishes every local branch, worktree ones included.
    if [ "$ALLREFS" = 1 ]; then
      STRAY=$( cd "$CWD" 2>/dev/null && git "${REPO_LOC[@]}" for-each-ref \
        --format='%(refname:short)' 'refs/heads/worktree-agent-*' 2>/dev/null | head -1 )
      [ -n "$STRAY" ] && push_gate_block "$STRAY (via --all/--mirror)"
      continue
    fi

    # 1. explicit refspecs — check both sides of src:dst
    for R in ${REFS[@]+"${REFS[@]}"}; do
      SRC=${R%%:*}; SRC=${SRC#+}
      case "$R" in *:*) DST=${R#*:} ;; *) DST=$SRC ;; esac
      [ -z "$SRC" ] && continue          # `:branch` is a deletion
      case "${SRC##*/}" in worktree-agent-*) push_gate_block "$SRC" ;; esac
      case "${DST##*/}" in worktree-agent-*) push_gate_block "$DST" ;; esac
    done
    [ "${#REFS[@]}" -gt 0 ] && [ "$REF_UNRESOLVED" = 0 ] && continue

    # 2. no usable refspec — resolve the current branch of the TARGET repo
    if [ "$REF_UNRESOLVED" = 0 ] && [ "$REPO_UNRESOLVED" = 0 ]; then
      HEAD_BR=$( cd "$CWD" 2>/dev/null && git "${REPO_LOC[@]}" symbolic-ref \
        --quiet --short HEAD 2>/dev/null )
      if [ -n "$HEAD_BR" ]; then
        case "${HEAD_BR##*/}" in worktree-agent-*) push_gate_block "$HEAD_BR" ;; esac
        continue                          # resolved, and it is not a worktree branch
      fi
    fi

    # 3. unresolvable — fall back to the (conservative) cwd rule
    case "$CWD" in
      */.claude/worktrees/agent-*) push_gate_block_cwd ;;
    esac
  done < <(printf '%s\n' "$SKEL" | tr ';&|`()<>' '\n\n\n\n\n\n\n\n')
  ;;
esac

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
#   work); existing history (already in HEAD) is never re-validated. A valid
#   'done' proof must have real verifier-DISTANCE: scrutinize (bead has SHIP —
#   an independent reviewer) | cmd (hook RE-RUNS it, must exit 0 — the acting
#   proof). artifact (file exists) and commit (sha resolves) are REJECTED for
#   'done' — both are zero-distance no-ops a stub passes (the explore-len0
#   hole); they prove progress, not done. A report-only done (no gradeable
#   deliverable) uses cmd with a minimal `test -s <path>`.
if command -v jq &>/dev/null && [ -n "$GIT_TOPLEVEL" ]; then
  LEDGERS=$(git -C "$GIT_TOPLEVEL" diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E 'pulse-ledger\.jsonl$')
  # commit-by-pathspec / chained-add cases: file may not be staged yet at PreToolUse
  if [ -z "$LEDGERS" ] && echo "$SKEL" | grep -q 'pulse-ledger\.jsonl'; then
    LEDGERS=$(git -C "$GIT_TOPLEVEL" ls-files '*pulse-ledger.jsonl' 2>/dev/null)
  fi
  # TOTAL time budget across every proof command in this commit. Each proof
  # used to get its own `timeout 60` while the PreToolUse hook that runs them
  # is itself capped at 120s — so two slow proofs blew the hook's own ceiling
  # and the commit failed opaquely, with no indication that a PROOF was the
  # cause. Budget the whole gate instead, and say so when it runs out.
  # Single-proof behavior is unchanged (60s, exactly as before).
  PROOF_BUDGET=${HARNESS_PULSE_PROOF_BUDGET:-90}
  PROOF_DEADLINE=$(( $(date +%s) + PROOF_BUDGET ))

  # `while read`, not `for L in $LEDGERS` — a ledger path containing a space
  # word-split into nonexistent paths, silently skipping the gate for it.
  while IFS= read -r L; do
    [ -z "$L" ] && continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line" | jq -e '.' &>/dev/null || continue        # skip non-JSON
      [ "$(echo "$line" | jq -r '.outcome // empty')" = "done" ] || continue
      KIND=$(echo "$line" | jq -r '.proof.kind // empty')
      case "$KIND" in
        artifact)
          echo "Blocked: pulse 'done' proof 'artifact' (file-exists) is stub-passable — a zero-distance no-op that proves progress, not done (explore-len0). Use kind:cmd (even 'test -s <path>' re-runs and beats file-exists; better, grep the deliverable for a required marker) or kind:scrutinize. Offending entry in $L." >&2
          FAILED=1 ;;
        commit)
          echo "Blocked: pulse 'done' proof 'commit' (sha-resolves) proves PROGRESS, not done — every real commit resolves, so it's a no-op a stub clears (explore-len0). Use kind:cmd or kind:scrutinize. Offending entry in $L." >&2
          FAILED=1 ;;
        scrutinize)
          B=$(echo "$line" | jq -r '.proof.bead // empty')
          if [ -z "$B" ] || ! { command -v br &>/dev/null && br show "$B" 2>/dev/null | grep -q 'SHIP'; }; then
            echo "Blocked: pulse 'done' proof scrutinize verdict not SHIP for bead '$B' (in $L)." >&2; FAILED=1; fi ;;
        cmd)
          C=$(echo "$line" | jq -r '.proof.cmd // empty')
          if [ -z "$C" ]; then
            echo "Blocked: pulse 'done' proof cmd is empty (in $L)." >&2
            FAILED=1
          else
            PROOF_LEFT=$(( PROOF_DEADLINE - $(date +%s) ))
            if [ "$PROOF_LEFT" -le 0 ]; then
              echo "Blocked: pulse proof budget (${PROOF_BUDGET}s total for this commit) ran out before verifying: $C (in $L)." >&2
              echo "  Split the ledger across commits, make the proof cheaper, or raise \$HARNESS_PULSE_PROOF_BUDGET." >&2
              FAILED=1
            else
              # Per-command ceiling stays 60s, so the one-proof case behaves
              # exactly as it always did.
              [ "$PROOF_LEFT" -gt 60 ] && PROOF_LEFT=60
              PROOF_OUT=$( cd "$GIT_TOPLEVEL" && timeout "$PROOF_LEFT" bash -c "$C" 2>&1 )
              PROOF_RC=$?
              if [ "$PROOF_RC" -ne 0 ]; then
                # The proof's own output was going to /dev/null, so a blocked
                # commit said only "proof cmd failed" and the author had to
                # re-run it by hand to find out why. Show it.
                echo "Blocked: pulse 'done' proof cmd exited $PROOF_RC (in $L):" >&2
                echo "  cmd: $C" >&2
                if [ "$PROOF_RC" -eq 124 ]; then
                  echo "  timed out after ${PROOF_LEFT}s (budget: ${PROOF_BUDGET}s total, \$HARNESS_PULSE_PROOF_BUDGET)" >&2
                fi
                if [ -n "$PROOF_OUT" ]; then
                  echo "  --- proof output (last 15 lines) ---" >&2
                  printf '%s\n' "$PROOF_OUT" | tail -15 | sed 's/^/  /' >&2
                else
                  echo "  (proof produced no output)" >&2
                fi
                FAILED=1
              fi
            fi
          fi ;;
        *)
          echo "Blocked: pulse 'done' entry has no valid proof token (kind: cmd | scrutinize — artifact/commit are rejected as zero-distance no-ops; see explore-len0). See /pulse step 4.5 — log blocked/quiet if you can't prove it. Offending entry in $L:" >&2
          echo "  $(echo "$line" | jq -c '{ts,row,outcome,bead}' 2>/dev/null)" >&2
          FAILED=1 ;;
      esac
    done < <(git -C "$GIT_TOPLEVEL" diff HEAD -- "$L" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//')
  done <<< "$LEDGERS"
fi

# 3. Lint files headed into this commit: already-staged + chained-add.
#    (FAST checks only — named-file scope, no full-project runs.)
CANDIDATES=$(printf '%s\n%s\n' \
  "$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)" \
  "$ADD_FILES" | grep -v '^$' | sort -u)

if [ -n "$CANDIDATES" ]; then
  GIT_ROOT=${GIT_TOPLEVEL:-$(pwd)}
  # ARRAYS, not space-joined strings. As strings these were passed to the
  # linters UNQUOTED, so a single path containing a space split into two
  # nonexistent filenames, the linter errored on both, and the hook BLOCKED
  # an otherwise-clean commit. (Reproduced: staging `my dir/ok.js` made
  # biome report `No such file or directory` for `.../my` and `dir/ok.js`
  # and the commit was refused.)
  JS_FILES=()
  PY_FILES=()

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
      *.js|*.ts|*.jsx|*.tsx) JS_FILES+=("$RESOLVED") ;;
      *.py) PY_FILES+=("$RESOLVED") ;;
    esac
  done <<< "$CANDIDATES"

  if [ "${#JS_FILES[@]}" -gt 0 ] && command -v biome &>/dev/null; then
    # bd-no31: pin biome at the repo config (root:false makes bare biome resolve
    # the user-level ~/.config/biome instead, flagging the project's own style).
    if [ -f "$GIT_ROOT/biome.jsonc" ]; then
      export BIOME_CONFIG_PATH="$GIT_ROOT/biome.jsonc"
    elif [ -f "$GIT_ROOT/biome.json" ]; then
      export BIOME_CONFIG_PATH="$GIT_ROOT/biome.json"
    fi
    OUTPUT=$(biome check --error-on-warnings "${JS_FILES[@]}" 2>&1) || {
      echo "biome: $OUTPUT" >&2
      FAILED=1
    }
  fi

  if [ "${#PY_FILES[@]}" -gt 0 ] && command -v ruff &>/dev/null; then
    OUTPUT=$(ruff check "${PY_FILES[@]}" 2>&1) || {
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
