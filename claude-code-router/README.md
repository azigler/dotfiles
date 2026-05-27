# claude-code-router (CCR) — pico-routed local-models proxy

CCR is the Anthropic-Messages-to-OpenAI-Chat translator that lets Claude Code
(which only speaks Anthropic Messages) hit local OpenAI-compat backends on
`pico` (Mac Studio M1 Max, 64 GB) without losing tool-use, parallel calls, or
nested schema fidelity. Main interactive sessions still hit Anthropic; only
specific tiers (`background`, `longContext`) route local.

**This README is the "what's deployed snapshot"** — the production posture as
it actually landed in dotfiles, with the GUARDRAILS, op commands, and known
limitations the next operator needs. For the spec (test cases, OQs, rationale
walks), read bead `dotfiles-ukx.6` directly. For the cross-arc invariants this
config depends on, read `../local-models/GUARDRAILS.md`.

**Last verified:** 2026-05-27 — Wave 16 amendments:
- ukx.12 (Wave 15) — `transformer: { use: ["Anthropic"] }` block REMOVED
  from pico-* providers (was causing 404 with `'dict object' has no
  attribute 'parameters'` — see Section 8 "Wave 15 transformer reversal")
- ukx.11 (Wave 16) — Devstral lmstudio-community quant swap landed but
  PARTIAL: Devstral tool tier remains BLOCKED for compound reasons (G18).
  Devstral prose tier still VIABLE.

---

## 1. What's deployed where

### On zig (Ubuntu orchestrator)

| Component | State | Notes |
|---|---|---|
| `@musistudio/claude-code-router` v2.0.0 | npm-installed globally | `npm install -g @musistudio/claude-code-router` |
| CCR daemon | listens on `127.0.0.1:3456` | localhost-only; not exposed on tailnet |
| Config | `~/.claude-code-router/config.json` | symlinked from `./config.json` in this dir |
| Log | `~/.claude-code-router/claude-code-router.log` | `LOG: true, LOG_LEVEL: info` in config |
| Control | `ccr start / stop / restart / status / code` | npm-shipped CLI |

CCR is **not** wrapped in a systemd unit — it runs as a user-foreground process
started ad-hoc via `ccr start`. The original spec (`dotfiles-ukx.6` §3.1)
called for a systemd unit; v1 ships without it because solo-user usage doesn't
need 24/7 daemon discipline. Revisit when a scheduled / headless consumer
(e.g., the `explore-nfc` research agent or `blightmud-hgi` MUD agent) actually
needs CCR up at boot.

### On pico (Mac Studio M1 Max 64 GB)

| Component | Bind | LaunchAgent | Notes |
|---|---|---|---|
| `mlx_lm.server` | `100.72.47.4:8081` | `com.zig.mlx.plist` (see `../mlx/`) | Lazy-load mode (no `--model` flag); **tool use is broken on this port** — see G16 + ukx.10 |
| Ollama | `100.72.47.4:11434` | `com.zig.ollama.plist` (see `../ollama/`) | `OLLAMA_KEEP_ALIVE=24h`, `NUM_PARALLEL=1` (commit `9eb2f0c`) |
| llama-swap | `100.72.47.4:8090` | manual launch today; future plist | Spawns per-model `mlx_lm.server --model X` instances on disjoint ports (5802 etc.) |
| llama-swap model registry | 4 models | qwen3-coder, trinity-mini, devstral, deepseek-coder-v2-lite-mlx | aliases map to full HuggingFace paths in llama-swap config |

The llama-swap layer is **load-bearing** for tool-using subagents — G16
documents the empirical receipt. Direct `mlx_lm.server` (lazy-load) silently
REFUSES tool calls; llama-swap's `--model`-preloaded child instances PASS.
ukx.10 tracks the suspected upstream chat-template bug.

---

## 2. Routing rules (the `Router` block)

From `config.json`:

```jsonc
"Router": {
  "default":              "anthropic,claude-opus-4-7",
  "background":           "pico-mlx,qwen3-coder",
  "longContext":          "pico-ollama,laguna-xs.2:latest",
  "longContextThreshold": 50000
}
```

| Scenario | Provider, model | Why |
|---|---|---|
| `default` | `anthropic,claude-opus-4-7` | Main session needs frontier intelligence; the orchestrator runs here. Cost is acceptable for orchestration turns. |
| `background` | `pico-mlx,qwen3-coder` (via llama-swap :8090) | Tool-using subagent dispatches. Only PASS path per G16 — `:8090` is the llama-swap front that spawns an eagerly-loaded `mlx_lm.server` per model, so tool envelopes work. |
| `longContext` (>50K tokens) | `pico-ollama,laguna-xs.2:latest` | Laguna XS.2 is the only model passing the 100K bench (AB-verdict v2 §TL;DR). Laguna MLX requires the Blaizzy fork (G7) which is not yet system-wide on pico. |

