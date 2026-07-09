#!/usr/bin/env bash
# bootstrap-transcripts.sh — one-time init of the claude-transcripts vault
# (explore-76oc §4.3). Reuses the proven detached-git-dir pattern from the memory
# vault. Fail-loud + gated: creates the PRIVATE repo and commit #1 (PERMANENT
# history) ONLY after (a) the full-tree secret audit gate passes, (b) the size guard
# has chunked any >=99 MiB file (split-on-copy) so no blob breaches the 100 MiB wall,
# and (c) the "only transcript paths staged, none under */memory/" assertion holds.
#
#   bootstrap-transcripts.sh --dry-run   # validate gate + staging vs the LIVE tree
#                                          in a throwaway git-dir; no repo, no commit.
#   bootstrap-transcripts.sh             # the real bootstrap.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/transcripts-lib.sh"

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
LBL=""; [ "$DRY" -eq 1 ] && LBL=" (DRY RUN)"

echo "== claude-transcripts vault bootstrap${LBL} =="

# 0. idempotency guard --------------------------------------------------------
if [ "$DRY" -eq 0 ] && [ -d "$TRANSCRIPTS_GIT" ]; then
  echo "ABORT: $TRANSCRIPTS_GIT already exists — vault already bootstrapped." >&2
  exit 1
fi
if [ ! -d "$TRANSCRIPTS_WORKTREE" ]; then
  echo "ABORT: work-tree $TRANSCRIPTS_WORKTREE missing." >&2; exit 1
fi

# 1. AUDIT GATE (OQ-B2/B3) — commit #1 is permanent, so scan the FULL tier first.
#    Scans the whole projects tree (jsonl/txt/md); memory was already audited in
#    Phase 1, so a superset scan is simply thorough. ~1-2 min over 3.7 GB.
echo "-- audit gate: scanning transcript tier for high-confidence secrets (may take ~1-2 min) --"
if ! python3 "$SCRUB" scan "$TRANSCRIPTS_WORKTREE"; then
  echo "ABORT: secret audit gate FAILED — rotate + redact the finding(s) before bootstrapping." >&2
  exit 1
fi
echo "   audit gate: CLEAN"

# For a dry run, use a THROWAWAY git-dir over the live tree so we never create the
# real vault. For the real run, use the canonical detached git-dir.
if [ "$DRY" -eq 1 ]; then
  TRANSCRIPTS_GIT=$(mktemp -d)/dry.git
  export TRANSCRIPTS_GIT
fi

# 2. create the PRIVATE repo (real run only) ----------------------------------
if [ "$DRY" -eq 0 ]; then
  if gh repo view "$TRANSCRIPTS_REPO" >/dev/null 2>&1; then
    echo "   remote $TRANSCRIPTS_REPO already exists — reusing"
  else
    gh repo create "$TRANSCRIPTS_REPO" --private \
      --description "Claude Code harness transcript tier (auto-committed vault)"
  fi
fi

# 3. init the detached vault --------------------------------------------------
mkdir -p "$(dirname "$TRANSCRIPTS_GIT")"
tvault init -q
if [ -e "$TRANSCRIPTS_WORKTREE/.git" ]; then
  echo "ABORT: $TRANSCRIPTS_WORKTREE/.git exists — detached layout broken (D1/E7)." >&2
  exit 1
fi
echo "   init OK — no .git at the work-tree root"

# 4. repo-LOCAL creds + hooksPath — NEVER --global (explore-62q5). Identity inherited.
git --git-dir="$TRANSCRIPTS_GIT" config credential.helper '!gh auth git-credential'
git --git-dir="$TRANSCRIPTS_GIT" config core.hooksPath "$TRANSCRIPTS_GIT/hooks"

# 5. install the Layer-1 pre-commit gate (secret scan + size wall) ------------
mkdir -p "$TRANSCRIPTS_GIT/hooks"
install -m 0755 "$HERE/pre-commit-scrub-transcripts" "$TRANSCRIPTS_GIT/hooks/pre-commit"
echo "   installed Layer-1 pre-commit hook (secret scan + 100 MiB wall)"

