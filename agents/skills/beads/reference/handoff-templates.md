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
factory/eval/evaluators.py (or project equivalent)
EOF
)" \
  --acceptance-criteria "$(cat <<'EOF'
- [ ] Evaluator exists and runs as part of the eval suite
- [ ] Evaluator fails on the original buggy behavior
- [ ] Evaluator passes on the current fixed behavior
EOF
)"
```

## Receipt-of-work bead (post-shipping)

After a fix ships and the user wants a durable record of "what got
fixed, why, and how we know it stuck" — this becomes an Asana ticket
via `/asana` (see [asana-integration.md](asana-integration.md)).
The bead version:

```bash
br create -t receipt -p 3 "receipt: <scope> — <headline>"
br update <id> \
  --description "$(cat <<'EOF'
## Consolidated summary (1–3 sentences)
When this work happened, which agent(s), the headline outcome.

## Stakeholder feedback
Quote from the original Slack / doc thread.

## Root causes (numbered)
1. ...
2. ...

## Fixes shipped
- bd-XXXX — one-line summary
- ...

## Validation
Before/after numbers, smoke tests, trace links.

## Deployed
Where, when, env var changes, restart notes.

## Replied in Slack threads
Links.

## Evaluator
Name in factory/eval/evaluators.py.
EOF
)"
```
