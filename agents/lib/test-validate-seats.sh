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
    tap: personal
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
    sigil: "🔮"
    home: ~/explore
    model: fable
    effort: high
    tap: personal
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

# --- 6b. SEATTAP: a seat with no tap at all ---------------------------------
# Zig's ruling, 2026-08-09: personal is the default and the roster SAYS so, so
# that the hall's `-` means only "unregistered window". The sed deletes the
# seat-level tap line (4 spaces) without touching the schedule's (8 spaces).
F="$BASE/seattap-missing.yml"
sed '/^    tap: personal$/d' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SEATTAP-MISSING a seat with no tap must fail"; fi
case "$OUT" in *"SEATTAP:"*) ok ;; *) bad "SEATTAP-MISSING expected that tag, got: $OUT" ;; esac

# --- 6c. SEATTAP: a seat naming a tap that is not declared ------------------
F="$BASE/seattap-unknown.yml"
sed 's/^    tap: personal$/    tap: nosuchtap/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SEATTAP-UNKNOWN an undeclared tap must fail"; fi
case "$OUT" in *"SEATTAP:"*) ok ;; *) bad "SEATTAP-UNKNOWN expected that tag, got: $OUT" ;; esac

# --- 8b. SIGIL-EPRES: a TEXT-presentation glyph from inside the emoji blocks
# The dotfiles-gl6z defect itself: 🗝 U+1F5DD is emoji-RANGE, passes the block
# ban and the denylist, and is Emoji_Presentation=No — the terminal renders it
# one cell while the court pads two. Case 7 (the U+2000-U+2BFF ban) cannot see
# it; only the property can. Each of the four ratified breakages is checked,
# so a data refresh that drops a range cannot go unnoticed.
for pair in "SIGIL-EPRES-KEY 🗝" "SIGIL-EPRES-SHIELD 🛡" "SIGIL-EPRES-CANDLE 🕯" "SIGIL-EPRES-DOVE 🕊"; do
  CASE=${pair%% *}; GLYPH=${pair##* }
  F="$BASE/sigil-epres-$CASE.yml"
  sed "s/sigil: \"📜\"/sigil: \"$GLYPH\"/" "$GOOD" > "$F"
  run "$F"
  if [ "$RC" -ne 0 ]; then ok; else bad "$CASE text-presentation sigil must fail"; fi
  case "$OUT" in
    *"Emoji_Presentation=No"*) ok ;;
    *) bad "$CASE must fail for the PROPERTY, not something else, got: $OUT" ;;
  esac
done

# --- 8c. SIGIL-EPRES-GOOD: the four REPLACEMENTS must pass ------------------
# The other half of the same fact. A rule that rejects everything would satisfy
# 8b; these four are the glyphs the roster now carries.
for GLYPH in 🔑 🔭 🔮 🪶; do
  F="$BASE/sigil-epres-ok.yml"
  sed "s/sigil: \"📜\"/sigil: \"$GLYPH\"/" "$GOOD" > "$F"
  run "$F"
  if [ "$RC" -eq 0 ]; then ok; else bad "SIGIL-EPRES-GOOD $GLYPH must pass: $OUT"; fi
done

# --- 8d. SIGIL-ASCII: a sigil must be a GLYPH, not a letter ----------------
# The property rule subsumes this: 'x' is Emoji_Presentation=No like any other
# text character, so the sigil field can no longer hold ASCII art.
F="$BASE/sigil-ascii.yml"
sed 's/sigil: "📜"/sigil: "x"/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SIGIL-ASCII must fail"; fi
case "$OUT" in *"Emoji_Presentation=No"*) ok ;; *) bad "SIGIL-ASCII: expected the property reason, got: $OUT" ;; esac

# --- 8e. GLYPH-VS-SIGIL: the RENDERED-OUTPUT rule lets plain text through ---
# glyph_violation() is what a renderer's output is scanned with (test-hall.sh).
# ASCII and · must pass it while the text-presentation glyphs are still caught,
# or the hall's own glyph assertion is either useless or unusable.
GV=$(python3 - "$VALIDATOR" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_vs", sys.argv[1])
vs = importlib.util.module_from_spec(spec); spec.loader.exec_module(vs)
pass_chars = "abz09 -·"
fail_chars = "\U0001F5DD\U0001F6E1\U0001F56F\U0001F54A⚔"
bad = [c for c in pass_chars if vs.glyph_violation(c)]
missed = [c for c in fail_chars if not vs.glyph_violation(c)]
widths = (vs.display_width("\U0001F511"), vs.display_width("\U0001F5DD"), vs.display_width("ab"))
if bad: print("REJECTED-PLAIN-TEXT " + repr(bad))
elif missed: print("ACCEPTED-TEXT-GLYPH " + repr(missed))
elif widths != (2, 1, 2): print(f"WIDTHS {widths}")
else: print("OK")
PY
)
if [ "$GV" = "OK" ]; then ok; else bad "GLYPH-VS-SIGIL rendered-output rule is wrong ($GV)"; fi

# --- 9. WINDOW: schedule window doesn't resolve to a seat name or alias ----
F="$BASE/window.yml"
sed 's/window: desk/window: nonexistent-window/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "WINDOW: must fail"; fi
case "$OUT" in *"WINDOW:"*) ok ;; *) bad "WINDOW: expected that tag, got: $OUT" ;; esac

# --- 10. the REAL agents/seats.yml must pass its own validator --------------
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
if [ -f "$REPO_ROOT/agents/seats.yml" ]; then
  run "$REPO_ROOT/agents/seats.yml"
  if [ "$RC" -eq 0 ]; then ok; else bad "REAL-ROSTER agents/seats.yml must pass: $OUT"; fi
else
  bad "REAL-ROSTER agents/seats.yml not found at $REPO_ROOT/agents/seats.yml"
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
