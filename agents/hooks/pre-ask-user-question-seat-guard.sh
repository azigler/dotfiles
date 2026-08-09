#!/bin/bash
# PreToolUse (AskUserQuestion): block the interactive question tool when this
# session lives in a SEAT'S WINDOW that the roster marks NON-INTERACTIVE
# (`interactive: false` in agents/seats.yml), and route the seat into
# AGENTS.md's autonomous-loop exception instead of merely denying it.
#
# THE INCIDENT (2026-08-09, dotfiles-9i39). After the marshal's clean
# night-end boundary molt, the fresh context onboarded with NO tick pending
# and ended its turn on an AskUserQuestion routing menu addressed to Zig. The
# `marshal` window went 🔔; pulse-inject then correctly deferred the next
# injection as `deferred-blocked-on-human` — and with Zig away, that one menu
# would have frozen the maiden campaign AND every future 01:07 tick
# indefinitely. It took a supervised Esc + rename to clear.
#
# The prose rule already existed and did not cover this: /marshal forbids
# asking Zig a question FROM A TICK, and the offending turn was not a tick —
# it was an idle post-molt context merely LIVING in a scheduled seat's window,
# where a 🔔 freezes exactly the same way. Zig's framing is simpler than any
# tick/idle distinction and is what this hook implements: *"i dont interact
# with marshal"* — the seat, not the turn, is what decides.
#
# ---------------------------------------------------------------------------
# SCOPE — deliberately as narrow as it can be made:
#   * ONLY the AskUserQuestion tool. ExitPlanMode and every other tool are
#     untouched (the 🔔 the incident produced was this tool's).
#   * ONLY a window that resolves to a seat whose roster row says exactly
#     `interactive: false`. An interactive seat, an unmarked seat, a scratch
#     window, a worktree with no tmux at all — every one of them is allowed
#     without the hook so much as reading the roster past its first grep.
#   * The mark is REGISTRY-DRIVEN. This file names no seat; adding or removing
#     a seat from the guard is a one-line roster edit, reviewed like any other
#     roster change, and visible in `agents/seats.json` for harnessd.
#
# FAIL OPEN, ABSOLUTELY. Every unresolvable input — no roster, an unparseable
# roster, no python3, no tmux, an unregistered window, a seat_resolve refusal —
# ALLOWS the call. A guard that fails closed here locks every session on the
# machine out of asking Zig anything, which is far worse than the freeze it
# exists to prevent (repo rule 1: a hook bug breaks every session, including
# yours).
#
# ONE PARSER, NOT TWO. The roster is read through validate-seats.py's own
# `load_seats_yaml` — the same function agents/lib/seat-resolve.sh's `_seat_dump`
# reuses. This is a second READER of the one parser, never a second parser; a
# hand-rolled grep for `interactive:` would drift from the validator that gates
# the file at commit time.
#
# Behavior:
#   - exit 0 = allow the tool call (every path but one)
#   - exit 2 = BLOCK and surface stderr to the agent
#
# Test:  agents/hooks/test/test-pre-ask-user-question-seat-guard.sh
# Mutants: agents/hooks/test/mutate-ask-user-question-guard.sh

INPUT=$(cat)

# Tool gate. The settings.json matcher already scopes this to AskUserQuestion;
# this is the belt, and it is written to fail OPEN on a missing/odd payload
# rather than guess — an empty tool_name (no jq, malformed JSON) falls through
# to the roster checks below, which are themselves the real gate.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
  ""|AskUserQuestion) ;;
  *) exit 0 ;;
esac

_AQ_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
_AQ_LIB="$_AQ_DIR/../lib/seat-resolve.sh"
_AQ_VALIDATOR="$_AQ_DIR/../lib/validate-seats.py"
[ -r "$_AQ_LIB" ] || exit 0
[ -r "$_AQ_VALIDATOR" ] || exit 0
# shellcheck source=../lib/seat-resolve.sh
. "$_AQ_LIB" || exit 0
command -v seat_roster_path >/dev/null 2>&1 || exit 0
command -v seat_self_name   >/dev/null 2>&1 || exit 0

