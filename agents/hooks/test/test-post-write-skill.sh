#!/bin/bash
# Test for post-write-skill.sh's CROSS-FILE HEADING CITATION check (explore-cs5i).
#
# WHY THIS EXISTS. `pulse/SKILL.md` cited `AGENTS.md "Surfacing to Andrew"` for
# as long as it took nobody to notice: the heading had been renamed to
# `## Surfacing to Zig — AskUserQuestion, not trailing prose`, so an agent
# following the pointer grepped for a heading that does not exist and found
# nothing. The pointer still LOOKED authoritative. That is the same failure
# class as a producer with no consumer — a surface that resolves to air.
#
# A cross-reference linter that cannot go RED is the vacuity this fleet keeps
# rediscovering (`explore-6g3l`), so the FIRST case here is the broken citation
# and the second is the working control beside it. Both matter: a checker that
# flags everything is deleted within a week.
#
#     A. a citation naming a heading that does not exist  -> WARNS
#     B. a citation naming a real heading (prefix form)   -> silent
#     C. a citation naming a real heading in full         -> silent
#     D. no citations at all                              -> silent
#     E. citations present but no AGENTS.md to check      -> WARNS ("not verified")
#
# E is the positive-control rung: "I could not check" must never render the
# same as "I checked and it was fine".
#
# Hook test convention (see test-worktree-guard.sh). Runs under BASH.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/agents/hooks/post-write-skill.sh"
AGENTS="$ROOT/agents/AGENTS.md"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: cannot find $HOOK" >&2
  exit 1
fi
if [ ! -f "$AGENTS" ]; then
  echo "FAIL: cannot find $AGENTS — the fixture rests on its real headings" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A skill file has to live at */skills/*/SKILL.md for the hook to look at it,
# and AGENTS.md is resolved three directories up from the file.
mk() {   # $1 = case dir, $2 = body ; echoes the SKILL.md path
  local d="$TMP/$1/agents/skills/probe"
  mkdir -p "$d"
  cp "$AGENTS" "$TMP/$1/agents/AGENTS.md"
  {
    echo '---'
    echo 'description: a probe'
    echo 'when_to_use: never'
    echo '---'
    echo
    printf '%s\n' "$2"
  } > "$d/SKILL.md"
  echo "$d/SKILL.md"
}

run_hook() {   # $1 = SKILL.md path -> stderr on stdout
  printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" 2>&1 >/dev/null
}

expect_flags() {   # $1 = path, $2 = case name
  if run_hook "$1" | grep -q 'no heading in'; then ok; else bad "$2"; fi
}
expect_clean() {   # $1 = path, $2 = case name
  if run_hook "$1" | grep -q 'no heading in'; then bad "$2"; else ok; fi
}

# --- A: the real historical defect ------------------------------------------
A=$(mk a 'See AGENTS.md "Surfacing to Andrew" for the escalate path.')
expect_flags "$A" "A: a citation to a renamed heading WARNS"

# --- B: the corrected form, prefix-matched ----------------------------------
B=$(mk b 'See AGENTS.md "Surfacing to Zig" for the escalate path.')
expect_clean "$B" "B: a prefix citation of a real heading is silent"

# --- C: the possessive/full forms the house style actually uses -------------
C=$(mk c 'Per AGENTS.md'"'"'s "Two writers, one working tree" rule, merge.')
expect_clean "$C" "C: AGENTS.md'\''s \"...\" possessive form is silent"

# --- D: no citations --------------------------------------------------------
D=$(mk d 'Nothing cited here at all.')
expect_clean "$D" "D: a file with no citations is silent"

# --- E: citations present, AGENTS.md missing -> NOT VERIFIED, not clean -----
E=$(mk e 'See AGENTS.md "Surfacing to Zig".')
rm -f "$TMP/e/agents/AGENTS.md"
# Point HOME somewhere empty so the ~/dotfiles fallback cannot rescue it.
if printf '{"tool_input":{"file_path":"%s"}}' "$E" \
   | HOME="$TMP/e-empty" bash "$HOOK" 2>&1 >/dev/null \
   | grep -q 'were NOT verified'; then ok; else
  bad "E: citations with no AGENTS.md report NOT VERIFIED"
fi

# --- G: agents_root() itself unresolvable -> LOUD, unconditionally (dotfiles-tm0w) --
# Independent of whether this file cites AGENTS.md at all: a target that
# resolves NOWHERE must be reported, not silently absorbed into "nothing to
# check here". Use a file with NO citations and NO local AGENTS.md three dirs
# up, under a HOME that has neither ~/.agents content nor ~/dotfiles/agents.
G_DIR="$TMP/g/agents/skills/probe"
mkdir -p "$G_DIR"
{
  echo '---'
  echo 'description: a probe'
  echo 'when_to_use: never'
  echo '---'
  echo
  echo 'Nothing cited, and no local AGENTS.md either.'
} > "$G_DIR/SKILL.md"
if printf '{"tool_input":{"file_path":"%s"}}' "$G_DIR/SKILL.md" \
   | HOME="$TMP/g-empty" bash "$HOOK" 2>&1 >/dev/null \
   | grep -q 'agents_root() could not resolve'; then ok; else
  bad "G: agents_root() unresolvable is reported even with no citations to check"
fi

# --- F: the shipped tree is clean -------------------------------------------
# Not a unit test — a live assertion that this check passes on every skill it
# governs today. If it fires here, a real citation is broken.
DIRTY=0
for f in "$ROOT"/agents/skills/*/SKILL.md "$ROOT"/agents/skills/TOOLKIT.md; do
  [ -f "$f" ] || continue
  case "$f" in */TOOLKIT.md) continue ;; esac   # not a SKILL.md; hook skips it
  if run_hook "$f" | grep -q 'no heading in'; then
    DIRTY=$((DIRTY + 1))
    echo "  broken citation in $f" >&2
    run_hook "$f" | grep 'no heading in' >&2
  fi
done
[ "$DIRTY" -eq 0 ] && ok || bad "F: every shipped SKILL.md citation resolves"

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
