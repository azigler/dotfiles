# GUARDRAILS doc template

When research surfaces an **invariant** — something that must be true
across the project, not a one-off finding — it goes in a project-level
GUARDRAILS file. Numbered sections for cross-reference.

## File location

- For projects with infra/serving-layer concerns: `<project>/local-models/GUARDRAILS.md` or similar
- For broader project conventions: `<project>/GUARDRAILS.md` at root
- For domain-specific (e.g., autonovel-voice): `<project>/<domain>/GUARDRAILS.md`

## Section template

```markdown
## G<N> — <short title that fits in a glance>

**Empirical receipt (<date>):** [The one-paragraph statement of the invariant,
with a citation to the bead / probe / refs/research/ file that established it.]

[Detail block — 2-5 paragraphs covering: the root cause, the failure mode,
how to detect it, the workaround. Include code snippets where helpful.]

**Rule:** [The one-sentence operational consequence — what consumers must
do (or not do) because of this invariant.]

**Cross-references:** bead `<id>`, `refs/research/<topic>.md`, related G<M>
```

## Numbering convention

- G1, G2, G3... in order of addition (chronology > taxonomy — taxonomy drifts).
- Letter prefix for category if you need it:
  - G1-Gn — general (the default)
  - H1-Hn — health-check / operational
  - S1-Sn — security-related
- New section gets a new number, even if it supersedes an old one — keep the
  old as `G<N>-LEGACY` with strikethrough or a "REVISED" callout pointing
  to the new section. Don't quietly delete; the audit trail matters.

## Revision pattern

When you discover a previous GUARDRAILS section was wrong or
incomplete:

```markdown
## G<N> — <revised title>

**REVISED <date>** (was: "<previous title>" — see G<N>-LEGACY at end).

[New content.]

---

## G<N>-LEGACY — <original title> (REVISED — kept for trace)

~~[Original content with strikethrough.]~~

**Why revised:** [One paragraph: what we learned that changed the position.]
```

## Examples (from local-models/GUARDRAILS.md)

- **G1**: Trinity tool-use parser nuance — revised 4× as empirical evidence accumulated
- **G7**: Laguna MLX BLOCKED — has upstream PR workaround (Blaizzy's branch)
- **G13**: Qwen3 MLX prose collapse — FIXED via `repetition_penalty` request param
- **G14**: mlx_lm.server has no model unload — workaround via llama-swap
- **G15**: DeepSeek-V2-Lite MoE arch unsupported in mlx-lm 0.31.3 (same pattern as G7)
- **H1**: Run healthcheck at iter start — the operational hygiene one

## When to add to GUARDRAILS vs leave in a bead

| Where to put | When |
|---|---|
| Bead --notes only | One-time finding; specific to one work item |
| `refs/research/<topic>.md` | Detailed report; reference for future readers |
| GUARDRAILS | **Cross-arc invariant** that every future consumer must respect |
| Deferred-decisions log | Open architectural question not yet resolved |

The GUARDRAILS test: would I want another orchestrator picking up this
project to know this BEFORE they touch the relevant subsystem? If yes,
it goes in GUARDRAILS.

## Anti-patterns

- **GUARDRAILS sprawl**: dumping every finding into GUARDRAILS until
  it's 500 sections long. Reserve for genuine invariants.
- **Quiet revision**: editing G7 in-place without leaving a LEGACY
  trail. Future readers can't see why the position changed.
- **Stale GUARDRAILS**: an invariant that was true 6 months ago but
  has since been fixed upstream. Periodically re-verify (annual
  GUARDRAILS audit is reasonable for a long-lived project).
