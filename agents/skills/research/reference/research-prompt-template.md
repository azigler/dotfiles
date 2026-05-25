# Research subagent prompt template

Canonical shape for the prompt you send to a `general-purpose` research
subagent. Self-contained — the agent has zero session history.

Copy this skeleton, fill in the brackets, dispatch.

```
You are a focused research agent. Your goal: [ONE CRISP SENTENCE
NAMING THE QUESTION].

## Context

[What's the project. What's the arc. What's the bead. Why does this
matter. Cite 2-4 existing refs / beads / GUARDRAILS sections that the
agent should treat as ground truth.]

## What we already know (don't re-derive)

[Bullet list of settled findings. Cite exact files / URLs / bead IDs
so the agent doesn't waste compute re-discovering them.]

## What I need you to find

[Numbered list of specific sub-questions. Be concrete. "What plugins
exist?" is bad; "What pi.dev plugins are published on npm as
@earendil-works/* OR by third parties as @*/pi-* ?" is good.]

## Source material to read

[Explicit URLs / paths / repo names. Don't make the agent guess.]

- https://...
- ~/explore/.../some-file.md
- npm package @foo/bar
- GitHub: search topic:X OR code-search "pattern Y"

## Output format

Save to `/tmp/research-<topic>.md` (~1500 words max). Structure:

```
## TL;DR
[The headline, 1-2 paragraphs]

## [Question 1]
[Findings, with source citations]

## [Question 2]
...

## Sources
[All URLs / files consulted]
```

## Constraints (non-negotiable)

- Be EMPIRICAL. Don't speculate. If you can't find X, say so.
- Cite source URLs / file paths / line numbers where possible.
- Verify load-bearing claims with a probe if possible (curl, install
  + smoke, file read).
- Surface uncertainty: "I couldn't determine X" beats "X probably is".
- Word cap: ~1500 (going slightly over OK for high-density empirical
  reports; don't pad).
- NO new top-level files except the report.
- NO commits.
- NO nested subagents. You are a leaf agent.

Bead: `<bead-id>` (for your reference; do NOT modify the bead — the
orchestrator does that after you return).
```

## Variations

### High-stakes scrutiny dispatch (Step 3.5 Option B)
See `scrutiny-subagent-prompt.md`.

### Empirical verification dispatch
For verifying ONE specific claim, prefer doing it yourself (faster +
cheaper). Only dispatch if it requires multi-step setup the orchestrator
can't easily do (e.g., installing a tool in an isolated venv on a
remote host, then smoke-testing).

### Comparison dispatch
When asking "X vs Y," include a decision matrix in the output format:
```
| Capability | X | Y | Notes |
|---|---|---|---|
| ... | ... | ... | ... |
```
Forces the agent to compare apples-to-apples on named axes.

## Anti-patterns in dispatch prompts

| Anti-pattern | Fix |
|---|---|
| Vague question ("research X") | Make it specific ("does X support Y in version Z, and what's the install path?") |
| No source list | List specific URLs / files |
| No output spec | Specify exact structure + word cap |
| Forgot constraints block | Always include "no nested subagents" + "no commits" + word cap |
| Single source given | List 3-5 sources so agent triangulates |
| Asking for opinion not fact | Frame as "what does the evidence say" not "what should we do" |
| No empirical mandate | Add "verify claims with probes where possible" |
