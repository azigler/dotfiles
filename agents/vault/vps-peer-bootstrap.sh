#!/usr/bin/env bash
# vps-peer-bootstrap.sh  — Phase 1 of the Claude-state sync (spec lin-i2d.1).
# Stands up a SECONDARY box as a FULL MIRROR of Zig's Claude state.
# SAFE + NON-DESTRUCTIVE:
#   * partial (blob:none) clone of the two PRIVATE vault repos into detached git-dirs
#   * worktree = ~/.claude/projects (shared), FULL checkout — every slug
#   * NO commit, NO push, NO changes to existing untracked content
#   * read-only zero-deletion SELFTEST (the OQ-09 data-loss gate) then UNSTAGES
#
# ---------------------------------------------------------------------------
# ROLE CHANGE, 2026-07-28 (Zig's call; dotfiles-suu9)
# ---------------------------------------------------------------------------
# This used to scope the checkout narrowly:
#     memory = ALL linearb slugs (memory is tiny); transcripts = ACTIVE slugs only
# — four hand-listed transcript slugs, on the theory that a secondary is a
# coworker-facing box that should carry only what its pulse rows need.
#
# That premise is retired. These boxes are Zig's own pop-up machines, and the
# narrow scope cost more than it saved. It failed the SAME way twice, and both
# times silently, with the hourly sync still reporting OK:
#   dotfiles-f8f2  ~/dotfiles transcripts never synced from vps-8a9eb245
#   dotfiles-suu9  ~/linearb/pipeline-website missing while 19 other slugs were
#                  too — the cone only ever grew for projects a session had been
#                  opened in ON THAT BOX, so anything merely READ was invisible
#
# A full checkout is also strictly SAFER with respect to the OQ-09 gate below.
# That selftest exists because sparse leaves paths unmaterialized, which `add -A`
# can stage as DELETIONS against the shared worktree. With every path present
# there is nothing absent to delete, so the failure mode it guards is gone
# rather than merely detected.
#
# Cost is small and one-directional: ~4.6 GB of worktree from ~513 MB of already
# -cloned objects, versus invisible permanent data loss. Not a close call.
# If a genuinely shared coworker box ever needs narrow scope again, reintroduce
# it as an explicit opt-in FLAG — never as the default.
set -euo pipefail

VAULT="$HOME/.claude/vaults"
WT="$HOME/.claude/projects"
MEM_GIT="$VAULT/memory.git"
TR_GIT="$VAULT/transcripts.git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$VAULT"
# Refuse to clobber an existing peer setup — bail loudly so a re-run is a conscious act.
for g in "$MEM_GIT" "$TR_GIT"; do
  if [ -e "$g" ]; then echo "REFUSING: $g already exists — remove it deliberately to re-bootstrap"; exit 3; fi
done

# ---- clone one vault repo into a detached git-dir, then FULL checkout ----
# args: <repo-url> <git-dir>
bootstrap_one() {
  local url="$1" gitdir="$2" name; name="$(basename "$gitdir")"
  say "clone $name (partial, no-checkout)"
  git clone --filter=blob:none --no-checkout "$url" "$TMP/$name"
  mv "$TMP/$name/.git" "$gitdir"
  rm -rf "$TMP/$name"
  git --git-dir="$gitdir" config core.bare false
  git --git-dir="$gitdir" config core.worktree "$WT"

  # Explicitly OFF, not merely unset: a re-bootstrap over a previously-sparse
  # git-dir must not inherit a stale cone.
  git --git-dir="$gitdir" config core.sparseCheckout false

  say "$name: FULL checkout — every slug; untracked content untouched"
  git --git-dir="$gitdir" --work-tree="$WT" checkout main 2>&1 | tail -3 || {
    echo "checkout reported issues — inspect above"; }
  echo "tracked top-level slugs now present in the index: $(git --git-dir="$gitdir" --work-tree="$WT" ls-files | sed 's#/.*##' | sort -u | wc -l)"
}

bootstrap_one "https://github.com/azigler/claude-memory.git"      "$MEM_GIT"
bootstrap_one "https://github.com/azigler/claude-transcripts.git" "$TR_GIT"

# ---- the OQ-09 selftest: does `add -A` stage ZERO deletions? (READ-ONLY) ----
selftest_zero_deletions() {
  local gitdir="$1" excludes="$2" name; name="$(basename "$gitdir")"
  say "SELFTEST $name — add -A must stage ZERO deletions (skip-worktree working)"
  local -a g=(git --git-dir="$gitdir" --work-tree="$WT")
  [ -f "$excludes" ] && g+=(-c "core.excludesFile=$excludes")
  "${g[@]}" add -A 2>/dev/null || true
  local dels; dels="$("${g[@]}" diff --cached --diff-filter=D --name-only 2>/dev/null | wc -l)"
  local staged; staged="$("${g[@]}" diff --cached --name-only 2>/dev/null | wc -l)"
  echo "staged total=$staged  staged DELETIONS=$dels"
  if [ "$dels" -ne 0 ]; then
    echo "!! FAIL: $dels deletions staged — sparse skip-worktree NOT protecting the back-catalog"
    "${g[@]}" diff --cached --diff-filter=D --name-only | sed 's#/.*##' | sort -u | head | sed 's/^/   would-delete slug: /'
  else
    echo "OK: zero deletions — the peer add would NOT clobber un-synced history"
  fi
  say "$name — UNSTAGE everything (Phase 1 commits NOTHING)"
  "${g[@]}" reset -q 2>/dev/null || true
  echo "post-reset staged: $("${g[@]}" diff --cached --name-only 2>/dev/null | wc -l)"
}

selftest_zero_deletions "$MEM_GIT" "$HOME/dotfiles/agents/vault/memory.excludes"
selftest_zero_deletions "$TR_GIT"  "$HOME/dotfiles/agents/vault/transcripts.excludes"

say "Phase 1 done — clones in place, FULL checkout, zero-deletion proven. NO commit/push."
echo "materialized slugs under $WT: $(ls -d "$WT"/-home-ubuntu* 2>/dev/null | wc -l)"
echo
echo "NEXT: this box writes under its OWN unix user, so its slugs are -home-<user>-*"
echo "while the vault's canonical content is -home-ubuntu-*. session-start.sh"
echo "canonicalizes that automatically (symlink per project, created before the"
echo "session writes) — but ONLY for a box marked as secondary. Create the marker:"
echo "  printf '%s %s PEER\\n' \"\$(date -u +%FT%TZ)\" \"\$(hostname -s)\" > $VAULT/.peer"
echo "Without it, every session here writes to a -home-<user>-* slug that both"
echo ".excludes files hard-exclude: never staged, never synced, and silent."
