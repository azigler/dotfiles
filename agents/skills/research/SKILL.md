---
description: Orchestrator-side research harness. Codifies the workflow for layering findings + theories + experiments autonomously on an open-ended technical arc, without the user having to prompt each next step. Bootstraps a `refs/research/` archive, dispatches parallel general-purpose research subagents per gotcha/question, empirically verifies their claims, folds findings into beads + GUARDRAILS + cross-arc docs, and pushes material results to the user via notification + file-send. Distinct from /grok (in-repo code reading), /explore (external multi-source compile to Asana), /spec (writing new specs), /check (OQ resolution).
when_to_use: User says "research X", "look into Y", "explore the lay of the land for Z", "what's the state of the art on W", "find me a fix for this gotcha", "keep going" / "stay autonomous" on a research-heavy arc. Also fire PROACTIVELY when (a) you hit an operational blocker that probably has a known upstream fix, (b) the project enters a new substrate / library / framework you haven't characterized, (c) you suspect a finding might be wrong and want a second opinion, (d) you're between user prompts on a multi-iter autonomous loop and need to decide what to do next.
argument-hint: "<topic> [follow-up: <specific question>]"
---

# /research — Orchestrator research harness

You are running a research arc. The user has handed you a multi-step
technical investigation and expects you to **drive it autonomously**:
set the goal, identify gaps, dispatch research, verify empirically,
scrutinize, document findings, layer new theories + experiments on
top, and keep going. The user prods sparingly. You prod yourself.

This skill captures the workflow that's emerged from doing exactly
that — codifying it so future sessions don't have to re-derive the
disciplines, the failure modes, or the layering pattern.

## Mental model: goals + iterations (vs /explore's compile + publish)

`/research` and `/explore` look superficially similar (both fetch
sources, both produce reports) but the **shapes are different**:

- `/explore` is **compile + publish**: user hands you a list of URLs +
  an Asana destination; you fetch all, synthesize a single artifact,
  ship to Asana, optionally to LinkedIn. **One pass. One deliverable.**

- `/research` is **goals + iterate**: user hands you an open question
  or a multi-phase arc; you set explicit research goals, dispatch
  research, **scrutinize the findings**, fold to canon, surface new
  questions, dispatch the next layer, repeat until the goal hierarchy
  is satisfied. **Many passes. A research tree.**

The /research arc has a goal at each level:
- **Arc goal**: the user's framing question (often vague — "make this work" / "figure out X")
- **Iteration goal**: what you'll learn / decide / build THIS round
- **Per-research-item goal**: the specific question one dispatch answers

You SET each goal explicitly before dispatching. You ITERATE by
re-setting the iteration goal after each round, based on what the
previous round surfaced. Goals are the discipline that keeps a
multi-day research arc from becoming a wandering brain-walk.

## What this skill does

`/research` is the canonical orchestrator for **goal-driven layered
technical investigation**: take an open-ended question or a complex
arc, set explicit goals, walk each through dispatch → verify →
scrutinize → fold → layer without losing the thread. Distinct from
in-repo grok (`/grok`), multi-source compile to Asana (`/explore`),
formal spec writing (`/spec`), or OQ resolution (`/check`). Those are
scoped phases; `/research` is the umbrella discipline you operate
inside.

This is a **fully-supported, opinionated process**. Every research
arc gets the same disciplined treatment: bead-tracked, refs-archived,
GUARDRAILS-driven, healthcheck-gated, with parallel subagent dispatch
when items are independent, and cross-fold synthesis when findings
in one item update another's basis.

Concretely, `/research` covers:

| Phase | What | Skill output |
|---|---|---|
| **0. Frame** | Identify gap, frame question crisply, name expected output shape | A scoped question + a target bead |
| **1. Pre-flight** | Healthcheck-style probes; verify substrate state; surface stale assumptions before researching them | Green-light or fix-first |
| **2. Dispatch** | Either yourself or via parallel general-purpose subagents (1-6 at a time depending on independence) | Research reports |
| **3. Verify** | Empirically probe agent claims with cheap roundtrips before folding | Confirmed / corrected findings |
| **3.5 Scrutinize** | Adversarial read — catch reasoning gaps, hidden assumptions, definitional drift the user would catch if they read it cold | Confirmed / Refined / Reversed |
| **4. Fold** | Save to `refs/research/<topic>.md`; update beads --notes; close; cross-link related beads; update GUARDRAILS/cross-epic docs | Persistent state captured |
| **5. Layer** | Surface NEW questions from the findings; bead them; dispatch next-tier research without waiting for user prompt | Recursive research tree |
| **6. Loop / handoff** | If autonomous mode: schedule wakeup + brief; if interactive: push notification + SendUserFile for digestible artifacts | Continuous progress |

The skill is opinionated about: bead-location discipline (`cd` to
target repo before `br create`/`update`), subagent prompt shape
(self-contained, cites sources, ~1500-2000 word cap), empirical
verification (don't trust agent claims about live systems without a
probe), and corrections-as-first-class-citizens (every reversed
finding gets a `REVISED` callout, not a quiet edit).

## When NOT to use this

| Want | Skill |
|---|---|
| In-repo code reading before editing | `/grok` |
| Multi-source compile + Asana + LinkedIn post | `/explore` |
| Write a new formal specification | `/spec` |
| Walk decisions on a spec's open questions | `/check` |
| Adversarial pre-impl plan critique | `/scrutinize` |
| Implement code from a checked spec | `/impl` |
| Session-end handoff | `/offboard` |
| Conference paper / proposal pipeline | `/cfp` |

`/research` is the **umbrella discipline** while those are scoped
phases. You can be inside `/research` AND be invoking `/spec` for
one of its outputs, or invoking `/grok` to ground a specific
finding. Don't pick `/research` if a single scoped skill already fits.

## Pipeline at a glance

```
                    ┌──────────────────────────────────┐
                    │  0. Frame the gap                │
                    └─────────────┬────────────────────┘
                                  │
                    ┌─────────────▼────────────────────┐
                    │  1. Pre-flight healthcheck       │
                    └─────────────┬────────────────────┘
                                  │ green-light
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │  2. Dispatch (you OR parallel research subagents) │
        └─────────────────────────┬─────────────────────────┘
                                  │ reports return
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │  3. Empirically verify the load-bearing claims    │
        └─────────────────────────┬─────────────────────────┘
                                  │
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │  3.5 Adversarial scrutiny (model what the user    │
        │     would say if they read this cold) — MANDATORY │
        └─────────────────────────┬─────────────────────────┘
                                  │
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │  4. Fold: refs/research/, beads --notes, GUARDRAILS│
        │     cross-link related arcs                       │
        └─────────────────────────┬─────────────────────────┘
                                  │
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │  5. Layer: new questions → next-tier beads        │
        │     dispatch without waiting for user prompt      │
        └─────────────────────────┬─────────────────────────┘
                                  │
                                  ▼
                ┌─────────────────┴────────────────┐
                │  Autonomous?  ─────► 6a. Schedule wakeup, push notif, loop  │
                │  Interactive? ─────► 6b. Brief user, await direction        │
                └──────────────────────────────────┘
```

## Step 0 — Onboard: goals + cost discipline

### 0a. Onboarding questions (first time on a research arc)

Before dispatching the first research item, ask the user (or decide
yourself based on the framing):

1. **What's the arc goal?** ("Pick a substrate for X" / "Find a fix
   for Y" / "Understand the lay of the land for Z" — capture it
   verbatim if they said it; reframe in your own words if not.)
2. **Cost-tracking?** If the arc is going to span more than ~1 hour of
   compute, ask: "Want cost-tracking on this? Adds a ledger row per
   session via /offboard." If yes, fire `/cost-tracking` setup:
   ```bash
   cp ~/.claude/skills/cost-tracking/reference/ledger-template.md \
      refs/cost-tracking.md
   git add refs/cost-tracking.md
   git commit -m ":dollar: cost: bootstrap cost-tracking ledger for /research arc"
   ```
   Then `/offboard` auto-appends a row each session. See the
   [/cost-tracking skill](../cost-tracking/SKILL.md) for full details.
