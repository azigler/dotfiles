#!/bin/bash
# Test for pre-ask-user-question-seat-guard.sh — the PreToolUse:AskUserQuestion
# gate that blocks the interactive question tool inside a seat's window when the
# roster marks that seat `interactive: false` (dotfiles-9i39).
#
# WHAT THIS SUITE IS REALLY FOR. The guard has two failure directions and they
# are wildly asymmetric:
#
#   over-block  — a hook that cannot resolve a window, or cannot read the
#                 roster, and blocks anyway, locks EVERY session on this machine
#                 out of asking Zig anything. That is worse than the freeze the
#                 guard exists to prevent, so the fail-open cases (A3-A5, A10,
#                 A11) are the load-bearing half of this file, not the trimming.
#   under-block — the 2026-08-09 incident itself: a 🔔 in a scheduled window
#                 that pulse-inject then defers behind, indefinitely.
#
# And one that is neither: a block that merely DENIES. A bare refusal invites a
# retry or a stall, and a stalled seat in a scheduled window is the same freeze
# by another route — so B3/B4/B5 assert the message carries the whole
# replacement pattern, and B6 asserts the `br create` it hands over is ACTUALLY
# EXECUTABLE (this repo's rule 2), by running the bytes the agent sees through
# the real bead-create gate.
#
# Hook test convention (see test-pre-tmux-kill-guard.sh): executable bash,
# non-zero exit = failed, PASS/FAIL summary on the last line. Case IDs lead
# every failure name — mutate-ask-user-question-guard.sh reads them back and
# asserts each mutant dies on the case(s) it NAMES.
#
# HERMETIC. A whole fixture tier under a temp dir: its own copy of agents/hooks
# and agents/lib, its own seats.yml, its own $HOME, and the documented
# SEAT_WINDOW / SEAT_SESSION / SEATS_YML seams instead of a tmux server. The
# live roster and the live tmux server are never read. A LIVE marshal drain runs
# tonight; this suite must not be able to touch it.

set -u

REPO_AGENTS="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

BASE=$(mktemp -d)
trap 'chmod -R u+w "$BASE" 2>/dev/null; rm -rf "$BASE"' EXIT

# --- the fixture tier -------------------------------------------------------
TIER="$BASE/tier"
mkdir -p "$TIER/agents"
cp -r "$REPO_AGENTS/hooks" "$TIER/agents/hooks"
cp -r "$REPO_AGENTS/lib"   "$TIER/agents/lib"
HOOK="$TIER/agents/hooks/pre-ask-user-question-seat-guard.sh"
CREATE_GATE="$TIER/agents/hooks/pre-bead-create.sh"

# The roster used by every case but the malformed/missing ones.
#
#   seat-mute   — marked `interactive: false`. The fixture's marshal.
#   seat-talk   — unmarked. The default, and the majority of the roster.
#   seat-yes    — `interactive: true`, the explicit form of unmarked.
#   seat-quoted — `interactive: "false"`, a STRING. It must NOT block: the
#                 guard reads the boolean identity, never truthiness, so a typo
#                 degrades toward allow (A8).
ROSTER="$TIER/agents/seats.yml"
write_roster() { # <path>
  cat > "$1" <<'YAML'
schema: 1
hosts: [fixture-host]
charter: null
taps:
  personal:
    type: claude
    config_dir: ~/.claude
    failover: []
seats:
  seat-mute:
    charter-line: "fixture non-interactive seat — the marshal's shape"
    office: "The Mute"
    sigil: "🪖"
    home: ~/tmp
    model: sonnet
    effort: high
    tap: personal
    interactive: false
    aliases: [seat-mute-old]
    history: refs/seats/seat-mute.history.md
    schedules:
      - unit: pulse-seat-mute
        tap: personal
        window: seat-mute
        session: fixture-host
  seat-talk:
    charter-line: "fixture interactive seat — carries no interactive key at all"
    office: "The Talker"
    sigil: "🧪"
    home: ~/tmp
    model: sonnet
    effort: high
    tap: personal
    aliases: []
    history: refs/seats/seat-talk.history.md
    schedules: []
  seat-yes:
    charter-line: "fixture seat that says interactive: true out loud"
    office: "The Herald"
    sigil: "📯"
    home: ~/tmp
    model: sonnet
    effort: high
    tap: personal
    interactive: true
    aliases: []
    history: refs/seats/seat-yes.history.md
    schedules: []
  seat-quoted:
    charter-line: "fixture seat whose mark is the STRING false, not the boolean"
    office: "The Typo"
    sigil: "🔧"
    home: ~/tmp
    model: sonnet
    effort: high
    tap: personal
    interactive: "false"
    aliases: []
    history: refs/seats/seat-quoted.history.md
    schedules: []
YAML
}
write_roster "$ROSTER"

