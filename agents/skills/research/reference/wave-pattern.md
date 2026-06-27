# Wave pattern (autonomous /research loops)

How to organize a multi-iteration autonomous research arc when the
user has handed you a "keep going" mandate.

## The wave structure

Each iteration is a **Wave** numbered sequentially (Wave 0, 1, 2, ...).
Each Wave has:
- An **iteration goal** (what you'll learn / decide / build this round)
- A **dispatch list** (research items, each with its own sub-number — Wave 7 #1, #2, ...)
- **Outcomes** (what shipped, what surfaced new questions)
- **Next-wave priorities** (what the next round will pick up)

```
Wave 0: Foundation — healthcheck, GUARDRAILS bootstrap, baseline probes
Wave 1: Initial research dispatch (1-3 parallel items)
Wave 2: Process Wave 1 results + dispatch follow-ups
Wave 3: ...
...
```

## Per-wave rhythm

For each wave:

1. **Brief at start** — "Wave N goal: <X>. Dispatching <count> research items: <list>."
2. **Dispatch in parallel** when items are independent (Step 2 in SKILL.md)
3. **Process returns as they fire** (notifications drive you, don't poll)
4. **Verify + scrutinize each** before folding (Steps 3, 3.5)
5. **Fold to canon** (Step 4)
6. **Layer**: surface new questions, bead them, decide if they belong in this wave or next (Step 5)
7. **Schedule next wakeup OR brief user** depending on mode (Step 6)

## Wave 0 — Bootstrap discipline

For a brand-new research arc:
- Establish project-level GUARDRAILS file if none exists
- Create healthcheck.sh if substrate has a known failure mode
- Create deferred-decisions bead at project level
- Bootstrap `refs/research/` directory

## Wave numbering rationale

- **Numbered** so you can reference "Wave 3 finding" cleanly
- **Sequential** because they're chronological (taxonomy drifts; chronology doesn't)
- **Sub-numbered** per dispatch (Wave 7 #1, #2, ...) for parallel-dispatch waves
- Don't rename retroactively even if the wave scope drifts — keep the trace honest

## When to start a new wave vs continue current

| Situation | Action |
|---|---|
| Just folded a finding; new questions surfaced | If small + same domain, add to current wave; if big or different domain, start new wave |
| User gave new direction mid-wave | Finish current wave's in-flight items; start new wave for the new direction |
| Wave is sprawling beyond 6 items | Force a synthesis pass; close wave; start next |
| Stuck waiting on user input | Don't start new wave; brief + wait |

## Concurrent waves

Don't run more than ONE wave at a time. Each wave has a goal; you
can't goal-drive two threads simultaneously.

If multiple research items are independent within a wave, dispatch in
parallel (Step 2 in SKILL.md). But the wave itself is serial.

## Push-notification rhythm during a wave

- At wave START: optional notification "Wave N kicking off: <goal>"
- During wave: only for material findings (reverse / unblock / new
  issue / complete arc)
- At wave END: brief in-conversation summary (or push if user is away)

Don't push for routine progress (every dispatched item, every
completed item, etc.). The user's attention is the budget.

## Wave-end brief template

```
**Wave <N> wrap.**

Goal: <iteration goal>

Shipped this wave:
- <bullet 1>
- <bullet 2>
...

[Optional: a table of items if many]

| # | Status |
|---|---|
| 1 <name> | ✅ closed — <one-line outcome> |
| 2 <name> | 🟡 in flight |

Material findings:
- <reversal / unblock / new issue>

Next wave will: <iteration goal for Wave N+1>

[If autonomous: "Wakeup scheduled for HH:MM"]
[If interactive: "Awaiting direction OR proceeding with next wave on cadence"]
```

## Examples from the local-coding-models arc

| Wave | Goal | Items |
|---|---|---|
| 0 | Foundation | GUARDRAILS bootstrap, healthcheck, X4-X5 probes, CCR install |
| 1 | Epic A core + initial epic-D explore | X1 (env propagation), D's E1 (prose blind-rate) |
| 5 | Wave 1 receipts + qwen_sampler | trinity_shim, qwen_sampler, CCR per-provider research |
| 6 | Hermes Agent rescope | Process Hermes vs pi.dev research, rescope explore-7hh |
| 7 | 6-item parallel research dispatch | autonovel-on-Hermes arch, Hermes primer, landscape, Devstral, DeepSeek, llama-swap |
| 8 | Plugin authoring deep-dive + Phase 1 spec + migration plan | 3 items + ecosystem inventory followup |
| 9 | Model-front sweep | Full DeepSeek bench, R1 variants, D10 Laguna, GLM revisit, AB-verdict update |

Waves 2-4 don't exist — gaps are fine; the wave numbering just
captures the actual flow.

## Anti-patterns

- **Skipping the wave-end brief** — user loses thread of where the
  arc is
- **Trying to run 2 waves concurrently** — goal-drift; you can't
  scrutinize two arc-shapes at once
- **Wave that's actually 15 items** — split it; smaller waves are
  easier to scrutinize + fold
- **No wave goal** — drifting brain-walk; reset
- **Wave numbering drift** — renaming Wave 7 → Wave 5 retroactively
  because "they're chronologically wrong" — DON'T; chronology is
  what it is