3. **Autonomous or interactive mode?** If autonomous: confirm wakeup
   cadence (default 30 min via ScheduleWakeup) and notification
   tolerance ("push for material findings, silence for routine
   progress" is the default).

### 0b. Frame the gap (per research item)

Before dispatching anything, name the question crisply. Bad framing
leads to a 2000-word report that doesn't answer what you wanted.

**Frame each research item as:**
- **What's the gap?** (One sentence. Concrete.)
- **What would "answered" look like?** (Output shape: a decision, a
  comparison matrix, a how-to recipe, a list of options with
  tradeoffs, etc.)
- **What's the user-visible deliverable?** (A bead update? A new
  GUARDRAILS section? A spec sketch? A side-by-side artifact?)
- **What's already known?** (Cite existing refs / beads / GUARDRAILS
  so the research agent doesn't re-discover settled ground.)

**Capture this as a bead BEFORE dispatching:**
```bash
cd <target-repo-root>     # bead-location discipline
br create -p <prio> -t task --parent <epic> "research: <crisp question>"
```

Bead types to use:
- `task` — research that produces a report
- `spec` — research that produces a spec sketch  
- `bug` — research into a known broken thing (with a fix as the deliverable)
- `decision` — research that resolves an open architectural question
- `note` — research that just captures findings (no action)

The bead is the durable handle. Its `--notes` field will hold the
full report after dispatch returns.

## Step 1 — Pre-flight healthcheck

Before research that touches live systems (model servers, APIs, daemons),
verify the substrate is healthy. Stale or hung state will silently
poison every probe the research agent runs.

For our local-models stack, the healthcheck is `~/dotfiles/local-models/healthcheck.sh`.
For project-specific arcs, look for a similar pre-flight in the project's
`refs/` or `local-models/` or equivalent. If none exists, **build one
the first time you hit an avoidable bug from stale state** — the cost
of one healthcheck script is one wasted iter.

See `reference/healthcheck-pattern.md` for the template.

**Healthcheck rule of thumb:**
- Exit 0: proceed with research
- Exit 1: warnings — note them, proceed carefully
- Exit 2: critical — fix before researching, otherwise garbage in / garbage out

Run the healthcheck:
- At the start of every iteration when relevant systems are in scope
- After any failed probe before retrying
- Before dispatching benchmarks or long-running experiments

## Step 2 — Dispatch

Two flavors: you do it yourself, or you dispatch a subagent.

### Do it yourself when

- Single-source, ≤15 min of reading
- Highly local to the project (in-repo grep / file walk)
- You've already done 90% of the research; just need to verify one fact
- Output is a one-paragraph fold-in to an existing bead

### Dispatch a subagent when

- Multi-source synthesis (web + repo + npm + GitHub issues)
- Reading source code you haven't seen
- Producing an artifact (markdown report, side-by-side comparison)
- Comparing 2+ frameworks / libraries / approaches
- Time-box would exceed 30 min of your own work

**Subagent type to use:**
- `general-purpose` for read-only research (no commits, no file
  modifications beyond `/tmp/<output>.md`). Default choice.
- `subagent` with `isolation: "worktree"` ONLY when the agent needs
  to make commits (rare for research — usually a fold step you do
  yourself).

### Parallel dispatch — when and how many

Independent items dispatch in parallel. Dependent items serialize.

| Items | When | Notes |
|---|---|---|
| 1 | Single deep dive | Reasonable default |
| 2-3 | Independent comparisons | Common — e.g., "research A vs B" + "research independent C" |
| 4-6 | Systematic sweep | Rare — e.g., 6-blocker gotcha research |
| 7+ | Almost never | Diminishing returns; harder to fold |

