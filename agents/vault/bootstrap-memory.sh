#!/usr/bin/env bash
# bootstrap-memory.sh — one-time init of the claude-memory vault (explore-76oc §4.1).
#
# Fail-loud + gated. Creates the PRIVATE repo and commit #1 (PERMANENT history)
# ONLY after (a) the secret audit gate passes and (b) the "only */memory/**
# staged" assertion holds. Any violation aborts before a single commit lands.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/vault-lib.sh"

echo "== claude-memory vault bootstrap =="

# 0. idempotency guard --------------------------------------------------------
if [ -d "$MEMORY_GIT" ]; then
  echo "ABORT: $MEMORY_GIT already exists — vault already bootstrapped." >&2
  exit 1
fi

# 1. AUDIT GATE (OQ-B2/B3) — commit #1 is permanent, so scan the live tier FIRST.
echo "-- audit gate: scanning memory tier for high-confidence secrets --"
MEM=("$HOME"/.claude/projects/*/memory)
if [ ! -e "${MEM[0]}" ]; then
  echo "ABORT: no memory dirs under $MEMORY_WORKTREE." >&2
  exit 1
fi
if ! python3 "$SCRUB" scan "${MEM[@]}"; then
  echo "ABORT: secret audit gate FAILED — redact the finding(s) before bootstrapping." >&2
  exit 1
fi
echo "   audit gate: CLEAN"

# 2. create the PRIVATE repo --------------------------------------------------
if gh repo view "$MEMORY_REPO" >/dev/null 2>&1; then
  echo "   remote $MEMORY_REPO already exists — reusing"
else
  gh repo create "$MEMORY_REPO" --private \
    --description "Claude Code harness memory tier (auto-committed vault)"
fi

# 3. init the detached vault --------------------------------------------------
mkdir -p "$VAULT_DIR"
mvault init -q
if [ -e "$MEMORY_WORKTREE/.git" ]; then
  echo "ABORT: $MEMORY_WORKTREE/.git exists — detached layout broken (D1)." >&2
  exit 1
fi
echo "   init OK — no .git at the work-tree root"

# 4. repo-LOCAL creds + hooksPath — NEVER --global (explore-62q5).
# Identity: intentionally NOT set repo-locally — the vault INHERITS the machine's
# global git identity (Zig's), so vault commits are authored by Zig with Claude as
# co-author (see the commit trailer in vault-lib.sh). This supersedes OQ-E6's
# "distinct bot identity" (Zig 2026-07-08: commit as me, Claude co-authors).
git --git-dir="$MEMORY_GIT" config credential.helper '!gh auth git-credential'
git --git-dir="$MEMORY_GIT" config core.hooksPath "$MEMORY_GIT/hooks"

# 5. install the Layer-1 pre-commit secret gate -------------------------------
install -m 0755 "$HERE/pre-commit-scrub" "$MEMORY_GIT/hooks/pre-commit"
echo "   installed Layer-1 pre-commit hook"

# 6. stage + ASSERT only */memory/** staged (D1 correctness) ------------------
mvault add -A
outside=$(mvault status --porcelain | grep -vE '/memory/' || true)
if [ -n "$outside" ]; then
  echo "ABORT: files staged OUTSIDE */memory/ — excludes misfire. NOT committing:" >&2
  printf '%s\n' "$outside" | head >&2
  exit 1
fi
staged=$(mvault status --porcelain | wc -l | tr -d ' ')
echo "   staged $staged memory path(s) — all under */memory/ ✓"
if mvault status --porcelain | grep -qE 'home-ubuntu-(linearb|cfp)'; then
  echo "   confidential slugs (linearb/cfp) included per D3 ✓"
else
  echo "   note: no linearb/cfp memory staged (none present on disk?)"
fi

# 7. commit #1 (hook re-runs the gate) + push ---------------------------------
# authored by Zig (inherited global identity), Claude as co-author.
mvault commit -q -m "memory: initial snapshot $(date -u +%FT%TZ)" \
                 -m "Co-Authored-By: Claude <noreply@anthropic.com>"
mvault branch -M main
mvault remote add origin "https://github.com/$MEMORY_REPO.git"
mvault push -u origin main

echo "== bootstrap complete: $MEMORY_REPO (PRIVATE) =="
mvault log --oneline -1
