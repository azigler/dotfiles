#!/usr/bin/env bash
# vault-lib.sh — claude-memory vault helpers (explore-76oc Phase 1, §4.1).
# Sourced by session-end.sh, bootstrap-memory.sh, and vault-selftest.sh.
#
# Layout (D1 — detached git-dir + shared work-tree, sandbox-validated):
#   git-dir   = ~/.claude/vaults/memory.git      (OUTSIDE the tree → no root .git)
#   work-tree = ~/.claude/projects
#   excludes  = ~/dotfiles/agents/vault/memory.excludes   (whitelist */memory/**)
#
# Identity is repo-LOCAL only; this file NEVER runs `git config --global`
# (explore-62q5 — a --global identity write clobbered the machine once).

VAULT_DIR="${VAULT_DIR:-$HOME/.claude/vaults}"
MEMORY_GIT="${MEMORY_GIT:-$VAULT_DIR/memory.git}"
MEMORY_WORKTREE="${MEMORY_WORKTREE:-$HOME/.claude/projects}"
MEMORY_EXCLUDES="${MEMORY_EXCLUDES:-$HOME/dotfiles/agents/vault/memory.excludes}"
MEMORY_LOCK="${MEMORY_LOCK:-$VAULT_DIR/.memory.lock}"
MEMORY_REPO="${MEMORY_REPO:-azigler/claude-memory}"
SCRUB="${SCRUB:-$HOME/.claude/skills/scrub-secrets/scrub.py}"

# Raw vault git op — NO lock. Caller MUST hold the flock (vault_push_memory's
# critical section) or be single-threaded (bootstrap / selftest).
mgit() {
  git --git-dir="$MEMORY_GIT" \
      --work-tree="$MEMORY_WORKTREE" \
      -c core.excludesFile="$MEMORY_EXCLUDES" "$@"
}

# Locked single op — for one-shot external callers (bootstrap / selftest /
# vault-restore). Serializes on a machine-local flock (OQ-A1/A2); -w 10 = a
# benign timeout rather than a hang.
mvault() {
  mkdir -p "$VAULT_DIR" 2>/dev/null
  flock -w 10 "$MEMORY_LOCK" \
    git --git-dir="$MEMORY_GIT" \
        --work-tree="$MEMORY_WORKTREE" \
        -c core.excludesFile="$MEMORY_EXCLUDES" "$@"
}

# Echo PRIVATE / PUBLIC / INTERNAL / UNKNOWN. Cached once/day (OQ-E2). Fail
# CLOSED: any error → UNKNOWN, and the caller refuses to push.
cached_repo_visibility() {
  local cache="$VAULT_DIR/.memory-visibility" today line d v vis
  today=$(date -u +%F)
  if [ -f "$cache" ]; then
    line=$(cat "$cache" 2>/dev/null)
    d="${line%% *}"; v="${line#* }"
    if [ "$d" = "$today" ] && [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  vis=$(gh repo view "$MEMORY_REPO" --json visibility -q .visibility 2>/dev/null \
        | tr '[:lower:]' '[:upper:]')
  [ -z "$vis" ] && vis="UNKNOWN"
  mkdir -p "$VAULT_DIR" 2>/dev/null
  printf '%s %s\n' "$today" "$vis" > "$cache" 2>/dev/null
  echo "$vis"
}

# The locked body of the SessionEnd push (the flock is held via fd 9). Benign
# errors are quiet (note:), real errors are loud (WARN:) — OQ-A3.
_vault_push_locked() {
  local vis out slug
  vis=$(cached_repo_visibility)
  if [ "$vis" != "PRIVATE" ]; then
    echo "note: memory push skipped (visibility=$vis)" >&2
    return 0
  fi
  if ! out=$(mgit add -A 2>&1); then
    echo "WARN: memory vault stage failed: $out" >&2
    return 0
  fi
  if mgit diff --cached --quiet 2>/dev/null; then
    return 0                                   # nothing changed
  fi
  slug=$(printf '%s' "$PWD" | sed 's#/#-#g')
  if ! out=$(mgit commit -q -m "memory: ${slug} $(date -u +%FT%TZ)" 2>&1); then
    # a pre-commit-hook block (Layer 1 secret gate) or a real fs failure — loud.
    echo "WARN: memory vault commit blocked/failed:" >&2
    printf '%s\n' "$out" >&2
    return 0
  fi
  # reconcile then best-effort push — both benign on failure (OQ-A1/A3).
  mgit pull --rebase --autostash -q origin main >/dev/null 2>&1 || true
  if ! mgit push -q origin main >/dev/null 2>&1; then
    echo "note: memory push deferred" >&2
  fi
}

# SessionEnd push step (§4.1). Best-effort; NEVER fails the caller. ONE flock
# spans the whole add→commit→pull→push critical section (OQ-A1/A2).
vault_push_memory() {
  [ -d "$MEMORY_GIT" ] || return 0             # inert until bootstrap runs
  mkdir -p "$VAULT_DIR" 2>/dev/null
  # stale-lock sweep (OQ-A2): a SIGKILLed session must not wedge future commits.
  find "$MEMORY_GIT" -name index.lock -mmin +5 -delete 2>/dev/null
  (
    flock -w 10 9 || { echo "note: memory vault busy (lock timeout)" >&2; exit 0; }
    _vault_push_locked
  ) 9>"$MEMORY_LOCK"
  return 0
}
