# Local-models guardrails

Cross-arc invariants observed empirically. Violations cause silent failures or production regressions across all four current epics (A: CCR router, B: CoD MUD agent, C: LSRA research agent, D: autonovel pi.dev harness) plus future arcs.

Last updated: 2026-05-25 evening (post-research-agent sweep — many earlier findings REVISED).

---

## H1 — Run healthcheck at iter start (DO THIS FIRST)

`~/dotfiles/local-models/healthcheck.sh` — pre-flight probe across the whole stack. Detects:
- Pico tailnet reachability
- MLX server :8081 hung process (process alive but not serving — past failure mode that wasted 4+ hours of one iter)
- MLX RSS bloat (>30 GB = model accumulation; consider `launchctl kickstart -k gui/501/com.zig.mlx`)
- Ollama :11434 unresponsive
- llama-swap :8090 status (optional)
- CCR :3456 status (optional)
- **Functional completion roundtrip** — proves stack actually serves, not just handshakes
- Pico disk pressure

Exit codes: 0=healthy, 1=warnings, 2=critical (hung or unreachable; **do not start model work until fixed**).

**Run pattern:**
- At the start of every iteration when local-model work is on the agenda
- After any failed completion before retrying
- Before dispatching benchmarks or long-running experiments

**Recovery cheatsheet** (for the common failures):
| Symptom | Fix |
|---|---|
| MLX server unresponsive | `ssh pico 'launchctl kickstart -k gui/501/com.zig.mlx'` (KeepAlive=true, auto-restarts) |
| MLX RSS >30 GB | Same kickstart; bonus: switch clients to llama-swap :8090 (G14) |
| Ollama unresponsive | `ssh pico '/opt/homebrew/opt/ollama/bin/ollama serve &'` |
| Pico disk pressure | See pico-cleanup-2026-05-25.md recommendations |
| Network/tailnet | Check tailscale status on both ends |

---

## SUMMARY: which model for which task (2026-05-25, empirically verified + research-validated)

**Key research-agent reversal (evening 2026-05-25):** Several Wave 0/1 findings were caused by missing client-side configuration, NOT server/model limitations. The 6 research agents found upstream fixes / known-good configurations for most issues. See G1, G7, G12, G13, G14 below for revised positions.