# A roster with NOBODY marked — the fleet's normal state, and the one the cheap
# gate exists for (C1).
ROSTER_NONE="$BASE/seats-none.yml"
write_roster "$ROSTER_NONE"
sed -i 's/^    interactive: false$//; s/^    interactive: true$//; s/^    interactive: "false"$//' "$ROSTER_NONE"

# A roster that gets PAST the cheap gate (it still carries a literal
# `interactive: false` line) and then dies in the parser. That ordering is the
# point: this case tests the PARSE failing open, not the grep.
ROSTER_BAD="$BASE/seats-malformed.yml"
{
  echo "schema: 1"
  echo "seats:"
  echo "  seat-mute:"
  echo "    interactive: false"
  echo "a line with no colon at all, which the parser must refuse"
} > "$ROSTER_BAD"

# --- driving the hook -------------------------------------------------------
# `env -u` scrubs every real-session seam so a case can never inherit the
# developer's own window, session or roster. No tmux server is ever contacted:
# SEAT_WINDOW/SEAT_SESSION are seat-resolve.sh's documented offline seams.
#
# fire <window> <roster> [tool_name] [extra env...] -> writes $OUT_ERR, returns rc
OUT_ERR=""
fire() {
  local win=$1 roster=$2 tool=${3:-AskUserQuestion}; shift 3 2>/dev/null || shift $#
  local errf="$BASE/err.$$"
  local -a envargs=()
  [ -n "$win" ] && envargs+=("SEAT_WINDOW=$win")
  [ -n "$roster" ] && envargs+=("SEATS_YML=$roster")
  printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"questions":[]}}' "$tool" \
    | env -u TMUX -u TMUX_PANE -u HANDOFF_WINDOW -u SEAT_WINDOW -u SEATS_YML \
          -u CLAUDE_CODE_SESSION_ID \
          SEAT_SESSION=fixture-host \
          SEAT_TMUX_SOCKET_DIR="$BASE/no-sockets" \
          ${envargs+"${envargs[@]}"} "$@" \
          bash "$HOOK" >/dev/null 2>"$errf"
  local rc=$?
  OUT_ERR=$(cat "$errf")
  rm -f "$errf"
  return $rc
}

blocks() { # <case-id + text> <window> <roster> [extra env...]
  local name=$1 win=$2 roster=$3; shift 3
  fire "$win" "$roster" AskUserQuestion "$@"
  local rc=$?
  [ "$rc" = "2" ] && { ok; return 0; }
  bad "$name (want exit 2, got $rc)"
  return 1
}

allows() { # <case-id + text> <window> <roster> [extra env...]
  local name=$1 win=$2 roster=$3; shift 3
  fire "$win" "$roster" AskUserQuestion "$@"
  local rc=$?
  [ "$rc" = "0" ] && { ok; return 0; }
  bad "$name (want exit 0, got $rc; stderr: $(printf '%s' "$OUT_ERR" | head -2 | tr '\n' ' '))"
  return 1
}

# ===========================================================================
# B — THE BLOCK. It must fire for the marked seat, and it must REDIRECT.
# ===========================================================================

blocks "B1 marked seat blocks: the marshal-shaped window must not open a 🔔" \
  seat-mute "$ROSTER"
B1_ERR=$OUT_ERR

if printf '%s' "$B1_ERR" | grep -qF "seat-mute"; then ok; else
  bad "B1b block message must NAME the seat it is refusing for"
fi

