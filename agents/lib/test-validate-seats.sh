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

# A hermetic --systemd-dir every fixture gets BY DEFAULT (dotfiles-hfm5): both
# units every fixture below is derived from (pulse-desk, pulse-dream) are
# installed AND enabled, nothing else is. Without this, every `run "$F"` call
# that omits --systemd-dir falls through to validate-seats.py's own default
# (~/.config/systemd/user) -- THIS BOX'S real, live timer state -- and every
# fixture's WARN-mode output fills up with however many real pulse-* timers
# happen to be enabled here today. That noise never fails a test (warn mode
# never blocks), but it is not hermetic, and it is exactly the kind of
# host-state coupling the UNIT/UNIT-ORPHAN caution in the module docstring
# argues against — even a WARN should not depend on what this particular box
# happens to have enabled right now.
NEUTRAL_SD="$BASE/neutral-systemd"
mkdir -p "$NEUTRAL_SD/timers.target.wants"
touch "$NEUTRAL_SD/pulse-desk.timer" "$NEUTRAL_SD/pulse-dream.timer"
touch "$NEUTRAL_SD/timers.target.wants/pulse-desk.timer" \
      "$NEUTRAL_SD/timers.target.wants/pulse-dream.timer"

run() { # run <fixture-file> [extra validator args...] -> sets OUT, RC
  local f=$1
  shift
  local args=("$@") a has_sd=0
  for a in ${args[@]+"${args[@]}"}; do
    case "$a" in --systemd-dir|--systemd-dir=*) has_sd=1 ;; esac
  done
  [ "$has_sd" -eq 0 ] && args+=(--systemd-dir "$NEUTRAL_SD")
  OUT=$(python3 "$VALIDATOR" "$f" ${args[@]+"${args[@]}"} 2>&1)
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
# 8b; these four are the glyphs the roster now carries. dream's sigil is
# retargeted to a neutral valid glyph first (dotfiles-e8l0's SIGIL-UNIQUE rule
# would otherwise reject desk=🔮 as colliding with GOOD's own dream=🔮).
for GLYPH in 🔑 🔭 🔮 🪶; do
  F="$BASE/sigil-epres-ok.yml"
  sed -e 's/sigil: "🔮"/sigil: "🎯"/' -e "s/sigil: \"📜\"/sigil: \"$GLYPH\"/" "$GOOD" > "$F"
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
# Explicitly opts OUT of the hermetic NEUTRAL_SD default (the whole point of
# this case is checking the roster against THIS BOX'S real installed units) —
# still non-strict, so a legitimate roster-edits-before-unit-install ordering
# never fails this suite; see the WARN-by-default rationale in the module
# docstring.
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
if [ -f "$REPO_ROOT/agents/seats.yml" ]; then
  run "$REPO_ROOT/agents/seats.yml" --systemd-dir "$HOME/.config/systemd/user"
  if [ "$RC" -eq 0 ]; then ok; else bad "REAL-ROSTER agents/seats.yml must pass: $OUT"; fi
else
  bad "REAL-ROSTER agents/seats.yml not found at $REPO_ROOT/agents/seats.yml"
fi

# --- 11. EMIT-JSON: --emit-json succeeds and round-trips verbatim ----------
# (dotfiles-btw8) The whole contract in one check: every key the parser
# produced from the GOOD fixture must reappear in the emitted JSON with the
# SAME spelling and the SAME value — nothing renamed, nothing dropped, one
# thing added (`_generated`, and only at the top level).
run_emit() { # run_emit <yml> <out> -> sets EOUT, ERC
  EOUT=$(python3 "$VALIDATOR" "$1" --emit-json "$2" 2>&1)
  ERC=$?
}

EMIT_OUT="$BASE/emit.json"
run_emit "$GOOD" "$EMIT_OUT"
if [ "$ERC" -eq 0 ]; then ok; else bad "EMIT-JSON emit from GOOD fixture must succeed (rc=$ERC): $EOUT"; fi

RT=$(python3 - "$VALIDATOR" "$GOOD" "$EMIT_OUT" <<'PY'
import importlib.util, json, sys
validator, yml, out = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("_vs", validator)
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)
doc = vs.load_seats_yaml(open(yml).read())
emitted = json.load(open(out))
if "_generated" not in emitted:
    print("EMIT-ROUNDTRIP missing _generated key")
    sys.exit()
gen = dict(emitted)
del gen["_generated"]
meta = emitted["_generated"]
for key in ("source", "generator", "warning"):
    if key not in meta:
        print(f"EMIT-ROUNDTRIP _generated missing field {key!r}")
        sys.exit()