**Router keys deliberately omitted:** `subagent`, `think`, `webSearch`.

- `subagent`: not in CCR's documented Router surface (confirmed via source
  read in `dotfiles-ukx.6` /check OQ1 + scrutinize A1). Per-dispatch routing
  uses CCR's in-prompt `<CCR-SUBAGENT-MODEL>` tag — see GUARDRAILS G12.
- `think`: extended-thinking detection unverified; deferred.
- `webSearch`: out of scope.

The Providers block is **the canonical model registry for CCR-routed calls** —
edit `./config.json` (symlinked), then `ccr restart`.

---

## 3. Environment variables

| Var | Value | Where set | Purpose |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | secret (1Password / `.envrc`) | per-shell | Anthropic provider's `api_key` field expands `$ANTHROPIC_API_KEY` at CCR start time |
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:3456` | set by `eval "$(ccr activate)"` or by `ccr code` wrapper | Points Claude Code at CCR instead of the real Anthropic endpoint |
| `ANTHROPIC_AUTH_TOKEN` | `ccr` | set by `ccr activate` alongside BASE_URL | CCR accepts any token on the local endpoint; this satisfies Claude Code's auth check |

**Important:** do **NOT** put `ANTHROPIC_BASE_URL` in `~/.claude/settings.json`
globally — that would force every main-session turn through CCR, including
ones that should hit Anthropic directly. Set it per-invocation via
`ccr activate` (current shell + children) or use `ccr code` (which wraps a
single `claude` run).

`CLAUDE_CODE_SUBAGENT_MODEL` is **NOT** the routing mechanism — that env var
is upstream-broken end-to-end (G12; anthropics/claude-code#43869). Local
routing happens via Router rules + the `<CCR-SUBAGENT-MODEL>` in-prompt tag.

---

## 4. Per-tier rationale (G16 routing matrix)

This table mirrors `dotfiles-ukx.6` §4.1's verdict matrix; the spec has the
full derivation. Summary form here for operator quick-reference:

| Tier | Provider+model | Why this path |
|---|---|---|
| `default` | `anthropic, claude-opus-4-7` | Main session; frontier intelligence; cost acceptable |
| `background` | `pico-mlx, qwen3-coder` via llama-swap :8090 | Tool-using subagent dispatches; **only** PASS path per G16 (3/3 deterministic trials) |
| `longContext` (>50K tok) | `pico-ollama, laguna-xs.2:latest` | Only model passing 100K bench (AB-verdict v2); Ollama backend (Laguna MLX needs Blaizzy fork — G7) |
| Trinity tier (available, not routed) | `pico-mlx, trinity-mini` via llama-swap :8090 + `trinity_shim.py` + `max_tokens ≥ 2000` | Reasoning-heavy work; emits parallel `<tool_call>` XML in `content`; shim parses Hermes XML into `tool_calls[]` |
| Devstral tier (available, not routed) | `pico-ollama, devstral:24b` — non-tool work only | Devstral MLX template is tool-blind; Ollama devstral also broken for tools (Wave 14); usable for prose / completion |
| DeepSeek-V2-Lite tier (Ollama only) | `pico-ollama, deepseek-coder-v2:16b-lite-instruct-q4_K_M` | Ties Qwen3 + Devstral at 17/20 (AB-verdict v2); MLX path BLOCKED per G15 (MoE arch unsupported) |

**G13 prose-collapse caveat (still active):** Qwen3 MLX mode-collapses on long
prose generation (~5000+ tokens output) unless the request body includes
`repetition_penalty: 1.10, repetition_context_size: 64`. CCR does not inject
these — see GUARDRAILS G13. For background subagent **tool work** this doesn't
bite (short outputs, structured calls). For any subagent that generates long
prose, route that one explicitly via Ollama Qwen3 instead.

---

## 5. Operational commands

### Restart after editing config.json

```bash
# edit ./config.json (symlinked to ~/.claude-code-router/config.json)
ccr restart
ccr status      # confirm new PID, daemon listening on :3456
```

### Smoke-test routing

```bash
# Anthropic Messages shape (CCR's native input) → pico-mlx via llama-swap
curl -sS -X POST http://127.0.0.1:3456/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{
    "model": "pico-mlx,qwen3-coder",
    "max_tokens": 30,
    "messages": [{"role":"user","content":"Reply with PONG only."}]
  }'
