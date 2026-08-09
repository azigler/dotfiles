#!/bin/bash
# Test for validate-seats.py — the seats.yml v1 schema/policy gate
# (dotfiles-lbxa). One GOOD fixture (must pass) + one fixture per violation
# class (must fail, and must fail for the RIGHT reason — checked by grepping
# the reported class tag out of stderr, not just the exit code).
#
# Convention: executable bash, non-zero exit = failure, PASS/FAIL summary on
# the last line (see test-agents-root.sh).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="$HERE/validate-seats.py"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); }

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

run() { # run <fixture-file> -> sets OUT, RC
  OUT=$(python3 "$VALIDATOR" "$1" 2>&1)
  RC=$?
}

# --- GOOD: a minimal valid seats.yml must PASS -----------------------------
GOOD="$BASE/good.yml"
cat > "$GOOD" <<'EOF'
schema: 1
hosts: [zig-computer]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: [work]
  work:
    type: claude
    config_dir: ~/.claude-work
    failover: []
seats:
  desk:
    charter-line: "chancery/allocation"
    office: "The Chancellor"
    sigil: "📜"
    home: ~/explore
    model: fable
    effort: high
    aliases: []
    history: refs/seats/desk.history.md
    schedules:
      - unit: pulse-desk
        tap: personal
        window: desk
        session: zig-computer
  dream:
    charter-line: "consolidation"
    office: "The Remembrancer"
    sigil: "🕯"
    home: ~/explore
    model: fable
    effort: high
    aliases: []
    history: refs/seats/dream.history.md
    schedules:
      - unit: pulse-dream
        tap: personal
        window: dream
        session: zig-computer
EOF
run "$GOOD"
if [ "$RC" -eq 0 ]; then ok; else bad "GOOD fixture must pass (rc=$RC): $OUT"; fi
case "$OUT" in
  *"OK"*) ok ;;
  *) bad "GOOD fixture: expected an OK line, got: $OUT" ;;
esac

# --- 1. R1: bad seat name grammar (uppercase) -------------------------------
F="$BASE/r1.yml"
sed 's/^  desk:/  Desk:/; s/window: desk/window: Desk/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "R1: bad seat name grammar must fail"; fi
case "$OUT" in *"R1:"*) ok ;; *) bad "R1: expected an R1: violation, got: $OUT" ;; esac

# --- 2. ALIAS-VS-NAME: an alias equals another seat's name ------------------
F="$BASE/alias-vs-name.yml"
sed '/^  desk:/,/aliases: \[\]/ s/aliases: \[\]/aliases: [dream]/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "ALIAS-VS-NAME: must fail"; fi
case "$OUT" in *"ALIAS-VS-NAME:"*) ok ;; *) bad "ALIAS-VS-NAME: expected that tag, got: $OUT" ;; esac

# --- 3. ALIAS-VS-ALIAS: the same alias declared by two different seats -----
F="$BASE/alias-vs-alias.yml"
sed 's/aliases: \[\]/aliases: [di-monday]/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "ALIAS-VS-ALIAS: must fail"; fi
case "$OUT" in *"ALIAS-VS-ALIAS:"*) ok ;; *) bad "ALIAS-VS-ALIAS: expected that tag, got: $OUT" ;; esac

# --- 4. R4: one window bound to two different taps -------------------------
F="$BASE/r4.yml"
sed 's/window: dream/window: desk/' "$GOOD" > "$F"
# also flip dream's tap to `work` so it disagrees with desk's `personal` on
# the now-shared window `desk`
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
# the SECOND "tap: personal" occurrence belongs to the dream schedule
idx = text.rfind("tap: personal")
text = text[:idx] + "tap: work" + text[idx + len("tap: personal"):]
open(p, "w").write(text)
PY
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "R4: must fail"; fi
case "$OUT" in *"R4:"*) ok ;; *) bad "R4: expected that tag, got: $OUT" ;; esac

# --- 5. TAP: unknown/missing type -------------------------------------------
F="$BASE/tap.yml"
sed 's/type: claude/type: openai/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "TAP: must fail"; fi
case "$OUT" in *"TAP:"*) ok ;; *) bad "TAP: expected that tag, got: $OUT" ;; esac

# --- 6. MODEL: value outside the pinned set --------------------------------
F="$BASE/model.yml"
sed 's/model: fable/model: claude-3/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "MODEL: must fail"; fi
case "$OUT" in *"MODEL:"*) ok ;; *) bad "MODEL: expected that tag, got: $OUT" ;; esac

# --- 7. SIGIL: classic-symbol range (nerdfont-fallback risk) ---------------
F="$BASE/sigil-range.yml"
sed 's/sigil: "📜"/sigil: "⚔"/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SIGIL (range): must fail"; fi
case "$OUT" in *"SIGIL:"*) ok ;; *) bad "SIGIL (range): expected that tag, got: $OUT" ;; esac

# --- 8. SIGIL: the learned denylist (U+1F3A4 microphone) -------------------
F="$BASE/sigil-deny.yml"
sed 's/sigil: "📜"/sigil: "🎤"/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SIGIL (denylist): must fail"; fi
case "$OUT" in *"SIGIL:"*) ok ;; *) bad "SIGIL (denylist): expected that tag, got: $OUT" ;; esac

# --- 9. the REAL agents/seats.yml must pass its own validator --------------
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
if [ -f "$REPO_ROOT/agents/seats.yml" ]; then
  run "$REPO_ROOT/agents/seats.yml"
  if [ "$RC" -eq 0 ]; then ok; else bad "REAL agents/seats.yml must pass: $OUT"; fi
else
  bad "REAL agents/seats.yml not found at $REPO_ROOT/agents/seats.yml"
fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
