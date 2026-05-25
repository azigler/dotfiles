# Local-models guardrails

Cross-arc invariants observed empirically. Violations cause silent failures or production regressions across all four current epics (A: CCR router, B: CoD MUD agent, C: LSRA research agent, D: autonovel pi.dev harness) plus future arcs.

Last updated: 2026-05-25 (multiple revisions during Wave 0/1 probes).

---

## SUMMARY: which model for which task (2026-05-25, empirically verified)

| Workload | Recommended | Why | Avoid |
|---|---|---|---|
| **Tool-use / structured JSON** | `qwen3-coder:30b` (Ollama) | ✅ parallel `tool_calls[]`, fast, no MLX serving quirks | Trinity (both), Devstral untested |
| **Long literary prose / chapter drafts** | `qwen3-coder:30b` (Ollama) | ✅ ~22s for 2K chars, in-voice. Qwen3 *MLX* mode-collapses (G13). | Qwen3 MLX, Trinity MLX (empty content G1) |
| **Long-context (>32K tokens)** | `laguna-xs.2:latest` (Ollama) | Only model passing 100K bench; format-clean | Laguna MLX (G7), Qwen3 MLX (G13) |
| **Reasoning-heavy + visible-trace** | `mlx-community/Trinity-Mini-4bit` | Separate `reasoning` field useful for audit | Default to Qwen3 Ollama unless trace needed |
| **Background subagent dispatch (Claude Code)** | Qwen3 Ollama via CCR | Both tool-use + prose, covered | Same as above |
| **Code generation** | Qwen3 Ollama or Devstral MLX | Both score 17/20 on bench | n/a |

**Net empirical finding (Wave 1):** Qwen3-Coder via Ollama is the workhorse. MLX backend's role narrows to: (a) Trinity reasoning trace use case, (b) higher per-token speed for some workloads (35 tps MLX vs 33 tps Ollama for Qwen3 — but only matters for streaming UX, not for batch agent dispatch).

---

## G1 — Trinity needs special-case response parsing (NOT a blanket ban)

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

**Preferred routing**:
- Tool calls / structured output → **Qwen3-Coder MLX** (verified parallel tool calls)
- Prose / narrative → **Qwen3-Coder Ollama** or **Laguna Ollama** (NOT Qwen3 MLX — see G13 below)
- Reasoning-heavy planning → Trinity MLX with both fields surfaced

## G13 — `mlx_lm.server` has a long-form repetition-collapse issue (Qwen3 + Trinity confirmed)

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

**Action item (pi-harness explore-7hh):** investigate root cause and report back via PR to mlx-lm upstream. Could be a 1-line fix in sampler config.

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

## G7 — Laguna MLX is BLOCKED in current mlx-lm

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

## G12 — `CLAUDE_CODE_SUBAGENT_MODEL` does NOT propagate into worktree subagents

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

## Cross-references

- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — bench source for G1/G3/G7
- `~/explore/local-coding-models/refs/pico-state.md` — current pico configuration
- `~/explore/refs/cross-epic-overlap-2026-05-25.md` — cross-arc infra/experiments/dependencies
- `~/.claude/skills/heartbeat/SKILL.md` — halt-machinery canonical pattern (I2)
- All four spec beads link to this file: `dotfiles-ukx.6`, `blightmud-hgi.5`, `explore-nfc.5`, `bd-b5p.1`
