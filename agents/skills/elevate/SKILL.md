---
description: Max-effort, fresh-eyes re-examination of ONE finished thing — the opportunity gate (what was MISSED), twin of /scrutinize's correctness gate. Targeted only.
when_to_use: A specific exploration / design / decision / project is "done" but a baseline pass may have under-thought it; the user says "elevate X", "fresh eyes on max", "what opportunity did we miss here". NOT first-pass research (use /dive). NOT the weekly corpus review (use /desk). NOT a correctness review (use /scrutinize).
argument-hint: "<target: a path / project / exploration / decision>"
---

# /elevate — max-effort fresh eyes on ONE finished thing

Most work in this harness is produced at the default `high` effort, and a
lot of the explore compendium was produced on pulse ticks in *convergent*
"catalog it" mode. That mode scopes to what was asked and greps the average
(AGENTS.md "Effort"). `/elevate` is the deliberate counter-move: take **one
finished thing** and re-examine it with maximum intelligence and fresh,
unpolluted eyes, hunting the *upside* a baseline pass missed.

It is the **generative twin of `/scrutinize`**:

| | `/scrutinize` | `/elevate` |
|---|---|---|
| Asks | "what's WRONG / unverified?" | "what was MISSED / what's the opportunity?" |
| Stance | critical, adversarial, skeptical | divergent, generative, opportunity-seeking |
| Output | killed/confirmed findings | novel opportunities, connections, builds |
| Gate on | correctness before shipping | upside before moving on |

**Scope: targeted only.** `/elevate` examines ONE subject. The weekly
compendium-wide sweep it used to carry (the old "Mode B") is now **`/desk`**
— the lab's allocator, which reads the whole corpus and writes the
resourcing memo. If your instinct is "sweep everything," that's `/desk`, not
this. (Split 2026-07-26, beads `explore-369f` / `explore-mqvu`. `/desk`
calls this skill's max-effort technique internally for its opportunity pass
— the technique is shared, the scope is not.)

## The three non-negotiables

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
3. **Shorter than the thing it examines.** A targeted elevate that outruns
   its subject has become part of the comprehension-rot problem it exists
   to fight (`explore-jdgk`: the old sweep narratives grew 1,460 → 1,666 →
   2,190 words). **Hard cap: 600 words** in the report to Zig. If the
   re-read genuinely found more than 600 words of upside, that is a `/desk`
   input, not a longer elevate.

## The register — chief of research, not a note-taker

The output **argues for resourcing this line of inquiry**. Zig is the
lab owner; you are the chief of research (memory:
`explore-is-a-research-lab`). A catalogue of observations is not the
deliverable. Every elevate report carries, in this order:

- **The ask** — the single highest-leverage next move, concretely stated
  (a build? a Vibes card? an hour of his time? a bead?).
- **The signal** — why NOW: what makes this ripe, cited to a file path,
  bead id, or source. A claim with no citation does not go in.
- **Expected return** — what it unlocks if it works.
- **Honest risk** — the strongest reason NOT to do it. Writing this well is
  where the report earns trust; a pitch with no downside spends it.
- **Verdict** — do-now / experiment / defer / drop. Say one.

Assume Zig does not know the premise; explain it from scratch, briefly
(memory: `pitch-as-partner`, `plain-language-explanations`).

## Where the upside can land — lead with curiosity, not a tie-back

**Single owner: [`_shared/opportunity-landing.md`](../_shared/opportunity-landing.md)**
— the four landings (new idea / interlink / active work / interesting for its own
sake) and the three hard guards. Read it before fanning out the max-effort lenses;
the genuinely new idea is the whole point of a fresh pass, and this is what keeps
it off the modal tie-back. `/dive` and `/desk` point at the same file — never
re-copy it here.

## The run

1. **Identify the target + its source material** — the FINDINGS / specs /
   code / repo / decision bead. One subject. If you're tempted to name
   three, you want `/desk`.
2. **Fan out 2–3 max-effort fresh agents with divergent lenses** via a
   Workflow `agent(…, {effort:'max'})` — e.g. "what to build / resume,"
   "what to learn / connect," "what would a skeptic-of-the-skeptic see."
   Then one max-effort synthesis agent.

   **Bead context: progressive, not a bomb.** Interlinks live at the
   FINDINGS↔bead seam, so agents DO need bead context — but feed it the way
   a careful reader loads tabs. **NEVER `br list --json` the backlog into an
   agent**: its JSON inlines every bead's full `description` (~250 KB /
   ~60k tokens for ~100 open explore beads), which blows the budget AND,
   because every body is dense with the same tie-backs, *manufactures* the
   over-anchoring this skill exists to avoid. Pass the **titles index**
   (`br list`, text) and let the agent `br show <id>` only the beads its
   findings actually touch.
3. **Layer your own judgment on the synthesis and report to Zig** in the
   register above, under the 600-word cap. Name it as an elevate result.
4. **File a bead for anything worth doing** (`-t task` / `-t study`, title
   prefix `desk:` so it lands in the same standing-opportunity queue
   `/desk` drains). **Interlink it**: name the beads/explorations it
   connects **by id** in the body, and `br dep add` a real dependency where
   one exists. An orphan bead has thrown away the edge that was the whole
   finding.
5. **Close the loop seam, human-gated.** If the finding is a genuine "go
   research/build this," add a `📌 candidate Vibes card: <crisp title>`
   line to the bead so promotion is one step, not a re-derivation — then
   **offer** (AskUserQuestion) to add the card in an interactive session.
   Never auto-write the Vibes board; the queue is Zig's steering wheel.
   (Mechanical note: the fleet proxy has no section-add route anyway.)

`/elevate` is **interactive and on-demand**. It is not scheduled, it writes
no pulse-ledger row, and it has no autonomous mode. If you are running under
a timer, you are in `/desk`.

## Anti-patterns

- ❌ **Running it at baseline effort** — the entire value is the `max` lift;
  a `high`-effort re-read is just a second average pass.
- ❌ **Reusing the original agent/session** — it's anchored; you'll get the
  same conclusions back. Fresh context only.
- ❌ **Using it for correctness** — that's `/scrutinize`. Elevate looks for
  upside, not bugs.
- ❌ **Sweeping the whole compendium** — that's `/desk`. This skill takes
  one subject.
- ❌ **Outgrowing its subject** — over 600 words means you wrote a memo, and
  memos are `/desk`'s job.
- ❌ **Letting findings evaporate** — land real opportunities as interlinked
  beads. An un-captured insight is a no-op.
- ❌ **Sweeping output onto Asana** — beads, not the Vibes board.

## See also

- AGENTS.md "Effort" — the policy this enforces (`max` is a per-dispatch
  Workflow escalation, never a session setting)
- `/scrutinize` — the correctness twin
- `/desk` — the lab's allocator; the weekly corpus-wide review this skill
  used to carry
- `/dive` — first-pass research (elevate re-examines its output)
