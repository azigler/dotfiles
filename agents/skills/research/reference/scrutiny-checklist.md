# Scrutiny checklist (Step 3.5 of /research)

Apply this mentally to every research report BEFORE folding to canon.
Goal: catch the kind of reasoning gap, hidden assumption, or
definitional drift that the user would catch on a careful read.

The discipline is **model what the user would say if they read this
report cold.**

## The 8 questions

### 1. Source coverage
- Did the agent miss any obviously relevant source?
- Look at the citations list. What's NOT there that should be?
- Did they check the most recent commits / issues / PRs?
- Did they look at competitors / alternatives, or just one?

### 2. Reasoning chain
- Does the conclusion actually follow from the evidence presented?
- Is there a leap between "data shows X" and "therefore Y"?
- Are the cited facts strong enough to support the recommendation?

### 3. Hidden assumptions
- What is the report taking for granted?
- "X works the way docs say" → does our reality match the docs?
- "Library Y is maintained" → what's the last commit / release?
- "Substrate Z behaves like A" → have we verified?

### 4. Definitional drift
- When the report says "X works," is "works" defined the way YOUR
  consumers need?
- "Tool-use works" — single call or parallel? With JSON schema or just
  XML? Through our specific API path or only the native one?
- "Plugin system supports Y" — for built-in plugins or for user-added
  too?

### 5. Selection bias
- Did the agent only test happy paths?
- Did they only consider sources that agreed with their forming
  conclusion?
- Was the comparison rigged (e.g., comparing tool A's best feature to
  tool B's worst)?

### 6. Recency
- Are the cited sources current?
- A 2024 GitHub issue closed in 2026 doesn't apply.
- A package "last updated 6 months ago" may be abandoned vs. stable —
  context matters.
- Did the agent check if the upstream has changed since the source
  they cited?

### 7. Comparison apples-to-apples
- When comparing A vs B, are they measured on the same axes?
- Same workload? Same scale? Same evaluation criteria?
- "X scores 80%, Y scores 70%" — same test suite or different?
- "X is faster than Y" — under what conditions?

### 8. Contradictions with prior knowledge
- Does the conclusion clash with anything in our existing GUARDRAILS
  / refs / beads?
- If so, which is right? The new finding or the old?
- Sometimes the new finding is correct and revises old; sometimes
  the new finding is wrong because it missed prior context.

## What to do with findings

After applying the 8 questions, classify the report:

- **Confirmed** — passes all 8; proceed to fold (Step 4) as-is
- **Refined** — minor gaps that need a REVISED note appended before
  fold; you fix in-line and fold
- **Reversed** — major issue; either re-dispatch the research with
  corrected framing, OR capture the corrected finding inline (you
  doing the synthesis yourself) and fold the corrected version

## Examples from our arc

| Original finding | Scrutiny catch | Outcome |
|---|---|---|
| "Trinity MLX has separate `reasoning` field" (Q1 + Q4) | Field is empty when content is also empty — both hit token-budget limit | REFINED: needs max_tokens 3000+ caveat |
| "Pi.dev tool-injection is broken" (Q1, Q3, Q4) | Wire capture shows tools ARE injected; my reproduction probe found Ollama returned structured calls just fine | REVERSED: flaky integration, not missing component |
| "NousResearch/autonovel is Hermes-based" (Q1, Q3, Q8) | Git log shows direct Anthropic API; first commit predates user's Hermes adoption | REVERSED: ancestor pipeline, NOT Hermes substrate |
| "Hermes ships 29 providers, zero for local Ollama or MLX" (Q4 — definitional drift) | `custom` (one of the 29) IS the bundled OpenAI-compat adapter for local | REFINED: .13 is convenience layer, not basic capability |

## Time budget

This pass takes ~5 minutes for a typical 1500-word report. Worth it
EVERY TIME. Skipping it is how findings calcify wrong and downstream
work is built on bad ground.

**Scope limit (2026-06-10 polarity flip):** this inline checklist is
for LOW-STAKES intermediate notes only. Any finding that will be
folded to canon, cited in a verdict, or drive a decision gets an
INDEPENDENT scrutinizer subagent by default (SKILL.md Step 3.5
Option A, `scrutiny-subagent-prompt.md`) — prompted to refute,
defaulting to "refuted" when uncertain, verdict recorded on the bead.
Self-scrutiny by the producer at the canon boundary is
self-sycophancy with a checklist: every major catch in the original
arc was made by the user, not by inline self-review.
