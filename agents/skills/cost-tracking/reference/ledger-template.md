# <Project name> — Cost Tracking

Running tally of token costs for this project. Maintained automatically
by `/offboard` (orchestrator sessions) and manually appended for
per-bead subagent costs from the task-notification `<usage>` block.

## Pricing assumptions

Anthropic public API rates verified 2026-04-18. See
`~/.claude/skills/cost-tracking/SKILL.md` for the current canonical
table; replicated here for reproducibility:

| Model | Input | Output | Cache create | Cache read |
|---|---|---|---|---|
| claude-opus-4-7 | $15/M | $75/M | $18.75/M | $1.50/M |
| claude-sonnet-4-6 | $3/M | $15/M | $3.75/M | $0.30/M |
| claude-haiku-4-5 | $1/M | $5/M | $1.25/M | $0.10/M |

## Orchestrator consumption (per-session)

Orchestrator tokens are measured **exactly** by `/offboard` reading the
session's JSONL on disk. `isSidechain: true` entries are excluded —
their tokens land below in the per-bead subagent table.

| Date | Session ID (short) | Input | Output | Cache-create | Cache-read | Cost |
|---|---|---|---|---|---|---|
| <date> | <id> | <inK> | <outK> | <ccK> | <crK> | $0.00 |
| **Running total** | — | **0K** | **0K** | **0K** | **0K** | **$0.00** |

## Per-bead subagent consumption

Append a row each time a subagent returns. Token total comes from the
`<usage>` block in the task-notification at agent completion.

| Date | Bead | Task summary | Tokens | Cost | Wall-clock |
|---|---|---|---|---|---|
| <date> | <bd-id> | <one-line> | <total> | $0.00 | <Xm Ys> |
| **Running total** | — | — | **0** | **$0.00** | — |

## Notes

- This cost is absorbed by Claude Max if applicable; the API-equivalent
  cost is recorded as the simplest bottom-line for a reproducer paying
  standard API rates.
- Cache-read dominates long sessions (90% discount but accumulates
  fast); if it's a large fraction of total spend, prompt context is
  ballooning.
- For research projects: extend with Subject (model under study) and
  Scientist (research apparatus) tables — see hackathon-gemma's ledger
  for the multi-table pattern.

## Extending this ledger

Add tables as needed:

- **GPU consumption** — wall-clock + $ cost of training runs
- **Service-specific** — Gamma credits, Asana ops, Slack-bot tokens, etc.
- **Per-feature buckets** — "spec-bd-XXXX cost", "auth subsystem cost"

Keep the **Orchestrator consumption** table as-is — `/offboard`
expects to find and append to it.
