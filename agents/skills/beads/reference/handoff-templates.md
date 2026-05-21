# Handoff templates per pipeline stage

A bead's shape depends on which pipeline stage it represents. Each
stage hands off to the next, so the receiving agent's life is easier
when the bead carries the right fields populated.

The pipeline: **spec → check → test → impl → eval**. Each stage has its
own bead in the modern flow (spec content lives in the spec bead's
`--description`, not in a `specs/NN.md` file).

## Spec bead (the spec lives in the description)

```bash
br create -t spec -p 2 "spec: <subsystem-name>"
br update <id> \
  --description "$(cat <<'EOF'
## 1. Overview
- What this subsystem does
- Its role in the overall system
- What is NOT covered (explicit scope boundaries)

## 2. Current State / Baseline
- Summary of what exists today for this area
- References to existing code or related beads

## 3. Changes and Decisions
- Each change from baseline:
  - **Change:** what's different
  - **Why:** the design decision driving it

## 4. Formal Specification
- Data structures (type sketches)
- Algorithms in pseudocode
- API contracts (inputs / outputs / errors)
- Error conditions and handling

## 5. Test Cases (≥10)
TEST: basic-create
INPUT:    create("foo")
EXPECTED: returns id with prefix "f-"
RATIONALE: minimum-viable creation flow

TEST: edge-empty-input
... (etc — minimum 10 cases)

## 6. Open Questions
- OQ-01 (P1): <question>
  - Recommendation: <author's suggested answer>
  - Affects: <which subsystems / specs>
- OQ-02 (P2): ...

## 7. Future Considerations
- How this might evolve later
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Section 1.1 sources are documented
- [ ] All test cases have INPUT/EXPECTED/RATIONALE
- [ ] At least 10 test cases (Section 5)
- [ ] Open questions section exists (even if empty)
EOF
)"
```

## Check (decisions) bead

A separate bead, child of the spec bead. The check agent walks the spec's
OQs, conflicts, and dependencies — and **records resolutions on this
bead**, not back into the spec.

```bash
br create -t decision -p 1 "check: <spec-name> open questions"
br update <id> --parent <spec-bead-id>
br update <id> \
  --description "$(cat <<'EOF'
## Spec under review
- Spec bead: <spec-bead-id>
- OQs to resolve: OQ-01, OQ-02, ...
- Conflicts to walk: cross-spec issues with spec X
- Dependencies to confirm: interface agreements

## Process
For each open question, present analysis + recommendation,
then record decision via `br update <id> --notes "..."`.
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Every P1 OQ from spec has a DECIDED status
- [ ] Cross-spec conflicts marked RESOLVED
- [ ] Implementation Readiness summary appended to --notes
EOF
)"

# As decisions land, append to --notes:
br update <id> --notes "$(cat <<'EOF'
## Decisions

OQ-01: DECIDED 2026-MM-DD
  Answer: <one sentence>
  Rationale: <brief>
  Spec impact: <field/section that changes>

OQ-02: DECIDED ...
EOF
)"
```

## Standalone architectural decision bead (ADR-style)

Distinct from the "Check (decisions) bead" above. **Check decisions**
walk a spec's open questions and are parented to that spec.
**Architectural decisions** stand alone — they capture a CHOICE
between alternatives that's bigger than any single spec (e.g.,
"use SQLite vs Postgres", "no nested agents in the harness",
"calendar versioning over semver").

```bash
br create -t decision -p 2 "decision: <scope> — <one-line choice>"
# NO --parent — these stand alone
br update <id> \
  --description "$(cat <<'EOF'
## Context

What's the situation that requires a decision? What constraints are
in play? Name the team / project / external pressures.

## Decision

**State the decision in one or two bold sentences so it stands out
at a glance.** Use literal `**bold**` markdown even though the bead
view is plaintext — the asterisks make it scannable.

## Options considered

Enumerate **≥2 alternatives** with honest pros/cons each. One-sided
alternative sections are a red flag — if the section dismisses
options without serious consideration, the decision wasn't really
made.

- Option A: pros + cons
- Option B: pros + cons
- Option C (chosen): pros + cons

## Consequences

What does this decision make easier? Harder? Under what conditions
should it be revisited? The re-evaluation trigger is the key
forward-looking field — it tells future-you when a supersession
becomes worth writing.

## Advice (optional)

External consultation record — input from other engineers, papers,
RFCs, talks, etc.
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Context names the situation + constraints
- [ ] Decision sentence is bold and ≤2 sentences
- [ ] Options Considered has ≥2 alternatives with honest pros/cons
- [ ] Consequences names a re-evaluation trigger
EOF
)"
```

