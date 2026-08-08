#!/bin/bash
# Test for agents-root.sh — the shared "~/.agents vs $HOME/dotfiles/agents"
# resolver (dotfiles-tm0w). Hermetic: every case runs with $HOME pointed at a
# throwaway dir, so the real ~/.agents (currently an unrelated aaif
# skill-lock) and the real ~/dotfiles are never read.
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on
# the last line.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/agents-root.sh"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# new_home <name> -> path to a fresh fake $HOME with NOTHING pre-populated.
new_home() {
  local h="$BASE/$1"
  mkdir -p "$h"
  printf '%s' "$h"
}

# --- 1. Neither ~/.agents nor $HOME/dotfiles/agents exists -> unresolvable,
#        empty stdout, non-zero return. THE core "void" case the bead asks to
#        demonstrate.
H=$(new_home void)
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root')
RC=$?
if [ "$RC" -ne 0 ]; then ok; else bad "void: agents_root must return non-zero"; fi
if [ -z "$OUT" ]; then ok; else bad "void: agents_root must print nothing (got '$OUT')"; fi

# --- 2. Only $HOME/dotfiles/agents exists (today's real shape) -> resolves
#        to it.
H=$(new_home dotfiles-only)
mkdir -p "$H/dotfiles/agents/lib"
touch "$H/dotfiles/agents/AGENTS.md"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root')
if [ "$OUT" = "$H/dotfiles/agents" ]; then ok; else bad "dotfiles-only: got '$OUT'"; fi

# --- 3. ~/.agents holds the REAL demesne shape (agents/AGENTS.md as a
#        subdir, matching the verified ~/demesne layout) AND dotfiles/agents
#        also exists -> ~/.agents wins (preferred).
H=$(new_home demesne-shape)
mkdir -p "$H/.agents/agents/lib" "$H/dotfiles/agents/lib"
touch "$H/.agents/agents/AGENTS.md" "$H/dotfiles/agents/AGENTS.md"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root')
if [ "$OUT" = "$H/.agents/agents" ]; then ok; else bad "demesne-shape: got '$OUT' (want $H/.agents/agents)"; fi

# --- 4. ~/.agents holds ONLY the unrelated aaif skill-lock (the box's REAL
#        current state) -> must NOT be mistaken for the tier; falls back to
#        dotfiles/agents.
H=$(new_home aaif-lock)
mkdir -p "$H/.agents/skills" "$H/dotfiles/agents/lib"
touch "$H/.agents/.skill-lock.json" "$H/dotfiles/agents/AGENTS.md"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root')
if [ "$OUT" = "$H/dotfiles/agents" ]; then ok; else bad "aaif-lock: got '$OUT' (must not treat the skill-lock dir as the tier)"; fi

# --- 5. ~/.agents is a flat tier (AGENTS.md directly under it, no
#        agents/ subdir) -> the flatter-shape tolerance still resolves it.
H=$(new_home flat-shape)
mkdir -p "$H/.agents/lib" "$H/dotfiles/agents"
touch "$H/.agents/AGENTS.md"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root')
if [ "$OUT" = "$H/.agents" ]; then ok; else bad "flat-shape: got '$OUT' (want $H/.agents)"; fi

# --- 6. subtier=claude, demesne shape present -> resolves to
#        ~/.agents/claude (the settings.json marker).
H=$(new_home claude-demesne)
mkdir -p "$H/.agents/claude" "$H/dotfiles/claude"
touch "$H/.agents/claude/settings.json" "$H/dotfiles/claude/settings.json"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root claude')
if [ "$OUT" = "$H/.agents/claude" ]; then ok; else bad "claude-demesne: got '$OUT' (want $H/.agents/claude)"; fi

# --- 7. subtier=claude, only dotfiles/claude exists -> falls back, and the
#        flat-~/.agents tolerance (rule 2, agents-only) must NOT apply here.
H=$(new_home claude-fallback)
mkdir -p "$H/.agents" "$H/dotfiles/claude"
touch "$H/.agents/AGENTS.md"          # would satisfy the agents flat-shape rule
touch "$H/dotfiles/claude/settings.json"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root claude')
if [ "$OUT" = "$H/dotfiles/claude" ]; then ok; else bad "claude-fallback: got '$OUT' (want $H/dotfiles/claude; must not borrow the agents flat-shape rule)"; fi

# --- 8. subtier=claude, void (neither candidate) -> unresolvable ---------
H=$(new_home claude-void)
mkdir -p "$H"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root claude')
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then ok; else bad "claude-void: got rc=$RC out='$OUT'"; fi

# --- 9. an aaif-lock-only ~/.agents does not accidentally satisfy the
#        agents/<subtier> candidate for OTHER subtiers either (no marker
#        file present under .agents/claude at all).
H=$(new_home aaif-lock-claude)
mkdir -p "$H/.agents/skills" "$H/dotfiles/claude"
touch "$H/.agents/.skill-lock.json" "$H/dotfiles/claude/settings.json"
OUT=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root claude')
if [ "$OUT" = "$H/dotfiles/claude" ]; then ok; else bad "aaif-lock-claude: got '$OUT'"; fi

# --- 10. THE LIBRARY NEVER PRINTS A DIAGNOSTIC ITSELF ---------------------
# Callers own their own failure convention; a resolver that prints to stderr
# unconditionally would double-report in every one of the four call sites.
H=$(new_home silent-check)
ERR=$(HOME="$H" bash -c '. "'"$HERE"'/agents-root.sh"; agents_root' 2>&1 1>/dev/null)
if [ -z "$ERR" ]; then ok; else bad "agents_root must never print to stderr itself (got: $ERR)"; fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