**Memory clobber check (for arcs touching shared resources):**
- Pico has 64 GB unified, ~30 GB workable cliff
- llama-swap mitigates this for MLX
- Ollama has its own keep-alive
- If multiple subagents will hit the same backend simultaneously,
  serialize them or document the contention

### Subagent prompt shape

Use the template in `reference/research-prompt-template.md`. Key
elements every research-subagent prompt must include:

1. **Context block** — what we already know, why this matters, what
   the arc is. Self-contained — agent has zero session history.
2. **Source list** — explicit URLs / file paths / repo names. Don't
   make the agent guess where to look.
3. **Output spec** — exact structure of the report (sections,
   word cap, file path under `/tmp/`).
4. **Empirical mandate when applicable** — "do not speculate; if you
   can't find X, say so; verify with a probe if possible".
5. **Bead reference** — the agent should know which bead it's working
   on so its work can be folded.
6. **Constraints** — word cap, no new top-level files, no nested
   subagents (CRITICAL — subagents must not spawn subagents).

## Step 3 — Empirically verify

Research agent reports are not load-bearing on their own. **Every
load-bearing claim about a live system or external library must be
empirically verified** before you fold the finding.

Examples of load-bearing claims that need verification:
- "Tool X has feature Y" → curl it / call it
- "Library Z works with our stack" → install + smoke-test
- "Bug #1234 affects us" → reproduce the symptom
- "Pattern P from upstream codebase" → re-read the actual file

Cheap verification probes are usually < 60 seconds of work.
Skipping this step is how:
- The first Trinity tool-use ban got reversed 4× as we found nuance
- The "pi.dev is broken" finding became "pi.dev injects tools, Ollama
  Modelfile is the actual issue, but my own retest showed Ollama
  works fine — so the gap is pi.dev's prompt-shape after all"
- The "no DeepSeek MLX support" hang was found to be a model-arch
  issue (G15) after I'd already wasted 4+ hours retrying

**When the verification reverses a claim:** correction goes into the
fold as a `REVISED` callout. Future readers see both the original
hypothesis and the empirical reality. Don't quietly edit.

## Step 3.5 — Adversarial scrutiny (MANDATORY before fold)

Empirical verification catches "does it work in reality" failures.
**Scrutiny catches "does the reasoning hold even if it works"
failures** — flawed framings, hidden assumptions, missing context,
selection bias in the agent's sources, conclusions that don't follow
from the evidence.

This step is **mandatory before folding to canon** (Step 4). It is
the human-style critical-read pass that the user has historically
been doing FOR you — catching things like:

- "the report says NousResearch's autonovel is Hermes-based — but is
  it actually? you should verify the relationship" (turned out NO,
  it predates Hermes uptake and uses Claude direct)
- "you said 29 providers with zero for local Ollama — but `custom` is
  one of those 29 and it IS the local-Ollama path" (reframing the
  whole finding from "gap exists" to "convenience layer exists")
- "the cron auth gap blocks .14 — but is that really blocking, or just
  inconvenient? have you checked workarounds?" (often pivots
  "blocker" → "documented limitation with workaround")

**You should be doing this scrutiny pass yourself, not waiting for the
user to catch it.** The discipline is to model what the user would
say if they read the report cold.

### When to use the /scrutinize skill

The dedicated `/scrutinize` skill exists primarily for impl-wave
review (after code lands, before merge). For research findings, you
have two options:

**Option A — Inline scrutiny (default for single research items).**
Read the report yourself with adversarial intent. Apply the checklist
in `reference/scrutiny-checklist.md`. Take ~5 min. Capture concerns
as REVISED notes or open questions for follow-up.

**Option B — Dispatch a scrutinize-style research subagent (for
high-stakes / load-bearing findings).** When the research is going to
drive a major decision (e.g., picking a substrate, declaring a
pivot, closing an epic), dispatch a second general-purpose subagent
with the prompt in `reference/scrutiny-subagent-prompt.md` — it
re-reads the original sources independently and looks for what the
first agent missed. Costs another ~5-10 min of agent time; worth it
for decisions that lock in weeks of work.

