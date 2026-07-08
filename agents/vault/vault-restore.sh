#!/usr/bin/env bash
# vault-restore.sh — the safe REVERT half of the claude-memory audit thesis
# (explore-76oc §4.5 / OQ-E4). Materializes a PAST revision of a slug's memory
# into a STAGING tree for human review. It NEVER writes the live hot memory file
# and NEVER touches the vault's real index — so a restore cannot clobber a
# mid-write MEMORY.md (OQ-A4). Copy-back is a deliberate, manual human step.
#
# `--` discipline throughout: slugs begin with '-' (an argv footgun — OQ-E3), so
# every per-slug pathspec is passed after `--`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/vault-lib.sh"

STAGING_ROOT="$VAULT_DIR/restore-staging"

die()  { echo "vault-restore: $*" >&2; exit 1; }
usage() {
  cat >&2 <<'U'
Usage:
  vault-restore.sh list <slug> [N]         show the N (default 20) most recent vault
                                           commits touching <slug>/memory
  vault-restore.sh <sha> <slug> [subpath]  extract that revision of <slug>/memory into a
                                           staging tree, diff it against the live tree, and
                                           print copy-back instructions.

The LIVE memory (~/.claude/projects/<slug>/memory/) is NEVER modified — review the
staged copy and copy back by hand if you want it. slug begins with '-'.
  e.g.  vault-restore.sh list -home-ubuntu-explore
        vault-restore.sh 1a2b3c4 -home-ubuntu-explore MEMORY.md
U
  exit 2
}

[ -d "$MEMORY_GIT" ] || die "vault not bootstrapped ($MEMORY_GIT)"
[ $# -ge 2 ] || usage

first="$1"; slug="$2"; sub="${3:-}"
case "$slug" in
  -*) : ;;                                   # good — slugs begin with '-'
  *)  die "slug must begin with '-' (got: $slug)";;
esac

# --- list mode ---------------------------------------------------------------
if [ "$first" = "list" ]; then
  n="${sub:-20}"
  echo "== vault history for $slug/memory (newest first) =="
  git --git-dir="$MEMORY_GIT" log --oneline -n "$n" -- "$slug/memory" \
    || die "no history for $slug/memory"
  echo
  echo "Restore one with:  vault-restore.sh <sha> $slug [subpath]"
  exit 0
fi

# --- restore mode ------------------------------------------------------------
sha="$first"
git --git-dir="$MEMORY_GIT" rev-parse --verify -q "$sha^{commit}" >/dev/null \
  || die "not a commit in the vault: $sha"

path="$slug/memory"
if [ -n "$sub" ]; then
  # keep the subpath INSIDE <slug>/memory/ (scrutiny F2): reject '..' and absolute
  # paths so a crafted subpath can't point the diff/copy-back at another slug.
  case "/$sub" in
    */../*|*/..) die "subpath must stay within <slug>/memory/ (no '..'): $sub" ;;
  esac
  case "$sub" in
    /*) die "subpath must be relative to <slug>/memory/ (no leading '/'): $sub" ;;
  esac
  path="$slug/memory/$sub"
fi

short="$(git --git-dir="$MEMORY_GIT" rev-parse --short "$sha")"
staging="$STAGING_ROOT/$short"
mkdir -p "$staging"

# Extract via a THROWAWAY index (GIT_INDEX_FILE) so the checkout writes ONLY to
# the staging work-tree and leaves the vault's real index untouched — otherwise
# `checkout <sha> -- <path>` would stage the old content, and the next
# session-end could commit the revert unintentionally. Use a NAME-only temp path
# (mktemp -u): git creates a fresh valid index there — a pre-created zero-byte
# file is rejected ("index file smaller than expected").
tmpidx="$(mktemp -u)"
if ! GIT_INDEX_FILE="$tmpidx" git --git-dir="$MEMORY_GIT" --work-tree="$staging" \
      checkout "$sha" -- "$path" 2>/dev/null; then
  rm -f "$tmpidx"; rmdir "$staging" 2>/dev/null || true
  die "no such path in $sha: $path"
fi
rm -f "$tmpidx"

echo "== restored '$path' @ $short into staging =="
echo "  staged: $staging/$path"
echo "  live:   $MEMORY_WORKTREE/$path"
echo
echo "== diff (live vs staged revision; empty = identical) =="
if diff -ruN "$MEMORY_WORKTREE/$path" "$staging/$path"; then
  echo "(no differences — the live tree already matches $short)"
else
  drc=$?   # 1 = differences (shown above); >=2 = diff itself errored (scrutiny F3)
  [ "$drc" -ge 2 ] && echo "(warning: diff could not compare cleanly — exit $drc; inspect by hand)" >&2
fi
echo
echo "== nothing was applied. To adopt the staged revision, copy back BY HAND: =="
if [ -d "$staging/$path" ]; then
  # a FAITHFUL revert of a directory needs --delete: plain `cp` overlays and leaves
  # files that were added AFTER this revision in place (scrutiny F1). rsync --delete
  # makes live match the staged revision exactly. Review the diff above first.
  echo "  rsync -a --delete -- \"$staging/$path/\" \"$MEMORY_WORKTREE/$path/\""
  echo "  # (rsync --delete removes files added since $short; the diff above shows them as deletions)"
else
  echo "  cp -- \"$staging/$path\" \"$MEMORY_WORKTREE/$path\""
fi
echo "  # then review; the next session end commits the change to the vault."
echo
echo "(staging kept at $staging — remove it when done: rm -rf \"$staging\")"