**Target length**: ~250-300 words total. Tight but substantive. If it
balloons past 500, it's becoming a spec — convert to `-t spec`.

**Immutability discipline**: once closed, the `--description` is
read-only. The one allowed edit is appending a supersession pointer
to `--notes`:

```bash
# Append-only supersession pointer (matches /check skill's notes pattern)
EXISTING=$(br show <old-id> | awk '/^Notes:/{flag=1; next} flag')
br update <old-id> --notes "$EXISTING

---
SUPERSEDED 2026-MM-DD by bd-YYYY: <one-line reason>"
```

The new bead's `--description` starts with `## Supersedes bd-XXXX`
in its Context section. The graph is then traversable both
directions.

## Test bead

```bash
br create -t test -p 2 "tests: <spec-name>"
br update <id> --parent <spec-bead-id>
br update <id> \
  --description "$(cat <<'EOF'
## Spec under test
- Spec bead: <spec-bead-id> (read its Section 5 for cases)
- Decisions bead: <check-bead-id> (read --notes for resolved OQs)
- Test output path: <project convention — see /test SKILL>

## Task
Convert spec Section 5 cases to executable tests + add ≥5 edge / error
tests beyond the spec.
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Every spec Section 5 test case has a corresponding test
- [ ] ≥5 additional edge / error tests
- [ ] Tests import from real module paths (no inline stubs)
- [ ] No source files outside __tests__/ touched
EOF
)"
```

## Impl bead

```bash
br create -t impl -p 2 "impl: <module-name>"
br update <id> --parent <spec-bead-id>
br update <id> --deps "blocks:<test-bead-id>"   # impl needs test merged first
br update <id> \
  --description "$(cat <<'EOF'
## Spec + tests
- Spec bead: <spec-bead-id>
- Decisions bead: <check-bead-id>
- Test file: <path written by test agent>

## Task
Make all non-skipped tests pass. Follow spec Section 4 (formal spec)
and Section 6 (implementation notes).

## Constraints
- Do NOT modify tests (they define the contract)
- Public API must match what tests import
- Lint clean, doc comments on public API
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] All tests pass
- [ ] Linting clean (see /lint)
- [ ] No panicking code in non-test paths
- [ ] Doc comments on public API
EOF
)"
```

## Eval bead (the fix-bead → evaluator pattern)

When a fix lands, an eval bead ensures the issue can't regress.

```bash
br create -t eval -p 2 "eval: <area> — guard <regression>"
br update <id> --parent <fix-bead-id>
br update <id> \
  --description "$(cat <<'EOF'
## Regression to guard
- Fix bead: <fix-bead-id>
- The bug: <what was wrong>
- The fix: <what changed>
- Why an evaluator: this regressed once; ensure it can't again silently

## Evaluator location
<project>/eval/evaluators.py
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Evaluator exists and runs as part of the eval suite
- [ ] Evaluator fails on the original buggy behavior
- [ ] Evaluator passes on the current fixed behavior
EOF
)"
```

## Receipt-of-work pattern (post-shipping)

A post-shipping "receipt of work" — a stakeholder-facing summary of a
shipped fix or feature — is **not** a bead type. It belongs in
whatever external tracker the team uses for shipped-work visibility
(Asana, Linear, Jira, a project board). The bead-side equivalent is a
closed `impl` or `task` bead with `--external-ref` pointing at that
external ticket.

Why not a bead type: the canonical artifact lives in the external
tracker; a `receipt` bead type would only ever shadow it.
