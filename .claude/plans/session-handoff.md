# Session handoff — 2026-05-25 beb8609d (LCM re-bench arc + SD on-demand)

## State at offboard
- **Current branch**: main (dotfiles); main (explore)
- **Last commit (dotfiles)**: `895723b :wrench: a1111: on-demand only — no auto-start (frees 17GB for LLM inference)`
- **Last commit (explore)**: `0d08ac4 :card_file_box: beads: explore-4te.13 stub for DeepSeek-Coder-V2-Lite (next session)`
- **Open beads (explore)**: 5 — epic, .1 (spec, intentional), .9 (finetuning parent), .13 (DeepSeek next-session), .yw9 (MUD deferred)
- **Open beads (dotfiles)**: 0 in scope this session (st2/406 still deferred)
- **In-flight subagents**: none (final benches all completed)
- **Dirty files**: none committed; submodule HEAD changes (blightmud, simon-willison) untouched (orthogonal)

## What happened this session

### Arc 1: SD-WebUI permanent on-demand (dotfiles shipped + deployed)
- Caught: SD-WebUI's 17 GB resident checkpoint was throttling MLX long-context inference (Qwen 50K/100K) AND blocking GLM-4.5-Air from loading at all
- `a1111/com.zig.a1111.plist`: `RunAtLoad=false`, removed `KeepAlive` (which was respawning SD on every kill)
- `a1111/sd-up` + `sd-down`: helpers installed to /usr/local/bin
- `mac.setup.sh`: install via `launchctl bootstrap` (registers without starting) + sudo install helpers
- `a1111/README.md`: posture + lifecycle rewritten
- **Deployed to pico**, LaunchAgent registered + not running. User confirmed: do NOT re-enable on offboard — stays permanently on-demand.

### Arc 2: Local-coding-models methodical re-bench (explore/local-coding-models)
- Re-benched ALL 5 candidates under clean memory (post-SD-disable)
- Cross-suite reasoning: ran Trinity's reasoning prompts on every candidate (apples-to-apples)
- Ollama-via-GGUF path for Trinity (custom Modelfile from arcee-ai/Trinity-Mini-GGUF)
- GLM-4.5-Air: 4-bit abandoned (hardware-marginal, 0.6 tps), 3-bit shipped as alternative (17.5 tps, USABLE)
- Synthesis: `refs/AB-verdict-v2.md` covers everything

**Key empirical findings:**
1. **Memory hygiene matters MOST for long-context.** SD-throttling killed Qwen 50K/100K (now pass), didn't affect short-prompt decode (architecture-bound). For GLM 4-bit it was the difference between can't-load and 0.6 tps.
2. **Qwen3-Coder MLX is the daily-driver winner** (17/20 + 14/15 reasoning @ 35 tps)
3. **Laguna Ollama is the long-context champion** (only model passing 100K) + ties Qwen at 14/15 reasoning
4. **Trinity's reasoning-model marketing doesn't beat Qwen + Laguna's instruction-following** on the reasoning suite. Format-strict tests (markdown fence required) penalize Trinity.
5. **GLM 3-bit IS the right quant for 64 GB** — 30× faster than 4-bit; ~1-3% quality cost is worth it
6. **Trinity MLX > Trinity Ollama for tool-use**: Ollama embeds `<think>` inline (breaks JSON parsers); MLX uses separate `reasoning` field (clean)
7. **mlx-lm has no LagunaForCausalLM adapter** — Poolside's claim of mlx-lm support is aspirational. Laguna is Ollama-only locally.

