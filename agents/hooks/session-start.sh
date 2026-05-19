#!/bin/bash
# SessionStart / SubagentStart: inject project context so the agent
# starts oriented.

LOG=/tmp/session-start-hook.log

# Hooks receive JSON on stdin. SubagentStart's payload contains a `cwd`
# field — the subagent's intended working directory (the worktree).
# Without this, the hook runs in the ORCHESTRATOR's cwd and never sees
# the subagent's worktree, so the .beads symlink never gets created.
STDIN=$(cat 2>/dev/null || echo '{}')
HOOK_EVENT=$(echo "$STDIN" | jq -r '.hook_event_name // empty' 2>/dev/null)
HOOK_CWD=$(echo "$STDIN" | jq -r '.cwd // empty' 2>/dev/null)

{
  echo ""
  echo "===== session-start.sh fired $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
  echo "process cwd: $(pwd -P)"
  echo "hook_event: $HOOK_EVENT"
  echo "stdin cwd:  $HOOK_CWD"
  echo "stdin (first 400 chars): $(echo "$STDIN" | head -c 400)"
} >> "$LOG"

# Empirical finding 2026-05-19 (bead skills-library-1vs):
# The cd here was redundant — when SubagentStart fires, the harness has
# already placed the subagent's process cwd at the worktree path (see
# session-start-hook.log: `process cwd` always matches `stdin cwd` at
# hook-firing time). The cd was a no-op in the common case, BUT it
# remained a suspect source of cwd leak into the orchestrator's shell
# when the harness shares shell state across sessions.
#
# We dropped the cd to eliminate that suspect. If a future configuration
# surfaces where process cwd != stdin cwd at hook firing, restore the
# guard inside a subshell so it can't leak:
#   ( cd "$HOOK_CWD" && [hook work] )

echo "=== Session Context ==="

# Detect worktree: .git is a file (not a dir) in worktrees, and path contains /.claude/worktrees/
IN_WORKTREE=false
GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -f ".git" ] || echo "$GIT_TOPLEVEL" | grep -q '/.claude/worktrees/'; then
  IN_WORKTREE=true
fi

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  echo "Branch: ${BRANCH:-detached}"
  DIRTY=$(git status --short 2>/dev/null | head -10)
  if [ -n "$DIRTY" ]; then
    echo "Dirty files:"
    echo "$DIRTY"
  fi

  # Unabsorbed-submodule guard: if cwd is a submodule of a parent project
  # AND its .git is a real directory (not a gitlink file), the parent's
  # .gitmodules entry was created via `git submodule add` but the gitdir
  # was never absorbed via `git submodule absorbgitdirs`. Claude Code's
  # worktree-creation heuristic ends up placing subagent worktrees under
  # the parent's .claude/worktrees/ instead of the submodule's, breaking
  # the bead symlink + merge target for any subagent dispatch.
  # Fix: from the parent, run `git submodule absorbgitdirs <submodule>`.
  if ! $IN_WORKTREE && [ -d ".git" ]; then
    SUPER=$(git rev-parse --show-superproject-working-tree 2>/dev/null)
    if [ -n "$SUPER" ]; then
      SUB_PATH=$(realpath --relative-to="$SUPER" "$(pwd -P)" 2>/dev/null)
      echo ""
      echo "⚠ Unabsorbed submodule detected"
      echo "  This dir is registered as a submodule of $SUPER but its .git is"
      echo "  still a local directory. Subagent worktrees would land in the parent's"
      echo "  .claude/worktrees/ instead of this submodule's. Fix:"
      echo "    cd $SUPER && git submodule absorbgitdirs ${SUB_PATH:-<this-path>}"
    fi
  fi
fi

