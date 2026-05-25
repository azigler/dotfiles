# Scrutiny subagent prompt template (Step 3.5 Option B)

For high-stakes research findings — substrate decisions, pivots,
epic closures — dispatch a SECOND research subagent with this
template to do an independent adversarial read.

Costs ~5-10 min of agent time. Worth it when the decision locks in
weeks of work.

## When to use vs the inline checklist

| Situation | Use |
|---|---|
| Routine research, low-stakes folding | Inline scrutiny checklist (~5 min you do yourself) |
| Decision drives a substrate / pivot / epic-close | Dispatch this scrutiny subagent |
| User has flagged a concern about a report's conclusions | Dispatch this subagent + apply the user's concern as the framing |
| Report contradicts something we believed | Either resolves both via dispatch |

## Prompt template

```
You are an adversarial research-scrutiny agent. Your goal: catch
reasoning gaps, hidden assumptions, definitional drift, missing
context, or selection bias in [REPORT FILE PATH], a research output
that will drive a [DECISION TYPE — substrate pick / pivot / epic
closure / etc.] if accepted as-is.

## The original research

The original research agent produced [REPORT FILE PATH] addressing
the question: "[ORIGINAL QUESTION]".

Their conclusion was: "[CONCLUSION SUMMARY]".

This is about to be folded into [BEAD ID / GUARDRAILS / EPIC PIVOT]
unless your scrutiny pass surfaces a problem.

## Your job

Re-read the original sources INDEPENDENTLY (don't trust the agent's
synthesis). Apply this checklist:

### 1. Source coverage
Did the original agent miss any obviously relevant source? Check
their cited sources against what you can find. List up to 3 sources
they should have looked at but didn't.

### 2. Reasoning chain
Does the conclusion actually follow from the evidence presented? Or
is there a leap?

### 3. Hidden assumptions
What is the report taking for granted? Are those assumptions
verifiable? Are any KNOWN to be false?

### 4. Definitional drift
When the report says "X works," is "works" defined the way the
project's consumers need? Check the project's specific use case in
[CONSUMER CONTEXT — bead / spec / use case description].

### 5. Selection bias
Did the original agent only test happy paths? Only consider sources
that agreed with their forming conclusion? Compare like-for-like?

### 6. Recency
Are the cited sources current? Has anything moved since the original
sources were published? (Check repo commit dates, npm last-update,
issue close-dates, etc.)

### 7. Comparison apples-to-apples
When comparing A vs B, are they measured on the same axes? Same
workload? Same scale?

### 8. Contradictions with prior project knowledge
Does the conclusion clash with anything in:
- ~/explore/.../refs/ (project refs)
- The project's GUARDRAILS file (if any)
- Beads in `br list` (project state)
If so, which is right? Investigate.

## Sources to re-check independently

[Same source list as original research agent. Re-read with
adversarial intent.]

## Output

Save to `/tmp/scrutiny-<original-topic>.md` (~1000 words max):

```
## Verdict
CONFIRMED / REFINED / REVERSED

[One paragraph: what's your overall take?]

## Per-question findings
1. Source coverage: [verdict + what they missed if anything]
2. Reasoning chain: [verdict + leaps if any]
... [for each of the 8 questions]

## Specific corrections
[If REFINED or REVERSED: what exactly needs to change in the original
report? Provide REVISED text the orchestrator can paste in.]

## Net recommendation
[Should the orchestrator fold the original conclusion, fold a
modified version, or re-dispatch the research with different framing?]

## Sources I consulted
[Your independent source list — at least some should overlap with
the original; some should be NEW (sources the original missed).]
```

## Constraints

- Be GENUINELY adversarial. Your job is to find what they missed,
  not to confirm what they said.
- Cite sources independently — don't take the original's word for
  what a source says; re-read.
- Calibrate severity: CONFIRMED is fine if you genuinely can't find
  issues; don't manufacture concerns.
- Word cap: ~1000.
- NO new top-level files except your scrutiny output.
- NO commits.
- NO nested subagents.
```

## After the scrutiny agent returns

You (the orchestrator) read the scrutiny output and:

- **If CONFIRMED**: proceed to fold the original report (Step 4) as planned. Save the scrutiny output to `refs/research/scrutiny-<topic>.md` so future readers see the adversarial review happened.

- **If REFINED**: apply the corrections inline to the original report BEFORE folding. Both the original and the scrutiny go to refs/research/ for trail.

- **If REVERSED**: do NOT fold the original conclusion. Either:
  - Capture the corrected finding yourself, inline (synthesis based on both reports), and fold the corrected version
  - OR re-dispatch the original research with corrected framing (if the original's whole premise was off)

Either way, the scrutiny report is canon — it documents WHY the
original was wrong, which is valuable for future similar work.

## Example outputs from this pattern

From the local-coding-models arc:
- The user-driven scrutiny catches in SKILL.md's Step 3.5 example
  table are exactly the shape this subagent should produce. Read
  those for the calibration.