### Scrutiny checklist (apply mentally OR via subagent)

1. **Source coverage** — did the agent miss any obviously relevant
   source? (Check the references list against what you know about the
   space.)
2. **Reasoning chain** — does the conclusion actually follow from the
   evidence presented? Or is there a leap?
3. **Hidden assumptions** — what is the report taking for granted?
   (Substrate behaves like X. Library Y is maintained. Feature Z
   works the way docs say.)
4. **Definitional drift** — when the report says "X works," is "works"
   defined the way YOUR consumers need? (e.g., "tool-use works" but
   only in single-call mode, not the parallel calls you need.)
5. **Selection bias** — did the agent only test happy paths? Did they
   only consider sources that agreed with their forming conclusion?
6. **Recency** — are the cited sources current? (A 2024 GitHub issue
   that's been closed in 2026 doesn't apply.)
7. **Comparison apples-to-apples** — when comparing A vs B, are they
   measured on the same axes? Same workload? Same scale?
8. **Contradictions with prior knowledge** — does the conclusion clash
   with anything in our existing GUARDRAILS / refs / beads? If so,
   which is right?

### Examples of scrutiny catches in our arc

| Original finding | Scrutiny catch | Result |
|---|---|---|
| "Trinity MLX has separate `reasoning` field" | But the field is empty when content is also empty — both attempts hit token-budget limit | Refined: needs max_tokens 3000+ |
| "Pi.dev tool-injection is broken" | But the wire capture shows tools ARE injected; my reproduction probe found Ollama returned structured calls just fine | Reframed: flaky integration, not missing component |
| "NousResearch/autonovel is Hermes-based" | But git log shows direct Anthropic API; first commit predates user's adoption of Hermes for autonovel | Corrected: ancestor pipeline, NOT Hermes substrate |
| "Hermes ships 29 providers, zero for local Ollama or MLX" | But `custom` (one of the 29) IS the bundled OpenAI-compat adapter for local | Reframed: `.13` is convenience layer, not basic-capability |

The user caught all four of these. The discipline is **you should be
catching them yourself.**

### Output of scrutiny step

After scrutinizing, you either:
- **Confirmed** — the report holds; proceed to fold (Step 4)
- **Refined** — the report needs a REVISED note; add it before
  folding to canon
- **Reversed** — the report's conclusion is wrong; either
  re-dispatch with corrected framing, or capture the corrected
  finding inline and proceed to fold

## Step 4 — Fold

After verification, the research becomes durable state:

### 4a. Save the report
```bash
cp /tmp/<agent-output>.md <project>/refs/research/<topic>.md
```

`refs/research/` is the canonical archive convention. Every research
agent output lives there, named by topic (not by date). One file per
research question.

### 4b. Update the bead's `--notes`
```bash
cd <target-repo>     # discipline
br update <bead> --notes "$(cat <project>/refs/research/<topic>.md)"
br close <bead>      # if the research IS the deliverable
br sync --flush-only
```

The bead's notes carry the full report for posterity (in case the
refs file moves). Closing the bead surfaces the research as done in
`br list`.

### 4c. Update GUARDRAILS / cross-epic docs

If the research surfaces an **invariant** (something that must be true
across the project), add it to GUARDRAILS:
- Cross-arc invariants → `<project>/local-models/GUARDRAILS.md` or equivalent
- Cross-epic synthesis → `<project>/refs/cross-epic-overlap-<date>.md`

GUARDRAILS sections are short (G1, G2, ...). Numbered for easy
reference from beads and from each other. See `reference/guardrails-template.md`.

### 4d. Cross-link related beads

If the finding affects other beads (e.g., research on framework A
changes the spec for system B that uses A), update those beads' `--notes`
with a pointer back to the new finding.

### 4e. Push milestone notification + SendUserFile

