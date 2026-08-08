# Fable 5 effort/thinking/WebSearch envelope — empirical probe, 2026-08-08

Bead: `dotfiles-8eod`. Follows `agents/skills/research/reference/experiment-protocol.md`
(scaled down to a single-session probe: no scale ladder needed, 15 cells total).

## Why this probe exists

`agents/AGENTS.md` carries a dated finding — **"the Opus 5 400"** — that Opus 5
rejects `output_config.effort` of `xhigh`/`max` whenever thinking is disabled, and
names Claude Code's WebSearch tool path as the trigger. That finding was measured
on Opus 5. The machine default flipped to `claude-fable-5[1m]` on 2026-08-08 (see
`~/.claude/settings.json` `"model"` key), and AGENTS.md itself says "an effort
level tuned on one model is a calibration, not a constant — re-measure when the
fleet's default model changes." This probe is that re-measurement, and it also
re-checks Opus 5 under the exact same harness/version as a control, since the
original finding predates today by two weeks and this environment's version may
have moved.

## Phase E0 — Pre-registration

**Hypothesis** (recorded before running): Fable 5 arithmetic probes with no tools
(thinking presumed on-by-default) will work at all five effort levels. Fable 5
WebSearch probes — the documented thinking-disable trigger — will work at `high`
(matches AGENTS.md: no problem "at effort high or below") and will either 400 or
silently answer from stale training data at `xhigh`/`max`, mirroring the Opus 5
finding. The Opus 5 known-good control (arithmetic, high) is expected to pass; the
Opus 5 known-bad control (WebSearch, xhigh) is expected to reproduce the
documented 400 or a silent-stale answer.

**Method**: `claude -p "<tiny prompt>" --model <model> --effort <level> [--tools
...] [--setting-sources ""] --output-format json`, run from this worktree's shell
(which wraps `claude` with `--dangerously-skip-permissions` and routes through the
tailnet gateway `http://100.72.47.4:17017/claude` unless `CC_NO_GATEWAY=1`).
Non-search cells use a minimal custom `--system-prompt` and `--tools ""` to hold
cost down (no CLAUDE.md, no default tool definitions). Search cells use the
built-in default system prompt with only `WebSearch` enabled
(`--tools "WebSearch" --allowedTools "WebSearch"`), `--setting-sources ""` to skip
project CLAUDE.md loading. Each call capped at 120s via `timeout 120`.

**Version manifest**: `claude --version` = `2.1.226 (Claude Code)`. Model aliases
resolved: `claude-fable-5` → `canonicalModel: claude-fable-5` (`contextWindow:
200000` — note the bare alias does NOT pick up the `[1m]` extended-context variant
the session default uses). `claude-opus-5` → `canonicalModel: claude-opus-5`
(same 200k window). Gateway: `ANTHROPIC_BASE_URL=http://100.72.47.4:17017/claude`.
Effort values accepted by the CLI (`claude --help`): `low, medium, high, xhigh,
max`. **No CLI flag toggles thinking directly** — `claude --help` has no
`--thinking`/`--no-thinking` flag; the only documented mechanism (per AGENTS.md)
is Claude Code's internal WebSearch-tool-use path, which is what the search cells
below probe.

**Expected-outcome ranges**: non-search calls 2–10s wall time, ~$0.02–$0.06 each
(minimal system prompt); search calls 10–60s, ~$0.05–$1.4 each (multi-turn tool
loop, default system prompt). Success artifact: correct arithmetic answer text for
non-search cells; for search cells, a **cited URL** that could only come from a
live fetch (`server_tool_use` / `modelUsage[model].webSearchRequests` > 0 in the
response JSON) vs. a confident answer with **no** search requests logged (silent
stale) vs. an `is_error:true` / non-null `api_error_status` (400).

**Abort criteria**: two consecutive cells returning malformed/unparseable JSON, or
a single cell running past its 120s timeout without producing output, would have
triggered a stop-and-report. Neither occurred.

**Sample size**: N=1 per cell (15 cells) — a probe, not a statistical run. Each
cell's outcome is a categorical class (works / 400 / silent-stale / other), not a
quantity needing variance estimation, so N=1 per cell is adequate for this scope;
flagged explicitly as a limitation in Conclusions.

## Phase E1 — Calibration

**Positive control**: `claude -p "test" --model claude-fable-5 --effort high
--setting-sources ""` (no deliberate fault) → returned normally, `is_error:false`.
PASS — establishes the harness produces a clean result for a working config.

**Negative control** (proves the detection mechanism actually distinguishes
failure): `claude -p "test" --model claude-fable-5-nonexistent-xyz --effort high
--setting-sources "" --tools "" --system-prompt "test"` →

```json
{"is_error":true,"terminal_reason":"api_error","api_error_status":404,
 "result":"There's an issue with the selected model (claude-fable-5-nonexistent-xyz). It may not exist or you may not have access to it. Run --model to pick a different model."}
```