# → {"content":[{"type":"text","text":"PONG"}], ...}
```

If you get `Provider 'undefined' not found`, you used `/v1/chat/completions`
not `/v1/messages`. CCR translates Anthropic shape only — it does not pass
through raw OpenAI requests.

For end-to-end tool-use verification, see the curl recipe in
`~/explore/local-coding-models/refs/research/research-ccr-tool-schema-followup.md`
Section 5 (the recipe `dotfiles-ukx.9` used to validate llama-swap PASS / MLX
direct REFUSED / Ollama DEGRADED).

### Read logs

```bash
tail -f ~/.claude-code-router/claude-code-router.log
# Per-route timing, provider selected, and request/response payloads
# at LOG_LEVEL=info. Bump to debug if you need wire-level detail.
```

### Inspect provider registration

```bash
curl -sS http://127.0.0.1:3456/v1/providers   # CCR's provider list
```

### Activate in current shell (for headless / subagent dispatches)

```bash
eval "$(ccr activate)"
# Sets ANTHROPIC_BASE_URL=http://127.0.0.1:3456 + ANTHROPIC_AUTH_TOKEN=ccr
# in current shell + all child processes (including any Claude Code
# subagent dispatches launched from this shell).
```

---

## 6. GUARDRAILS that apply

Full text in `../local-models/GUARDRAILS.md`. One-line summaries here so the
operator knows which invariants touch CCR / local routing:

| ID | One-liner |
|---|---|
| **G1**  | Trinity tool-use needs server-side Hermes parser — model IS capable; mlx_lm.server lacks the parser registration. Use `trinity_shim.py` (client-side regex) or vLLM with `--tool-call-parser hermes`. |
| **G7**  | Laguna MLX is unblocked via the Blaizzy `pc/add-lg` fork (fork-pinned venv only); system-wide mlx-lm still unsupported. Production routes Laguna via Ollama. |
| **G8**  | Model IDs must match the on-disk tag exactly. `qwen3-coder` (llama-swap alias) ≠ `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (full HF path). Verify via `/v1/models` before committing. |
| **G9**  | `mlx_lm.server` tool-use is model-dependent — Qwen3-Coder returns structured `tool_calls[]` (parallel verified), Trinity jams into `content`. Cubist38 fork NOT required for in-scope workloads. |
| **G12** | Subagent routing uses CCR's in-prompt `<CCR-SUBAGENT-MODEL>` tag (in `body.system[1].text`). The env-var path `CLAUDE_CODE_SUBAGENT_MODEL` is upstream-broken end-to-end. |
| **G13** | `mlx_lm.server` repetition collapse on long prose is FIXED — include `repetition_penalty: 1.10, repetition_context_size: 64` in request body. CCR does not auto-inject; callers must include it for prose tasks. |
| **G14** | `mlx_lm.server` has no model-unload endpoint — RSS grows monotonically across model swaps. Use llama-swap (already deployed) or PR #1274's `--idle-timeout`. |
| **G15** | DeepSeek-Coder-V2-Lite MLX is BLOCKED (MoE arch unsupported in mlx-lm 0.31.3). Route via Ollama (`deepseek-coder-v2:16b-lite-instruct-q4_K_M`). |
| **G16** | Tool-using subagents MUST route via llama-swap (`:8090`), NOT direct `mlx_lm.server` (`:8081`). Empirical: llama-swap PASS 3/3, MLX direct REFUSED 0/3, Ollama DEGRADED (drops 2nd parallel call). |
| **G17** | `claude -p` cannot reach CCR's per-request `<CCR-SUBAGENT-MODEL>` tag — CC hardcodes system[0/1]; the tag parser checks system[1] and `--append-system-prompt` lands at system[2]. Workaround: scripted CCR routing uses direct curl to `/v1/messages`. |
| **G18** | `mlx_lm.server` v0.31.3 response parser doesn't handle Mistral `[TOOL_CALLS]/[ARGS]` envelope — silently drops bytes. Affects Devstral / Mistral-Small / Codestral. Workaround: route those via Ollama, or build a shim (pattern: `local-models/trinity_shim.py`). Devstral tool tier stays BLOCKED until a parser lands. |

The **G16 + G12 + G8** triad is what makes the current config work. Break any
of them (repoint pico-mlx back to :8081, set CLAUDE_CODE_SUBAGENT_MODEL,
collapse a model ID to a shorthand) and the next subagent dispatch silently
regresses. **G18 + G17** add: don't try to enable Devstral for tool routing
without a Mistral-envelope shim, and don't try to reach CCR's tag from
`claude -p`.

---

## 7. Cross-references

### Beads (run `br show <id>` for full context)

