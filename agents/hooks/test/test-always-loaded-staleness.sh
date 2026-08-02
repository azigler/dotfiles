#!/bin/bash
# Test for the always-loaded staleness detector — lib/always-loaded.sh +
# session-start capture + stop-always-loaded-check.sh (explore-6wwu,
# decision explore-0z6r).
#
# Runs entirely under a TEMP $HOME. It never reads or writes the live global
# config: every path the lib resolves hangs off $HOME, so pointing HOME at a
# mktemp dir gives a complete, disposable always-loaded tier.
#
# The standing fleet rule (dotfiles-cxle) is enforced here explicitly: a
# detector that never fires and a detector that always fires look identical in
# a suite that only tests the firing case. Every FIRES assertion below has a
# matching SILENT negative control.
#
# Hook test convention: executable bash, non-zero exit = failure, PASS/FAIL
# summary on the last line.

set -u

HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$HOOKS/lib/always-loaded.sh"
CHECK="$HOOKS/stop-always-loaded-check.sh"
SESSION_START="$HOOKS/session-start.sh"

PASS=0
FAIL=0
FAILED_NAMES=()
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

command -v jq >/dev/null 2>&1 || { echo "PASS: 0/0 test cases (jq not installed — skipped)"; exit 0; }

# Recorded BEFORE anything runs, asserted at the end (case 9): the live global
# config must be byte-identical when this test finishes.
LIVE_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
LIVE_CLAUDE_BEFORE=$(md5sum "$LIVE_CLAUDE_MD" 2>/dev/null | awk '{print $1}')

FAKE_HOME=$(mktemp -d)
STATE=$(mktemp -d)
DOTFILES="$FAKE_HOME/dotfiles"
PROJ="$FAKE_HOME/explore"
SLUG=$(printf '%s' "$PROJ" | sed 's#/#-#g')
MEMDIR="$FAKE_HOME/.claude/projects/$SLUG/memory"
SID="always-loaded-test-1234"
trap 'rm -rf "$FAKE_HOME" "$STATE"' EXIT

mkdir -p "$DOTFILES/agents" "$FAKE_HOME/.claude" "$PROJ" "$MEMDIR" \
         "$DOTFILES/agents/skills/pulse" "$DOTFILES/agents/skills/desk"

# The global tier is a SYMLINK into dotfiles — exactly the live layout, and the
# reason a naive mtime detector fails (see trap 1 in the lib).
cat > "$DOTFILES/agents/AGENTS.md" <<'EOF'
# Agent Guidelines
- **xhigh** — the DEFAULT for exploration, research, and multi-tool agentic work.
EOF
ln -s "$DOTFILES/agents/AGENTS.md" "$FAKE_HOME/.claude/CLAUDE.md"
ln -s "$DOTFILES/agents/skills" "$FAKE_HOME/.claude/skills"

printf '# explore\n\nProject briefing.\n' > "$PROJ/CLAUDE.md"
printf -- '- [a memory](feedback_a.md) — one line.\n' > "$MEMDIR/MEMORY.md"

cat > "$DOTFILES/agents/skills/pulse/SKILL.md" <<'EOF'
---
description: One tick of a self-driving project.
when_to_use: A "/pulse tick" arrives.
---

# /pulse

Body text that changes constantly.
EOF
cat > "$DOTFILES/agents/skills/desk/SKILL.md" <<'EOF'
---
description: The research lab's allocator.
when_to_use: Weekly resourcing memo.
---

# /desk
EOF

capture() { # <source>
  printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s","source":"%s"}' \
    "$SID" "$PROJ" "${1:-startup}" \
    | ( cd "$PROJ" && HOME="$FAKE_HOME" ALWAYS_LOADED_STATE_DIR="$STATE" \
        HARNESS_SESSION_START_LOG="$STATE/session-start.log" "$SESSION_START" ) >/dev/null 2>&1
}