if printf '%s' "$B1_ERR" | grep -qE 'br create .*-t task .*-p 1 .*human:'; then ok; else
  bad "B3 block message must carry the br-create redirect (the P1 human: bead), not just a refusal"
fi
if printf '%s' "$B1_ERR" | grep -qF '## Acceptance Criteria'; then ok; else
  bad "B3b the redirect's bead body must carry '## Acceptance Criteria' — without it the bead-create gate refuses the very command this block hands over"
fi
if printf '%s' "$B1_ERR" | grep -qF '## Options'; then ok; else
  bad "B3c the redirect must capture the OPTIONS being asked, not only the question"
fi

if printf '%s' "$B1_ERR" | grep -qiF 'push notification'; then ok; else
  bad "B4 block message must name step 2, the push notification"
fi
if printf '%s' "$B1_ERR" | grep -qF '✅'; then ok; else
  bad "B4b block message must name step 3, ending the turn ✅"
fi
if printf '%s' "$B1_ERR" | grep -qF 'AGENTS.md'; then ok; else
  bad "B5 block message must cite AGENTS.md's autonomous-loop exception as the authority"
fi
if printf '%s' "$B1_ERR" | grep -qF 'dotfiles-9i39'; then ok; else
  bad "B5b block message must cite the incident that produced the rule"
fi

