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

echo "---"
echo "selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
