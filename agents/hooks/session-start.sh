#!/bin/bash
# SessionStart / SubagentStart: inject project context so the agent
# starts oriented.

# Overridable so tests can assert on the diagnostics without writing to (or
# racing on) the shared log.
LOG=${HARNESS_SESSION_START_LOG:-/tmp/session-start-hook.log}

# Branch/dirty + capped-bead emission is shared with pre-compact.sh
# (dotfiles-b9ii) — one implementation, so the context cap can't drift
# between the two hooks that orient an agent.
HOOK_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib"
CTX_LIB="$HOOK_LIB_DIR/context-emit.sh"
if [ -r "$CTX_LIB" ]; then
  # shellcheck source=lib/context-emit.sh
  . "$CTX_LIB"
else
  # Degrade LOUDLY: a silently missing lib looks identical to "clean repo,
  # no beads", which is the worst possible way for this hook to fail.
  echo "⚠ hook lib missing: $CTX_LIB — git/bead context omitted from this session."
  emit_git_context() { :; }
  emit_bead_context() { :; }
fi

# Hooks receive JSON on stdin. SubagentStart's payload contains a `cwd`
# field — the subagent's intended working directory (the worktree).
# Without this, the hook runs in the ORCHESTRATOR's cwd and never sees
# the subagent's worktree, so the .beads symlink never gets created.
STDIN=$(cat 2>/dev/null || echo '{}')
HOOK_EVENT=$(echo "$STDIN" | jq -r '.hook_event_name // empty' 2>/dev/null)
HOOK_CWD=$(echo "$STDIN" | jq -r '.cwd // empty' 2>/dev/null)
HOOK_SESSION_ID=$(echo "$STDIN" | jq -r '.session_id // empty' 2>/dev/null)
HOOK_SOURCE=$(echo "$STDIN" | jq -r '.source // empty' 2>/dev/null)

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

# --- always-loaded staleness: capture the snapshot fingerprint (explore-6wwu)
# The always-loaded tier (global CLAUDE.md, the project CLAUDE.md chain,
# MEMORY.md, skill descriptions) is read from disk ONCE — right about now — and
# the in-memory copy is what every later request carries. A durable session then
# runs for hours or days on it while Zig edits the files, with nothing
# announcing the divergence. Fingerprint the set here so stop-always-loaded-
# check.sh can name what drifted. Silent + cheap; never blocks anything.
#
# NOT captured for worktree subagents: they are short-lived, and Stop does not
# fire for them, so the manifest would never be read.
#
# `source=compact` does NOT re-capture. Compaction rebuilds the CONVERSATION,
# not the always-loaded snapshot — the files are not re-read from disk — so
# overwriting here would silently erase real staleness. startup / resume / clear
# do re-capture (those are the paths where the tier is genuinely re-read).
if ! $IN_WORKTREE && [ -n "$HOOK_SESSION_ID" ] && [ -r "$HOOK_LIB_DIR/always-loaded.sh" ]; then
  (
    # shellcheck source=lib/always-loaded.sh
    . "$HOOK_LIB_DIR/always-loaded.sh"
    _AL_DIR="${ALWAYS_LOADED_STATE_DIR:-/tmp/claude-always-loaded}"
    _AL_MANIFEST="$_AL_DIR/$HOOK_SESSION_ID.manifest"
    if [ "$HOOK_SOURCE" = "compact" ] && [ -f "$_AL_MANIFEST" ]; then
      exit 0
    fi
    mkdir -p "$_AL_DIR" || exit 0
    if always_loaded_manifest "${HOOK_CWD:-$(pwd -P)}" > "$_AL_MANIFEST.tmp"; then
      mv "$_AL_MANIFEST.tmp" "$_AL_MANIFEST"
      # A fresh snapshot invalidates every prior "already reported" mark.
      rm -f "$_AL_DIR/$HOOK_SESSION_ID.reported"
    else
      rm -f "$_AL_MANIFEST.tmp"
    fi
  ) >> "$LOG" 2>&1
fi

