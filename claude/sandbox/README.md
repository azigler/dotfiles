# claude/sandbox — local-model parity smoke test

A test harness that runs the same Claude-Code-shaped scenarios through
**Anthropic Opus** (the orchestrator-tier baseline) and through **a local
model on pico** (Qwen3-Coder-30B via CCR + llama-swap, per GUARDRAILS G16),
so we can empirically answer the question:

> Does a local model actually work as a usable Claude Code subagent for real
> coding tasks?

This is the parity benchmark behind bead `dotfiles-ukx.3`. The nominated
local model is `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` via
llama-swap on pico (see `~/explore/local-coding-models/refs/AB-verdict-v2.md`
for the model-selection rationale).

---

## Layout

```
claude/sandbox/
├── README.md              (you are here)
├── claude-local           bash wrapper: claude + CCR routing tag
├── run-scenario.sh        runner: parses a scenario, invokes claude, writes result
├── scenarios/             10 scenarios, 5-section schema (Setup/Prompt/Pass/Cleanup/Notes)
│   ├── 01-trivial-rename.md
│   ├── 02-easy-add-function.md
│   ├── 03-medium-refactor.md
│   ├── 04-hard-bugfix.md
│   ├── 05-toolstressy-parallel.md
│   ├── 06-multiturn-clarify.md
│   ├── 07-bead-dispatch.md
│   ├── 08-longcontext.md
│   ├── 09-selfcorrect.md
│   └── 10-honest-failure.md
└── results/               per-run captures: <scenario>-<model>-<timestamp>.md
```

---

## Install

The sandbox is committed to dotfiles so it travels with the repo. For
day-to-day work, symlink it into the canonical playground path from the
bead:

```bash
# Optional: surface it at the bead-referenced path
ln -sf "$HOME/dotfiles/claude/sandbox" "$HOME/sandbox/claude-local-test"
```

To put the wrapper on `$PATH` so you can `claude-local -p "..."` from
anywhere:

```bash
# Either symlink into a $PATH dir:
ln -sf "$HOME/dotfiles/claude/sandbox/claude-local" "$HOME/.local/bin/claude-local"

# OR alias it in ~/.zshrc:
echo 'alias claude-local="$HOME/dotfiles/claude/sandbox/claude-local"' >> ~/.zshrc
```

**Prerequisites:**
- `claude` CLI installed and authenticated (`claude --version` should work)
- `ccr` (Claude Code Router) installed and running (`ccr status` shows
  Running on port 3456) — see `~/dotfiles/claude-code-router/README.md`
- llama-swap up on pico at `100.72.47.4:8090` serving qwen3-coder — see
  `~/dotfiles/local-models/GUARDRAILS.md` G16 + healthcheck
- For full smoke runs: run `~/dotfiles/local-models/healthcheck.sh` first
  (per GUARDRAILS H1)

---

## Usage

### Smoke-test the wrapper directly

```bash
claude-local -p "Reply with PONG only."
# → PONG (routed via CCR → llama-swap → Qwen3-Coder)
```

To prove routing actually went local: tail the CCR log while the request
runs:

```bash
tail -f ~/.claude-code-router/claude-code-router.log &
claude-local -p "Reply with PONG only."
# Look for log line referencing pico-mlx,qwen3-coder
```

### Run a single scenario

```bash
cd ~/dotfiles/claude/sandbox
./run-scenario.sh scenarios/01-trivial-rename.md opus
./run-scenario.sh scenarios/01-trivial-rename.md local
```

Each run:
1. Executes the scenario's `## Setup` block (mkdir, write fixture files)
2. Invokes `claude -p` (opus) or `./claude-local -p` (local) with the
   `## Prompt` text piped to stdin
3. Captures stdout + stderr + wall time + exit code + routing evidence
4. Executes `## Cleanup` to reset state
5. Writes a markdown report to `results/<scenario>-<model>-<timestamp>.md`

### Run all 3 smoke scenarios through both backends

```bash
cd ~/dotfiles/claude/sandbox
for s in scenarios/01-*.md scenarios/02-*.md scenarios/05-*.md; do
  ./run-scenario.sh "$s" opus
  ./run-scenario.sh "$s" local
done
```

(Full 10-scenario sweep is intentionally out of scope for ukx.3; it's a
follow-up impl bead.)

---

## Scenario catalog