- `dotfiles-ukx`     — parent epic (claude-code: wire to local models on pico)
- `dotfiles-ukx.6`   — spec (read this for the "why" + test cases + OQ walks)
- `dotfiles-ukx.8`   — research: CCR Anthropic transformer source audit (PASS at source-read; **REVERSED empirically in Wave 15** — see ukx.12 for what actually happened)
- `dotfiles-ukx.9`   — empirical per-backend tool-call probe (MLX REFUSED, Ollama DEGRADED, llama-swap PASS)
- `dotfiles-ukx.10`  — bug: suspected mlx_lm.server lazy-load chat-template gap (DEFERRED — needs more isolation; G16 amendment narrowed the mechanism)
- `dotfiles-ukx.11`  — task: swap llama-swap devstral entry to lmstudio-community quant (Wave 16 outcome: **PARTIAL** — quant landed but tool tier still BLOCKED per G18)
- `dotfiles-ukx.12`  — bug: REMOVED `transformer` block from pico-* providers (Wave 15; CCR was Anthropic↔OpenAI inverting; verified-fixed)
- `dotfiles-ukx.13`  — spec: Phase 3 full parity benchmark (N trials × 10 scenarios × 8 candidates incl Kimi-Linear)
- `dotfiles-cl8`     — bug (DEFERRED): mlx_lm.server response parser missing Mistral `[TOOL_CALLS]/[ARGS]` envelope support

### Refs (file paths)

- `../local-models/GUARDRAILS.md` — full invariant text (cross-arc; A/B/C/D all inherit)
- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — model selection rationale (bench data)
- `~/explore/local-coding-models/refs/research/research-ccr-tool-schema.md` — CCR transformer source audit (ukx.8)
- `~/explore/local-coding-models/refs/research/research-ccr-tool-schema-followup.md` — per-backend tool-call probe (ukx.9)
- `~/explore/local-coding-models/refs/research/research-ccr-subagent-routing.md` — `<CCR-SUBAGENT-MODEL>` mechanism (G12 source)
- `~/explore/local-coding-models/refs/research/research-llama-swap-toolshim.md` — llama-swap does ZERO tool-call transformation (debunks early hypothesis; root cause is `--model` flag)
- `~/explore/local-coding-models/refs/research/research-mlx-repetition.md` — G13 repetition_penalty finding
- `~/explore/local-coding-models/refs/research/research-trinity-toolcalls.md` — G1 Trinity-as-Arcee finding
- `~/explore/local-coding-models/refs/research/research-laguna-mlx.md` — G7 Blaizzy fork workaround
- `~/explore/local-coding-models/refs/research/research-mlx-unload.md` — G14 llama-swap recommendation
- `~/explore/local-coding-models/refs/research/research-devstral-toolaware-quant.md` — Wave 14 Devstral unblock path

### Sibling READMEs (stylistic precedent)

- `../mlx/README.md` — `mlx_lm.server` LaunchAgent + ops
- `../ollama/README.md` — Ollama LaunchAgent + bind discipline

---

## 8. Known limitations + workarounds

### Devstral MLX/Ollama is tool-mute in installed quants (3-layer breakdown per Wave 16)

- `mlx-community/Devstral-Small-2507-5bit` and `-4bit-DWQ` ship a 44-line
  tool-blind chat template — model narrates plans in text, never emits
  `tool_calls[]`. Ollama `devstral:24b` is also broken (Wave 14 probe:
  `finish_reason=stop`, 196 tokens, no tool_calls).
- **Wave 16 unblock attempt (`dotfiles-ukx.11`): PARTIAL.** Swapped to
  `lmstudio-community/Devstral-Small-2507-MLX-4bit` (13.3 GB, 68-line
  tool-aware Mistral envelope). Empirical 3-layer probe showed:
  1. **Chat template (Layer 1)**: ✓ tool-aware
  2. **Model decode (Layer 2)**: DEGRADED — only 1 of 2 requested tool_calls
     emitted, hallucinated LSP-style `{text, range}` schema instead of the
     `{old_string, new_string}` requested; tokenizer regex warning
  3. **mlx_lm.server response parser (Layer 3)**: BROKEN — server eats
     Mistral `[TOOL_CALLS]/[ARGS]` envelope silently (G18). Returns empty
     `message: {"role": "assistant"}` with no `content`/`tool_calls`.
- **Workaround:** route Devstral only for non-tool work (prose, completion).
  Tool-using dispatches go to Qwen3-Coder via llama-swap (G16 canonical).
