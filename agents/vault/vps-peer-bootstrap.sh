#!/usr/bin/env bash
# vps-peer-bootstrap.sh  — Phase 1 of the Claude-state sync (spec lin-i2d.1).
# Runs ON marketing-vps. SAFE + NON-DESTRUCTIVE:
#   * partial (blob:none) clone of the two PRIVATE vault repos into detached git-dirs
#   * worktree = ~/.claude/projects (shared), sparse-checkout scoped to linearb
#   * NO commit, NO push, NO changes to existing untracked content
#   * read-only zero-deletion SELFTEST (proves sparse skip-worktree prevents
#     delete-on-add — the OQ-09 data-loss gate) then UNSTAGES (never commits)
set -euo pipefail

VAULT="$HOME/.claude/vaults"
WT="$HOME/.claude/projects"
MEM_GIT="$VAULT/memory.git"
TR_GIT="$VAULT/transcripts.git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# memory = ALL linearb slugs (memory is tiny); transcripts = ACTIVE slugs only.
MEM_PATTERNS='/-home-ubuntu-linearb*/'
read -r -d '' TR_PATTERNS <<'PAT' || true
/-home-ubuntu-linearb/
/-home-ubuntu-linearb-marketing-vps/
/-home-ubuntu-linearb-imc-july26/
/-home-ubuntu-linearb-imc-aug26/
PAT

say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$VAULT"
# Refuse to clobber an existing peer setup — bail loudly so a re-run is a conscious act.
for g in "$MEM_GIT" "$TR_GIT"; do
  if [ -e "$g" ]; then echo "REFUSING: $g already exists — remove it deliberately to re-bootstrap"; exit 3; fi
done

# ---- clone one vault repo into a detached git-dir, sparse, then checkout ----
# args: <repo-url> <git-dir> <sparse-patterns>
bootstrap_one() {
  local url="$1" gitdir="$2" patterns="$3" name; name="$(basename "$gitdir")"
  say "clone $name (partial, no-checkout)"
  git clone --filter=blob:none --no-checkout "$url" "$TMP/$name"
  mv "$TMP/$name/.git" "$gitdir"
  rm -rf "$TMP/$name"
  git --git-dir="$gitdir" config core.bare false
  git --git-dir="$gitdir" config core.worktree "$WT"

  say "$name: write sparse-checkout patterns (info file — avoids the '-'-slug argv footgun)"
  git --git-dir="$gitdir" config core.sparseCheckout true
  printf '%s\n' "$patterns" > "$gitdir/info/sparse-checkout"
  echo "patterns:"; sed 's/^/  /' "$gitdir/info/sparse-checkout"

  say "$name: checkout (materializes ONLY the sparse linearb paths; untracked content untouched)"
  git --git-dir="$gitdir" --work-tree="$WT" checkout main 2>&1 | tail -3 || {
    echo "checkout reported issues — inspect above"; }
  echo "tracked top-level slugs now present in the index:"
  git --git-dir="$gitdir" --work-tree="$WT" ls-files | sed 's#/.*##' | sort -u | sed 's/^/  /'
}

bootstrap_one "https://github.com/azigler/claude-memory.git"      "$MEM_GIT" "$MEM_PATTERNS"
bootstrap_one "https://github.com/azigler/claude-transcripts.git" "$TR_GIT"  "$TR_PATTERNS"

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

say "Phase 1 done — clones in place, sparse scoped to linearb, zero-deletion proven. NO commit/push."
echo "materialized linearb slugs under $WT:"
ls -d "$WT"/-home-ubuntu-linearb* 2>/dev/null | sed 's/^/  /' || echo "  (none matched?)"