| # | Scenario | What it tests | Notable failure modes |
|---|---|---|---|
| **01** | trivial-rename | Single Edit on one file | Model "improves" beyond scope |
| **02** | easy-add-function | Write + Edit + Bash composition | Skips the test, uses unittest |
| **03** | medium-refactor | Extract method, byte-identical behavior | Breaks output formatting |
| **04** | hard-bugfix | Multi-file grep + trace + fix | Fixes the test, not the bug |
| **05** | toolstressy-parallel | Parallel Edit + Bash emission (G16 stress) | Serializes; local refuses if route wrong |
| **06** | multiturn-clarify | Honest underspec handling | Guesses instead of asking |
| **07** | bead-dispatch | Bead-format discipline + simulated sub-agent | Skips bead or skips implementation |
| **08** | longcontext | 30K-token preamble + focused change | Lost-in-context; prefill timeout |
| **09** | selfcorrect | Catch planted flaw, articulate why | Misses bug; "fixes" correct code |
| **10** | honest-failure | "I don't know" rate on fictional repo | Fabricates plausible answer |

Each scenario file follows the 5-section schema:

```markdown
# Scenario NN — <title>
## Setup       — bash to prep state (idempotent)
## Prompt      — verbatim prompt to feed claude
## Pass criteria — pass/fail predicates to evaluate against final state + output
## Cleanup     — bash to reset state
## Notes       — gotchas, expectations, what we're testing
```

Pass criteria are deliberately predicates a HUMAN evaluator can run with
`grep` / `python -m pytest` / shell `[[ ... ]]` — not auto-evaluated yet.
A future iteration will add an evaluator that runs the criteria against
each result file and emits a parity matrix.

---

## How routing works (wrapper internals)

`./claude-local` is a thin shim that uses TWO complementary routing layers:

**Layer A — model-tier trigger (PRIMARY).** CCR's Router config maps
`background` tier requests to `pico-mlx,qwen3-coder`. When Claude Code
sends a request with `model=claude-haiku-4-5` (the haiku "small/cheap"
tier), CCR maps it via `Router.background` and routes via llama-swap.
We achieve this by passing `--model claude-haiku-4-5` to the claude CLI.
This is the layer that actually fires today (confirmed via CCR log:
`Using background model for claude-haiku-4-5`).

**Layer B — explicit in-prompt tag (BACKUP per GUARDRAILS G12).** We also
inject `<CCR-SUBAGENT-MODEL>pico-mlx,qwen3-coder</CCR-SUBAGENT-MODEL>`
via `--append-system-prompt`. CCR's handler scans `body.system[].text`
for this tag and overrides routing when found. On the current Claude
Code CLI (v2.1.150), `--append-system-prompt` lands the tag at
`system[2]` (because Claude Code reserves `system[0]`=billing-header
and `system[1]`=canonical-claude-prompt). CCR's published scan logic
per G12 reads `system[1]` strictly, so this layer may not fire on every
CCR release — but it's harmless when ignored and load-bearing if CCR
ever broadens the scan.

The shim:
1. Sets `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` (CCR endpoint)
2. Sets `ANTHROPIC_AUTH_TOKEN=ccr` (CCR doesn't enforce real auth on
   localhost)
3. Invokes `claude --model claude-haiku-4-5 --append-system-prompt
   "<CCR-SUBAGENT-MODEL>pico-mlx,qwen3-coder</CCR-SUBAGENT-MODEL>" "$@"`
4. All other args pass through to `claude` unchanged

Override either layer via env var:

```bash
CCR_ROUTE="pico-ollama,laguna-xs.2:latest" claude-local -p "..."   # Layer B target
CCR_MODEL_TIER="claude-haiku-4-5" claude-local -p "..."             # Layer A trigger
ANTHROPIC_BASE_URL_LOCAL="http://other-ccr:3456" claude-local -p "..."
```

(See `~/dotfiles/claude-code-router/config.json` for the full
provider+model registry, and the Router block for tier mappings.)

---

## Verifying routing actually went local

`claude -p` strips API metadata from the output, so the model field is not
visible in stdout. Verification paths:

1. **CCR log** (best): `tail -f ~/.claude-code-router/claude-code-router.log`
   shows each routed request with provider+model on the chosen route
2. **llama-swap log on pico** (cross-check):
   `ssh pico 'tail -f ~/Library/Logs/llama-swap.log'` shows the spawned
   `mlx_lm.server --model X` child receiving the request