# Sets $OUT (hook stdout) and $CHECK_RC. NOT called via $( ) — a command
# substitution subshell would swallow the exit code we are asserting on.
OUT=""
CHECK_RC=0
check() {
  printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" \
    | HOME="$FAKE_HOME" ALWAYS_LOADED_STATE_DIR="$STATE" "$CHECK" \
      >"$STATE/check-stdout" 2>"$STATE/check-stderr"
  CHECK_RC=$?
  OUT=$(cat "$STATE/check-stdout")
}

msg() { printf '%s' "$1" | jq -r '.systemMessage // ""' 2>/dev/null; }

# ── 0. The lib resolves the tier at all ─────────────────────────────────────
MANIFEST_OUT=$(HOME="$FAKE_HOME" bash -c ". '$LIB'; always_loaded_manifest '$PROJ'")
N=$(printf '%s\n' "$MANIFEST_OUT" | grep -c .)
# global CLAUDE.md + project CLAUDE.md + MEMORY.md + 2 skills = 5
if [ "$N" -eq 5 ]; then ok; else bad "manifest resolves the 5 always-loaded files (got $N)"; fi

if printf '%s' "$MANIFEST_OUT" | grep -q "^global-claude"; then ok; else bad "manifest includes the global CLAUDE.md"; fi
if printf '%s' "$MANIFEST_OUT" | grep -q "^memory"; then ok; else bad "manifest includes MEMORY.md"; fi