For material findings (the kind the user would want to know now):
- Use `PushNotification` for the headline (under 200 chars, single
  line, lead with the actionable thing).
- Use `SendUserFile` to deliver the artifact (the research report)
  with a one-line caption containing the punchline.

(Note: the tool name is `SendUserFile`, NOT `PushUserFile` —
common typo. The push-vs-send distinction matters in how Claude
Code surfaces artifacts to the user.)

Save these for findings that:
- Reverse a prior belief
- Unblock something we were stuck on
- Surface a NEW issue to track
- Complete a major arc

Don't push for routine progress.

## Step 5 — Layer

This is the step you'll most often skip if you're operating reactively.
**Don't.**

After folding, look at the report with these questions:
1. What NEW questions did this surface? (Bead them.)
2. What ASSUMPTIONS does this rest on that we haven't verified? (Bead them.)
3. What FOLLOW-UP experiments would deepen this? (Bead them.)
4. What CROSS-ARC implications does this have? (Update those arcs' notes.)
5. What's the OBVIOUS NEXT STEP that a future-me would do? (Just do it; don't bead it for later.)

**The layering pattern is what distinguishes research from one-shot
lookup.** A single research agent gives you one report. Layering
gives you a tree where each new finding spawns the next round.

Example from the local-coding-models arc:
- Wave 7: pi.dev gap audit (#1 research) → reveals Hermes Agent exists
- → Wave 7+1: Hermes vs pi.dev comparison (#2 research) → reveals Hermes is structurally better
- → Wave 7+2: Hermes primer (#3 research) → reveals 4 live upstream bugs
- → Wave 7+3: Hermes plugin authoring deep-dive (#4 research) → builds working canary plugin
- → Wave 7+4: Hermes + pi.dev plugin ecosystem inventory (#5 research) → reveals .15 bead is a 0-day gap (first-mover opportunity)

Each layer was prompted by the previous one's findings, not by the
user. The user said "keep going"; the layering tree happened on its
own.

**The orchestrator's job is to read the report, ask "what's next?"
and dispatch. Without prodding.**

## Step 6 — Loop / handoff

### 6a. Autonomous mode

If the user said "keep going" / "stay autonomous":
1. Schedule a wakeup (`ScheduleWakeup` with delaySeconds=1800 for 30-min cadence) at end of every iter
2. Pass a self-contained continuation prompt so the next firing knows what to pick up
3. Push notification when material findings land between wakeups
4. Don't poll background tasks; they notify on completion
5. Use `SendUserFile` for digestible artifacts (user is away; this is how they catch up)

### 6b. Interactive / between-prompt

If the user is actively at the keyboard:
1. Brief them in 3-7 sentences max (state, blockers, next actionable)
2. Don't push notification (terminal has focus; it suppresses anyway)
3. Wait for direction unless there's an obvious next step that doesn't risk being wrong

### Handing off to another skill

`/research` is the umbrella. Inside it, you'll often:
- Hand off to `/spec` to write a formal spec from research findings
- Hand off to `/check` to walk OQs on a spec the research produced
- Hand off to `/test` + `/impl` to actually build something
- Hand off to `/scrutinize` for adversarial pre-impl review

The research bead crosslinks to whichever skill's bead picks up next.

## CRITICAL: deferred-decisions log

Open architectural questions that you can't resolve yet but shouldn't
forget go into a project-level `deferred-decisions` bead (typed
`decision`). Examples:

- "Should X be done as A or B? Need user input."
- "Library Y has gap Z; track upstream PR."
- "Pattern P deserves an upstream contribution; defer until our use proves it."

Format: D1, D2, D3... each with:
- **Status** (deferred / open / superseded / waiting-on-user)
- **Context** (one paragraph)
- **Decision frame** (what would we decide between?)
- **Recommendation** (your current pick, with rationale)
- **To resolve** (what would unblock the decision)

See `reference/deferred-decisions-template.md`.

This bead is the **canonical "stuff we don't want to lose"** list.
Check it at the start of every research iter to see if anything's
become unblocked.

## Anti-patterns

| Anti-pattern | What goes wrong | Discipline |
|---|---|---|
| Reactive operation | User has to prod for every next step; you waste their attention | **Layer findings without prodding** (Step 5) |
| Skipping verification | Research agent's claim becomes a load-bearing assumption that turns out wrong; cascades into bad downstream decisions | **Empirically probe load-bearing claims** (Step 3) |
| Quiet edits | Reversed findings disappear without trace; later confusion about "wait, didn't we say X?" | **Document corrections as REVISED callouts** (Step 4c) |
| Ignoring memory clobber | Parallel benches OOM pico; bad results | **Healthcheck + memory budget per arc** (Step 1) |
| Wrong bead location | Beads in dotfiles for autonovel work, etc. | **cd to target repo BEFORE br create/update** (Step 4b) |
| Polling background tasks | Burns context; the harness notifies anyway | **Trust the notification system** (Step 6a) |
| One-research-and-stop | Each research is one report; the arc needs the TREE | **Layer (Step 5) is mandatory** |
| Skipping fold | Research lives in `/tmp/`, dies when conversation compacts | **Save to refs/research/ + bead --notes** (Step 4a-b) |
| New top-level docs | Sprawl; user can't find canonical surface | **Extend existing GUARDRAILS / refs/ files**; reach for new files only when explicitly required |
| Nested subagents | Subagent spawns subagent → exponential context blowup | **Subagents must NOT spawn subagents** — repeat in every prompt |
| Token sprawl | 6000-word research reports | **~1500-2000 word cap** for research outputs |

## Reference material

- [research-prompt-template.md](reference/research-prompt-template.md) — canonical subagent prompt skeleton
- [healthcheck-pattern.md](reference/healthcheck-pattern.md) — pre-flight probe template
- [scrutiny-checklist.md](reference/scrutiny-checklist.md) — the 8 adversarial-read questions to apply (Step 3.5)
- [scrutiny-subagent-prompt.md](reference/scrutiny-subagent-prompt.md) — dispatch shape for high-stakes scrutiny
- [guardrails-template.md](reference/guardrails-template.md) — emerging-invariants doc layout
- [deferred-decisions-template.md](reference/deferred-decisions-template.md) — D-series log
- [fold-checklist.md](reference/fold-checklist.md) — what to do when a research agent returns
- [wave-pattern.md](reference/wave-pattern.md) — how to organize multi-iter autonomous loops

## Examples in the wild

This skill emerged from the **local-coding-models** arc (Mar–May 2026)
which covered Epic A (CCR routing), Epic B (CoD MUD agent), Epic C
(LSRA research agent), Epic D (autonovel pi.dev → Hermes pivot), and
explore-7hh (productize Hermes for our use cases).

Concrete patterns from that arc that informed this skill:
- **Systematic gotcha inventory**: Wave 7 #1-6 — 6 research agents dispatched
  in parallel after the user prompted "make beads for blockers, dispatch
  dedicated research subagents." 5 of 6 reversed prior beliefs.
- **Empirical verification reversing findings**: G1 (Trinity ban) revised
  4×; G13 (Qwen3 MLX prose collapse) went from "broken" to "fix is a
  client param" via verification probe; pi.dev gap audit re-framed from
  "broken" to "flaky integration"
- **Layered tree of research**: explore-7hh.11 → .12 → .17 → .19 → .21 each
  prompted by the previous's findings
- **Cross-fold pattern**: ecosystem-inventory (.21) corrected a misleading
  finding from autonovel-on-Hermes-architecture (.bd-b5p.2) about the
  `custom` provider's coverage
- **Layered without prodding** (mostly — the user had to remind me when I
  drifted into reactive mode)
- **GUARDRAILS as living invariants doc**: G1–G15 + H1 grew organically as
  findings calcified

The arc shipped 11 research reports archived in `~/explore/local-coding-models/refs/research/`
and ~30 bead state updates. The discipline scaled.