3. **Wall time** (sanity): local Qwen3-Coder is 35 tps vs Opus's ~80 tps
   first-token, plus 200ms tailnet RTT each turn — local runs are
   noticeably slower

The `run-scenario.sh` runner captures the most recent CCR log entries
referencing the routed model in each result file's "Model routing
evidence" section, so you can prove provenance after the fact.

---

## What's in scope for ukx.3 (this bead)

- Phase 1: sandbox + wrapper (this directory)
- Phase 2: 10-scenario catalog (the `scenarios/` directory)
- Phase 3 SMOKE: scenarios 01, 02, 05 through both backends → 6 result
  files in `results/`

## What's NOT in scope (follow-up impl beads)

- Phase 3 FULL: all 10 scenarios × both backends → 20 result files
- Phase 4: synthesis — parity matrix, fine-tune target hypotheses, fold
  into `refs/research/research-local-claude-code-parity.md`
- Auto-evaluator: a script that reads each result file and runs its
  scenario's "Pass criteria" against the captured state, emitting a
  pass/fail matrix
- CI integration: nothing here runs on push; it's a manual harness

---

## Phase 3 smoke-run results (2026-05-26)

Initial smoke runs for scenarios 01, 02, 05 through both backends landed
in `results/`. Top-line findings:

| Scenario | Opus | Local | Notes |
|---|---|---|---|
| 01 trivial-rename | PASS (12s, `DONE`) | FAIL — routing reaches pico-mlx but llama-swap 404s on tool schema | Routing PROVEN: CCR log shows `Using background model for claude-haiku-4-5` and request hits `pico-mlx,qwen3-coder` |
| 02 easy-add-function | PASS (28s, `DONE`) | Same failure as 01 | Same routing evidence |
| 05 toolstressy-parallel | PASS (18s, `DONE`) | Same failure as 01 | Same routing evidence |

**Local failure mode (consistent across all 3 scenarios):**
```
Error from provider(pico-mlx,qwen3-coder: 404): {"error": "'dict object' has no attribute 'parameters'"}
```

This is a tool-schema serialization issue at the llama-swap boundary —
the request reaches the right route (CCR's `background` tier → llama-swap
:8090 → Qwen3-Coder) but llama-swap can't deserialize Claude Code's tool
definitions. Per GUARDRAILS G16 the same llama-swap path PASSES a hand-
crafted `tools[]` curl request, so the issue is likely in CCR's
Anthropic→OpenAI transformer for the tools field shape that Claude Code
emits (probably differs from the simple raw-curl shape used in G16's
deterministic probe).

**This is the right kind of empirical finding for ukx.3 to surface.** The
harness is end-to-end: it proves routing works, then catches the
serialization issue with crystal-clear evidence. The fix is a follow-up
bead (likely `dotfiles-ukx.12` or new spec child) — either a CCR
transformer patch or a llama-swap config tweak. Phase 4 synthesis will
fold these results into a parity matrix + a tool-schema-shim
recommendation.

**What the smoke runs prove about the harness itself (the deliverable):**
- The wrapper routes correctly (Layer A confirmed via CCR log)
- The runner captures routing evidence, prompt, output, wall time, and
  sandbox state in a single self-contained markdown per run
- Result files are < 2 KB each — easy to diff, easy to grep, easy to
  fold into Phase 4 synthesis

---

## Cross-references

### Beads
- `dotfiles-ukx.3` — this bead (parity test suite)
- `dotfiles-ukx`   — parent epic (claude-code → local models)
- `dotfiles-ukx.4` — headless mode (sibling, in-flight)
- `dotfiles-ukx.5` — production-posture doc (sibling, merged)
- `dotfiles-ukx.6` — CCR routing spec (the "why")
- `dotfiles-ukx.9` — empirical per-backend tool-call probe (the G16 receipt)

### Refs
- `~/dotfiles/local-models/GUARDRAILS.md` — G12 (routing tag), G16 (llama-swap), H1 (healthcheck)
- `~/dotfiles/claude-code-router/README.md` — CCR production posture
- `~/dotfiles/claude-code-router/config.json` — Router rules + Providers
- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — model selection rationale
- `~/explore/local-coding-models/refs/research/research-ccr-subagent-routing.md` — G12 source receipt
- `~/explore/local-coding-models/refs/research/research-ccr-tool-schema-followup.md` — G16 source receipt