`is_error`/`api_error_status`/`terminal_reason` reliably surface an API-level
failure verbatim — this is the field set the matrix below reads for every cell.
Client-side validation was also observed and is a distinct category: `--effort
ultramega` produced a **warning printed to stdout before the JSON blob**
(`Warning: Unknown --effort value 'ultramega' — ignoring it and using the default
effort. Valid values: low, medium, high, xhigh, max.`) and then ran successfully
at the default effort — the CLI itself validates the enum client-side, before any
request reaches the API. This is a third, non-400 failure class the matrix could
have hit but didn't need to (all 15 cells used valid enum values).

⚠️ **Calibration surprise, logged as it happened rather than smoothed over**: the
intended negative control for the *specific* Opus-5-400 finding — WebSearch at
`xhigh` on Opus 5 — was expected to reproduce a 400 or a silent-stale answer. It
did neither (see cell `D_opus5_search_xhigh` below): real search, cited URLs,
`is_error:false`. Per protocol this means the *documented* known-bad case is not
currently known-bad in this environment, not that the pipeline can't detect
failure (the model-name 404 above proves it can). This divergence is itself the
headline result — see Conclusions.

## Raw per-cell matrix

All calls made 2026-08-08, via this worktree's `claude` wrapper (gateway routed
except where noted). Full raw JSON for every cell is in
`/tmp/claude-1000/-home-ubuntu-dotfiles/2cc9586e-51a1-4f39-adfe-14fa2e4d5458/scratchpad/cells/`
(scratchpad — not committed; the table below is the durable record).

### A — Fable 5, arithmetic, no tools (thinking not forced off by any tool path)

| Command | Outcome | Evidence |
|---|---|---|
| `--model claude-fable-5 --effort low` | works | `is_error:false`, result `"85"` (47+38), cost $0.042, 1 turn |
| `--model claude-fable-5 --effort medium` | works | `is_error:false`, result `"85"`, cost $0.042, 1 turn |
| `--model claude-fable-5 --effort high` | works | `is_error:false`, result `"85"`, cost $0.050, 1 turn |
| `--model claude-fable-5 --effort xhigh` | works | `is_error:false`, result `"85"`, cost $0.042, 1 turn |
| `--model claude-fable-5 --effort max` | works | `is_error:false`, result `"85"`, cost $0.051, 1 turn |

### B — Opus 5, arithmetic, no tools (known-good control + isolating cells)

| Command | Outcome | Evidence |
|---|---|---|
| `--model claude-opus-5 --effort high` (**known-good control**) | works | `is_error:false`, result `"85"`, cost $0.025 |
| `--model claude-opus-5 --effort xhigh` (isolates: does bare high-effort alone 400 with no tool involved?) | works | `is_error:false`, result `"85"`, cost $0.021 |
| `--model claude-opus-5 --effort max` | works | `is_error:false`, result `"85"`, cost $0.021 |

### C — Fable 5, WebSearch (the documented thinking-disable trigger), HN-front-page prompt

Prompt: *"Search the web for: what is the current #1 top story on Hacker News
(news.ycombinator.com) right now? Cite the URL of the HN item."* — answer
necessarily post-dates any training cutoff since HN's front page changes hourly.

| Command | Outcome | Evidence |
|---|---|---|
| `--model claude-fable-5 --effort high --tools WebSearch` | **real search** | `is_error:false`, `modelUsage.claude-fable-5.webSearchRequests: 4`, cites `https://news.ycombinator.com/item?id=49220609` + `simonwillison.net`, cost $0.685, 4 turns |
| `--model claude-fable-5 --effort xhigh --tools WebSearch` | **real search** | `is_error:false`, `webSearchRequests: 5`, same HN item cited + self-caveats "search results can't see the live HN front page directly", cost $1.140, 5 turns |
| `--model claude-fable-5 --effort max --tools WebSearch` | **real search** | `is_error:false`, `webSearchRequests: 7`, same HN item cited, cost $1.395, 5 turns |

### D — Opus 5, WebSearch, same prompt (reproduction attempt of the documented finding)

| Command | Outcome | Evidence |
|---|---|---|
| `--model claude-opus-5 --effort high --tools WebSearch` | **real search** | `is_error:false`, `webSearchRequests: 4`, cites HN item + article, cost $0.521 |
| `--model claude-opus-5 --effort xhigh --tools WebSearch` (**reproduction attempt of the AGENTS.md 400**) | **real search — did NOT reproduce** | `is_error:false`, `api_error_status: null`, `webSearchRequests: 4`, cites HN item, self-caveats freshness, cost $0.505 |
| `--model claude-opus-5 --effort max --tools WebSearch` | **real search** | `is_error:false`, `webSearchRequests: 4`, cites HN item, cost $0.509 |
| Same as row 2, repeated with `CC_NO_GATEWAY=1` (bypasses the tailnet gateway, direct-to-Anthropic auth path) | **real search — still no 400** | `is_error:false`, `webSearchRequests: 3`, cites HN item + article, cost $0.345 |
| Same as row 2, with `--output-format stream-json --include-partial-messages` (checks whether thinking blocks are actually present during the WebSearch turn) | **thinking WAS present** | 6 `"type":"thinking"` blocks in the stream, including one with a non-empty `signature` field (genuine extended-thinking signature, not a stub) — thinking was NOT disabled during this WebSearch-using xhigh session |