# B6 — THE REDIRECT IS EXECUTABLE (repo rule 2). A documented example is
# executable in a prompt-driven harness: agents copy it verbatim. So take the
# bytes the AGENT ACTUALLY SEES — the fenced block extracted from the hook's own
# stderr, never a retyped copy — and run them through the real bead-create gate.
# If that gate refuses, the redirect sends the seat into a second block, and the
# freeze this hook prevents becomes a stall instead.
REDIRECT_CMD=$(printf '%s\n' "$B1_ERR" | awk '
  /^```bash$/ { grab = 1; next }
  /^```$/     { grab = 0 }
  grab        { print }
')
if [ -n "$REDIRECT_CMD" ]; then ok; else
  bad "B6a could not extract a fenced bash block from the block message — the redirect must be copy-pasteable"
fi
if [ -n "$REDIRECT_CMD" ]; then
  # The example carries <placeholders>; substitute the shape of a real answer so
  # the gate sees a genuine invocation rather than an angle-bracket soup.
  REAL_CMD=$(printf '%s' "$REDIRECT_CMD" | sed -e 's/<the decision, in one line>/rule on the weekly cap/' \
    -e 's/<what this seat was doing, and the fork it reached>/idle after the boundary molt/' \
    -e 's/<option> — <what choosing it implies>/hold at 12 — the night stays inside the reserve/')
  if printf '%s' "$REAL_CMD" | jq -Rs '{tool_input:{command:.}}' | bash "$CREATE_GATE" >/dev/null 2>&1; then
    ok
  else
    bad "B6 the br-create the block hands over is REFUSED by pre-bead-create.sh — the redirect leads into another block"
  fi
  if bash -n <(printf '%s\n' "$REAL_CMD"); then ok; else
    bad "B6b the redirect example is not valid shell — an agent copying it verbatim gets a syntax error"
  fi
fi

# B7 — an ALIAS of the marked seat blocks too. A renamed window that still
# resolves to the seat is the same seat; a guard that only matched the canonical
# name would be silently disarmed by exactly the rename the aliases mechanism
# exists to survive (bd-msi5).
blocks "B7 alias of a marked seat blocks (rename must not disarm the guard)" \
  seat-mute-old "$ROSTER"

# ===========================================================================
# A — THE ALLOWS. Every one of these is a session that must keep working.
# ===========================================================================

allows "A1 unmarked seat: an ordinary seat's window may still ask Zig" \
  seat-talk "$ROSTER"
if [ -z "$OUT_ERR" ]; then ok; else
  bad "A1b allow path must be SILENT; got stderr: $(printf '%s' "$OUT_ERR" | head -2 | tr '\n' ' ')"
fi

allows "A2 unregistered window: a scratch window is not a seat" \
  scratchpad-window "$ROSTER"

allows "A3 UNRESOLVABLE window: no SEAT_WINDOW, no tmux, no cache -> allow" \
  "" "$ROSTER"

allows "A4 MISSING roster: seats.yml does not exist -> allow" \
  seat-mute "$BASE/no-such-roster.yml"

allows "A5 MALFORMED roster: parse error past the cheap gate -> allow" \
  seat-mute "$ROSTER_BAD"

allows "A6 nobody marked: a roster with no interactive:false at all -> allow" \
  seat-mute "$ROSTER_NONE"

allows "A7 interactive: true is not a mark" \
  seat-yes "$ROSTER"

allows "A8 STRICT boolean: interactive: \"false\" (a string) must NOT block" \
  seat-quoted "$ROSTER"

# A9 — another tool in the marked window. The settings.json matcher scopes this
# hook to AskUserQuestion; the in-hook belt must agree, or a future matcher edit
# silently widens the guard to ExitPlanMode and beyond.
fire seat-mute "$ROSTER" ExitPlanMode
RC_A9=$?
if [ "$RC_A9" = "0" ]; then ok; else
  bad "A9 non-AskUserQuestion tool in a marked window must be untouched (want 0, got $RC_A9)"
fi

# A10 — a BROKEN INSTALL. validate-seats.py missing is the roster's parser gone;
# the guard must degrade to allow rather than to a machine-wide refusal.
mv "$TIER/agents/lib/validate-seats.py" "$BASE/parked-validator.py"
allows "A10 validator missing (broken install) -> allow" seat-mute "$ROSTER"
mv "$BASE/parked-validator.py" "$TIER/agents/lib/validate-seats.py"

# A11 — a python3 that answers GARBAGE. Anything but the literal verdict is not
# a block: the guard trusts one exact string, so a probe that breaks in a way
# nobody predicted degrades toward allow.
GARBAGEDIR="$BASE/garbagepy"
mkdir -p "$GARBAGEDIR"
cat > "$GARBAGEDIR/python3" <<'EOF'
#!/bin/sh
# Consume the heredoc'd program, then answer something that is not a verdict.
cat >/dev/null
echo "Traceback (most recent call last): fixture python3 is broken"
exit 0
EOF
chmod +x "$GARBAGEDIR/python3"
# seat-resolve's own dump ALSO needs python3, so a garbage python3 makes the
# seat unresolvable first — which is itself a fail-open path. Either way the
# answer must be allow, and that is what this case pins.
allows "A11 python3 answering garbage -> allow" seat-mute "$ROSTER" \
  PATH="$GARBAGEDIR:$PATH"

# ===========================================================================
# C — COST. The cheap gate is what keeps this hook off the fleet's hot path.
# ===========================================================================
# With nobody marked (the roster the fleet actually had until 2026-08-09, and
# the one it returns to if the mark is ever dropped), the guard must not resolve
# a seat and must not spawn python3 at all. A recording stub on PATH is the
# only honest way to see that — a comment claiming it proves nothing.
PYLOGDIR="$BASE/pylog"
mkdir -p "$PYLOGDIR"
PY_LOG="$BASE/python3.invocations"
REAL_PY=$(command -v python3)
cat > "$PYLOGDIR/python3" <<EOF
#!/bin/sh
echo "invoked" >> "$PY_LOG"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$PYLOGDIR/python3"

: > "$PY_LOG"
allows "C1a nobody marked -> allow" seat-mute "$ROSTER_NONE" PATH="$PYLOGDIR:$PATH"
if [ ! -s "$PY_LOG" ]; then ok; else
  bad "C1 cheap gate: with NO seat marked, the guard must not spawn python3 at all (spawned $(wc -l < "$PY_LOG"))"
fi

# The mirror image: when somebody IS marked, the work does happen. Without this
# C1 could be satisfied by a hook that never does anything.
: > "$PY_LOG"
blocks "C2a marked seat still blocks under the recording python3" seat-mute "$ROSTER" PATH="$PYLOGDIR:$PATH"
if [ -s "$PY_LOG" ]; then ok; else
  bad "C2 the marked path must actually read the roster (python3 was never spawned — C1 would pass vacuously)"
fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
