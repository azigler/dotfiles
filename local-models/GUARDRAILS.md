# Local-models guardrails

Cross-arc invariants observed empirically. Violations cause silent failures or production regressions across all four current epics (A: CCR router, B: CoD MUD agent, C: LSRA research agent, D: autonovel pi.dev harness) plus future arcs.

Last updated: 2026-05-25.

---

## G1 — Never route tool-use calls to Trinity Ollama

**Symptom:** JSON tool-call parsing fails silently; agent gets back malformed `tool_use` blocks or empty content.

**Root cause:** Trinity-Mini Ollama emits `<think>...</think>` reasoning tokens *inline inside `content`* during tool-use responses. Trinity-Mini MLX writes the same content to a separate `reasoning` field, leaving `content`/`tool_calls` clean. Bench validated in `~/explore/local-coding-models/refs/AB-verdict-v2.md` (Trinity Ollama scored 14/20 vs Trinity MLX 17/20, with reasoning-format failures the dominant cost).

**Rule:** if an action requires structured output (tool calls, JSON, format-strict response):
- Trinity MLX: OK
- Trinity Ollama: BANNED
- Qwen3-Coder MLX: preferred (14/15 reasoning, 35 tps)
- Laguna Ollama: OK (14/15 reasoning, format-clean)

If you have a deployment where only Ollama is available, use **Laguna** for tool-use, not Trinity.

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

## G9 — `mlx_lm.server` upstream has no tool-use parser

Stock `mlx_lm.server` returns tool calls as **free-text inside `content`** (e.g. `<tool_call>read_file{...}</tool_call>`), not as structured `tool_calls[]`.

The `cubist38/mlx-openai-server` fork adds proper tool-use parsing. If your agent needs structured tool calls from MLX, pin to the fork.

**Verify** before assuming: `curl <mlx-server>/v1/chat/completions` with a `tools` array and check whether the response has `choices[0].message.tool_calls` or just `content` with tool-call-shaped text.

(Scrutinize finding from Epic A; applies to all epics routing through MLX with tool-use.)

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