# ── 1. NEGATIVE CONTROL: no manifest captured -> silent ─────────────────────
check
if [ "$CHECK_RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "no manifest is a silent no-op (rc=$CHECK_RC out='$OUT')"; fi

# ── 2. NEGATIVE CONTROL: captured, nothing changed -> SILENT ────────────────
# This is the assertion that keeps the detector honest. Without it, an
# always-fires detector passes every test below.
capture startup
[ -f "$STATE/$SID.manifest" ] && ok || bad "session-start captures a manifest"

check
if [ "$CHECK_RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "NEGATIVE CONTROL: unchanged tier must be silent (out='$OUT')"; fi

# ── 2b. NEGATIVE CONTROL: touch without a content change -> still SILENT ────
# mtime moves, content does not. A pure-mtime detector would cry wolf here.
touch "$DOTFILES/agents/AGENTS.md"
check
if [ "$CHECK_RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "NEGATIVE CONTROL: touch with no content change must be silent (out='$OUT')"; fi

# ── 2c. NEGATIVE CONTROL: a skill BODY edit is not always-loaded -> SILENT ──
cat >> "$DOTFILES/agents/skills/pulse/SKILL.md" <<'EOF'

More body prose. Not injected at session start.
EOF
check
if [ "$CHECK_RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad "NEGATIVE CONTROL: skill body edit must be silent (out='$OUT')"; fi

# ── 3. THE LIVE INSTANCE: the effort-policy edit lands in AGENTS.md ─────────
# The file the session sees is ~/.claude/CLAUDE.md, a symlink; the edit lands
# on the target. This is the case the bug report describes.
sleep 1
cat > "$DOTFILES/agents/AGENTS.md" <<'EOF'
# Agent Guidelines
- **high** — the DEFAULT, and the only level a *session* is ever set to.
- **xhigh** — NOT a session setting.
EOF
check
M=$(msg "$OUT")
if [ "$CHECK_RC" -eq 0 ]; then ok; else bad "detector never blocks (rc=$CHECK_RC)"; fi
if [ -n "$M" ]; then ok; else bad "FIRES on the live instance (effort-policy edit behind the CLAUDE.md symlink)"; fi
if printf '%s' "$M" | grep -q "global CLAUDE.md"; then ok; else bad "names WHICH file changed"; fi
if printf '%s' "$M" | grep -q "AGENTS.md"; then ok; else bad "names the real file behind the symlink"; fi
if printf '%s' "$M" | grep -qE "CHANGED [0-9]+ (seconds|minutes|hours|days) ago"; then ok; else bad "names HOW LONG ago (got: $M)"; fi

# ── 3b. It does not auto-repair ─────────────────────────────────────────────
if grep -q "NOT a session setting" "$DOTFILES/agents/AGENTS.md" \
   && ! grep -q "xhigh — the DEFAULT" "$DOTFILES/agents/AGENTS.md"; then ok; else bad "detector must not rewrite the changed file"; fi

# ── 4. Nag control: same change, second Stop -> silent ──────────────────────
check
if [ -z "$OUT" ]; then ok; else bad "same change does not re-nag on the next Stop"; fi

# ── 4b. …but a NEW edit to the same file reports again ──────────────────────
printf '\n- another rule\n' >> "$DOTFILES/agents/AGENTS.md"
check
if [ -n "$(msg "$OUT")" ]; then ok; else bad "a further edit reports again (new hash)"; fi

# ── 5. Skill DESCRIPTION change fires and names the skill ──────────────────
# No `sed -i`: BSD sed takes the script as `-i`'s backup suffix and then dies
# on the filename ("invalid command code"), so this test silently never ran on
# macOS (dotfiles-1rj5). Temp file + mv is correct on both seds.
sed 's/The research lab.s allocator./The research lab allocator, reworded./' \
  "$DOTFILES/agents/skills/desk/SKILL.md" > "$DOTFILES/desk.SKILL.md.tmp" \
  && mv "$DOTFILES/desk.SKILL.md.tmp" "$DOTFILES/agents/skills/desk/SKILL.md"
check
M=$(msg "$OUT")
if printf '%s' "$M" | grep -q "skill description: /desk"; then ok; else bad "skill frontmatter change names the skill (got: $M)"; fi

# ── 6. MEMORY.md + project CLAUDE.md are covered ────────────────────────────
printf -- '- [another memory](feedback_b.md) — added mid-session.\n' >> "$MEMDIR/MEMORY.md"
printf '\nA new project rule.\n' >> "$PROJ/CLAUDE.md"
check
M=$(msg "$OUT")
if printf '%s' "$M" | grep -q "MEMORY.md (auto-memory)"; then ok; else bad "MEMORY.md change is detected"; fi
if printf '%s' "$M" | grep -q "project CLAUDE.md"; then ok; else bad "project CLAUDE.md change is detected"; fi

# ── 7. Output contract: valid JSON, continue:true, never a block decision ───
if printf '%s' "$OUT" | jq -e '.continue == true' >/dev/null 2>&1; then ok; else bad "emits continue:true JSON"; fi
if printf '%s' "$OUT" | jq -e 'has("decision")' >/dev/null 2>&1; then bad "must NOT emit a decision field (would block Stop)"; else ok; fi

# ── 8. compact does NOT reset the snapshot; startup does ───────────────────
HASH_BEFORE=$(md5sum "$STATE/$SID.manifest" | awk '{print $1}')
capture compact
HASH_AFTER=$(md5sum "$STATE/$SID.manifest" | awk '{print $1}')
if [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then ok; else bad "source=compact must not re-capture (compaction does not re-read the tier)"; fi

capture startup
check
if [ -z "$OUT" ]; then ok; else bad "a fresh startup capture clears the staleness (out='$OUT')"; fi

# ── 9. Containment: nothing landed outside the temp HOME / temp state dir ──
# (Recorded at the top of the file, compared here — see LIVE_* below.)
if [ ! -e "/tmp/claude-always-loaded/$SID.manifest" ]; then ok; else bad "test leaked a manifest into the default state dir"; fi
LIVE_CLAUDE_AFTER=$(md5sum "$LIVE_CLAUDE_MD" 2>/dev/null | awk '{print $1}')
if [ "$LIVE_CLAUDE_BEFORE" = "$LIVE_CLAUDE_AFTER" ]; then ok; else bad "test mutated the LIVE global CLAUDE.md"; fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
