---
description: Spec writing — produces a formal specification as a high-priority bead typed `spec` (NOT a file). The spec content lives in the bead's --description with sections for Overview / Baseline / Changes / Formal Spec / Test Cases / Open Questions / Future. Pairs with /check (walks OQs), /test (extracts cases), /impl (implements). Pre-existing specs/ folders stay file-based; new specs created with this skill are beads.
argument-hint: "<scope-name>"
when_to_use: Defined work needs a formal specification before /check, /test, /impl. Produces a typed spec BEAD (not a file); ends ready for /check to walk the open questions.
---

# /spec — Specification Writing

You are a spec-writing agent. Your output is a **bead typed `spec`**
with the full specification in its `--description` field, ready for
`/check` to walk its open questions and `/test` to extract test cases.

## Why beads (not files)

Specs are handoff packets, not human-curated documents. Beads:

- **Greppable** — `br list --type spec`, `br search`, `br show`
- **Time-ordered** — created_at + updated_at preserve narrative
- **Inert when stale** — closed beads stop appearing in `br ready`
- **Cross-linkable** — `--parent`, `--deps`, `Bead:` trailers tie work
  back to the spec without a brittle file path
- **No file rot** — descriptions live with the bead's lifecycle, not
  in a separate `specs/NN.md` file that gets stale on every refactor

Pre-existing `specs/<NN>-name.md` files stay where they are — those
projects already have established workflows. New specs created via
`/spec` from this point forward are beads.

## Inputs

The orchestrator passes:
1. **Scope name** — what to spec (e.g., "auth subsystem", "rate limiting")
2. **Bead ID** — the spec bead the content goes into (already typed `spec`)
3. **Brief** — what's in scope and what's NOT

If scope is ambiguous or overlapping with existing specs (`br list --type spec`
to check), **stop and ask** before writing.

## Step 1: Load context (in main session)

Read in order:

1. `CLAUDE.md` — project conventions, file layout, decisions
2. `MEMORY.md` if present — user preferences
3. **Existing related specs** — `br list --type spec` plus
   `br search <related-keyword>`. If `specs/` files exist for adjacent
   subsystems, read those too.
4. **External references** — RFCs, library docs, prior art the brief names

## Step 2: Understand the baseline

What already exists for this subsystem? Code references, behaviors,
APIs. Document the current state — the spec formalizes or extends it.

## Step 3: Apply project decisions

For each design decision affecting your scope, document:
- **What changes** from baseline
- **Why** (reference the decision id or source)
- **How** (concrete spec)

## Step 4: Write the spec to the bead

### Step 4a (recommended): Run an Interrogator pass before finalizing Section 6

Section 6 (Open Questions) is where the spec's load-bearing decisions
live. The single biggest failure mode in spec writing is **missing an
OQ that should have been there** — a decision the author assumed was
settled but actually wasn't.