- **Mitigation paths (not implemented):**
  - Upstream fix to `mlx_lm.server` (see deferred `dotfiles-cl8`)
  - Local shim mirroring `trinity_shim.py` for Mistral envelope
  - Or just don't bother (Qwen3-Coder is the canonical tool tier)
- See `~/explore/local-coding-models/refs/research/research-devstral-mlx-server-parser-gap.md` (73 lines, full raw-probe outputs).

### Wave 15 transformer reversal (don't add `transformer: ["Anthropic"]` back)

`dotfiles-ukx.8` source-read research recommended adding `transformer: { use:
["Anthropic"] }` to pico-* providers in `config.json`. **Wave 15 empirical
work (`dotfiles-ukx.12`) reversed this:**

- With the transformer block, CCR converts Unified → Anthropic outgoing
  (because the block tells CCR "this backend speaks Anthropic")
- mlx_lm.server got Anthropic-shape body with `input_schema` instead of
  `parameters` — Qwen3's chat template choked, returning 404 with
  `'dict object' has no attribute 'parameters'`
- **Fix:** REMOVE the transformer block. CCR's default
  `convertAnthropicToolsToUnified` correctly produces the OpenAI-compat
  `{type:function, function:{name, description, parameters}}` shape

The current `config.json` (this dir) does NOT have a transformer block on
pico-mlx or pico-ollama providers. Keep it that way.

### Trinity needs the shim + `max_tokens ≥ 2000`

- Trinity-Mini emits Hermes-style `<tool_call>{...}</tool_call>` XML inside
  `message.content`, not as structured `message.tool_calls[]` (G1). At
  `max_tokens < 2000` the response truncates mid-XML.
- **Workaround:** route via llama-swap :8090, set `max_tokens ≥ 2000`, and
  apply `~/dotfiles/local-models/trinity_shim.py` to parse XML into the
  `tool_calls[]` shape before passing to downstream code.
- Trinity is **not** currently in any Router scenario. Available as an opt-in
  via explicit `--model pico-mlx,trinity-mini` override.

### Ollama parallel-tool is DEGRADED

- Ollama silently drops the 2nd parallel `tool_call` when the model emits
  multiple in one turn (G16 / ukx.9). Pre-Wave 13 the assumption was Ollama
  was the "safer" path; empirically llama-swap is the only PASS.
- **Workaround:** none for parallel tools on Ollama — route those dispatches
  via llama-swap. Sequential tool use (one per assistant turn) works on
  Ollama for cases that can't use llama-swap.

### `mlx_lm.server` lazy-load chat-template bug (suspected; ukx.10)

- When started without a `--model` flag (the launchd config on pico does
  this), `mlx_lm.server` appears to NOT apply `chat_template.jinja` correctly
  for tool-use requests — model REFUSES with "I cannot execute multiple
  commands in parallel." Same weights via llama-swap (which starts each MLX
  child with `--model X`) work fine.
- **Workaround:** route tool-using calls via llama-swap :8090 (G16). Do not
  use `:8081` direct for tool work. Direct `:8081` is still fine for
  non-tool prose / PONG / completion calls.
- **Status:** ukx.10 is DEFERRED — needs more isolation (toggle `--model`
  on/off, confirm template path divergence in source) before filing upstream.

### Secondary: `mlx_lm.server` v0.31.3 newline-escaping bug

- The server emits `content` strings with literal `\n` characters instead of
  escaped `\\n`, breaking strict JSON parsing. CCR and llama-swap re-encode
  and don't suffer; raw `curl` callers must use `strict=False` JSON parsing
  or pre-filter.

### No automatic failover

- If pico is down (network, plist crash, OOM), CCR returns the upstream error
  to Claude Code; the call hard-fails. By design — see `dotfiles-ukx.6` §3.6
  + /check OQ4. Silent failover would hide cost regressions.
- **Workaround for the user:** re-invoke with an explicit Anthropic model
  (`--model claude-sonnet-4-6` or similar) to escape the local route.

### CCR has no per-provider sampler-defaults transformer

- There's no built-in CCR transformer that injects `repetition_penalty`,
  `top_p`, etc. on a per-provider basis (researched 2026-05-25).
- **Workaround:** callers that need the Qwen sampler shape must include it
  in the request body. For Python callers, use
  `~/dotfiles/local-models/qwen_sampler.py`. For Claude Code subagent
  dispatches (which send Anthropic Messages, no `repetition_penalty` in
  schema), prose tasks are at risk of G13 mode-collapse — route long-prose
  dispatches via Ollama Qwen3 instead.

---

**Operator quick-check before depending on this:** run
`~/dotfiles/local-models/healthcheck.sh` (per GUARDRAILS H1). If it exits
non-zero, CCR's local routes will fail before you've even dispatched.
