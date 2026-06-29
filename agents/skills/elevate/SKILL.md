---
description: Max-effort, fresh-eyes re-examination of FINISHED work — the generative twin of /scrutinize. Where /scrutinize is a critical/adversarial gate hunting for what's WRONG, /elevate is an opportunity gate hunting for what was MISSED: the novel opportunity, the non-obvious connection, the thing worth building that a baseline-effort pass walked past. Runs fresh, unpolluted subagents at effort:'max' via Workflow so the re-read isn't anchored to the original (often lower-effort) framing. Two modes — targeted (elevate one project/exploration/decision) and sweep (the biweekly compendium-wide opportunity-finder, pulse-elevate.timer).
when_to_use: An exploration / finding / design / decision is "done" but you suspect a baseline pass under-thought it; the user says "elevate X", "look at this with fresh eyes on max", "what opportunity did we miss here"; or the biweekly pulse-elevate sweep fires. NOT for correctness review (use /scrutinize) and NOT for first-pass research (use /explore).
argument-hint: "<target: a path / project / exploration / 'sweep'>"
---

# /elevate — max-effort fresh-eyes re-examination

Most work in this harness is produced at the default `high` effort, and a
lot of the explore compendium was produced on `1/day` pulse ticks in
*convergent* "catalog it" mode. That mode scopes to what was asked and
greps the average (AGENTS.md "Effort — the intelligence dial"). `/elevate`
is the deliberate counter-move: take finished work and **re-examine it with
maximum intelligence and fresh, unpolluted eyes**, hunting specifically for
the *upside* a baseline pass missed.

It is the **generative twin of `/scrutinize`**:

| | `/scrutinize` | `/elevate` |
|---|---|---|
| Asks | "what's WRONG / unverified?" | "what was MISSED / what's the opportunity?" |
| Stance | critical, adversarial, skeptical | divergent, generative, opportunity-seeking |
| Output | killed/confirmed findings | novel opportunities, connections, builds |
| Gate on | correctness before shipping | upside before moving on |

## The two non-negotiables

1. **Max effort.** The whole point is to beat baseline thinking, so the
   re-examination agents run at **`effort:'max'`**. The bare `Agent` tool
   has no effort param (it inherits the session level), so `/elevate`
   dispatches through a **Workflow** `agent(prompt, {effort:'max'})`.
   Running this at default effort defeats it entirely.
2. **Fresh + unpolluted.** Use *new* subagents with clean context — never
   continue the agent (or the session) that produced the original work, or
   it re-treads the same groove. Give them the source material but NOT the
   original conclusions framed as settled. Divergent lenses (2+ different
   angles) beat one.

## Mode A — targeted elevate (`/elevate <target>`)

Re-examine one thing: an exploration folder, a project, a finding, a
design, a decision.