The **Interrogatory LLM pattern** (Fowler bliki:
https://martinfowler.com/bliki/InterrogatoryLLM.html) is the inverse
of `/check`: instead of walking OQs that already exist, you have an
LLM *generate* the OQs by interrogating your draft.

Workflow:

1. **Draft Sections 1-5** (Overview, Baseline, Changes, Formal Spec,
   Test Cases) — the body of the spec. Leave Section 6 empty for now.
2. **Dispatch a read-only interrogator** via `subagent_type:
   "general-purpose"` or `"Explore"` (NOT a worktree subagent — this
   is read-only review). Prompt template:

   > You are an interrogator on a spec draft. Read the spec below and
   > ask probing questions to surface: assumptions that aren't
   > explicit, edge cases the test cases don't cover, dependencies on
   > other specs that aren't named, decisions that look settled but
   > actually aren't, and concurrency / failure modes the design
   > doesn't address. Severity-rank your questions P1 (blocks impl) /
   > P2 (impl can proceed but with risk) / P3 (nice-to-resolve).
   > Output as a numbered list — no commentary, just questions and
   > severities.
   >
   > Spec draft:
   > <paste Sections 1-5 verbatim>

3. **The interrogator's questions populate Section 6**. The author
   still owns the *recommendations* (the suggested answer for each
   OQ); the interrogator just surfaces what to decide.
4. Then write the full spec (with Section 6 populated) to the bead
   via `br update` as in Step 4b below.

This pattern surfaces OQs the author would have missed because they're
inside the author's blind spot. Used in front of `/check` it makes
that walk shorter and sharper — `/check` decides the OQs the
interrogator wrote.

### Step 4b: Write the spec

Write the full spec as the bead's `--description`. Use this structure
(see [reference template](../beads/reference/handoff-templates.md#spec-bead)
for the complete shape):

```bash
br update <spec-bead-id> --description "$(cat <<'EOF'
## 1. Overview
- What this subsystem does
- Role in the overall system
- What is NOT covered

## 2. Current State / Baseline
- What exists today (with code references)

## 3. Changes and Decisions
- Change / Why / How for each decision

## 4. Formal Specification
- Data structures (type sketches)
- Algorithms in pseudocode
- API contracts (input / output / errors)
- Error conditions

## 5. Test Cases (≥10)
TEST: <name>
INPUT:    <code or call>
EXPECTED: <behavior>
RATIONALE: <what this tests>
... (10 minimum)

## 6. Open Questions
- OQ-01 (P1): <question>
  - Recommendation: <author's suggested answer>
  - Affects: <subsystems / specs>
- OQ-02 (P2): ...

## 7. Future Considerations
- How this might evolve
EOF
)"
```

Also populate `--acceptance-criteria` (this is what `/check` and the
orchestrator use to verify the spec is ready):

```bash
br update <spec-bead-id> --acceptance-criteria "$(cat <<'EOF'
- [ ] Section 1.1 sources documented (which docs informed this spec)
- [ ] Sections 2 and 3 cite existing code or specs by reference
- [ ] Section 5 has ≥10 test cases with INPUT/EXPECTED/RATIONALE
- [ ] Section 6 lists open questions with recommendations
EOF
)"
```

If the bead doesn't already have `--type spec`:

```bash
br update <spec-bead-id> --type spec
```

## Writing guidelines

1. **Concrete, not abstract.** Pseudocode > prose. Type layouts >
   descriptions. Code examples > hand-waving.
2. **Every claim has a source.** Reference design docs, code, RFCs.
3. **Test cases are mandatory.** ≥10. Both happy-path and error.
4. **Type sketches, not final code.** Use `// sketch` comments.
5. **Cross-reference other specs** by bead ID (`see bd-XXXX`) or by
   path (`specs/NN-name.md`) where applicable.
6. **Current scope only.** Future features go to Section 7.

## Step 5: Commit + handoff

```bash
br sync --flush-only
git add .beads/issues.jsonl
git commit -m ":page_facing_up: spec: <scope-name>

Bead: <spec-bead-id>"
```

The orchestrator picks up `<spec-bead-id>` and dispatches `/check`
with that ID as parent.

## Self-review (5 items)

Before closing your bead:

- [ ] Bead is typed `spec` (`br show <id>` shows `[spec]`)
- [ ] Section 1.1 sources documented
- [ ] At least 10 test cases
- [ ] Section 6 (Open Questions) populated — even if "none" must be stated
- [ ] Acceptance criteria match the spec content

## When this skill does NOT apply

- The project has an existing spec in `specs/NN.md` you're amending —
  edit the file directly, don't create a new bead
- The work is too small to spec — atomic 1-bead-1-commit work doesn't
  need a spec; just create the work bead with a tight description
- The work is exploratory — create a `-t note` bead instead and create
  a P3 follow-up if it solidifies

## See also

- [/beads](../beads/SKILL.md) — bead lifecycle, fields, anti-patterns, types
- [/beads reference/handoff-templates.md](../beads/reference/handoff-templates.md) — full per-stage bead templates
- [/check](../check/SKILL.md) — walks OQs from this spec bead, records decisions
- [/test](../test/SKILL.md) — extracts Section 5 test cases into tests
- [/impl](../impl/SKILL.md) — implements against the spec + tests
