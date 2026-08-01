#!/bin/bash
# The scrutiny-verdict matcher — ONE definition, shared by every gate that
# asks "did an independent reviewer say SHIP?".
#
# Source via:
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/scrutiny-verdict.sh"
#
# Consumers (keep this list current — it is the answer to "who reads this?"):
#   * agents/hooks/pre-bead-close.sh   — the `br close` scrutiny gate, and its
#     `--selftest` acceptance matrix, which IS this file's test.
#   * agents/hooks/pre-commit-checks.sh — the pulse-ledger `done` proof gate,
#     kind:scrutinize.
#
# WHY THIS FILE EXISTS. The matcher was hoisted inside pre-bead-close.sh in
# 2026-06-09 "so --selftest and the gate itself share one definition" — but the
# SECOND consumer never adopted it. pre-commit-checks.sh kept a bare
# `br show "$B" | grep -q 'SHIP'`, which accepts the four letters SHIP anywhere
# in a bead body: "Verdict: do NOT SHIP" and "needs scrutiny before we SHIP"
# both bought a pulse tick a `done` row, while pre-bead-close's own selftest
# matrix listed both as FAIL (dotfiles-8aj5, 2026-08-01). Hoisting one level
# further — out of the hook and into lib/ — is what makes "one definition"
# true across FILES, not just within one.
#
# Do NOT re-inline these patterns anywhere. A third copy is the defect.
#
# ⚠️ BASH ONLY. scrutiny_verdict_ok ends in `grep -qvE` over possibly-empty
# input, and `grep -qv` on EMPTY input exits 0 under zsh and 1 under bash — so a
# zsh-run harness reports the no-verdict cases as ACCEPTED and hides a real
# false-accept. Every consumer is #!/bin/bash; test them as bash.

# A "Verdict:" line ending in SHIP|OVERRIDE is the accept condition (a bare
# `Verdict: SHIP`, the dated `## Scrutiny — <date>: Verdict: SHIP` header, and
# a remediation chain `Verdict: FIX-FIRST -> addressed -> SHIP`), as is the
# verdict sitting directly after a scrutiny marker (`## Scrutiny — OVERRIDE:`).
# REJECT and an unresolved FIX-FIRST fail, as does a negated "do NOT SHIP".
SCRUTINY_VERDICT_RE='(Verdict:[[:space:]]*(.*[^[:alnum:]])?(SHIP|OVERRIDE)[[:punct:][:space:]]*$|[Ss]crutin[a-z]*[^[:alnum:]]+(SHIP|OVERRIDE))'
SCRUTINY_NEGATED_RE='\b[Nn][Oo][Tt][[:space:]]+(SHIP|OVERRIDE)\b'

# Returns 0 when $1 records an accepted scrutiny verdict.
# NOTE the negation filter is applied LINE-WISE (grep over the already-matched
# lines), so a "do not ship" elsewhere in the notes cannot veto a real verdict.
scrutiny_verdict_ok() {
  echo "$1" | grep -E "$SCRUTINY_VERDICT_RE" | grep -qvE "$SCRUTINY_NEGATED_RE"
}