**Files written this session (in `~/explore/local-coding-models/refs/`):**
- `qwen3-coder-mlx-clean.md` (17/20 @ 35 tps)
- `qwen3-coder-mlx-custom.md` (14/15 @ 45.6 tps — beats Trinity)
- `devstral-mlx-clean.md` (17/20 @ 12.5 tps)
- `devstral-mlx-custom.md` (13/15 @ 13.6 tps)
- `trinity-mini-mlx-v2.md` (17/20 @ 50.6 tps — was SD-throttled)
- `trinity-mini-mlx-custom.md` (13/15 @ 52.6 tps — was SD-throttled)
- `trinity-mini-mlx-clean.md` (17/20 @ 52 tps — replaces v2)
- `trinity-mini-mlx-custom-clean.md` (12/15 @ 52.9 tps — non-determinism on P21)
- `trinity-mini-ollama.md` (14/20 @ 53 tps — <think> inline issues)
- `trinity-mini-ollama-custom.md` (11/15 @ 53.2 tps)
- `laguna-xs.2-ollama-clean.md` (16/20 @ 32.9 tps — long-context champion confirmed)
- `laguna-xs.2-ollama-custom.md` (14/15 @ 36 tps — ties Qwen)
- `glm-4.5-air-mlx.md` (4-bit hardware-marginal verdict)
- `glm-4.5-air-mlx-3bit.md` (3-bit subset 4/9 @ 17.5 tps — USABLE)
- `models-training-data.md` (per-model training data + license)
- `AB-verdict-v2.md` (synthesis covering all of the above)
- `trinity-eval-prompts.md` (15-prompt reasoning suite with DSL check directives)
- `run-eval.py` (extended with `--prompts <path>`, `--max-tokens-mult`, data-driven `**check**:` DSL)

## What's next

### Highest priority for next session
1. **Bead .13: DeepSeek-Coder-V2-Lite as candidate #6** — Laguna's own comparison peer. License is DeepSeek License (NOT Apache/MIT, usage-restricted) — flag for any commercial use consideration. Recommended targets: `mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit` + GGUF mirror. Bench standard + reasoning on both stacks.
2. **Task #36: pico disk cleanup discussion** with user. Items to discuss before deleting:
   - `~/glm-flat/` (56 GB) — 4-bit GLM, now superseded by 3-bit at `~/glm-3bit/` (44 GB). Likely safe to delete.
   - `~/trinity-gguf/` (15 GB) — Trinity GGUF source, redundant after Ollama imported it. Safe to delete.
   - `~/.cache/huggingface/hub/models--mlx-community--GLM-4.5-Air-4bit/` (2.1 GB residual) — leftover config files. Safe to delete.
   - `~/.cache/huggingface/hub/models--mlx-community--Laguna-XS.2-mxfp4/` (17 GB) — MLX-unavailable Laguna; could delete if confident mlx-lm won't add Laguna support.
   - Total reclaim potential: ~90 GB. Pico is at 286/926 GB; not urgent but tidy.

### Lower priority
3. **Trinity reasoning-suite re-run with `--max-tokens-mult 8` on GLM 3-bit** — would show GLM's true pass rate without budget pressure. Would likely match Trinity 17/20 quality.
4. **More permissive pass-checks** — extend DSL to check JSON validity / code parses, not markdown fence presence. Would re-rank Trinity favorably.
5. **Phase 2 fine-tuning (.9.x)** — Qwen3-Coder MLX is the LoRA validation primary candidate. See `refs/finetuning-toolchain.md`.

## Warnings / watch-outs

- **SD-WebUI stays permanently on-demand.** Per user explicit instruction. Don't re-enable LaunchAgent. User can `sd-up` when they want image gen, `sd-down` when done.
- **GLM 4-bit weights at `~/glm-flat/` are now superseded** by 3-bit at `~/glm-3bit/`. Don't reach for the 4-bit; it's hardware-marginal on 64 GB. Cleanup task #36 will discuss removal.
- **`hf download` truncates `.incomplete` files on resume** — never trust hf-cli for big multi-file downloads. Use the curl-resume scripts: `~/local-coding-models/glm-resume-download.sh` and `~/local-coding-models/glm-3bit-resume-download.sh` on pico. Both are robust (curl --continue-at per file, bash 5 from /opt/homebrew/bin).
- **Trinity Ollama vs Trinity MLX have different `<think>` behavior**: MLX uses separate `reasoning` field (clean for JSON parsers); Ollama embeds inline in `content` (breaks parsers). Always prefer Trinity MLX for tool-use agents.
- **Laguna MLX is BLOCKED** — `LagunaForCausalLM` not in mlx-lm 0.31.3, no PR open. Laguna is Ollama-only locally until upstream adds support.
- **Memory hygiene discipline**: restart `mlx_lm.server` between models so only one is resident. Restart Ollama if its `OLLAMA_KEEP_ALIVE=24h` keeps too many models warm. Empirical: GLM 4-bit fails to load even after SD-disable when other big MLX models are resident.
- **Pico disk: 286/926 GB used** — lots of headroom but task #36 disk cleanup discussion is pending before next big downloads.
