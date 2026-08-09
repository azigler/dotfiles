#!/bin/bash
# molt-thresholds.sh — THE two-tier molt threshold, as ONE constant plus one
# derivation (dotfiles-9060, landing with the marshal build dotfiles-69qr).
#
# THE DESIGN IS DELIBERATELY TWO-TIER, AND THAT IS EXACTLY WHY IT NEEDED
# BINDING. it06's stop-context-guard fires at 75% — a BACKSTOP, the last
# moment a session can still afford a real /offboard before auto-compaction
# lands mid-wrap. 69qr R5 paces the marshal at 50% — PROACTIVE, molting at a
# work-item boundary so the backstop is never reached at all. Two numbers,
# two mechanisms, one intent. Nothing bound them: move one and the other
# silently means something different — a marshal molting twice as often as
# intended (pacing dropped), or never molting proactively at all (pacing
# raised to the backstop, so only the guard ever fires and every molt happens
# mid-arc). Neither turns anything red. That is the whole failure mode.
#
# SO THERE IS ONE PRIMARY NUMBER AND ONE DERIVATION, NOT TWO NUMBERS:
#
#     MOLT_BACKSTOP_PCT = 75                      (it06, the guard's default)
#     MOLT_HEADROOM_PCT = 25                      (what an offboard+molt costs)
#     MOLT_PACING_PCT   = BACKSTOP - HEADROOM     (69qr R5 -> 50)
#
# The relationship is the point: the pacing threshold is not "50 because 50",
# it is "far enough below the backstop that a seat which paces itself never
# reaches it". HEADROOM is the real quantity — one /offboard (handoff note +
# commit + push) plus the molt itself — and 75->50 is the measured shape of
# that on this fleet (the guard's own header records why 85 was too late for
# a 15% window; 25 is the same argument, one tier earlier).
#
# CONSUMERS (both, and there must never be a third that hardcodes a literal):
#   * agents/hooks/stop-context-guard.sh  — sources this for its default
#     threshold, keeping a literal fallback so a tree without this file (a
#     mutant copy, a fixture dir) still guards at 75 rather than at nothing.
#   * agents/scheduler/marshal-drain.sh   — sources this for the pacing
#     percentage it publishes in every plan, which is what the /marshal skill
#     molts against between beads.
#
# agents/lib/test-molt-thresholds.sh is the binding test: it fails if EITHER
# number moves without the other, and it reads both consumers from disk rather
# than trusting this file alone.
#
# Overridable via the environment (a caller may raise the backstop for an
# experiment) — the derivation follows, which is the property that makes this
# a binding rather than a second place to edit.

MOLT_BACKSTOP_PCT="${MOLT_BACKSTOP_PCT:-75}"
MOLT_HEADROOM_PCT="${MOLT_HEADROOM_PCT:-25}"
MOLT_PACING_PCT=$(( MOLT_BACKSTOP_PCT - MOLT_HEADROOM_PCT ))

# molt_thresholds_sane — return 0 iff the derived pair is usable. A caller
# that overrode the environment into nonsense (headroom >= backstop, either
# number outside 1..99) gets a refusal, not a negative percentage.
molt_thresholds_sane() {
  [ "$MOLT_BACKSTOP_PCT" -gt 0 ] 2>/dev/null || return 1
  [ "$MOLT_BACKSTOP_PCT" -lt 100 ] || return 1
  [ "$MOLT_HEADROOM_PCT" -gt 0 ] || return 1
  [ "$MOLT_PACING_PCT" -gt 0 ] || return 1
  [ "$MOLT_PACING_PCT" -lt "$MOLT_BACKSTOP_PCT" ] || return 1
  return 0
}
