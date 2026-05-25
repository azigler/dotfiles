# Deferred-decisions log template

The canonical "stuff we don't want to lose" list for a research arc.
Single typed `decision` bead at the project level (e.g., `dotfiles-5e2`
in the local-models arc).

## Why a single bead

- One place to scan for "what's still open"
- Numbered (D1, D2, ...) for cross-reference from research reports
  / GUARDRAILS / spec OQs
- Doesn't pollute the bead list with one-bead-per-decision noise
- Easy to inspect at iter-start: `br show <id>` lists everything

## Bead creation

```bash
cd <target-repo>
br create -p 3 -t decision "deferred-decisions: open architectural questions to cover in depth later"
# bead ID gets returned; capture it
```

## Body template

```markdown
Living list of deferred decisions and blockers across the <arc-name>
arc. Cover in depth later — not blocking current work but should be
resolved before respective epics ship.

## D1 — <crisp question>

**Status:** deferred <date> / open / waiting-on-user / superseded
**Context:** [1-2 paragraphs: what's the situation, why does this need a decision?]
**Decision frame:** [What would we decide between? List the 2-4 options.]
**Recommendation:** [Your current pick, with rationale.]
**To resolve:** [What would unblock the decision? User input? Empirical probe? New research?]
**Cross-references:** bead `<id>`, GUARDRAILS G<N>, refs/research/<topic>.md
**See:** [Related D-series entries if any.]

## D2 — <next>

...
```

## Status meanings

- **deferred** — decided we don't need this now; revisit later
- **open** — actively in scope; need a decision soon
- **waiting-on-user** — orchestrator needs user input
- **superseded** — moot now (another decision absorbed it); kept for trail
- **resolved** — decided; should be moved out of the deferred list to GUARDRAILS / spec / committed code

## When to add a deferred decision

After a research item or a scrutinize pass, if there's an
architectural question that:
- Doesn't have a clear answer yet
- Isn't blocking the current iteration
- Has consequences for future work
- Would be lost to context-compaction if not captured

Add a D-entry.

## When to revisit

- At the start of every research iter (check if any have become
  unblocked or moved to "waiting-on-user → user-responded")
- During /offboard (note any "stuff for next session")
- When user explicitly asks "what's still open?"

## Examples from the local-coding-models arc

`dotfiles-5e2` has D1-D12 covering:
- /dispatch skill enhancement (D1) — deferred per user
- Autonovel substrate pivot beyond heartbeat (D2) — declared
- Hermes productization scope (D3)
- CCR sampler-defaults transformer (D4)
- Trinity → Hermes integration path (D5)
- Pico disk cleanup (D6) — waiting-on-user
- Epic D E1 blind-rate (D7) — superseded by D2
- Epic C seed topic (D8) — waiting-on-user
- Epic B CoD creds (D9) — waiting-on-user
- Laguna mlx-lm branch test (D10)
- Hermes upstream bugs to track (D11)
- pico-tailnet provider shape (D12)

## Anti-patterns

- **Capturing routine TODOs as D-entries** — TODOs go in regular
  beads. D-entries are architectural decisions that need framing +
  recommendation.
- **D-entry never updated** — if D5 has been "open" for 3 iters, it
  needs either escalation (ask the user) or close (decide and capture
  in GUARDRAILS / spec).
- **D-entries that aren't decisions** — pure status updates / progress
  notes belong in beads, not the deferred-decisions log.