# 6. stage + size-guard (split-on-copy) + ASSERT only transcript paths --------
if [ "$DRY" -eq 1 ]; then
  # LIGHT validation: list would-stage paths WITHOUT hashing 3.7 GB into objects
  # (a real `add -A` into a /tmp git-dir could exhaust tmpfs). `add -An` honors the
  # excludesFile and writes no objects. The size guard itself is proven by the
  # isolated selftest (TT3), so the dry run only needs to confirm the whitelist on
  # the REAL tree + the audit gate + count would-be-chunked files.
  echo "-- dry: computing would-stage paths (git add -An, no object writes) --"
  wouldadd=$(tgit add -An 2>/dev/null | sed "s/^add '//; s/'$//")
  badmem=$(printf '%s\n' "$wouldadd" | grep -E '/memory/' || true)
  badoth=$(printf '%s\n' "$wouldadd" | grep -Ev '(\.jsonl|/tool-results/[^/]+\.txt)$' | grep -v '^$' || true)
  if [ -n "$badmem" ] || [ -n "$badoth" ]; then
    echo "ABORT(dry): would stage non-transcript or memory paths:" >&2
    printf '%s\n' "$badmem" "$badoth" | grep -v '^$' | head >&2
    rm -rf "$(dirname "$TRANSCRIPTS_GIT")"; exit 1
  fi
  n=$(printf '%s\n' "$wouldadd" | grep -cv '^$' || true)   # || true: grep exits 1 on empty (F5)
  big=$(find "$TRANSCRIPTS_WORKTREE" -type f \( -name '*.jsonl' -o -path '*/tool-results/*.txt' \) \
          -size +"${TS_SPLIT_TRIGGER}c" 2>/dev/null | wc -l | tr -d ' ') || big=0   # find/pipefail guard
  echo ""
  echo "== DRY RUN complete — audit gate CLEAN; whitelist valid on the live tree =="
  echo "   $n transcript path(s) would stage; 0 memory/junk; $big file(s) >=99 MiB would be split-on-copy."
  rm -rf "$(dirname "$TRANSCRIPTS_GIT")"
  exit 0
fi
# 7. BATCHED initial import — commit+push in size-bounded slug groups so no single
#    push exceeds ~1.5 GiB (a single 3.7 GB HTTPS push can be rejected/time out).
#    Each batch: stage the group's paths → size guard → leak assert → commit → push
#    (the pre-commit hook re-runs the secret scan + size wall per batch). Authored by
#    Zig (inherited global identity), Claude as co-author. Uses a bare `tvault push`
#    (NOT tgit_net) so a large push isn't killed by the daily-push timeout.
BUDGET_BYTES="${TS_BOOTSTRAP_BATCH_BYTES:-1610612736}"   # 1.5 GiB per push
REMOTE_SET=0; BATCH=0
group=(); gsize=0

_flush_group() {
  [ "${#group[@]}" -eq 0 ] && return 0
  tgit add -A -- "${group[@]}"
  _transcripts_apply_size_guard || { echo "ABORT: size guard failed in batch." >&2; exit 1; }
  local leaked; leaked=$(_transcripts_leaked_paths) || true
  if [ -n "$leaked" ]; then
    echo "ABORT: non-transcript/memory path(s) staged in batch — NOT committing:" >&2
    printf '%s\n' "$leaked" | head >&2; exit 1
  fi
  if tgit diff --cached --quiet 2>/dev/null; then group=(); gsize=0; return 0; fi
  BATCH=$((BATCH+1))
  local n; n=$(tgit diff --cached --name-only | wc -l | tr -d ' ')
  echo "-- batch $BATCH: committing $n path(s) (~$((gsize/1048576)) MiB) --"
  tgit commit -q -m "transcripts: initial import batch $BATCH $(date -u +%FT%TZ)" \
                 -m "Co-Authored-By: Claude <noreply@anthropic.com>"
  if [ "$REMOTE_SET" -eq 0 ]; then
    tgit branch -M main
    tgit remote add origin "https://github.com/$TRANSCRIPTS_REPO.git"
    echo "-- pushing batch $BATCH (establishes main) --"
    tvault push -u origin main
    REMOTE_SET=1
  else
    echo "-- pushing batch $BATCH --"
    tvault push origin main
  fi
  group=(); gsize=0
}

echo "-- batched initial import (budget $((BUDGET_BYTES/1048576)) MiB/push) --"
for d in "$TRANSCRIPTS_WORKTREE"/*/; do
  [ -d "$d" ] || continue
  slug=$(basename "$d")
  sz=$(du -sb "$d" 2>/dev/null | cut -f1) || sz=0; : "${sz:=0}"
  group+=("$slug")
  gsize=$((gsize + sz))
  [ "$gsize" -ge "$BUDGET_BYTES" ] && _flush_group
done
_flush_group

echo "== bootstrap complete: $TRANSCRIPTS_REPO (PRIVATE) — $BATCH batch(es) =="
tgit log --oneline -1
