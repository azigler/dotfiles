---
description: Per-session orchestrator token-cost ledger with a compute script that reads the Claude Code session JSONL on disk. Tracks INFERENCE cost only (input + output tokens at standard API rates) — cache infrastructure is shown as reference counters but excluded from the cost total, matching "what would this session have cost as raw API calls." Filters out subagent sidechains (those have their own per-bead rows). Use when a project wants a reproducible budget — research papers, billing transparency, or just curiosity about where your tokens go. Set up once via /onboard's first-session prompt; updated thereafter by /offboard.
when_to_use: User asks "how much have I spent on this project?", "log this session's cost", "set up cost tracking", "where are my tokens going?" Also runs automatically during /offboard if refs/cost-tracking.md exists.
---

# /cost-tracking — Per-session inference cost ledger

Every Claude Code session writes a JSONL log to disk
(`~/.claude/projects/<slug>/<session-id>.jsonl`) with exact per-turn
token usage. This skill turns those logs into a project-level ledger:

- **Orchestrator-only** token totals per session (subagent sidechains
  are filtered — those land per-bead via task-notification `<usage>`)
- **Inference-only cost** (input + output × standard rates). Cache
  infrastructure (cache_creation, cache_read) is tracked as reference
  counters but EXCLUDED from the cost — that's overhead, not inference.
- Applied pricing from the script's per-model rate table (verify the
  table covers the model you actually ran — see Pricing reference)
- Markdown-row append to `refs/cost-tracking.md`

## Cost model (revised 2026-05-26)

**The cost number is INFERENCE-ONLY:**
```
cost = input_tokens × input_rate + output_tokens × output_rate
```

Cache infrastructure overhead is NOT included in the headline cost.
`--format verbose` shows the cache counts and a comparison
"with-cache-infra" number for awareness, but the canonical cost is
input + output only — matching "raw API call as if no caching."

Why: cache is project infrastructure (a discipline for cheap reuse of
context), not the inference work itself. Counting it inflates the
number without describing what the session actually accomplished. The
inference cost is the comparable, portable metric.

## Setup (once per project)

```bash
# 1. Copy the ledger template into the project
cp ~/.claude/skills/cost-tracking/reference/ledger-template.md \
   refs/cost-tracking.md

# 2. Edit the header to reflect this project (purpose, model discipline)

# 3. Commit the empty ledger
git add refs/cost-tracking.md
git commit -m ":dollar: cost: bootstrap cost-tracking ledger"
```

After bootstrap, `/offboard` automatically appends a row each session.

Session artifacts standardized on `refs/` 2026-06-09. Projects with a
legacy `.claude/plans/cost-tracking.md` keep working (check both), but
migrate on first touch: `git mv .claude/plans/cost-tracking.md refs/`.

The compute script is GLOBAL — it lives at
`~/.claude/skills/cost-tracking/compute-cost.py` (symlinked from
dotfiles). Projects don't need their own copy.

## Usage from /offboard

`/offboard` Step 4 invokes the script if the project has the ledger:

```bash
if [ -f refs/cost-tracking.md ]; then
  python3 ~/.claude/skills/cost-tracking/compute-cost.py --format row >> /tmp/cost-row.txt
  # Then offboard appends that row to the right table in cost-tracking.md
fi
```

## Manual invocation

```bash
# Most-recent session in the current project (auto-discovers via cwd slug)
python3 ~/.claude/skills/cost-tracking/compute-cost.py

# Specific session
python3 ~/.claude/skills/cost-tracking/compute-cost.py \
  --session-jsonl ~/.claude/projects/<slug>/<session-id>.jsonl

# Explicit model (default is claude-opus-4-7)
python3 ~/.claude/skills/cost-tracking/compute-cost.py --model claude-sonnet-4-6

# Different output formats
python3 ~/.claude/skills/cost-tracking/compute-cost.py --format verbose
python3 ~/.claude/skills/cost-tracking/compute-cost.py --format json
python3 ~/.claude/skills/cost-tracking/compute-cost.py --format commit-line
```

## Output formats

| Format | Use |
|---|---|
| `row` (default) | Markdown table row for `cost-tracking.md` — date, session-id-short, in/out/cc/cr token K-counts, $ cost |
| `verbose` | Human-readable breakdown including orchestrator-turn count and skipped-sidechain count |
| `json` | Machine-readable; pipe into another tool |
| `commit-line` | Compact one-liner (`Tokens: in=7K out=1162K cc=4535K cr=390708K -> $758.40`) for embedding in commit bodies |

## What's filtered

- `isSidechain: true` entries are EXCLUDED — those are subagent
  contributions, already captured per-bead via the task-notification
  `<usage>` block when each subagent finished
- Non-`assistant` entries are skipped (user messages, system notes)
- Malformed JSONL lines are skipped with a stderr warning

The result is the orchestrator's true per-session burn. Subagent costs
are tracked separately per-bead.

## Pricing reference

**Staleness warning:** rates below were verified 2026-04-18 and the
table only covers the models listed. Before trusting a ledger total,
confirm the script's rate table has a row for the model the session
actually ran (e.g. a newer model like Fable 5 needs a row added —
check current rates via /claude-api or the Anthropic pricing page).
A session priced with the wrong model's rates is silently wrong.

Costs use Anthropic public API rates verified 2026-04-18:

| Model | Input | Output | Cache create | Cache read |
|---|---|---|---|---|
| claude-opus-4-7 | $15/M | $75/M | $18.75/M | $1.50/M |
| claude-sonnet-4-6 | $3/M | $15/M | $3.75/M | $0.30/M |
| claude-haiku-4-5 | $1/M | $5/M | $1.25/M | $0.10/M |

Cache-read dominates long sessions (90% discount but accumulates fast
when the same prompt context replays each turn).

## When this matters

- **Research projects** publishing reproducibility budgets — split
  ledger into Subject (the model under study) vs Scientist (the
  apparatus) consumption (see hackathon-gemma's ledger for an exemplar
  of this pattern)
- **Billing transparency** in commercial work — clients want to see
  what they're paying for
- **Performance tuning** — if cache-read is dominating, your prompt
  context is too large; if output is dominating, your responses are
  too verbose
- **Personal curiosity** — most Claude Max users never look; worth a
  glance once a month

## When this is overkill

- One-off exploratory sessions
- Projects where you have no ledger appetite
- Sessions ENTIRELY in subagent worktrees (those don't have an
  orchestrator JSONL — subagent costs land per-bead)

If a project doesn't have `refs/cost-tracking.md`, `/offboard`
silently skips Step 4. No-op, no error. Cost-tracking is opt-in.

## Extending the ledger

The default template has one **Orchestrator consumption (per-session)**
table. Projects can add more — research projects often have:

- **Subject consumption** — the model under study (per-bead)
- **Scientist consumption** — the research apparatus (per-bead)
- **GPU consumption** — wall-clock + dollar cost of training runs
- **Per-resource consumption** — Gamma credits, Asana ops, etc.

Hackathon-gemma's ledger (still at its legacy `.claude/plans/` path) is a strong reference
for the multi-table extended pattern. Copy the bones from
[reference/ledger-template.md](reference/ledger-template.md) and add
sections as needed.

## See also

- [/offboard](../offboard/SKILL.md) — invokes this script as part of session exit
- [/onboard](../onboard/SKILL.md) — offers to bootstrap cost-tracking on first session
- [reference/ledger-template.md](reference/ledger-template.md) — the template to copy into `refs/cost-tracking.md`
