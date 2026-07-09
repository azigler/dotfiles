#!/usr/bin/env bash
# vault-selftest-transcripts.sh — Phase-3 §5 tests for the claude-transcripts vault.
# The ISOLATED tests (TT*) run anytime — throwaway git-dir + fake tree via env
# overrides, never touching the live vault or the live projects tree; size tests use
# lowered TS_* thresholds to exercise the LOGIC without 100 MB of I/O. The LIVE tests
# (LT*) assert against the bootstrapped vault (skipped if not bootstrapped).
# Exit 0 = all green, 1 = a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/transcripts-lib.sh"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# ============================ ISOLATED TESTS ============================

# TT1 — whitelist stages ONLY transcripts (main + deep subagent + tool-results txt),
# never memory (.md or a stray .jsonl), never stray txt/config.
(
  tw=$(mktemp -d)
  export VAULT_DIR="$tw/v" TRANSCRIPTS_GIT="$tw/v/t.git" TRANSCRIPTS_WORKTREE="$tw/wt"
  mkdir -p "$TRANSCRIPTS_WORKTREE/-p/u1/subagents/w/x" "$TRANSCRIPTS_WORKTREE/-p/u1/tool-results" \
           "$TRANSCRIPTS_WORKTREE/-p/memory" "$VAULT_DIR"
  echo m  > "$TRANSCRIPTS_WORKTREE/-p/u1.jsonl"
  echo s  > "$TRANSCRIPTS_WORKTREE/-p/u1/subagents/w/x/journal.jsonl"
  echo t  > "$TRANSCRIPTS_WORKTREE/-p/u1/tool-results/r.txt"
  echo md > "$TRANSCRIPTS_WORKTREE/-p/memory/MEMORY.md"
  echo mj > "$TRANSCRIPTS_WORKTREE/-p/memory/stray.jsonl"
  echo n  > "$TRANSCRIPTS_WORKTREE/-p/notes.txt"
  echo c  > "$TRANSCRIPTS_WORKTREE/-p/config.json"
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" init -q
  tgit add -A
  s=$(tgit diff --cached --name-only)
  rc=0
  printf '%s\n' "$s" | grep -q '/memory/' && rc=1
  printf '%s\n' "$s" | grep -qE 'notes\.txt|config\.json' && rc=1
  printf '%s\n' "$s" | grep -q 'u1.jsonl' || rc=1
  printf '%s\n' "$s" | grep -q 'subagents/w/x/journal.jsonl' || rc=1
  printf '%s\n' "$s" | grep -q 'tool-results/r.txt' || rc=1
  rm -rf "$tw"; exit $rc
) && ok "whitelist-stages-only-transcripts" || no "whitelist-stages-only-transcripts"

# TT2 — inverse leak-guard refuses a memory path even when an in-tree .gitignore
# bypasses core.excludesFile (scrutiny-finding-1 class); no commit slips through.
(
  tw=$(mktemp -d)
  export VAULT_DIR="$tw/v" TRANSCRIPTS_GIT="$tw/v/t.git" TRANSCRIPTS_WORKTREE="$tw/wt" \
         TRANSCRIPTS_LOCK="$tw/v/.lock" TRANSCRIPTS_VISCACHE="$tw/v/.vis"
  mkdir -p "$TRANSCRIPTS_WORKTREE/-p/memory" "$VAULT_DIR"
  echo real > "$TRANSCRIPTS_WORKTREE/-p/u.jsonl"
  echo mem  > "$TRANSCRIPTS_WORKTREE/-p/memory/M.md"
  printf '!*\n'    > "$TRANSCRIPTS_WORKTREE/-p/.gitignore"     # negate excludes → try to stage everything
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" init -q
  git --git-dir="$TRANSCRIPTS_GIT" config user.name t; git --git-dir="$TRANSCRIPTS_GIT" config user.email t@t
  printf '%s PRIVATE\n' "$(date -u +%F)" > "$TRANSCRIPTS_VISCACHE"
  _transcripts_push_locked >/dev/null 2>&1 || true
  # the guard must have refused: NO commit, and the memory file is not tracked.
  if git --git-dir="$TRANSCRIPTS_GIT" rev-parse HEAD >/dev/null 2>&1 \
     || git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" ls-files | grep -q 'memory/'; then
    rm -rf "$tw"; exit 1
  fi
  rm -rf "$tw"; exit 0
) && ok "inverse-leak-guard-refuses-memory" || no "inverse-leak-guard-refuses-memory"

# TT3 — split-on-copy round-trips byte-identically; original not tracked; parts each
# under the (lowered) wall. Uses tiny thresholds to avoid 100 MB of I/O.
(
  tw=$(mktemp -d)
  export VAULT_DIR="$tw/v" TRANSCRIPTS_GIT="$tw/v/t.git" TRANSCRIPTS_WORKTREE="$tw/wt" \
         TS_SPLIT_TRIGGER=4096 TS_CHUNK_HUMAN=2K TS_WARN_BYTES=1024 TS_WALL_BYTES=1048576
  mkdir -p "$TRANSCRIPTS_WORKTREE/-p/u1" "$VAULT_DIR"
  orig="$TRANSCRIPTS_WORKTREE/-p/u1/big.jsonl"
  yes '{"k":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' | head -120 > "$orig"  # ~8.5 KB
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" init -q
  tgit add -A
  _transcripts_apply_size_guard || { rm -rf "$tw"; exit 1; }
  s=$(tgit diff --cached --name-only)
  rc=0
  printf '%s\n' "$s" | grep -qx -- '-p/u1/big.jsonl' && rc=1               # original must NOT be tracked
  np=$(printf '%s\n' "$s" | grep -c -- '-p/u1/big.jsonl.part[0-9]' || true)
  [ "$np" -ge 2 ] || rc=1                                                   # split into >=2 parts
  cat_out=$(mktemp)
  for pp in $(printf '%s\n' "$s" | grep -- '-p/u1/big.jsonl.part' | sort); do
    tgit cat-file -p ":$pp" >> "$cat_out"
  done
  cmp -s "$cat_out" "$orig" || rc=1                                         # concat(parts) == original
  # each part strictly under the (lowered) wall
  for pp in $(printf '%s\n' "$s" | grep -- '-p/u1/big.jsonl.part'); do
    bs=$(tgit cat-file -s ":$pp"); [ "$bs" -lt "$TS_WALL_BYTES" ] || rc=1
  done
  rm -f "$cat_out"; rm -rf "$tw"; exit $rc
) && ok "split-on-copy-round-trips-and-original-untracked" || no "split-on-copy-round-trips-and-original-untracked"

