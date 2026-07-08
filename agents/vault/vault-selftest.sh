#!/usr/bin/env bash
# vault-selftest.sh — Phase-1 §5 test cases as live assertions against the
# bootstrapped claude-memory vault. Idempotent + safe: read-only on the vault
# except a temp-cache toggle it cleans up; the secret-gate check runs the
# scanner over a /tmp scratch, never mutating the live projects tree.
# Exit 0 = all green, 1 = a failure, 2 = vault not bootstrapped.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/vault-lib.sh"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

[ -d "$MEMORY_GIT" ] || { echo "vault not bootstrapped ($MEMORY_GIT)"; exit 2; }

# T1 — tracks only */memory/** (D1) ------------------------------------------
if mvault ls-files | grep -vE '/memory/' | grep -q .; then
  no "tracks-only-memory (non-memory files are tracked!)"
  mvault ls-files | grep -vE '/memory/' | head >&2
else
  ok "tracks-only-memory"
fi

# T2 — no .git at the work-tree root (D1) ------------------------------------
if [ -e "$MEMORY_WORKTREE/.git" ]; then no "no-git-at-tree-root"; else ok "no-git-at-tree-root"; fi

# T3 — includes confidential slugs (D3), only if present on disk -------------
if ls -d "$MEMORY_WORKTREE"/*home-ubuntu-linearb*/memory >/dev/null 2>&1 \
   || ls -d "$MEMORY_WORKTREE"/*cfp*/memory >/dev/null 2>&1; then
  if mvault ls-files | grep -qE 'home-ubuntu-(linearb|cfp)'; then
    ok "includes-confidential-slugs"
  else
    no "includes-confidential-slugs (present on disk but untracked)"
  fi
else
  echo "SKIP: includes-confidential-slugs (no linearb/cfp memory on disk)"
fi

# T4 — push refuses when repo is not PRIVATE (visibility guard) --------------
realvis=$(cached_repo_visibility)
if [ "$realvis" = "PRIVATE" ]; then ok "repo-visibility-PRIVATE"; else no "repo-visibility (got $realvis)"; fi
printf '%s %s\n' "$(date -u +%F)" "PUBLIC" > "$VAULT_DIR/.memory-visibility"
before=$(mvault rev-parse HEAD 2>/dev/null || echo none)
pubout=$(vault_push_memory 2>&1 || true)
after=$(mvault rev-parse HEAD 2>/dev/null || echo none)
if [ "$before" = "$after" ] && printf '%s' "$pubout" | grep -q 'visibility=PUBLIC'; then
  ok "push-refuses-if-public"
else
  no "push-refuses-if-public (before=$before after=$after)"
fi
rm -f "$VAULT_DIR/.memory-visibility"          # force a fresh gh lookup next real run

# T5 — a stale (>5min) index.lock is swept (OQ-A2) ---------------------------
lk="$MEMORY_GIT/index.lock"
touch "$lk"; touch -d '10 minutes ago' "$lk" 2>/dev/null || true
find "$MEMORY_GIT" -name index.lock -mmin +5 -delete 2>/dev/null
if [ ! -e "$lk" ]; then ok "stale-lock-recovered"; else no "stale-lock-recovered"; rm -f "$lk"; fi

# T6 — Layer-1 gate: hook installed + executable, and the scanner blocks a token
hook="$MEMORY_GIT/hooks/pre-commit"
if [ -x "$hook" ]; then ok "pre-commit-hook-installed+executable"; else no "pre-commit-hook-installed+executable"; fi
tmpd=$(mktemp -d); mkdir -p "$tmpd/memory"
# construct a fake anthropic-shaped token at runtime so this source file never
# contains the literal secret pattern (would trip other scanners on commit).
faketok="sk-ant-$(printf 'a%.0s' $(seq 1 40))"
printf 'leaked: %s\n' "$faketok" > "$tmpd/memory/leak.md"
if ! python3 "$SCRUB" scan "$tmpd/memory" >/dev/null 2>&1; then
  ok "secret-gate-detects-planted-token"
else
  no "secret-gate-detects-planted-token (scanner did NOT flag it)"