| Workload | Recommended | Why | Avoid |
|---|---|---|---|
| **Tool-use / structured JSON** | `qwen3-coder:30b` (Ollama OR MLX) | ✅ both backends return parallel `tool_calls[]`. Trinity needs hermes-parser shim (G1). | Trinity without parser shim |
| **Long literary prose / chapter drafts** | Qwen3-Coder MLX **with `repetition_penalty=1.10`** in body | ✅ verified clean (82% tail-unique) — G13 has the fix. Ollama also fine. | Qwen3 MLX *without* repetition_penalty (mode collapse) |
| **Long-context (>32K tokens)** | `laguna-xs.2:latest` (Ollama) | Only model passing 100K bench. Laguna MLX has PR #1223 path (G7) | Laguna MLX from stock mlx-lm 0.31.3 (unsupported until PR merges) |
| **Reasoning-heavy + visible-trace** | `mlx-community/Trinity-Mini-4bit` | Separate `reasoning` field; trained by Arcee AI for function-calling (BFCL 59.67) | n/a |
| **Background subagent dispatch (Claude Code)** | Qwen3 Ollama via CCR (with `<CCR-SUBAGENT-MODEL>` tag — G12) | Both tool-use + prose, covered; env-var route is upstream-broken (#43869) | env-var `CLAUDE_CODE_SUBAGENT_MODEL` (broken) |
| **Code generation** | Qwen3 Ollama or Devstral MLX | Both score 17/20 on bench | n/a |

**Net empirical finding (Wave 1 + research sweep):** Qwen3-Coder via either backend works for most workloads. The MLX serving layer is feature-complete enough when you know the request-body parameters and have the right serving shim (llama-swap for residency, parser shim for Trinity tool-use).

---

## G1 — Trinity tool-use needs server-side parser (model IS capable, server lacks it)

**REVISED 2026-05-25 evening with research-agent finding (Trinity is from Arcee AI, NOT AGI-0):**

- Trinity-Mini was explicitly trained by **Arcee AI** for function-calling (BFCL V3 score 59.67, "robust function calling and multi-step agent workflows")
- The `<tool_call>...</tool_call>` XML output **is the intended Hermes-style format**, not a defect
- Qwen3-Coder works in `mlx_lm.server` because the server has Qwen-shaped parser; **mlx_lm 0.31.3 lacks a Hermes-parser registration for Trinity** — that's the entire gap
- vLLM has the canonical serving recipe: `--enable-auto-tool-choice --reasoning-parser deepseek_r1 --tool-call-parser hermes`

**Fix paths (in order of robustness):**
1. **Best:** switch to vLLM or vllm-mlx with the hermes parser registered
2. **Practical:** keep mlx_lm.server + add a ~30-line client-side regex shim to extract `<tool_call>{...}</tool_call>` into OpenAI `tool_calls[]` shape
3. **Trivial fallback:** system-prompt coerce Trinity into raw `{"tool_calls":[...]}` JSON without using the `tools` parameter (works but loses trained Hermes path)

**Trinity is NOT banned for tool-use. The fix is in the serving layer, not the model. Trinity-Mini is a real tool-calling model.**

For prose / brainstorming / planning: Trinity MLX content field is clean (reasoning goes to separate `reasoning` field). Trinity Ollama still jams `<think>` into content — for Ollama, strip the `<think>` block client-side.

**Research source:** `~/explore/local-coding-models/refs/research/research-trinity-toolcalls.md`. Bead: `explore-4te.17`.

---

## G1-LEGACY — original blanket-ban content (kept for trace)

**Original claim (morning 2026-05-25):** "Trinity is banned for structured output on both backends."

**REVISED again (evening 2026-05-25) with finer empirical evidence:** Trinity-Mini behavior depends on *which response field you read*:

**Trinity MLX:** `message.reasoning` (separate field) + `message.content`. Reasoning tokens go into `reasoning`; final answer goes into `content`. Verified empirically.
```json
{"role": "assistant",
 "content": "The dying embers of the campfire glowed like dying stars...",
 "reasoning": "Okay, let's tackle this continuation. The user wants me to..."}
```
The earlier "empty content" finding was misread — the prose generation request that returned empty content was a separate issue (prompt-length + token-budget interaction).

**Trinity Ollama:** does NOT separate. `<think>...</think>` jams into `content` along with the answer. Parsers that don't strip the think-block break.

**Tool-use specifically:** Trinity (both backends) still emits tool calls as text inside `content` with `<tool_call>` markers, NOT as structured `tool_calls[]` arrays. So for tool-use Trinity is still suboptimal — Qwen3-Coder MLX is preferred for tool calls.

**Updated rule** based on intended workload:

| Workload | Trinity MLX | Trinity Ollama |
|---|---|---|
| Structured tool calls (`tool_calls[]`) | ❌ jams in `content` | ❌ jams in `content` |
| Format-strict JSON in `content` | ⚠️ Reasoning consumes budget; parse `content` separately | ❌ `<think>` contamination |
| Prose / narrative / brainstorming | ✅ Read `content`; ignore `reasoning` (or surface as audit trail) | ⚠️ Strip `<think>` block first |
| Planning where reasoning trace is wanted | ✅ Surface `reasoning` to user | ⚠️ Extract via regex |

**Preferred routing** (updated 2026-05-25 evening with Devstral receipt):
- Tool calls / structured output → **Qwen3-Coder MLX or Ollama** (verified parallel tool calls). Trinity MLX OK with trinity_shim.py wrapper. **Devstral OUT** (no function-calling training; hallucinates shell commands instead per explore-4te.21 probe).
- Prose / narrative → **Qwen3-Coder Ollama** (preferred), **Laguna Ollama**, **Qwen3 MLX with G13 sampler fix**, **Trinity MLX**, **Devstral MLX** (all viable; pick by latency/voice fit)
- Code generation → Qwen3 or Devstral (both score 17/20 on bench)
- Reasoning-heavy planning → Trinity MLX with both `content` + `reasoning` fields surfaced

## G13 — `mlx_lm.server` repetition collapse — FIXED (use `repetition_penalty` in request body)

**REVISED 2026-05-25 evening (research-agent finding, then verified empirically):**

`mlx_lm.server` **already accepts** `repetition_penalty`, `repetition_context_size`, `presence_penalty`, `frequency_penalty` as request-body parameters — documented in [mlx_lm/SERVER.md](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md) but **NOT exposed in `--help`** (doc-discoverability bug, not feature gap).

**Verified live on pico (2026-05-25):**

| Config | Length | Tail unique % | Verdict |
|---|---|---|---|
| baseline (no repetition_penalty) | 3339 chars | 66% | mild repetition |
| `repetition_penalty=1.05, repetition_context_size=64` | 3167 chars | 81% | clean |
| **`repetition_penalty=1.10, repetition_context_size=64`** | 3227 chars | **82%** ✅ | **sweet spot — recommend** |
| `repetition_penalty=1.15, repetition_context_size=64` | 3301 chars | 75% | over-penalized; slightly worse |

**The fix is a one-line client change.** Always send Qwen's recommended sampler shape:
```jsonc
{
  "temperature": 0.7,
  "top_p": 0.8,
  "top_k": 20,
  "repetition_penalty": 1.10,    // ← THE FIX
  "repetition_context_size": 64  // (default 20 is too short for sentence loops)
}
```

This matches the Qwen3-Coder-30B HF model card recommendation. Ollama works out of the box because its `repeat_penalty=1.1` default does what Qwen's recipe asks; MLX requires manual specification.

**Earlier "Qwen3 MLX broken for long prose" finding was wrong — it was a missing client param, not a server defect.**

**Action items:**
- All callers of mlx_lm.server for prose generation MUST include `repetition_penalty` in body
- Upstream PR: surface in `--help` (cosmetic but high-leverage; bead `explore-4te.14`)
- Alternative: nginx shim that injects defaults; or `cubist38/mlx-openai-server` fork has the CLI flag

**Research source:** `~/explore/local-coding-models/refs/research/research-mlx-repetition.md`. Bead: `explore-4te.14`.

---

## G13-LEGACY — original "collapse is unfixable" content (kept for trace)

**Empirical receipts (2026-05-25, Epic D E1 probes — multiple model variations):**

| Model | Backend | Long-prose result | Failure mode |
|---|---|---|---|
| Qwen3-Coder | **MLX** | ❌ collapses after ~150 tokens | Chinese-char repetition @ T=0.85; English-sentence loop @ T=0.5 |
| Qwen3-Coder | **Ollama** | ✅ 2460 chars clean | n/a |
| Trinity-Mini | **MLX** (max_tokens=3000) | ⚠️ produces 14K chars but tail collapses | "hidden beneath the acceptance" loop in last ~500 chars |
| Trinity-Mini | MLX (max_tokens=500) | ❌ empty content (reasoning consumes budget) | n/a |
| Laguna-XS.2 | **Ollama** | ✅ 2423 chars clean | n/a |
| Devstral-Small | **MLX** | ✅ 2525 chars (in v3 probe; longer untested) | none observed at 700 tokens |

**Diagnosis (mechanism untested):**
- Pattern is `mlx_lm.server` produces *repetition collapse* on long-form generation. Affects Qwen3 (fast onset) and Trinity (slow onset). Devstral may also collapse at longer lengths — needs probe.
- The **same model via Ollama produces clean output**, so the underlying weights are fine. The serving layer (sampler, repetition penalty, KV-cache) is the issue.
- Likely candidates: missing/wrong `repetition_penalty` config, sampler temperature handling, KV-cache eviction at long context.

**Rule:**
- **Tool calls / short structured prompts (<500 tokens output): MLX is FINE.** G9 stands; Qwen3 MLX returns parallel tool_calls cleanly.
- **Long literary prose / chapter drafts: route to OLLAMA backend** (Qwen3 Ollama or Laguna Ollama). DO NOT use MLX for >1500 chars of generation output.
- **If you must use Trinity MLX for prose** (e.g. for the reasoning trace): use max_tokens 3000+ but be prepared to **truncate the tail before the collapse** (around 80% of generated length is a safe cut).

**Load-bearing for:** Epic D autonovel (prose), Epic C LSRA REWRITE_REPORT, Epic B social-mode quest dialogue.

**Action item (pi-harness explore-7hh.9):** investigate root cause; possibly PR to expose `--repetition-penalty` flag in mlx-lm upstream. `mlx_lm.server --help` confirms the flag is NOT exposed in CLI (only `--temp`, `--top-p`, `--top-k`, `--min-p`).

**Convenience wrapper available**: `~/dotfiles/local-models/qwen_sampler.py` bakes the Qwen sampler defaults into every request. Use `call_qwen_mlx(prompt=...)` or `inject_qwen_defaults(body)` for direct request augmentation. Self-tested 2026-05-25.

### Sampler-only mitigations (2026-05-25 empirical probe)

| Config | Length | Tail unique-word % | Verdict |
|---|---|---|---|
| Qwen3 MLX baseline (temp=0.7) | 3339 chars | 66% | mild repetition |
| Qwen3 MLX + min_p=0.05 | 3157 chars | 53% | WORSE — more repetition |
| Qwen3 MLX + **temp=0.7 + min_p=0.1 + top_p=0.9** | 2918 chars | **76%** | best of the three; usable |

So Qwen3 MLX with conservative sampling (top_p=0.9, min_p=0.1, temp=0.7) is workable for medium-length prose. Still inferior to Qwen3 Ollama which has `repeat_penalty=1.1` by default. **Earlier "catastrophic collapse" finding (Chinese chars) was specifically at temp=0.85 + long prompts — sampling at temp=0.85 with high-entropy outputs blows up.**

**Updated rule for MLX prose:**
- Long-form prose (>3000 chars): prefer Ollama backend
- Short-to-medium prose (≤3000 chars): MLX is OK at `temp ≤ 0.7, min_p=0.1, top_p=0.9`
- High creativity (temp ≥ 0.8): DO NOT use MLX — sampler can't dampen high-entropy mode collapse

---

## G2 — Pico is single-stream by default

Both `mlx_lm.server` and Ollama on pico are configured serial (Ollama `NUM_PARALLEL=1` per commit `9eb2f0c`; MLX has no continuous-batching support yet). N concurrent agent dispatches will queue, not parallelize.

**Implications:**
- Parallel worktree subagents experience real serialization (~3× wall-clock vs Sonnet for a 3-subagent fan-out)
- Long-context (Laguna 100K) requests during multi-arc operation block all other arcs
- Per-action latency budgets that assume parallelism are wrong

**Mitigation:** none v1 (continuous batching = vLLM/SGLang future work). Plan for serial when sizing.

---

## G3 — macOS unified-memory cliff at ~30 GB weight-footprint

Pico has 64 GB unified memory. Models share that pool with everything else (SD-WebUI when running, Ollama caches, MLX-Server resident model, OS).

**Empirical cliffs:**
- 1 large model (Qwen 15 / Laguna 17 / Trinity 13 GB) + OS: ✅ fine
- 2 large models concurrent: usually fine
- GLM-4.5-Air 4-bit (~50 GB) + anything: ❌ swap thrash, 0.6 tps
- GLM-4.5-Air 3-bit (~44 GB) alone: ✅ usable at 17.5 tps
- SD-WebUI loaded (~17 GB) + MLX long-context: ❌ silent degradation

**Rule:** before loading a new model, evict the previously-resident one. Don't trust "macOS will handle it" — swap pressure produces 50× slowdowns the agent can't detect from response timing alone (it looks "successful" at slow speed).

This is what Epic C's OQ-13 (model-residency policy) addresses. All four epics inherit the constraint.

---

## G4 — SD-WebUI is permanently on-demand

`~/dotfiles/a1111/com.zig.a1111.plist` is `RunAtLoad=false`. Control with:
- `sd-up` — start SD-WebUI (for an SD session)
- `sd-down` — stop it (free ~17 GB for inference)

**Do NOT re-enable the LaunchAgent.** User explicit instruction.

If you start `sd-up` for a session, leave a reminder to `sd-down` afterward, or any subsequent long-context inference will degrade silently (G3 applies).

---

## G5 — `hf download` corrupts `.incomplete` files on resume

Hugging Face CLI's resume logic truncates partially-downloaded shards instead of resuming from offset. Result: silent corruption that only surfaces at model-load time.

**Rule:** for downloads >5 GB on pico, use the curl-resume scripts:
- `~/local-coding-models/glm-resume-download.sh`
- `~/local-coding-models/glm-3bit-resume-download.sh`

Both are robust to network interruption.

---

## G6 — Long jobs go to log files on the target host

Per project convention (memory: `long_jobs_log_files`): any job expected to run >5 min should be `nohup`-to-log-file on the target host, not harness-tracked timeouts or background polling loops.

**Pattern:**
```bash
ssh pico 'nohup ~/script.sh > ~/script.log 2>&1 &'
# Later, when you want to check:
ssh pico 'tail -50 ~/script.log'
```

Applies to: model downloads, benchmarks, fine-tuning, 24h agent runs, eviction profiling.

---

## G7 — Laguna MLX WORKAROUND-AVAILABLE via Blaizzy fork (was BLOCKED)

**REVISED 2026-05-26 (Wave 10 D10 empirical):**

The Blaizzy mlx-lm fork (`pc/add-lg` branch) was empirically tested on pico in an isolated venv. Laguna XS.2 loads + generates correctly. G7 demoted from BLOCKED to WORKAROUND-AVAILABLE.

**Workaround (verified working):**
```bash
python3.10 -m venv ~/laguna-test/.venv
source ~/laguna-test/.venv/bin/activate
pip install git+https://github.com/Blaizzy/mlx-lm.git@pc/add-lg
# Test: from mlx_lm import load, generate
#       model, tok = load("mlx-community/Laguna-XS.2-mxfp4")
#       generate(model, tok, prompt="...", max_tokens=20)
```

Empirical result (`~/d10-laguna-load.log` on pico, 2026-05-26):
- `laguna` arch registered in branch's models registry ✓
- Model loads (12 files, ~10 sec) ✓
- Generation OK on capital-of-France prompt ✓
- Minor tokenizer warning: `fix_mistral_regex=True` recommended (Mistral-Small-3.1 tokenizer issue; cosmetic)

**Upstream status (unchanged):**
- PR exists: [ml-explore/mlx-lm#1223](https://github.com/ml-explore/mlx-lm/pull/1223) by Blaizzy, opened 2026-04-28
- **Still open, mergeable_state: blocked**, no maintainer review yet as of 2026-05-26
- 826 LOC across 7 files — genuinely novel arch (per-layer-type RoPE, variable head count, per-head sigmoid output gating, hybrid dense+MoE MLP)
- vLLM, SGLang, TensorRT-LLM, Transformers, Ollama all have day-zero Laguna support — mlx-lm was the odd one out

**Current recommendation:**
1. **Laguna MLX is now USABLE via fork-pinned venv** — for Laguna-specific work, install the Blaizzy fork in an isolated environment
2. The system-wide mlx-lm (used by the launchd-managed `mlx_lm.server` at :8081) still does NOT support Laguna — only the fork venv does
3. To benchmark Laguna MLX vs Laguna Ollama: start a fork-pinned `mlx_lm.server` on a different port, route per-bead
4. Watch PR #1223 for upstream merge; switch system-wide install when merged (probably auto-fixable via `pip install -U mlx-lm` once a release ships)
5. Add a benchmark-comment to PR #1223 to nudge review (social proof — johntdavies's M5 Max bench is already there; ours would be M1 Max)

**Routing implications:**
- AB-verdict v2 "Laguna MLX" row can be filled in via fork-pinned bench (Wave 11+ work)
- `dotfiles-5e2` D10 deferred-decision can be marked RESOLVED
- Hermes Agent pico-mlx plugin (`explore-7hh.13`) may want to expose both system MLX (:8081) AND Laguna-fork MLX as separate profiles

**Research source:** `~/explore/local-coding-models/refs/research/research-laguna-mlx.md`. D10 result archived in bead `explore-4te.18` `--notes`.

---

## G7-LEGACY — original "Laguna is BLOCKED" content (kept for trace)

`LagunaForCausalLM` is not in mlx-lm 0.31.3. Laguna is **Ollama-only** locally until upstream adds support.

**Empirical verification (2026-05-25):** `mlx_lm.server` *lists* `mlx-community/Laguna-XS.2-mxfp4` in `/v1/models` (because the path exists on disk), but a real `POST /v1/chat/completions` returns:
```
error: Model type laguna not supported.
```
So even though discovery shows it, completion rejects it. Don't be fooled by the model-list response.

If a spec asks "route long-context to Laguna MLX," it's wrong. Route to **Laguna Ollama** (`laguna-xs.2:latest` — verify with `ollama list` on pico).

---

## G8 — Model IDs must match the on-disk tag exactly

Generic shorthand like `"qwen3-coder"` or `"laguna"` in config files is a bug magnet. The actual identifiers are full paths.

**Empirically verified on pico (2026-05-25):**

| Backend | Exact tag | Notes |
|---|---|---|
| MLX | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | ✅ serves |
| MLX | `mlx-community/Trinity-Mini-4bit` | ✅ serves |
| MLX | `mlx-community/Devstral-Small-2507-5bit` | ✅ serves |
| MLX | `mlx-community/Laguna-XS.2-mxfp4` | ❌ listed but errors per G7 |
| Ollama | `qwen3-coder:30b` | ✅ |
| Ollama | `trinity-mini:latest` | ✅ but G1 applies |
| Ollama | `laguna-xs.2:latest` | ✅ — use for long-context |
| Ollama | `devstral:24b` | ✅ |
| Ollama | `qwen2.5:7b` | small fallback |
| Ollama | `llama3.2:3b` | smallest fallback |

**Rule:** any config touching local models must reference the *exact* tag. Use `curl http://100.72.47.4:8081/v1/models` (MLX) and `curl http://100.72.47.4:11434/api/tags` (Ollama) over tailnet to verify before committing config.

---

## G9 — `mlx_lm.server` tool-use support is model-dependent (RETRACTED original claim)

**Original claim (2026-05-25 morning):** "Stock mlx_lm.server has no tool-use parser; needs cubist38 fork."

**REVISED with empirical evidence (2026-05-25 evening):** Stock `mlx_lm.server` DOES return structured `tool_calls[]` for models that were trained on tool-use (Qwen3-Coder). It does NOT for models that weren't (Trinity).

**Empirical evidence:**

| Model | tool_calls[] populated? | parallel tool calls? |
|---|---|---|
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | ✅ yes | ✅ yes (verified: 2 read_file calls in one turn) |
| `mlx-community/Trinity-Mini-4bit` | ❌ no — jams in `content` as `<tool_call>...</tool_call>` text | n/a |
| `mlx-community/Devstral-Small-2507-5bit` | not yet tested | not yet tested |
| `mlx-community/Laguna-XS.2-mxfp4` | n/a (G7 — doesn't serve) | n/a |

**Rule:** Stock mlx_lm.server is fine for Qwen3-Coder tool-use including parallel calls. **The cubist38/mlx-openai-server fork is NOT required** for the workloads in scope. If you switch to a different model and tool calls start showing up in `content`, you've hit a model-side limitation (G1 applies — that model is on the banned list for tool use).

**Verify** before assuming for a new model: `curl <mlx-server>/v1/chat/completions` with a `tools` array and check whether the response has `choices[0].message.tool_calls` or just `content` with tool-call-shaped text.

This materially de-risks Epic A — no pico-side rewrite needed. (Spec edit: §3.1 doesn't need to pin server fork.)

---

## G12 — Subagent routing: use CCR's in-prompt tag (env-var path is upstream-broken)

**REVISED 2026-05-25 evening (research-agent finding):**

The env-var route `CLAUDE_CODE_SUBAGENT_MODEL` IS a real documented var but **upstream-broken end-to-end** per [anthropics/claude-code#43869](https://github.com/anthropics/claude-code/issues/43869). Empirically validated across all 5 documented routing surfaces in the issue — none work; Sonnet quota stays flat while Opus burns.

**YAML `model:` frontmatter** only accepts Anthropic aliases (`sonnet`/`opus`/`haiku`/`inherit` or full IDs). Putting `pico-ollama,qwen3-coder:30b` there is silently invalid.

**No `subagentModel` settings.json key exists.** Closest is `teammateDefaultModel` (Agent Teams only, in `~/.claude.json`, alias-only).

**THE WORKING MECHANISM** (verified in CCR source AND empirically tested 2026-05-25):

The tag must appear in `body.system[1].text` (the **second** system message in an Anthropic Messages request — NOT in user content, NOT in the first system message). CCR's request handler checks for this specific shape:

```javascript
if(e.body?.system?.length>1 && e.body?.system[1]?.text?.startsWith("<CCR-SUBAGENT-MODEL>")){
  let h = e.body?.system[1].text.match(/<CCR-SUBAGENT-MODEL>(.*?)<\/CCR-SUBAGENT-MODEL>/s);
  if(h) { /* strip tag, route to h[1] */ }
}
```

**Correct wire shape:**

```jsonc
{
  "model": "claude-opus-4-7",  // ignored — overridden by tag
  "system": [
    {"type": "text", "text": "<your normal system prompt>"},
    {"type": "text", "text": "<CCR-SUBAGENT-MODEL>pico-ollama,qwen3-coder:30b</CCR-SUBAGENT-MODEL>"}
  ],
  "messages": [...]
}
```

**Empirical receipt (2026-05-25):** sent request with `model: claude-opus-4-7` + tag in system[1] → response had `model: qwen3-coder:30b`. **Tag works as documented.**

**For Claude Code subagent dispatches:** Claude Code naturally builds multi-element `system[]` arrays (system prompt + CLAUDE.md + skill bodies). The orchestrator must inject the tag as a NEW second system message (or insert it at index 1 if it doesn't exist there). This is where the `/dispatch` skill would plumb the override.

**Proven config:**
1. Run `eval "$(ccr activate)"` to set `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` + `ANTHROPIC_AUTH_TOKEN=ccr` in current shell + all children
2. DROP `CLAUDE_CODE_SUBAGENT_MODEL` from settings.json (misleading; doesn't work)
3. DROP custom `model:` frontmatter pointing at non-Anthropic models
4. Inject `<CCR-SUBAGENT-MODEL>pico-ollama,qwen3-coder:30b</CCR-SUBAGENT-MODEL>` into subagent prompts (e.g., wire into `/dispatch` skill as opt-in)
5. CCR's existing config (already at `~/dotfiles/claude-code-router/config.json`) is sufficient — providers + Router block wired

**Research source:** `~/explore/local-coding-models/refs/research/research-ccr-subagent-routing.md`. Bead: `dotfiles-ukx.7`.

---

## G17 — `claude -p` cannot reach CCR's per-request routing tag; use curl-direct for scripted CCR routing

**Empirical receipt (2026-05-26, dotfiles-ukx.4 subagent dev):**

Claude Code's `claude -p` (headless / SDK mode) cannot inject content at `system[1]` of the outgoing Anthropic Messages request, which is where CCR's `<CCR-SUBAGENT-MODEL>` per-request routing tag must live to be parsed (per `dotfiles-ukx.8` source-read of `anthropic.transformer.ts`).

**Empirical failure modes (preserved as test artifacts dotfiles-7wi + dotfiles-l7d):**

| Approach | Failure |
|---|---|
| `claude -p < prompt` (default opus) | Routes to Anthropic via CCR's `default` route — defeats local routing intent |
| `claude --model haiku < prompt` | Rejected by Claude Code's client-side model validation before request leaves CC |
| `claude -p --append-system-prompt "<CCR-SUBAGENT-MODEL>..."` | Tag lands at `system[2]`, not `system[1]` — CCR parser doesn't see it |

CC fills `system[0]` (billing identifier) + `system[1]` (CC/SDK identifier) by hard-coded position; any user-supplied system content lands at `system[2]+`.

**Workaround (in production at `~/dotfiles/claude/scripts/nightly-digest.sh`):**

```bash
curl -sS http://127.0.0.1:3456/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: dummy" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 4096,
    "messages": [{"role":"user","content":"<prompt>"}]
  }'
```

CCR sees `haiku` in body → consults Router → `background` route → `pico-mlx,qwen3-coder` → llama-swap on :8090 → local Qwen3 response. Verify routing worked by checking response body's `model:` field — should show `mlx-community/Qwen3-Coder-...`, not an Anthropic model.

**Pattern generalizes:** any shell-side automation that wants CCR per-request routing should use curl-against-`/v1/messages`, NOT `claude -p`. The `claude` CLI is the wrong tool when CCR's routing intelligence needs to act per-request.

**Affects:**
- `dotfiles-ukx.6` §3.4 (headless mode) — spec needs amendment from "claude -p" to "curl-direct"
- `explore-7hh.16` (LSRA prototype) — plan curl-direct for its automation
- `bd-b5p.4` (Hermes-autonovel Phase 1) — same

**Could change if upstream lands:**
- A `--system-prefix` flag on `claude -p` that injects at `system[1]`
- Pass-through `--model` strings without client-side validation (let CCR decide validity)
- A native subagent-routing tag mechanism in CC that CCR could integrate against

None exist as of Claude Code v2026-05 / CCR v2.0.0. File upstream feature request when next-priority.

**Research source:** `~/explore/local-coding-models/refs/research/research-claude-p-ccr-tag-gap.md`. Bead: `dotfiles-ukx.4` (closed); test artifacts `dotfiles-7wi` + `dotfiles-l7d` (closed).

---

## G16 — Tool-using subagents MUST route via llama-swap, NOT direct mlx_lm.server

**Empirical receipt (2026-05-26, dotfiles-ukx.9):** Same Qwen3-Coder-30B-A3B-Instruct-4bit weights probed via three local backends with an identical parallel-tool-call payload (Edit + Bash tools, prompt forcing parallel use):

| Backend | URL | Verdict |
|---|---|---|
| llama-swap | `100.72.47.4:8090` | **PASS** — 2 tool_calls (Edit + Bash) properly emitted |
| Ollama | `100.72.47.4:11434` | **DEGRADED** — 1 tool_call (Edit only, Bash silently dropped) |
| mlx_lm.server | `100.72.47.4:8081` | **REFUSED** — model returned plain text "I cannot execute multiple commands in parallel as requested" |

The MLX direct refusal is the surprising part: the model didn't try and fail, it explicitly refused. Hypothesis: `mlx_lm.server`'s default chat template doesn't wrap the tools schema in Qwen3's expected `<tools>...</tools>` XML envelope, so from the model's perspective tools are not advertised. llama-swap injects the correct envelope before forwarding.

**Routing rule:** **For any subagent that may emit parallel tool calls, route via llama-swap (`100.72.47.4:8090`).** Do NOT point CCR's `pico-mlx` provider at `mlx_lm.server` direct on :8081 for tool-using work. Direct MLX is fine for non-tool prose/completion work (PONG roundtrip works, autonovel-style prose works); the tool-call refusal is specific to the tool-schema path.

**Ollama for tool-use is degraded but workable** for non-parallel cases. For parallel-emitting subagents (orchestrator dispatches that fan out Read/Edit/Bash), llama-swap is the safe path.

**This finding is the real `why-llama-swap-exists` for our stack** — not just memory eviction (G14), but tool-call envelope correctness too.

**Wave 13 root-cause correction (2026-05-26):** the initial "llama-swap injects tool envelope" hypothesis was FALSIFIED by source-read of llama-swap (`research-llama-swap-toolshim.md`) — llama-swap does ZERO tool-call transformation. The actual divergence is at mlx_lm.server's startup-flag level:

- `:8081` (launchd `com.zig.mlx.plist`) starts with NO `--model` flag → lazy-load mode → tools silently fail (model's `chat_template.jinja` not applied properly for tools)
- `:5802` (spawned by llama-swap for qwen3-coder) starts with `--model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` → eager-load mode → chat_template loaded correctly → tools work

Empirically verified with deterministic temp=0+seed=42 across 3 trials per backend: MLX direct 0/3 emits tool_calls, llama-swap 3/3 emits 2 tool_calls (Edit+Bash). The divergence is structural, not sampling noise.

**`mlx_lm.server` has a lazy-load chat-template bug** worth filing upstream. Llama-swap accidentally avoids it by always spawning `--model`-preloaded instances. Alternative workaround: restart `:8081` with explicit `--model X` (locks to single model but tools would work) — trades flexibility for fidelity; not currently recommended.

**Secondary finding (file upstream issue):** `mlx_lm.server` v0.31.3 emits response `content` strings with literal `\n` characters instead of escaped `\\n`, breaking strict JSON parsing on the client. CCR + llama-swap re-encode and don't suffer; raw curl callers must use `strict=False` JSON parsing or pre-filter.

**Research source:** `~/explore/local-coding-models/refs/research/research-ccr-tool-schema-followup.md`. Bead: `dotfiles-ukx.9`. Updates `dotfiles-ukx.6` §4.1 routing config (pico-mlx repoint :8081 → :8090).

### Wave 15 G16 amendment — CCR config REVERSAL on `transformer: { use: ["Anthropic"] }`

The Wave 11 ukx.8 research **recommended** `transformer: { use: ["Anthropic"] }` on the pico-mlx + pico-ollama providers. The Wave 13 G16 work + Wave 14 ukx.3/ukx.5 ALL propagated that recommendation into the production config + README.

**Wave 15 ukx.12 empirical: that recommendation was WRONG.** When the smoke environment first tried to send tool-using requests through CCR → llama-swap, every request 404'd with `'dict object' has no attribute 'parameters'` (a Jinja error from mlx_lm.server's chat template trying to access `tool.parameters` on an Anthropic-shape dict that only has `input_schema`).

**Root cause**: `transformer: { use: ["Anthropic"] }` tells CCR "this provider speaks Anthropic Messages format" — meaning CCR converts the OUTGOING (Unified → Anthropic) on the request side. But pico-mlx (mlx_lm.server via llama-swap) speaks OpenAI Chat Completions. So CCR was sending an Anthropic-shape body to an OpenAI-shape backend; the `input_schema` field never got renamed to `parameters`; the chat template's `{{ tool.parameters }}` access raised an AttributeError.

**Fix (live in commit edf1964-+1)**: REMOVE the `transformer` block entirely from pico-mlx + pico-ollama providers. CCR's default behavior for an OpenAI-compat backend is to convert Anthropic→OpenAI on the request side via its built-in `convertAnthropicToolsToUnified` function (verified empirical: parallel tool calls now PASS through the full CCR→llama-swap pipeline at 2/2 emitted).

**Lesson** (worth carrying to the [[preserve-process-artifacts]] memory + the /research SKILL anti-pattern table): **source-read research is necessary but not sufficient — every load-bearing recommendation needs an empirical wire-test before declaring victory**. ukx.8 source-read recommended the transformer config; only ukx.3's smoke env exercised the full pipeline and exposed that the recommendation was upside-down. This is the second time this session (G16-original was also reversed) — the pattern is clear.

**Updated production posture** (all in dotfiles main as of Wave 15):
- `~/dotfiles/claude-code-router/config.json` — no transformer blocks on pico-* providers
- `~/dotfiles/claude-code-router/README.md` — needs update (ukx.5 doc references the now-removed block)
- `dotfiles-ukx.6` §4.1 — needs update (still shows transformer block)
- `dotfiles-ukx.8` + `dotfiles-ukx.9` research files — needs REVISED block flagging the wrong recommendation

**Empirical receipt (2026-05-26)**: parallel tool-call probe through CCR /v1/messages → Router.background → pico-mlx (no transformer) → llama-swap :8090 → mlx_lm.server :5802 → Qwen3-Coder → 2 tool_use blocks (Edit + Bash) returned in correct Anthropic shape. End-to-end PASS.

### G16 extension (2026-05-26 same session) — Qwen3-Coder is the only working model

Extended the probe across the other tool-shortlist models, all routed via llama-swap :8090 (the known-good path for Qwen3):

| Model via llama-swap | Verdict | Notes |
|---|---|---|
| qwen3-coder | ✅ PASS | parallel tool_calls emitted correctly |
| devstral-mlx | ❌ REFUSED / TEXT MODE | model narrates plan in text; no tool_calls |
| trinity-mini-mlx | 🟡 PARSEABLE via shim (at ≥2000 tok max) | Re-probe with max_tokens=2000: Trinity emits 2 parallel `<tool_call>...</tool_call>` XML blocks in CONTENT (correct args, both Edit + Bash). NOT in `message.tool_calls[]` because llama-swap doesn't parse Hermes XML. The Wave 5 `trinity_shim.py` is the client-side parsing solution — Trinity becomes VIABLE for parallel tool use when shim is applied |
| deepseek-coder-v2-lite-mlx | ⛔ SKIPPED | G15 blocks (MoE arch unsupported in mlx-lm 0.31.3) |

**Practical: tool-using local routing paths in priority order:**
1. **Qwen3-Coder via llama-swap :8090** — native PASS; no shim needed
2. **Trinity Mini via llama-swap :8090 + trinity_shim.py** — emits parallel `<tool_call>` XML correctly at max_tokens ≥2000; shim parses XML into structured `tool_calls[]`. Wave 5 already shipped the shim
3. **(Fallback) Ollama Qwen3-Coder :11434** — DEGRADED (single tool call per turn), but works for sequential subagent dispatch with "one tool per assistant turn" hint

**Devstral remains tool-mute in the currently-installed quants** — `mlx-community/Devstral-Small-2507-5bit` ships a 44-line tool-blind template; `mlx-community/Devstral-Small-2507-4bit-DWQ` same. Ollama `devstral:24b` ALSO broken (Wave 14 empirical probe: `finish_reason=stop`, 196 tokens, no tool_calls, plain markdown narration).

**Wave 14 unblock path**: `lmstudio-community/Devstral-Small-2507-MLX-4bit` (13.3 GB, 4-bit) ships the full Mistral `[TOOL_CALLS]/[AVAILABLE_TOOLS]/[TOOL_RESULTS]` envelope. Swap llama-swap to this quant + re-probe to unblock Devstral. Tracked as `dotfiles-ukx.11`. Research at `~/explore/local-coding-models/refs/research/research-devstral-toolaware-quant.md`.

**Updated routing rule:** CCR's `pico-mlx` provider for tool-using subagents → Qwen3-Coder via llama-swap :8090. For non-tool prose/completion work, direct MLX :8081 is still fine. Long-context Laguna → Ollama :11434 (unchanged). Devstral + Trinity stay non-tool-routed.

---

## G15 — DeepSeek-Coder-V2-Lite MLX BLOCKED (MoE arch not supported, same pattern as Laguna)

**Empirical receipt (2026-05-25 evening, explore-4te.13):** Attempted to load `mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit` via stock mlx_lm.server. Result: HF auto-download started (4.1 GB downloaded into proper snapshots/ cache), then **HUNG indefinitely** — server process at 0% CPU, no log activity, no model load completed after 70+ min. Smoke test curl timed out at 5min then 30min budgets, returning no bytes.

**Root cause (suspected):** DeepSeek-V2-Lite is a 16B MoE (Mixture-of-Experts) model with custom modeling code (`modeling_deepseek.py`, `tokenization_deepseek_fast.py`). mlx-lm 0.31.3 likely doesn't support this MoE variant. Same pattern as **G7 Laguna** — `LagunaForCausalLM not supported`, but for DeepSeek the failure mode is silent hang instead of explicit error.

**Workaround: use Ollama path.** Ollama supports the model via `deepseek-coder-v2:16b-lite-instruct-q4_K_M` (~10 GB). Pull command:
```bash
OLLAMA_HOST=http://100.72.47.4:11434 /opt/homebrew/opt/ollama/bin/ollama pull deepseek-coder-v2:16b-lite-instruct-q4_K_M
```

**Action items:**
- Bench DeepSeek via Ollama against AB-verdict-v2 suite once pull completes.
- File mlx-lm issue / check upstream PR tracker for DeepSeek-V2 MoE support (mirror Laguna PR#1223 pattern).
- Do NOT include DeepSeek in any MLX-only routing config (CCR's `pico-mlx`, llama-swap's `deepseek-coder-v2-lite-mlx` entry should be marked `disabled: true` until upstream supports it).

**Bead:** `explore-4te.13`.

---

## G14 — `mlx_lm.server` has no model unload (use llama-swap or PR #1274)

**Research finding (2026-05-25 evening):**

Verified in mlx-lm 0.31.3 source: NO unload endpoint, NO `--idle-timeout`, NO `--keep-alive`, NO `MLX_LM_*` env vars, NO memory-pressure listeners.

**Root cause of monotonic RSS growth observed empirically (X4 probe — RSS 22→36→45 GB across 3 model swaps):** `ModelProvider._load()` in `server.py` drops Python refs (`self.model = None`) but **never calls `mx.metal.clear_cache()` or `gc.collect()`**. MLX's Metal allocator retains buffers. Maintainer `awni` confirms on issue #467: manual fix is `del model; mx.clear_cache()`.

**Upstream:**
- Issue [#1235](https://github.com/ml-explore/mlx-lm/issues/1235) — exact feature request, open
- PR [#1274](https://github.com/ml-explore/mlx-lm/pull/1274) — `--idle-timeout` implementation, open/unmerged
- Issue [#467](https://github.com/ml-explore/mlx-lm/issues/467) — confirms `del self.model` alone is insufficient

**Best workaround: [llama-swap](https://github.com/mostlygeek/llama-swap)** — Go proxy that fronts N mlx_lm.server processes (one per model on disjoint ports), exposes `POST /api/models/unload`, default "one model at a time" policy enforces the "at most one big model resident" constraint. Native ARM64 Homebrew install. Doesn't drop sessions when switching.

Alternative: `cubist38/mlx-openai-server` fork has FastAPI rewrite with `on_demand_idle_timeout` YAML config.

Fallback: build PR #1274's branch directly via `uv tool install git+https://github.com/ml-explore/mlx-lm.git@refs/pull/1274/head` to get `--idle-timeout 300` pre-merge.

**Recommendation:** install llama-swap on pico, front 8081 with it, run mlx_lm.server backends on 8091/8092/8093 (one per model). Keep current single-server setup for now; switch to llama-swap if memory pressure becomes operational pain.

**Research source:** `~/explore/local-coding-models/refs/research/research-mlx-unload.md`. Bead: `explore-4te.19`.

---

## G12-LEGACY — original "env var doesn't propagate" content (kept for trace)

**Empirically verified (2026-05-25 X1 probe):** Dispatched a worktree subagent that ran `echo "$CLAUDE_CODE_SUBAGENT_MODEL"` → `<UNSET>`. Same result for `ANTHROPIC_BASE_URL` — does not propagate. The variable lives in the orchestrator's shell environment but doesn't cross the worktree-subagent boundary, even with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` enabled.

**What DOES propagate** to worktree subagents (probed empirically):
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` ✅
- `CLAUDECODE=1` ✅
- `CLAUDE_CODE_ENTRYPOINT=cli` ✅
- `CLAUDE_CODE_EXECPATH=...` ✅
- `CLAUDE_CODE_SESSION_ID=...` ✅
- `CLAUDE_EFFORT=...` ✅
- Other `CLAUDE_*` vars from the orchestrator's process env

**What does NOT propagate:**
- `CLAUDE_CODE_SUBAGENT_MODEL` ❌
- Any `ANTHROPIC_*` vars (no `ANTHROPIC_API_KEY`, no `ANTHROPIC_BASE_URL`) ❌

**Implication for routing subagents to local:** The env var mechanism is dead. Use **per-agent YAML `model:` frontmatter** in `~/dotfiles/claude/agents/<name>.md` — Claude Code reads that at dispatch time, the subagent inherits the model selection through the dispatch payload (not through env propagation). Per-agent overrides are the only viable mechanism.

This is a material change from Epic A spec §3.3 which assumed env var was canonical. (Spec edit applied 2026-05-25.)

---

## G11 — Tailnet HTTP latency to pico ≈ 160-220ms RTT

Measured 2026-05-25 from zig→pico over Tailscale, 100 sequential GETs:

| Endpoint | P50 | P95 | P99 | min | max |
|---|---|---|---|---|---|
| MLX `/v1/models` | 183ms | 195ms | 223ms | 168 | 223 |
| Ollama `/api/tags` | 160ms | 171ms | 187ms | 156 | 187 |

**~3× higher than ping latency** (HTTP request overhead + JSON serialization + tailnet WireGuard). This is the *floor* — actual completion calls add prompt-prefill + decode time on top.

**Implications:**
- B's combat tier targeted ≤300ms decisions; network alone eats ~200ms, leaving ~100ms for decode. Trinity MLX at 52 tps × 80 tokens = 1.54s decode — **B's combat target is unmeetable as written** (scrutinize A4 confirmed empirically).
- A's scheduled headless jobs that do N tool calls: each Read/Bash roundtrip costs ~200ms over and above local execution. A 20-tool-call task takes 4s of pure network overhead before any LLM work.
- C/D running on-pico daemons avoid this entirely (localhost calls are sub-ms).

---

## G10 — Settings on pico that other arcs depend on

| Setting | Value | Reason | Owner |
|---|---|---|---|
| `OLLAMA_KEEP_ALIVE` | `24h` | Avoid 60-90s cold-load on every call | A (`~/dotfiles/ollama/`) |
| `OLLAMA_NUM_PARALLEL` | `1` | Stability (was 2; dropped per commit `9eb2f0c`) | A |
| `OLLAMA_CONTEXT_LENGTH` | `65536` (after A's check OQ7) | Laguna can handle 100K; 32K was too conservative | A |
| `mlx_lm.server` build | cubist38 fork | Tool-use parsing (G9) | A (pending verification) |
| SD-WebUI `RunAtLoad` | `false` | G4 | committed |
| MLX warmup plist | 23h interval, 5s timeout curl | A check OQ6 — avoid first-token-15s | A (to-build) |

---

## G18 — `mlx_lm.server` tool-call response parser doesn't handle Mistral `[TOOL_CALLS]/[ARGS]` envelope

**Status:** Verified empirically 2026-05-27 via `dotfiles-ukx.11` Devstral swap probe.

`mlx_lm.server` v0.31.3's response-side tool-call parser only recognizes OpenAI-style `<|tool_call|>` markers (and Qwen3-specific variants). It does **not** parse Mistral's `[TOOL_CALLS]function_name[ARGS]{...}` envelope.

**Symptom:** request a tool call against `lmstudio-community/Devstral-Small-2507-MLX-4bit` (or any Mistral-envelope model). Response comes back as `{"finish_reason": "stop", "message": {"role": "assistant"}}` — empty message, no `content`, no `tool_calls`. N completion tokens silently dropped.

**Direct CLI probe** (bypassing server's parser) confirms the model IS emitting `[TOOL_CALLS]Edit[ARGS]{...}` correctly. The bytes are there; the server eats them.

**Affected models:** any Mistral-family model loaded into `mlx_lm.server` (Devstral, Mistral-Small, Codestral, etc.).

**Not affected:** Qwen3-Coder family (uses Qwen3-specific envelope mlx_lm.server understands).

### Mitigation paths (none implemented yet — Devstral tool tier remains BLOCKED)

1. **Upstream fix**: file an issue / PR against `ml-explore/mlx-lm` to add a Mistral `[TOOL_CALLS]/[ARGS]` envelope parser. Probably localized to the tool-call extraction layer.
2. **Local shim**: pattern after `local-models/trinity_shim.py` — wrap the model's raw text output and convert `[TOOL_CALLS]function[ARGS]{json}` into OpenAI `tool_calls[]` shape. Lives in CCR's transformer layer.
3. **Different runtime**: serve Devstral via Ollama (which has its own tool-parser) or `vllm` (which handles Mistral natively) instead of mlx_lm.server. Adds runtime divergence; not preferred.
4. **Don't bother**: Qwen3-Coder via llama-swap is the canonical tool-tier path (G16 + ukx.9 PASS). Devstral was nice-to-have, not load-bearing.

### Compound issues at the model level

Even if mlx_lm.server's parser landed, Devstral itself has additional problems visible in the CLI probe:
- **Serial, not parallel** — emits 1 tool_call instead of the requested 2 (Edit + Bash)
- **Hallucinated schemas** — invented an LSP-style `{text, range}` for Edit instead of honoring the requested `{old_string, new_string}` from the tool's `parameters` JSON Schema
- **Tokenizer regex warning** — `transformers` reports Mistral's tokenizer regex is incorrect; suggests `fix_mistral_regex=True`

So Devstral's tool tier is broken at three layers, not one.

**Operational impact**: Devstral remains BLOCKED for tool tier. Prose tier (plain text generation) still works fine. Don't add Devstral to CCR's `pico-mlx` provider's tool-routed models list. Keep using Qwen3-Coder MLX via llama-swap as the canonical tool-tier path.

### Wave 14 → Wave 16 reversal pattern

Wave 14 research (`research-devstral-toolaware-quant.md`) said path (b) — swap the quant — would unblock tool use. Empirical Wave 16 probe (this guardrail) showed path (b) gets us the right prompt template but doesn't fix the runtime parser gap.

**3rd empirical reversal this arc** (after G16 original mechanism + ukx.8 transformer config). The discipline: source-read recommendations need wire-tests at EVERY load-bearing layer before declaring "fixed."

See `~/explore/local-coding-models/refs/research/research-devstral-mlx-server-parser-gap.md` for the full 3-layer breakdown with raw probe outputs.

---

## Cross-references

- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — bench source for G1/G3/G7
- `~/explore/local-coding-models/refs/pico-state.md` — current pico configuration
- `~/explore/refs/cross-epic-overlap-2026-05-25.md` — cross-arc infra/experiments/dependencies
- `~/.claude/skills/heartbeat/SKILL.md` — halt-machinery canonical pattern (I2)
- All four spec beads link to this file: `dotfiles-ukx.6`, `blightmud-hgi.5`, `explore-nfc.5`, `bd-b5p.1`