# TT4 — the pre-commit 100 MiB wall blocks a staged over-wall blob (lowered wall so
# a tiny file trips it; proves the belt-and-suspenders without 100 MB of I/O).
(
  tw=$(mktemp -d)
  export TRANSCRIPTS_GIT="$tw/t.git" TRANSCRIPTS_WORKTREE="$tw/wt"
  mkdir -p "$TRANSCRIPTS_WORKTREE/-p" "$tw"
  head -c 4096 /dev/zero | tr '\0' 'a' > "$TRANSCRIPTS_WORKTREE/-p/u.jsonl"
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" init -q
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" -c core.excludesFile="$TRANSCRIPTS_EXCLUDES" add -A
  # run the hook directly with a lowered wall + git env
  out=$(GIT_DIR="$TRANSCRIPTS_GIT" GIT_WORK_TREE="$TRANSCRIPTS_WORKTREE" TS_WALL_BYTES=2000 \
        bash "$HERE/pre-commit-scrub-transcripts" 2>&1); hrc=$?
  rm -rf "$tw"
  { [ "$hrc" -ne 0 ] && printf '%s' "$out" | grep -q '>= 100 MiB'; } && exit 0 || exit 1
) && ok "pre-commit-100MiB-wall-blocks" || no "pre-commit-100MiB-wall-blocks"

# TT5 — REGRESSION: the leak-guard must return 0 (success) on a CLEAN index under
# `set -e`. grep exits 1 when it matches nothing (the good/no-leak case); without the
# `|| true` guards, `leaked=$(_transcripts_leaked_paths)` silently aborted the first
# bootstrap on the no-leak path. This guards that footgun.
(
  tw=$(mktemp -d)
  export VAULT_DIR="$tw/v" TRANSCRIPTS_GIT="$tw/v/t.git" TRANSCRIPTS_WORKTREE="$tw/wt"
  mkdir -p "$TRANSCRIPTS_WORKTREE/-p" "$VAULT_DIR"
  echo ok > "$TRANSCRIPTS_WORKTREE/-p/u.jsonl"
  git --git-dir="$TRANSCRIPTS_GIT" --work-tree="$TRANSCRIPTS_WORKTREE" init -q
  tgit add -A                                    # only a clean transcript staged → no leak
  ( set -e; l=$(_transcripts_leaked_paths); [ -z "$l" ] )   # must NOT abort, must be empty
  rc=$?
  rm -rf "$tw"; exit $rc
) && ok "leak-guard-returns-0-on-clean-under-set-e" || no "leak-guard-returns-0-on-clean-under-set-e"

# ============================ LIVE-VAULT TESTS ============================
if [ ! -d "$TRANSCRIPTS_GIT" ]; then
  echo "SKIP (live): transcripts vault not bootstrapped ($TRANSCRIPTS_GIT)"
else
  # LT1 — tracks only transcript paths (+ .partNNN), none under memory/.
  bad=$(tgit ls-files | grep -Ev '(\.jsonl|/tool-results/[^/]+\.txt)(\.part[0-9]{3})?$' || true)
  mem=$(tgit ls-files | grep '/memory/' || true)
  if [ -z "$bad" ] && [ -z "$mem" ]; then ok "live-tracks-only-transcripts"; else
    no "live-tracks-only-transcripts"; printf '%s\n' "$bad" "$mem" | head >&2; fi

  # LT2 — no .git at the work-tree root (D1/E7).
  if [ -e "$TRANSCRIPTS_WORKTREE/.git" ]; then no "live-no-git-at-tree-root"; else ok "live-no-git-at-tree-root"; fi

  # LT3 — vaults-share-one-tree: memory & transcripts vaults track DISJOINT paths.
  MG="${MEMORY_GIT:-$VAULT_DIR/memory.git}"
  if [ -d "$MG" ]; then
    both=$(comm -12 \
      <(git --git-dir="$MG" ls-files 2>/dev/null | LC_ALL=C sort) \
      <(tgit ls-files 2>/dev/null | LC_ALL=C sort) )
    if [ -z "$both" ]; then ok "vaults-share-one-tree-disjoint"; else
      no "vaults-share-one-tree-disjoint (a path is tracked by BOTH)"; printf '%s\n' "$both" | head >&2; fi
  else
    echo "SKIP: vaults-share-one-tree (memory vault not present)"
  fi

  # LT4 — repo is PRIVATE (visibility guard precondition).
  rv=$(t_cached_repo_visibility)
  if [ "$rv" = "PRIVATE" ]; then ok "live-repo-visibility-PRIVATE"; else no "live-repo-visibility (got $rv)"; fi
fi

echo "---"
echo "transcripts selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