# Layer-2 secret-hygiene alert (explore-r2iq): the session-end scan raises
# ~/.claude/.secret-alert when it finds a secret in the memory tier. Surface it
# prominently for top-level sessions so the next session acts on it (redact +
# move the value to ~/.secrets). Cleared automatically once the tier scans clean.
if ! $IN_WORKTREE && [ -f "$HOME/.claude/.secret-alert" ]; then
  # Self-verify before crying wolf (explore-ytms): the marker may be STALE — a
  # prior scan error, or the tier was cleaned since it was raised. The memory
  # tier is tiny (~MB) and the scan is sub-second, so re-scan NOW and only
  # surface the alert if it STILL finds something. This self-heal kills the
  # "false alert rides every new session" symptom on the first start.
  _SCRUB="$HOME/.claude/skills/scrub-secrets/scrub.py"
  _RESCAN_RC=2   # default: could-not-verify (missing scrub/tier) → soft branch, never a scary FOUND
  if [ -f "$_SCRUB" ] && command -v python3 &>/dev/null; then
    _MEM=("$HOME"/.claude/projects/*/memory)
    if [ -e "${_MEM[0]}" ]; then
      _RESCAN=$(python3 "$_SCRUB" scan "${_MEM[@]}" 2>&1); _RESCAN_RC=$?
    fi
  fi
  if [ "$_RESCAN_RC" -eq 0 ]; then
    # tier scans CLEAN → the marker was stale; self-heal silently (clear both).
    rm -f "$HOME/.claude/.secret-alert" "$HOME/.claude/secret-scan.log" 2>/dev/null
  elif [ "$_RESCAN_RC" -eq 1 ]; then
    # STILL a real finding → surface, refreshing the log so Details is never dangling.
    { date -u +%FT%TZ; printf '%s\n' "$_RESCAN"; } > "$HOME/.claude/secret-scan.log" 2>/dev/null
    echo ""
    echo "⚠ SECRET ALERT — a scan found a secret in the memory tier."
    echo "  Details: $HOME/.claude/secret-scan.log"
    echo "  Redact:  python3 ~/.claude/skills/scrub-secrets/scrub.py redact <file> --apply"
    echo "  Policy:  secrets live in ~/.secrets, referenced by pointer — never in memory."
  else
    # could not re-verify (scan error / missing scrub) → do NOT cry wolf with a
    # scary FOUND alert; note it softly (marker kept) with a valid diagnostics path.
    { date -u +%FT%TZ; printf 'session-start re-scan could not verify (rc=%s):\n%s\n' \
        "$_RESCAN_RC" "${_RESCAN:-<no scan output>}"; } \
      > "$HOME/.claude/secret-scan-error.log" 2>/dev/null
    echo ""
    echo "⚠ secret-scan could not verify the memory tier (scan error; marker kept)."
    echo "  Diagnostics: $HOME/.claude/secret-scan-error.log"
  fi
fi

# --- settings.json symlink guard (dotfiles-kdav) ---------------------------
# ~/.claude/settings.json is supposed to BE the tracked template at
# ~/dotfiles/claude/settings.json, via a symlink. Claude Code writes global
# settings atomically (temp file + rename), and rename() REPLACES a symlink
# with a regular file. Anything that makes it write global settings does this:
# accepting a permission, changing effort in the menu, toggling fast mode.
#
# The break is completely silent and the damage COMPOUNDS: the live file keeps
# working, so nothing alarms, while the tracked template quietly falls behind.
# Last time (dotfiles-2wqv) it drifted 5 settings including ANTHROPIC_BASE_URL
# — the proxy carrying all API traffic — and left `effortLevel: xhigh` in the
# template, which is the Opus 5 WebSearch-killer, so a fresh machine or a
# sync.sh restore would have silently reinstalled a broken config.
#
# DO NOT AUTO-REPAIR. Re-symlinking blindly destroys whatever the live copy
# gained since the break; last time live was a SUPERSET by 5 settings. That is
# the entire lesson of 2wqv. Warn, name the merge, and let a human decide.
#
# Cost: one `[ -L ]` test on the happy path. The jq key-diff only runs when the
# invariant is ALREADY broken, so a healthy session pays nothing measurable.
if ! $IN_WORKTREE; then
  _ST_LIVE="$HOME/.claude/settings.json"
  _ST_TMPL="$HOME/dotfiles/claude/settings.json"
  if [ -e "$_ST_LIVE" ] && [ ! -L "$_ST_LIVE" ]; then
    echo ""
    echo "⚠ ~/.claude/settings.json is a REGULAR FILE, not a symlink to dotfiles."
    echo "  Claude Code rewrote it (atomic rename replaces the symlink). Every"
    echo "  setting added since then is now UNTRACKED and will be lost on the"
    echo "  next fresh install or sync.sh restore."
    # Name the diverged KEYS so the merge is mechanical rather than
    # archaeological. Only runs on the already-broken path.
    if [ -f "$_ST_TMPL" ] && command -v jq &>/dev/null; then
      if _ST_KEYS=$(jq -rs '
        (.[0] // {}) as $live | (.[1] // {}) as $tmpl
        | [ (($live | keys_unsorted) + ($tmpl | keys_unsorted)) | unique | .[]
            | select(($live[.] // null) != ($tmpl[.] // null)) ]
        | join(", ")
      ' "$_ST_LIVE" "$_ST_TMPL" 2>>"$LOG"); then
        if [ -n "$_ST_KEYS" ]; then
          echo "  Diverged keys (live vs dotfiles/claude/settings.json): $_ST_KEYS"
        else
          echo "  No key differences — the two agree; only the link is gone."
        fi
      else
        # Say so rather than printing the reassuring "no differences" — one of
        # the two files not parsing is itself worth knowing about.
        echo "  (could not diff the keys — one of the files is not valid JSON; see $LOG)"
      fi
    fi
    echo "  Fix, MERGE FIRST — do not just re-run sync:"
    echo "    1. diff ~/.claude/settings.json ~/dotfiles/claude/settings.json"
    echo "    2. copy anything live-only INTO ~/dotfiles/claude/settings.json, commit it"
    echo "    3. bash ~/dotfiles/sync.sh claude   # replaces live with a symlink to the template"
    echo "  Step 3 without step 2 deactivates every live-only setting (sync.sh"
    echo "  does stash a copy under ~/dotfiles/.backup/<timestamp>/, but nothing"
    echo "  ever reads it again)."
  fi
fi

emit_git_context

# Unabsorbed-submodule guard: if cwd is a submodule of a parent project
# AND its .git is a real directory (not a gitlink file), the parent's
# .gitmodules entry was created via `git submodule add` but the gitdir
# was never absorbed via `git submodule absorbgitdirs`. Claude Code's
# worktree-creation heuristic ends up placing subagent worktrees under
# the parent's .claude/worktrees/ instead of the submodule's, breaking
# the bead symlink + merge target for any subagent dispatch.
# Fix: from the parent, run `git submodule absorbgitdirs <submodule>`.
# (`-d .git` already implies a git work tree, so this no longer needs to
# nest inside the branch/dirty block that emit_git_context replaced.)
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

  # Self-referential .beads/.beads loop: detect + heal (dotfiles bd-8uqr).
  # `ln -s "$repo/.beads" .beads` run from a repo ROOT instead of a fresh
  # worktree nests the link INSIDE the store as .beads/.beads -> .beads.
  # Symlink-following tree walkers then hit ELOOP: one sat in andrewzigler3
  # from 2026-07-17 to 2026-08-02, 500-ing the dev server's font route and
  # flaking a Playwright spec, while handoff notes wrote it off as "the usual
  # symlink artifact". Nothing looked for it, so nothing found it.
  #
  # PREDICATE — deliberately narrow. We act ONLY on a path literally named
  # .beads/.beads that IS a symlink AND resolves to its own parent. A
  # worktree's LEGITIMATE .beads symlink is named `.beads` (one level up) and
  # points at the MAIN repo's store, so it can never match — deleting those
  # would break bead sharing on every worktree on the machine, far worse than
  # the bug. Anything else at that path (a real dir, a link elsewhere) is
  # reported, never touched, and removal is plain `rm` on the LINK — never
  # `rm -rf`, so a live bead store is unreachable from here.
  #
  # Runs AFTER the worktree symlink step above on purpose: in a worktree
  # `.beads` then resolves to the main repo's store, so a subagent session
  # heals the main checkout too. Sits under `command -v br` because a repo
  # with a .beads/ store is by definition a repo where br is in use.
  if [ -L ".beads/.beads" ]; then
    _loop_tgt=$(readlink -f ".beads/.beads")
    _loop_par=$(readlink -f ".beads")
    if [ -n "$_loop_tgt" ] && [ "$_loop_tgt" = "$_loop_par" ]; then
      rm ".beads/.beads"
      echo "⚠ Removed self-referential .beads/.beads -> $_loop_par (ELOOP source, dotfiles bd-8uqr)"
      echo "BEADS LOOP HEALED: .beads/.beads -> $_loop_par" >> "$LOG"
    else
      echo "⚠ .beads/.beads is a symlink to $_loop_tgt — not self-referential, so left in place. Inspect it."
      echo "BEADS LOOP FOREIGN: .beads/.beads -> $_loop_tgt" >> "$LOG"
    fi
    unset _loop_tgt _loop_par
  fi

  # JSONL merge protection for worktree merges (lin-eqh fix, 2026-06-10).
  # Two layers, BOTH set here because git config never travels with a clone:
  #   1. git config: merge.jsonl-union.driver -> ~/.claude/hooks/merge-jsonl.sh
  #      (idempotent, re-set every session — solves the config-doesn't-clone problem)
  #   2. .gitattributes: .beads/*.jsonl merge=jsonl-union (committed)
  # The custom driver dedupes by bead ID keeping the newer updated_at.
  # The previous setup — git's BUILT-IN `merge=union` — was the resurrection
  # bug itself: union keeps BOTH sides' lines on conflict, so a stale "open"
  # line from a worktree branch survives next to main's "closed" line and
  # br's auto-import can flip the bead back open. Any plain union line is
  # therefore REMOVED (it also overrides jsonl-union when it sorts later,
  # since last gitattributes match wins).
  # If the driver script is missing at merge time, git falls back to a
  # visible conflict — never a silent resurrection.
  # SKIP in worktrees: auto-commits here corrupt worktree branches.
  #
  # Failure visibility (dotfiles-b9ii): every command here used to end in a
  # blanket 2>/dev/null — precisely what pre-bash-stderr-guard.sh blocks
  # AGENTS for doing, in the harness's own hook. A failed install was
  # therefore completely invisible while being exactly the condition the
  # driver exists to prevent. Errors now go to $LOG (not the agent's
  # context — this runs on every session and must stay quiet), and a real
  # failure gets ONE visible line.
  if ! $IN_WORKTREE && [ -d ".beads" ]; then
    MD_ERR=""
    _md_try() { # <label> <cmd...>
      local label=$1; shift
      local out
      if ! out=$("$@" 2>&1); then
        MD_ERR="${MD_ERR}${label}: ${out}"$'\n'
        echo "MERGE-DRIVER FAIL [$label]: $out" >> "$LOG"
        return 1
      fi
      [ -n "$out" ] && echo "merge-driver [$label]: $out" >> "$LOG"
      return 0
    }

    _md_try "git config name" \
      git config merge.jsonl-union.name "JSONL union merge (dedupe by bead ID, keep newer updated_at)"
    _md_try "git config driver" \
      git config merge.jsonl-union.driver "$HOME/.claude/hooks/merge-jsonl.sh %O %A %B"

    # `sed -i` on a missing .gitattributes is an expected no-op, not an error.
    if [ -f .gitattributes ]; then
      _md_try "strip legacy merge=union" \
        sed -i -E '/^\.beads\/\*\.jsonl[[:space:]]+merge=union[[:space:]]*$/d' .gitattributes
    fi
    if ! grep -q 'merge=jsonl-union' .gitattributes 2>/dev/null; then
      if ! echo '.beads/*.jsonl merge=jsonl-union' >> .gitattributes 2>>"$LOG"; then
        MD_ERR="${MD_ERR}append .gitattributes: write failed"$'\n'
      fi
    fi

    if [ -n "$(git status --porcelain -- .gitattributes 2>/dev/null)" ]; then
      _md_try "git add" git add .gitattributes
      # Pathspec commit: only .gitattributes, even if other changes are staged.
      _md_try "git commit" \
        git commit -q -m ":wrench: config: jsonl-union merge driver for .beads JSONL (dedupe by ID, keep newer)" -- .gitattributes
    fi

    if [ -n "$MD_ERR" ]; then
      echo ""
      echo "⚠ jsonl-union merge driver NOT fully installed — bead-resurrection guard is degraded."
      printf '%s' "$MD_ERR" | sed 's/^/  /' | head -6
      echo "  Full detail: $LOG"
    fi
  fi

  # In a worktree with an .envrc, pre-approve direnv so the agent's Bash
  # tool picks up the project env (nix flake, PATH tweaks) automatically.
  # Harmless if direnv/nix are not installed — we swallow errors.
  if $IN_WORKTREE && [ -f ".envrc" ] && command -v direnv &>/dev/null; then
    direnv allow . 2>/dev/null && echo "direnv: allowed $(pwd -P)"
  fi

  br sync --import-only 2>/dev/null

  # The capped open-bead banner. Implementation + the full rationale for the
  # cap and the truncation notice live in lib/context-emit.sh, shared with
  # pre-compact.sh. Display-only: never triages or closes anything (triaging
  # ~/explore is the elevate session's special job).
  emit_bead_context

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

# --- secondary-box slug canonicalization (vault sync, spec lin-i2d.1 P5) ---
# SECONDARY BOXES ONLY (~/.claude/vaults/.peer present): the project slug is
# PATH-derived, so the same repo gets a different slug per machine — ~/dotfiles
# is -home-andrew-dotfiles here but -home-ubuntu-dotfiles on the primary, purely
# because the unix user differs. Both vaults' .excludes hard-exclude
# `/-home-andrew*` so a secondary commits canonical content rather than its own
# local naming. The consequence: ANY slug not canonicalized here is written to,
# never staged, never committed, and never synced — silently, with the hourly
# timer still reporting OK.
#
# This is therefore a UNIVERSAL transform, not an allowlist. It was an allowlist
# twice, and both times the allowlist was the bug:
#   2026-07-27 (dotfiles-f8f2)  only -home-andrew-linearb* was mapped, so every
#                               ~/dotfiles session on this box went unsynced.
#   2026-07-28 (dotfiles-suu9)  ~/linearb/pipeline-website was missing for the
#                               same root reason one layer down, in the cone.
# An allowlist here fails CLOSED-but-silent: the cost of a missing entry is
# invisible data loss, and the cost of an over-broad match is a symlink nobody
# reads. Those are not symmetric, so match broadly.
#
# Zig's call 2026-07-28: this box is his own machine, not a coworker-facing peer,
# so every project canonicalizes — "pop-up dotfiles for ease and consistency".
if [ -f "$HOME/.claude/vaults/.peer" ]; then
  _pk_cwd="${HOOK_CWD:-$(pwd -P)}"
  _pk_slug="$(printf '%s' "$_pk_cwd" | sed 's#/#-#g')"
  # The bare home slug needs its own arm: `${-home-andrew#-home-andrew-}` does
  # NOT strip (no trailing dash to match), which would yield the nonsense canon
  # `-home-ubuntu--home-andrew`.
  case "$_pk_slug" in
    -home-andrew)   _pk_canon="-home-ubuntu" ;;
    -home-andrew-*) _pk_canon="-home-ubuntu-${_pk_slug#-home-andrew-}" ;;
    *)              _pk_canon="" ;;
  esac
  if [ -n "$_pk_canon" ]; then
    _pk_proj="$HOME/.claude/projects"
    mkdir -p "$_pk_proj/$_pk_canon"
    [ -e "$_pk_proj/$_pk_slug" ] || ln -s "./$_pk_canon" "$_pk_proj/$_pk_slug"
    # Cone maintenance only matters while a vault is actually sparse. This box
    # went full-checkout on 2026-07-28, so appending would just grow a file
    # nothing reads; a still-sparse box keeps the old behaviour.
    for _pk_v in transcripts memory; do
      _pk_gd="$HOME/.claude/vaults/$_pk_v.git"
      [ -d "$_pk_gd" ] || continue
      [ "$(git --git-dir="$_pk_gd" config --get core.sparseCheckout)" = "true" ] || continue
      _pk_sf="$_pk_gd/info/sparse-checkout"
      [ -f "$_pk_sf" ] && ! grep -qxF "/$_pk_canon/" "$_pk_sf" && echo "/$_pk_canon/" >> "$_pk_sf"
    done
    unset _pk_v _pk_gd
  fi
fi

exit 0
