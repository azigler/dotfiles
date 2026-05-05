# `bv` — Beads Viewer (graph-aware triage)

Companion to `br`. Reads the same `.beads/issues.jsonl`, layers
graph-theoretic analysis (PageRank, betweenness, critical path, cycles,
HITS, eigenvector, k-core) on top, and emits agent-friendly JSON via
`--robot-*` flags. Repo: <https://github.com/Dicklesworthstone/beads_viewer>.

## Cardinal rule

**Never run bare `bv`.** It launches an interactive TUI and blocks the
agent session. Use `--robot-*` flags only. If you need to inspect a TUI
output for the user, the user can launch it themselves.

## Entry points (start here)

```bash
bv --robot-next        # one top pick — minimal, perfect for "what next?"
bv --robot-triage      # mega-command — ranked recs, quick wins, blockers, health, commands
```

`--robot-triage` returns:

| Field | What it gives you |
|---|---|
| `quick_ref` | At-a-glance counts + top 3 picks |
| `recommendations` | Ranked actionable items with `score`, `reasons[]`, `unblocks` |
| `quick_wins` | Low-effort high-impact items |
| `blockers_to_clear` | Items that unblock the most downstream work |
| `project_health` | Status / type / priority distributions, graph metrics |
| `commands` | Copy-paste shell commands for the next steps |

## Full command surface

**Planning:**
| Flag | Use |
|---|---|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists (multi-agent dispatch ordering) |
| `--robot-priority` | Priority misalignment detection with confidence scores |
| `--robot-capacity --agents N` | Capacity simulation + completion projections |
| `--robot-forecast <id\|all>` | ETA predictions (dependency-aware scheduling) |
| `--robot-burndown <sprint>` | Sprint burndown, scope changes, at-risk items |

**Graph analysis:**
| Flag | Use |
|---|---|
| `--robot-insights` | PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points |
| `--robot-graph --graph-format=mermaid` | Dep graph as Mermaid (or `json` / `dot`) |
| `--robot-impact-network [<id>\|all] --network-depth N` | Impact subnetwork |
| `--robot-blocker-chain <id>` | Full blocker chain analysis |
| `--robot-causality <id>` | Causal chain |

**Hygiene & alerts:**
| Flag | Use |
|---|---|
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Duplicates, missing deps, label suggestions, cycles |
| `--robot-drift` | Drift detection from saved baseline |
| `--robot-diff --diff-since <ref>` | Changes since commit/branch/tag/date |

**Search:**
| Flag | Use |
|---|---|
| `--search "query" --robot-search` | Semantic search (vector index, builds on first run) |
| `--search-mode hybrid --search-preset impact-first` | Hybrid: text + graph metrics |

**History:**
| Flag | Use |
|---|---|
| `--robot-history` | Bead-to-commit correlations from git history |
| `--robot-orphans` | Commits that should be linked to a bead but aren't |
| `--robot-explain-correlation <SHA>:<beadID>` | Why bv linked this commit to this bead |

**Files:**
| Flag | Use |
|---|---|
| `--robot-file-beads <path>` | Beads that touched a file |
| `--robot-file-hotspots` | Files touched by the most beads |
| `--robot-file-relations <path>` | Files that frequently co-change with the given file |

**Labels (when the project uses bead labels):**
| Flag | Use |
|---|---|
| `--robot-label-health` | Per-label health: velocity, staleness, blocked count |
| `--robot-label-flow` | Cross-label dependency flow + bottleneck labels |
| `--robot-label-attention --attention-limit N` | Attention-ranked labels |

**Recipes (pre-filters):**
```bash
bv --recipe actionable --robot-plan      # ready-to-work
bv --recipe high-impact --robot-triage   # top-PageRank
bv --robot-recipes                       # list all recipes
```

**Discovery:**
```bash
bv --robot-help               # cheat sheet
bv --robot-docs guide         # narrative intro JSON
bv --robot-docs commands      # full command schema
bv --robot-docs examples      # example invocations
bv --robot-schema             # JSON Schema for every robot command
bv --version                  # version
bv --check-update             # is a newer version available?
```

## Output discipline

Every `--robot-*` payload includes:

- `data_hash` — fingerprint of the source `issues.jsonl` (for caching)
- `status` — per-metric state: `computed | approx | timeout | skipped` + elapsed ms
- `as_of` / `as_of_commit` — present when `--as-of <ref>` is used

**Two-phase analysis matters when reading `--robot-insights`:**
- **Phase 1 (instant)**: degree, topo sort, density
- **Phase 2 (async, ~500ms timeout)**: PageRank, betweenness, HITS,
  eigenvector, cycles. If `status.pagerank == "timeout"`, the metric
  was skipped — don't trust an absent value as zero.

## jq recipes

```bash
# Top recommendation with reasons
bv --robot-triage | jq '.recommendations[0] | {id, title, score, reasons, claim_command}'

# Single-line "what next?"
bv --robot-next | jq -r '"Top pick: \(.id) — \(.title) (\(.reasons | join("; ")))"'

# Quick wins only
bv --robot-triage | jq '.quick_wins[] | {id, title, score}'

# Blockers that unblock the most downstream work
bv --robot-triage | jq '.blockers_to_clear[] | {id, title, unblocks}'

# Cycles in the dep graph (must fix — they break `br ready`)
bv --robot-insights | jq '.Cycles'

# Project health snapshot
bv --robot-triage | jq '.project_health'

# Top 5 by PageRank (structural importance)
bv --robot-insights | jq '.pagerank | to_entries | sort_by(-.value) | .[:5]'

# Are async metrics ready?
bv --robot-insights | jq '.status'
```

## Output format env vars

```bash
export BV_OUTPUT_FORMAT=toon   # ~30-50% fewer tokens than JSON
bv --robot-triage              # now emits TOON instead of JSON
```

`bv -f toon --robot-...` does the same per-invocation. Use TOON in
agent contexts where the savings matter; JSON elsewhere.

## When to reach for `bv` vs `br`

| Question | Tool |
|---|---|
| What's everything that's open? | `br list` |
| What's unblocked + ready? | `br ready` |
| What's the *single best next* bead? | `bv --robot-next` |
| Ranked next picks with reasoning? | `bv --robot-triage` |
| Multi-agent dispatch order? | `bv --robot-plan` |
| Are there cycles / structural problems? | `bv --robot-insights` |
| What's stale / has priority drift? | `bv --robot-alerts` |
| What's the dep graph look like? | `bv --robot-graph --graph-format=mermaid` |
| Find a bead by fuzzy meaning, not exact text | `bv --search "..." --robot-search` |
| Quick text grep | `br search "..."` |

## TUI (for the user, not the agent)

The user runs bare `bv` for the interactive TUI. Key views:
`a` actionable, `b` board, `g` graph, `h` history, `i` insights,
`r` ready filter, `/` search, `?` help. The agent should never
trigger this — it blocks until the user quits with `q`.

## Anti-patterns

- ❌ Running bare `bv` (blocks the session in the TUI)
- ❌ Reading `--robot-insights` PageRank without checking `status.pagerank` first (could be `timeout`)
- ❌ Using `bv` to *modify* state — bv is read-only analysis. Mutations go through `br`.
- ❌ Accepting the per-project `bv` prompt that asks to inject guidance into `AGENTS.md` — decline; this skill is the SSOT.