if command -v br &>/dev/null; then
  # In a worktree, symlink .beads/ to the main worktree's copy (single source of truth).
  # SAFETY: only act if .beads is missing, already a symlink, OR a directory
  # checked out from the branch with no local mutations (we'll detect via
  # local-only file count). Never delete a real .beads/ directory with
  # unmerged work — that'd nuke local bead history.
  if $IN_WORKTREE; then
    CUR_WT=$(pwd -P)
    # Derive MAIN_WT by stripping the canonical /.claude/worktrees/<name>/
    # suffix from the current worktree path. This works for both plain
    # repos AND absorbed submodules (where `git worktree list` reports the
    # gitdir path under .git/modules/<sub>/, not the working tree).
    MAIN_WT=$(echo "$CUR_WT" | sed -E 's|/\.claude/worktrees/[^/]+/?$||')
    # If path-strip didn't actually strip anything (the path doesn't
    # contain /.claude/worktrees/), MAIN_WT will equal CUR_WT. Fall
    # through to git-worktree-list for that case AND for any case
    # where MAIN_WT doesn't have a .beads dir.
    if [ -z "$MAIN_WT" ] || [ "$MAIN_WT" = "$CUR_WT" ] || [ ! -d "$MAIN_WT/.beads" ]; then
      MAIN_WT=$(git worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / {print substr($0, 10)}' \
        | grep -v '/.claude/worktrees/' \
        | head -1)
    fi
    {
      echo "IN_WORKTREE: true"
      echo "CUR_WT:      $CUR_WT"
      echo "MAIN_WT:     $MAIN_WT"
      echo ".beads exists: $([ -e .beads ] && echo yes || echo no) (symlink: $([ -L .beads ] && echo yes || echo no))"
    } >> "$LOG"
    if [ -n "$MAIN_WT" ] && [ -d "$MAIN_WT/.beads" ] && [ "$CUR_WT" != "$MAIN_WT" ]; then
      # Replace whatever's at .beads with the symlink. If it's a directory
      # checked out by `git worktree add` from a branch tip, the JSONL it
      # contains is already canonical (just the branch state) — safe to
      # supersede with the symlink for live-state sharing.
      if [ -L ".beads" ]; then
        rm .beads
      elif [ -d ".beads" ]; then
        rm -rf .beads
      fi
      ln -sn "$MAIN_WT/.beads" .beads
      echo "Symlinked .beads/ -> $MAIN_WT/.beads/"
      echo "SYMLINK CREATED: .beads -> $MAIN_WT/.beads/" >> "$LOG"
    else
      echo "SYMLINK SKIPPED: MAIN_WT=$MAIN_WT, .beads=$([ -d "$MAIN_WT/.beads" ] && echo yes || echo no), same=$([ "$CUR_WT" = "$MAIN_WT" ] && echo yes || echo no)" >> "$LOG"
    fi
  fi

  # Ensure .gitattributes has merge=union for JSONL (needed for worktree merges)
  # SKIP in worktrees: auto-commits here corrupt worktree branches with unintended changes
  if ! $IN_WORKTREE && [ -d ".beads" ] && ! grep -q 'merge=union' .gitattributes 2>/dev/null; then
    echo '.beads/*.jsonl merge=union' >> .gitattributes
    git add .gitattributes && git commit -q -m ":wrench: config: add gitattributes for JSONL merge" 2>/dev/null
  fi

  # In a worktree with an .envrc, pre-approve direnv so the agent's Bash
  # tool picks up the project env (nix flake, PATH tweaks) automatically.
  # Harmless if direnv/nix are not installed — we swallow errors.
  if $IN_WORKTREE && [ -f ".envrc" ] && command -v direnv &>/dev/null; then
    direnv allow . 2>/dev/null && echo "direnv: allowed $(pwd -P)"
  fi

  br sync --import-only 2>/dev/null
  BEADS=$(br list 2>/dev/null)
  if [ -n "$BEADS" ]; then
    echo ""
    echo "Open beads:"
    echo "$BEADS"
  fi

  # Top pick from bv (graph-aware triage). Bare `bv` would launch the TUI;
  # --robot-next emits one JSON object with the highest-score recommendation.
  # Silently skip if bv isn't installed or the project has no beads.
  if command -v bv &>/dev/null && [ -d ".beads" ]; then
    TOP_PICK=$(bv --robot-next 2>/dev/null | jq -r 'select(.id) | "Top pick: \(.id) — \(.title)"' 2>/dev/null)
    if [ -n "$TOP_PICK" ]; then
      echo ""
      echo "$TOP_PICK"
      echo "(bv --robot-triage for ranked list, --robot-plan for parallel tracks)"
    fi
  fi
fi

exit 0