1. Identify the target + its source material (the FINDINGS/specs/code/repo).
2. Run a small Workflow: 2-3 **max-effort** fresh agents with *divergent
   lenses* (e.g. "what to build / resume," "what to learn / connect," "what
   would a skeptic-of-the-skeptic see"), then a max-effort synthesis agent.
3. The orchestrator layers its own judgment on the synthesis and reports to
   Andrew — name it as an elevate result, with a clear verdict and the
   single highest-leverage next move.
4. If it surfaces something worth doing, **file a bead** for it (typed
   `note`/`task`); don't let the insight evaporate.

## Mode B — the sweep (`/elevate sweep`, biweekly)

The compendium-wide opportunity-finder. Fires on `pulse-elevate.timer`
(biweekly), or on demand.

1. Enumerate the explore compendium (`~/explore/*/FINDINGS.md` etc.) and
   any other finished-work corpus in scope.
2. Fan out **max-effort** fresh agents over slices (by cluster/theme), each
   hunting: cross-exploration clusters, novel "you should build X"
   opportunities, non-obvious connections to Andrew's active work, and
   "what did the per-card baseline pass miss." Then a max-effort synthesis.
3. **Deliver the findings to Andrew's attention via a session/push
   notification** (PushNotification / remote control) — a short "elevate
   sweep found N opportunities" with the headlines.
4. **Preserve the findings in beads** (one `note`/`task` bead per real
   opportunity, prefix the title `elevate:`), in the explore umbrella's
   `.beads/`. **Do NOT put them on Asana** — beads are the durable store;
   Asana is for the Vibes research queue, not elevate output.
5. **Write the opportunities back into the FINDINGS files** (the brain, not
   just the bead store). For each exploration the sweep examined, append (or
   refresh) a section in its `FINDINGS.md`:
   ```
   ## Novel opportunities (elevate sweep YYYY-MM-DD)
   - <opportunity> — <harness move> — <effort> — <risk>
   ```
   This is the BACKFILL mechanism: the ~40 pre-2026-06-29 explorations were
   created before `Novel opportunities` was a required `/explore` section, so
   the sweep completes them over time, cross-cuttingly (one section per file
   it touches), rather than a one-shot per-folder blast (which is the weaker,
   non-remixing mode). Don't rewrite existing content — append the dated
   section; multiple sweeps stack dated sections so the history is legible.
6. Append a one-line record to the explore handoff/ledger and commit +
   push the beads AND the touched FINDINGS files.

The sweep is autonomous (scheduled): it never blocks on AskUserQuestion —
it notifies + files beads + ends, exactly like a `/pulse` tick.

## The loop seam — opportunities re-enter the research queue

The point of the explore+elevate double loop is that it's a LOOP: explore
compresses sources into the brain, elevate (and explore's own `Novel
opportunities` pass) extracts "you should build/explore X" — and those Xs
should become FUTURE explorations, not just beads that gather dust. The
audit (2026-06-28, `explore-doj`) found the seam open: opportunities landed
in beads but never returned to the Vibes queue, so the two loops ran
parallel and never fed each other.

Closing it (the seam):

1. **Always file the bead** (as today — typed `note`/`task`, prefix
   `elevate:`). The bead is the durable record.
2. **Mark genuine "go research/build this" opportunities as Vibes
   candidates.** Add a `📌 candidate Vibes card: <crisp card title>` line to
   the bead so it's a one-step promotion, not a re-derivation.
3. **Promotion is HUMAN-GATED — never auto-write the Vibes board.**
   - In an **interactive** session, offer (AskUserQuestion) to add the card,
     then add it on a yes.
   - In the **autonomous sweep**, do NOT create cards — list the candidates
     in the push notification ("3 candidate Vibes cards: …") and let Andrew
     promote. Auto-spawning research cards from a scheduled loop is exactly
     the token-blowout / comprehension-rot debt the four loop costs warn
     about; the steering wheel stays in Andrew's hands.
   - Mechanical note: the fleet proxy has **no section-add route**, so a
     card can't be dropped straight into the Vibes section programmatically
     anyway — promotion goes through Andrew (or a future proxy route). Until
     then, the candidate list in the notification IS the promotion UI.

This makes the loop close without ceding the queue: opportunities surface,
Andrew chooses which become the next explorations, and the brain compounds.

## Anti-patterns

- ❌ **Running it at baseline effort** — the entire value is the `max` lift;
  a `high`-effort re-read is just a second average pass.
- ❌ **Reusing the original agent/session** — it's anchored; you'll get the
  same conclusions back. Fresh context only.
- ❌ **Using it for correctness** — that's `/scrutinize`. Elevate looks for
  upside, not bugs.
- ❌ **Letting findings evaporate** — always land real opportunities as
  beads (and notify, for the sweep). An un-captured insight is a no-op.
- ❌ **Sweeping output onto Asana** — beads + notification, not the Vibes
  board.

## See also

- AGENTS.md "Effort — the intelligence dial" — the policy this enforces
- `/scrutinize` — the critical twin
- `/explore` — first-pass research (elevate re-examines its output)
- `pulse-elevate.timer` / `.service` (machine-local) — the biweekly sweep