# --- the cheap gate -------------------------------------------------------
# No roster, or a roster where NO seat is marked non-interactive, costs one
# grep and nothing else. This matters: without it every AskUserQuestion on the
# machine would pay a tmux walk plus two python3 spawns to learn that the
# answer is "allow" — which it is, for every seat but one.
_AQ_ROSTER=$(seat_roster_path) || exit 0
grep -qE '^[[:space:]]*interactive:[[:space:]]*false[[:space:]]*$' "$_AQ_ROSTER" || exit 0

# --- who am I -------------------------------------------------------------
# --quiet because seat_resolve is loud BY DESIGN (it is an operator command
# that must never guess); its refusal text in a hook's stderr would be noise on
# an allow path. A refusal here IS the fail-open path: an unresolvable or
# unregistered window is not a marked seat, so the call proceeds.
_AQ_SEAT=$(seat_self_name --quiet) || exit 0
[ -n "$_AQ_SEAT" ] || exit 0

# --- is this seat marked non-interactive ----------------------------------
command -v python3 >/dev/null 2>&1 || exit 0
_AQ_VERDICT=$(python3 - "$_AQ_VALIDATOR" "$_AQ_ROSTER" "$_AQ_SEAT" <<'PY'
import importlib.util
import pathlib
import sys

vs_path, roster_path, seat = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    spec = importlib.util.spec_from_file_location("_aq_guard_vs", vs_path)
    vs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vs)
    doc = vs.load_seats_yaml(pathlib.Path(roster_path).read_text())
    row = (doc.get("seats") or {}).get(seat) or {}
    # STRICT identity against the boolean, never truthiness: only the literal
    # `interactive: false` marks a seat. `interactive: "no"`, `0`, a typo, or a
    # key the roster does not carry all mean "not marked" -> allow. The guard
    # blocks on a fact the registry states, never on one it might have meant.
    if row.get("interactive") is False:
        print("block")
except Exception:
    pass  # unreadable / unparseable roster -> say nothing -> the call is allowed
PY
)
[ "$_AQ_VERDICT" = "block" ] || exit 0

# --- BLOCK, and hand back the pattern that replaces it --------------------
# The message is the REDIRECT, not a refusal: a bare block invites a retry or a
# stall, and a stalled seat in a scheduled window is the same freeze by another
# route. Everything a model needs to execute the replacement is inline, because
# a post-molt context may hold nothing else.
cat >&2 <<MSG
🚫 [seat-guard] AskUserQuestion is BLOCKED in the '${_AQ_SEAT}' seat's window.

'${_AQ_SEAT}' is marked \`interactive: false\` in agents/seats.yml. Zig does not
interact with this seat: it is a SCHEDULED window, and an open question here
renders as 🔔, which makes pulse-inject defer every subsequent injection
(\`deferred-blocked-on-human\`). With Zig away that is not a pause, it is an
indefinite freeze of this seat's whole loop — the 2026-08-09 incident
dotfiles-9i39, which took a supervised Esc to clear.

DO THIS INSTEAD — AGENTS.md's autonomous-loop exception ("autonomous loops
never block on AskUserQuestion — they file a P1 \`human:\` bead + push
notification and end the tick"). Three steps, in order:

1. FILE THE DECISION as a P1 \`human:\` bead, capturing the question AND its
   options so Zig can rule without reconstructing your context:

\`\`\`bash
br create -t task -p 1 "human: <the decision, in one line>" -d "## Context
<what this seat was doing, and the fork it reached>

## Options
- A: <option> — <what choosing it implies>
- B: <option> — <what choosing it implies>

## Acceptance Criteria
- [ ] Zig rules between the options
- [ ] ${_AQ_SEAT} proceeds on that ruling at its next scheduled tick"
\`\`\`

2. SEND A PUSH NOTIFICATION naming the decision and the window, e.g.
   "${_AQ_SEAT}: needs a ruling on <decision> — bead <id>, window ${_AQ_SEAT}".
   If it returns "Remote Control inactive" it did NOT deliver — the bead is
   still the durable record, so do not retry the question here.

3. END THE TURN ✅. With no tick pending, ending idle is the CORRECT state for
   this seat: the next injection wakes it. An idle ${_AQ_SEAT} is a healthy
   ${_AQ_SEAT}; a 🔔 one is a stopped one.

If this seat genuinely should take questions from Zig, that is a roster change
(drop \`interactive: false\` from its seat in agents/seats.yml and regenerate
agents/seats.json) — not something to work around from inside a turn.
MSG
exit 2