if "DO NOT EDIT" not in meta["warning"]:
    print("EMIT-ROUNDTRIP _generated.warning is missing DO NOT EDIT")
    sys.exit()
if gen != doc:
    print("EMIT-ROUNDTRIP emitted JSON (minus _generated) != parsed YAML")
    sys.exit()
if "charter-line" not in emitted["seats"]["desk"]:
    print("EMIT-ROUNDTRIP charter-line key was renamed or dropped")
    sys.exit()
print("OK")
PY
)
if [ "$RT" = "OK" ]; then ok; else bad "$RT"; fi

# --- 12. EMIT-JSON is deterministic: two emissions are byte-identical -------
EMIT_OUT2="$BASE/emit2.json"
run_emit "$GOOD" "$EMIT_OUT2"
if cmp -s "$EMIT_OUT" "$EMIT_OUT2"; then
  ok
else
  bad "EMIT-DETERMINISM two emissions from the same input must be byte-identical"
fi

# --- 13. EMIT-JSON: the real agents/seats.yml emits cleanly too ------------
if [ -f "$REPO_ROOT/agents/seats.yml" ]; then
  REAL_EMIT="$BASE/real.json"
  run_emit "$REPO_ROOT/agents/seats.yml" "$REAL_EMIT"
  if [ "$ERC" -eq 0 ]; then ok; else bad "EMIT-REAL-ROSTER real seats.yml must emit cleanly (rc=$ERC): $EOUT"; fi
fi
# --- 11-15. UNIT / UNIT-ORPHAN (dotfiles-hfm5): schedules <-> installed units,
# both directions, WARN-by-default / strict-via-flag. Every case below points
# --systemd-dir at a SCRATCH fixture tree, never the real box, so these never
# depend on this machine's actual timer state (the seam the bead demanded).

# 11. UNIT (strict): a schedule's unit has no installed .timer -> must fail,
# tagged, and name the missing unit.
SD1="$BASE/systemd1"
mkdir -p "$SD1"
touch "$SD1/pulse-desk.timer"   # pulse-dream.timer deliberately absent
run "$GOOD" --systemd-dir "$SD1" --strict-units
if [ "$RC" -ne 0 ]; then ok; else bad "UNIT (strict): missing unit must fail"; fi
case "$OUT" in
  *"UNIT:"*"pulse-dream"*) ok ;;
  *) bad "UNIT (strict): expected a UNIT: violation naming pulse-dream, got: $OUT" ;;
esac

# 12. UNIT (default/warn): the SAME missing-unit fixture must NOT fail the
# build, but must still say so (nothing silent) -- the whole point of the seam.
run "$GOOD" --systemd-dir "$SD1"
if [ "$RC" -eq 0 ]; then ok; else bad "UNIT (warn): must NOT block by default, got rc=$RC: $OUT"; fi
case "$OUT" in
  *"WARN"*"UNIT:"*"pulse-dream"*) ok ;;
  *) bad "UNIT (warn): expected a WARN-prefixed UNIT: note naming pulse-dream, got: $OUT" ;;
esac

# 13. UNIT (strict, passing): both units installed -> must pass.
touch "$SD1/pulse-dream.timer"
run "$GOOD" --systemd-dir "$SD1" --strict-units
if [ "$RC" -eq 0 ]; then ok; else bad "UNIT (strict): both units installed must pass: $OUT"; fi

# 14. UNIT-ORPHAN (strict): an ENABLED pulse-* timer nobody's schedule claims
# and that is not in unit_allowlist -> must fail, tagged.
SD2="$BASE/systemd2"
mkdir -p "$SD2/timers.target.wants"
touch "$SD2/pulse-desk.timer" "$SD2/pulse-dream.timer" "$SD2/pulse-orphan.timer"
touch "$SD2/timers.target.wants/pulse-desk.timer" \
      "$SD2/timers.target.wants/pulse-dream.timer" \
      "$SD2/timers.target.wants/pulse-orphan.timer"
run "$GOOD" --systemd-dir "$SD2" --strict-units
if [ "$RC" -ne 0 ]; then ok; else bad "UNIT-ORPHAN (strict): unclaimed enabled timer must fail"; fi
case "$OUT" in
  *"UNIT-ORPHAN:"*"pulse-orphan"*) ok ;;
  *) bad "UNIT-ORPHAN (strict): expected that tag naming pulse-orphan, got: $OUT" ;;
esac

# 15. UNIT-ORPHAN (strict, passing via unit_allowlist): the SAME enabled
# orphan, but now recorded in the roster's unit_allowlist: -> must pass.
F="$BASE/unit-allowlist.yml"
{ cat "$GOOD"; echo "unit_allowlist: [pulse-orphan]"; } > "$F"
run "$F" --systemd-dir "$SD2" --strict-units
if [ "$RC" -eq 0 ]; then ok; else bad "UNIT-ORPHAN (strict, allowlisted): must pass: $OUT"; fi

