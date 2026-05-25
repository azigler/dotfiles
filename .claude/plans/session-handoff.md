# Session handoff — 2026-05-25 local-coding-models autonomous queue

## State at offboard (refreshed)
- **Branch**: main, clean
- **Last commit** (dotfiles): `9eb2f0c :wrench: ollama: NUM_PARALLEL 2->1 + claude: enable push notif + remote-control startup`
  - prior: `01923ee` (first offboard), `d2a7954` (env tweaks), `92dab31` (mlx install)
- **Last commit** (explore): `64b15d5 :card_file_box: step-12: finetuning toolchain research + .9.1 sub-bead stub`
- **Open beads**: 4 in `~/explore/.beads/` (epic-4te + sub-beads); 0 in dotfiles
- **Beads ready**:
  - `explore-4te.1` (spec — stays open as historical reference; amended with empirical findings)
  - `explore-4te.5` (GLM-4.5-Air bench — blocked on download still in flight)
  - `explore-4te.9` (step #12 parent — open because .9.1 child is open)
  - `explore-4te.9.1` (Qwen3-Coder LoRA validation — stub for user-driven training experiment)
- **Active background work on pico**:
  - `hf download mlx-community/GLM-4.5-Air-4bit` (PID 5721 last check; may have new PID; cache was 14 GB / 57 GB target)
- **Active background work on zig**: none (all watchers expired or exited)
- **Hourly wake-up**: scheduled at 12:59 with prompt to continue queue

## What happened this session (the autonomous queue arc)

Drove the entire explore-4te.* arc from research → spec → 5-model A/B benchmark → synthesis → step-12 finetuning prep. **9 of 11 queue items closed.** Remaining: GLM bench (blocked on download), step #12 sub-bead (user-driven validation).

### Beads closed this session
- `.2` MLX install on pico — dotfiles/mlx/com.zig.mlx.plist, mac.setup.sh updated
- `.3` Qwen3-Coder A/B — MLX wins 17/20 vs Ollama 15/20 (commit 186ba74)
- `.4` Devstral A/B — Ollama wins 19/20 vs MLX 17/20; slow decode 12 tps (commit 09f0b8e)
- `.7` Laguna A/B — Ollama-only (MLX arch gap for `LagunaForCausalLM`); 16/20 + ONLY model to pass P18 (100K context) (commit 0ee8785)
- `.8` Trinity — MLX-only; 10/20 but fastest decode 50 tps; reasoning-mode crowds answers (commit 35cd1f1)
- `.6` synthesis — refs/AB-verdict.md cross-comparison + spec .1 amendment (commit 00d9adb)

### Empirical finding worth highlighting
**Spec .1 ORIGINALLY said Phase 1 should use Ollama. Empirical reversal: MLX wins for the primary daily-driver** (Qwen3-Coder-30B-A3B on MLX, not Ollama). Discovered the 30× per-call slowdown when both stacks held the same model in memory — methodology lesson now in spec notes. Final recommended stack:
- Daily-driver: **Qwen3-Coder-30B-A3B on MLX** (+ claude-code-router proxy)
- Reliability fallback: **Devstral on Ollama** (95% pass rate)
- Long-context tier: **Laguna XS.2 on Ollama** (only model passing 100K context)

### MUD-agent bookmark amended
`explore-yw9` deferred bead updated with Bonsai 8B dual-loop concept (impulse model paired with thinking model). Plus Laguna XS.2's success on long-context creates a natural candidate for the slow-loop thinking model too.

### Lessons captured to memory
- `feedback-bead-location-discipline.md` — folder children → umbrella beads
- `feedback-long-jobs-log-files.md` — nohup-to-log, tail on demand, never harness-tracked timeouts

### Methodology lessons learned this session (in refs/AB-verdict.md)
1. Never hold both stacks' copy of same model simultaneously → 30× slowdown
2. Architecture coverage is real (Laguna ⊄ MLX, GLM-4.5-Air ⊄ Ollama library)
3. **Auto-restart-on-hang watchers destroy progress** — hf-cli GCs .incomplete files on restart. Lost ~18 GB of GLM progress to this. Going forward: notify-only watchers; only kill if truly dead (no sockets + log silent 10+ min)
4. Reasoning models (Trinity) need bigger max_tokens budgets than our suite gives
5. Long-context performance is hardware-bound past 50K tokens regardless of stack

## What's next (on next wake or next session)

1. **GLM-4.5-Air download** — was at 14 GB / 57 GB; check progress, let it continue if alive + log fresh + cache growing; only kill if truly dead. When done: smoke test via `curl http://100.72.47.4:8081/v1/chat/completions` (might hit "Model type X not supported" like Laguna did). If supported, run `python3 ~/explore/local-coding-models/refs/run-eval.py --model placeholder --mlx-model mlx-community/GLM-4.5-Air-4bit --stacks=mlx --out glm-4.5-air-mlx.md`. Then close `.5` and amend `refs/AB-verdict.md` + `.6` notes.
2. **Spec amendment commit** — the .1 spec --notes amendment is in the JSONL but may not be reflected in any rendered doc yet. Consider whether to also amend `~/explore/local-coding-models/FINDINGS.md` with the empirical reversal.
3. **Step #12 sub-bead `.9.1`** is stub-only — actual fine-tune validation is a user-driven experiment (target ~2hr on M1 Max for 100-example QLoRA on Qwen3-Coder; toolchain doc in `refs/finetuning-toolchain.md`).

## Warnings / watch-outs

- **GLM download has been TROUBLE** — multiple stalls + kill+restart cycles cost ~18 GB of progress. Be very conservative about kills going forward. Read `refs/AB-verdict.md` methodology section before touching the GLM download.
- **Ollama and MLX both servers running on pico** — `com.zig.ollama` (11434) and `com.zig.mlx` (8081). Don't kill either; the bench runner needs both reachable. New LaunchAgents added this session: `dotfiles/mlx/com.zig.mlx.plist`.
- **Spec .1 env tweaks deployed** — Ollama plist now has `OLLAMA_CONTEXT_LENGTH=131072`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=2` (committed to dotfiles, deployed to pico).
- **MUD-agent (explore-yw9) is still deferred** — DO NOT START IT until user explicitly re-opens. The coding-models foundation is the prerequisite for that arc per the user's earlier direction.
- **Context was getting high at offboard** — be mindful of token budget when resuming. Synthesis writeup work was the heaviest context consumer.

## Hourly wake-up still scheduled
Next wake-up at 12:59 with prompt that includes "GLM is the only outstanding bench". On wake: check GLM state, run bench if downloaded, else re-schedule. Loop continues until queue fully closed.