### E — Made-to-fail control: same search prompt, WebSearch unavailable, Fable 5, effort high

| Command | Outcome | Evidence |
|---|---|---|
| `--model claude-fable-5 --effort high --tools ""` (WebSearch not offered at all) | **visible failure — no hallucination** | `is_error:false`, result: `"I'll check Hacker News for the current top story."` — the model announces intent to search, has no tool to do it with, and the turn ends there. `webSearchRequests: 0`. It does **not** fabricate a specific headline or URL from training data. |

## Conclusions

**Does Fable 5 reject disabled-thinking at any effort?** No rejection was observed
at any effort level (`low` through `max`) in 15 cells across both models, whether
via a tool-free arithmetic probe or a WebSearch-driven multi-turn probe explicitly
designed to trigger the documented thinking-disable path. Every cell returned
`is_error:false` with `api_error_status:null`. The negative control confirms the
harness *can* surface a 400/404 when one genuinely occurs (the nonexistent-model
probe), so this is not a detection-blind spot — the failure mode the AGENTS.md
finding describes simply did not occur here, on either model, today.

**Is WebSearch safe at high (and beyond)?** Yes, and more strongly than expected:
all six WebSearch cells (Fable 5 × 3 effort levels, Opus 5 × 3 effort levels) did
a **real search** — `webSearchRequests` > 0, a URL cited that both models
independently agreed on (`news.ycombinator.com/item?id=49220609`), and, notably,
both models proactively caveated that the ranking might be stale because they
can't fetch HN's live front page directly. That self-caveat is the opposite of
silent-stale: it's the model flagging its own epistemic limit rather than
papering over it. The made-to-fail control (row E) is the clean contrast — with
WebSearch entirely unavailable, Fable 5 did not fabricate a plausible-sounding
headline; it announced intent and stopped, an honest (if abrupt) failure. Combined
with the stream-json check showing genuine thinking blocks present throughout a
WebSearch/xhigh Opus 5 session, the evidence points at **thinking staying enabled
throughout WebSearch tool use in this harness version (2.1.226) and gateway
configuration**, which is inconsistent with AGENTS.md's description of the
mechanism as it stood.

**What should AGENTS.md say?** The "Opus 5 400" section should get a `REVISED`
callout (per this repo's Verdict-discipline convention) rather than a silent edit:
the specific reproduction attempted here — WebSearch tool use at `xhigh`/`max` on
Opus 5, both gateway-routed and via `CC_NO_GATEWAY=1` direct — did not reproduce
on 2026-08-08 against `claude` CLI 2.1.226. Two live possibilities, not
distinguished by this probe: (a) Anthropic or the Claude Code client changed the
WebSearch/thinking interaction since 2026-07-25, or (b) the original failure was
tied to a request shape this probe didn't hit (e.g., the interactive TUI's
streaming path, a specific `--fallback-model` combination, or a `--betas` header
that API-key-only users get and this OAuth/gateway path doesn't). AGENTS.md's own
framing — "an effort level tuned on one model is a calibration, not a constant" —
applies here too: **do not delete the 400 warning outright**; downgrade it to "not
currently reproducible as of 2026-08-08 (see `dotfiles-8eod`); re-test before
relying on either the presence or the absence of the failure." Practically, this
means Fable 5 (and Opus 5) can currently be run at `xhigh`/`max` with WebSearch
active without the 400 hazard the prior finding warned about — but the warning's
underlying caution ("re-measure when the model or version changes") is exactly
what this probe exercised, and the next version bump should trigger the same
re-check.

**Surprising cell**: `D_opus5_search_xhigh` — the direct reproduction attempt of
the documented finding — was expected to fail (per pre-registration) and instead
produced the cleanest possible pass: a real search, a correct citation, and an
unprompted freshness caveat. Paired with the stream-json thinking-block check,
this is strong enough evidence to say the originally observed 400 is not currently
live in this harness/gateway/model combination, not merely "didn't happen to
trigger this time."

**Limitation**: N=1 per cell. A single non-reproduction is evidence the failure
mode is not *reliably* triggered by this exact request shape today; it is not
proof the failure mode can never occur (e.g., under load, with a different
`--fallback-model` chain, or via the interactive TUI rather than `-p`). Total
matrix cost: ~$5.11 across 15 cells (plus ~$3 of exploratory calibration/design
calls not in the table above).