# --- 16-19. FAILOVER (dotfiles-kf2i, spec dotfiles-d3ky): exist, be known,
# be same-type. Cases 16-17 reuse GOOD's two same-type taps; 18-19 need a
# THIRD tap of a different type, since GOOD's personal/work are both `claude`.

# 16. FAILOVER: an empty/null entry must fail, tagged, without naming a
# nonexistent tap as if it were real.
F="$BASE/failover-null.yml"
sed 's/failover: \[\]/failover: [null]/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "FAILOVER (null entry): must fail"; fi
case "$OUT" in
  *"FAILOVER:"*"empty/null"*) ok ;;
  *) bad "FAILOVER (null entry): expected the empty/null tag, got: $OUT" ;;
esac

# 17. FAILOVER: a target that names no declared tap must fail, tagged, and
# name the offending target.
F="$BASE/failover-unknown.yml"
sed 's/failover: \[work\]/failover: [nosuchtap]/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "FAILOVER (unknown target): must fail"; fi
case "$OUT" in
  *"FAILOVER:"*"nosuchtap"*) ok ;;
  *) bad "FAILOVER (unknown target): expected that tag naming nosuchtap, got: $OUT" ;;
esac

# 18. FAILOVER: cross-type failover is FORBIDDEN v1 (d3ky) -- a THIRD tap of a
# different `type:` is added, and `personal` (type claude) is pointed at it.
F="$BASE/failover-crosstype.yml"
python3 - "$GOOD" "$F" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
text = text.replace("failover: [work]", "failover: [codex-tap]")
marker = "seats:\n"
insert = (
    "  codex-tap:\n"
    "    type: codex\n"
    "    config_dir: ~/.codex\n"
    "    failover: []\n"
)
idx = text.index(marker)
text = text[:idx] + insert + text[idx:]
open(dst, "w").write(text)
PY
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "FAILOVER (cross-type): must fail"; fi
case "$OUT" in
  *"FAILOVER:"*"cross-type"*"FORBIDDEN"*) ok ;;
  *) bad "FAILOVER (cross-type): expected the cross-type/FORBIDDEN tag, got: $OUT" ;;
esac

# 19. FAILOVER: the failing-then-passing pair -- SAME fixture, but codex-tap's
# type is fixed to match `personal`'s (claude) -> must now pass.
F2="$BASE/failover-crosstype-fixed.yml"
sed 's/type: codex/type: claude/' "$F" > "$F2"
run "$F2"
if [ "$RC" -eq 0 ]; then ok; else bad "FAILOVER (cross-type, fixed to same-type): must pass: $OUT"; fi

# --- 20-21. SIGIL-UNIQUE (dotfiles-e8l0): no two live seats share a sigil --

# 20. two seats sharing a sigil must fail, tagged.
F="$BASE/sigil-unique.yml"
sed 's/sigil: "🔮"/sigil: "📜"/' "$GOOD" > "$F"
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SIGIL-UNIQUE (shared glyph): must fail"; fi
case "$OUT" in *"SIGIL-UNIQUE:"*) ok ;; *) bad "SIGIL-UNIQUE (shared glyph): expected that tag, got: $OUT" ;; esac

# 21. the failing-then-passing pair -- SAME fixture, ONLY dream's sigil
# changed to a DIFFERENT valid glyph instead of colliding with desk's -> must
# pass. (dream's is the second "📜" occurrence in $F after case 20's sed.)
F2="$BASE/sigil-unique-fixed.yml"
python3 - "$F" "$F2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
idx_dream = text.index("  dream:")
before, after = text[:idx_dream], text[idx_dream:]
old = 'sigil: "📜"'
assert after.count(old) == 1, after.count(old)
after = after.replace(old, 'sigil: "🪶"')
open(dst, "w").write(before + after)
PY
run "$F2"
if [ "$RC" -eq 0 ]; then ok; else bad "SIGIL-UNIQUE (fixed to distinct glyphs): must pass: $OUT"; fi

# --- 22-23. SEATTAP-CONSISTENCY (dotfiles-e8l0): seat tap <-> schedule tap --

# 22. desk's SCHEDULE tap set to `work` while desk's own (seat-level) tap
# stays `personal` -- the roster contradicting itself about which vendor a
# given run draws from -- must fail, tagged.
F="$BASE/seattap-consistency.yml"
python3 - "$GOOD" "$F" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "        tap: personal\n        window: desk"
new = "        tap: work\n        window: desk"
assert text.count(old) == 1, text.count(old)
open(dst, "w").write(text.replace(old, new))
PY
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "SEATTAP-CONSISTENCY (desk schedule vs seat tap): must fail"; fi
case "$OUT" in
  *"SEATTAP-CONSISTENCY:"*"desk"*) ok ;;
  *) bad "SEATTAP-CONSISTENCY: expected that tag naming desk, got: $OUT" ;;