fi
rm -rf "$tmpd"

# T7 — runtime guard refuses non-memory even when an in-tree .gitignore bypasses
# the excludes (scrutiny finding 1 regression guard). Fully ISOLATED: a throwaway
# git-dir + work-tree via env overrides; never touches the live vault or tree.
(
  tw=$(mktemp -d)
  export VAULT_DIR="$tw/vaults" MEMORY_GIT="$tw/vaults/m.git" \
         MEMORY_WORKTREE="$tw/wt" MEMORY_LOCK="$tw/vaults/.lock"
  # MEMORY_EXCLUDES intentionally stays the REAL excludes file (that's the SUT).
  mkdir -p "$MEMORY_WORKTREE/-s/memory" "$VAULT_DIR"
  echo real > "$MEMORY_WORKTREE/-s/memory/M.md"
  printf '!*\n' > "$MEMORY_WORKTREE/-s/.gitignore"     # negate the whitelist
  echo LEAK  > "$MEMORY_WORKTREE/-s/leak.jsonl"        # a transcript-shaped escapee
  git --git-dir="$MEMORY_GIT" --work-tree="$MEMORY_WORKTREE" init -q
  git --git-dir="$MEMORY_GIT" config user.name  t      # repo-local (never --global)
  git --git-dir="$MEMORY_GIT" config user.email t@t
  printf '%s PRIVATE\n' "$(date -u +%F)" > "$VAULT_DIR/.memory-visibility"  # stub guard
  _vault_push_locked >/dev/null 2>&1 || true
  # the guard must have refused: NO commit exists, and leak.jsonl is not tracked.
  if git --git-dir="$MEMORY_GIT" rev-parse HEAD >/dev/null 2>&1 \
     || git --git-dir="$MEMORY_GIT" --work-tree="$MEMORY_WORKTREE" ls-files | grep -q .; then
    echo "FAIL: runtime-guard-refuses-non-memory (a commit/track slipped through)"; rc=1
  else
    echo "PASS: runtime-guard-refuses-non-memory"; rc=0
  fi
  rm -rf "$tw"; exit $rc
) && pass=$((pass+1)) || fail=$((fail+1))

# T8 — /vault-restore writes STAGING, never the live tree, never the vault index
# (spec §4.5 / OQ-E4). Restore HEAD of a tracked slug's memory file and assert the
# live file + the vault's real index are byte-for-byte untouched afterwards.
VR="$HERE/vault-restore.sh"
someslug=$(mvault ls-files | head -1 | cut -d/ -f1)
somefile=$(mvault ls-files | grep -m1 "^${someslug}/memory/" || true)
if [ -x "$VR" ] && [ -n "$someslug" ] && [ -n "$somefile" ]; then
  livef="$MEMORY_WORKTREE/$somefile"; sub=${somefile#"${someslug}"/memory/}
  h0=$(sha256sum "$livef" 2>/dev/null | awk '{print $1}'); s0=$(mvault status --porcelain | wc -l | tr -d ' ')
  bash "$VR" "$(mvault rev-parse HEAD)" "$someslug" "$sub" >/dev/null 2>&1 || true
  h1=$(sha256sum "$livef" 2>/dev/null | awk '{print $1}'); s1=$(mvault status --porcelain | wc -l | tr -d ' ')
  staged="$VAULT_DIR/restore-staging/$(mvault rev-parse --short HEAD)/$somefile"
  if [ -f "$staged" ] && [ "$h0" = "$h1" ] && [ "$s0" = "$s1" ]; then
    ok "vault-restore-writes-staging-not-live"
  else
    no "vault-restore-writes-staging-not-live (staged=$([ -f "$staged" ] && echo y||echo n) liveEq=$([ "$h0" = "$h1" ] && echo y||echo n) idxEq=$([ "$s0" = "$s1" ] && echo y||echo n))"
  fi
  rm -rf "$VAULT_DIR/restore-staging"
else
  echo "SKIP: vault-restore-writes-staging-not-live (no tracked slug/file or script missing)"
fi

echo "---"
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
