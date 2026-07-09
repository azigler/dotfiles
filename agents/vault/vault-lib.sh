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

# Network vault op with a HARD timeout — a stalled connection must never hang
# session end (scrutiny finding 3: flock -w bounds lock acquisition, NOT the ops
# inside it). Degrades to bare git if `timeout` is absent.
mgit_net() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${VAULT_NET_TIMEOUT:-30}" git --git-dir="$MEMORY_GIT" \
      --work-tree="$MEMORY_WORKTREE" -c core.excludesFile="$MEMORY_EXCLUDES" "$@"
  else
    git --git-dir="$MEMORY_GIT" \
      --work-tree="$MEMORY_WORKTREE" -c core.excludesFile="$MEMORY_EXCLUDES" "$@"
  fi
}

# Echo PRIVATE / PUBLIC / INTERNAL / UNKNOWN. Caches a DEFINITIVE answer once/day
# (OQ-E2). Fail CLOSED: any error → UNKNOWN and the caller refuses to push.
cached_repo_visibility() {
  local cache="$VAULT_DIR/.memory-visibility" today line d v vis
  local gh_cmd
  today=$(date -u +%F)
  if [ -f "$cache" ]; then
    line=$(cat "$cache" 2>/dev/null)
    d="${line%% *}"; v="${line#* }"
    if [ "$d" = "$today" ] && [ -n "$v" ]; then echo "$v"; return 0; fi
  fi
  # bounded network lookup (finding 3).
  gh_cmd=(gh repo view "$MEMORY_REPO" --json visibility -q .visibility)
  command -v timeout >/dev/null 2>&1 && gh_cmd=(timeout 15 "${gh_cmd[@]}")
  vis=$("${gh_cmd[@]}" 2>/dev/null | tr '[:lower:]' '[:upper:]')
  if [ -n "$vis" ]; then
    # cache ONLY a definitive answer (finding 2): a transient gh failure must not
    # pin UNKNOWN for the whole UTC day and disable versioning — next session retries.
    mkdir -p "$VAULT_DIR" 2>/dev/null
    printf '%s %s\n' "$today" "$vis" > "$cache" 2>/dev/null
  else
    vis="UNKNOWN"
  fi
  echo "$vis"
}

# The locked body of the SessionEnd push (the flock is held via fd 9). Benign
# errors are quiet (note:), real errors are loud (WARN:) — OQ-A3.
_vault_push_locked() {
  local vis out slug leaked
  vis=$(cached_repo_visibility)
  if [ "$vis" != "PRIVATE" ]; then
    echo "note: memory push skipped (visibility=$vis)" >&2
    return 0
  fi
  if ! out=$(mgit add -A 2>&1); then
    echo "WARN: memory vault stage failed: $out" >&2
    return 0
  fi
  # SAFETY (scrutiny finding 1): re-assert ONLY */memory/** is staged, EVERY run.
  # An in-tree .gitignore OVERRIDES core.excludesFile (documented git precedence:
  # excludesFile is the lowest), so the whitelist is not a hard guarantee. Without
  # this, a negating .gitignore under a slug would silently commit+push transcripts
  # into permanent history — the exact catastrophic leak. bootstrap asserts this
  # once at commit #1; the every-session path must too. Refuse loudly, unstage.
  leaked=$(mgit diff --cached --name-only 2>/dev/null | grep -vE '/memory/' || true)
  if [ -n "$leaked" ]; then
    mgit reset -q 2>/dev/null || true
    echo "WARN: memory vault REFUSED — non-memory path(s) staged (excludes bypassed?):" >&2
    printf '%s\n' "$leaked" | head >&2
    return 0
  fi
  if mgit diff --cached --quiet 2>/dev/null; then
    return 0                                   # nothing changed
  fi
  # Name the commit after the slug(s) whose memory ACTUALLY changed — derived from the
  # STAGED files, not $PWD. A session-end commits whatever memory changed across ALL
  # slugs, so the committing session's cwd frequently mismatched the content (the
  # message claimed one folder while changing another — explore-ha3v).
  local slugs nslugs subj; local -a msg
  slugs=$(mgit diff --cached --name-only 2>/dev/null | sed 's#/memory/.*##' | sort -u | grep -v '^$' || true)
  nslugs=$(printf '%s\n' "$slugs" | grep -c . || true)
  if [ "$nslugs" -le 1 ]; then
    subj="memory: ${slugs:-$(printf '%s' "$PWD" | sed 's#/#-#g')} $(date -u +%FT%TZ)"
    msg=(-m "$subj")
  else
    subj="memory: ${nslugs} slugs $(date -u +%FT%TZ)"
    msg=(-m "$subj" -m "$(printf '%s\n' "$slugs")")   # full slug list in the body
  fi
  # authored by Zig (vault inherits the global git identity — no repo-local override,
  # explore-62q5), Claude as co-author. Supersedes OQ-E6's distinct-bot-identity.
  msg+=(-m "Co-Authored-By: Claude <noreply@anthropic.com>")
  if ! out=$(mgit commit -q "${msg[@]}" 2>&1); then
    # a pre-commit-hook block (Layer 1 secret gate) or a real fs failure — loud.
    echo "WARN: memory vault commit blocked/failed:" >&2
    printf '%s\n' "$out" >&2
    return 0
  fi
  # reconcile then best-effort push — bounded by timeout (finding 3), benign on
  # failure (OQ-A1/A3: non-fast-forward / offline are quiet).
  mgit_net pull --rebase --autostash -q origin main >/dev/null 2>&1 || true
  if ! mgit_net push -q origin main >/dev/null 2>&1; then
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