esac

# 23. the failing-then-passing pair -- SAME fixture, desk's SEAT-level tap
# (only, not dream's) brought into agreement with its schedule -> must pass.
F2="$BASE/seattap-consistency-fixed.yml"
python3 - "$F" "$F2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
idx_desk = text.index("  desk:")
idx_dream = text.index("  dream:")
block = text[idx_desk:idx_dream]
old = "    tap: personal"
assert block.count(old) == 1, block.count(old)
block = block.replace(old, "    tap: work")
text = text[:idx_desk] + block + text[idx_dream:]
open(dst, "w").write(text)
PY
run "$F2"
if [ "$RC" -eq 0 ]; then ok; else bad "SEATTAP-CONSISTENCY (fixed): must pass: $OUT"; fi

# --- 24-26. PROFILE (dotfiles-iez1): 'tick' is a jail PROFILE of a real tap,
# not a tap of its own -- ~/.claude-tick and ~/.claude carry the same account.

# 24. a `profiles:` entry naming an undeclared tap must fail, tagged, and name
# the offending tap.
F="$BASE/profile-unknown-tap.yml"
python3 - "$GOOD" "$F" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
marker = "seats:\n"
insert = (
    "profiles:\n"
    "  tick:\n"
    "    config_dir: ~/.claude-tick\n"
    "    tap: nosuchtap\n"
)
idx = text.index(marker)
text = text[:idx] + insert + text[idx:]
open(dst, "w").write(text)
PY
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "PROFILE-TAP-UNKNOWN (unknown tap): must fail"; fi
case "$OUT" in
  *"PROFILE:"*"nosuchtap"*) ok ;;
  *) bad "PROFILE-TAP-UNKNOWN (unknown tap): expected that tag naming nosuchtap, got: $OUT" ;;
esac

# 25. a seat declaring a `profile:` that is not declared under `profiles:`
# (no `profiles:` block exists at all here) must fail, tagged, and name desk.
F="$BASE/profile-seat-unknown.yml"
python3 - "$GOOD" "$F" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
idx_desk = text.index("  desk:")
idx_dream = text.index("  dream:")
block = text[idx_desk:idx_dream]
old = "    tap: personal\n    aliases:"  # the SEAT-level tap only, not the
                                        # schedule's own (same value, deeper
                                        # indent) -- anchored on what follows
assert block.count(old) == 1, block.count(old)
block = block.replace(old, "    tap: personal\n    profile: tick\n    aliases:")
text = text[:idx_desk] + block + text[idx_dream:]
open(dst, "w").write(text)
PY
run "$F"
if [ "$RC" -ne 0 ]; then ok; else bad "PROFILE-SEAT-UNKNOWN (seat profile undeclared): must fail"; fi
case "$OUT" in
  *"PROFILE:"*"desk"*) ok ;;
  *) bad "PROFILE-SEAT-UNKNOWN (seat profile undeclared): expected that tag naming desk, got: $OUT" ;;
esac

# 26. the valid case: a declared `profiles:` block (tick -> tap: personal)
# plus a seat referencing it by name -- must pass, and the seat's BILLING tap
# is unchanged (still `personal`, read via SEATTAP as always).
F="$BASE/profile-good.yml"
python3 - "$GOOD" "$F" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
marker = "seats:\n"
insert = (
    "profiles:\n"
    "  tick:\n"
    "    config_dir: ~/.claude-tick\n"
    "    tap: personal\n"
)
idx = text.index(marker)
text = text[:idx] + insert + text[idx:]
idx_desk = text.index("  desk:")
idx_dream = text.index("  dream:")
block = text[idx_desk:idx_dream]
old = "    tap: personal\n    aliases:"  # seat-level tap only, see case 25
assert block.count(old) == 1, block.count(old)
block = block.replace(old, "    tap: personal\n    profile: tick\n    aliases:")
text = text[:idx_desk] + block + text[idx_dream:]
open(dst, "w").write(text)
PY
run "$F"
if [ "$RC" -eq 0 ]; then ok; else bad "PROFILE (valid profile reference): must pass: $OUT"; fi
case "$OUT" in *"OK"*) ok ;; *) bad "PROFILE (valid): expected an OK line, got: $OUT" ;; esac

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED[@]}"; do echo "  - $n"; done
exit 1
