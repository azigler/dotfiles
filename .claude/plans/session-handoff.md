# Session handoff — 2026-05-26 181ac599 (Wave 9 closeout → Wave 15 ukx.12 fix → end-to-end local routing PROVEN)

## State at offboard
- **Current branch**: main (dotfiles + explore), master (autonovel)
- **Last commit (dotfiles)**: `5352f63 :white_check_mark: smoke: scenario 01 local run #2 (PASS w/ 2.5× variance vs run #1)`
- **Last commit (explore)**: `14e2c74 :arrow_up: autonovel: bump to 713c610 — bd-b5p.4 Phase 1 Hermes-autonovel smoke landed`
- **Last commit (autonovel)**: `713c610 :card_file_box: beads: close bd-b5p.4 — Phase 1 Hermes-autonovel smoke PASS`
- **Open beads**: 4 dotfiles + 20 explore + 6 autonovel = 30 total (all have descriptions per /beads discipline; audit-fixed mid-session)
- **In-flight subagents**: none (Wave 14A/B/C all closed and cleaned)
- **In-flight on pico**: llama-swap :8090 + mlx_lm.server :8081 + Ollama :11434 + CCR :3456 on zig (all healthy per last healthcheck)
- **Dirty files**: `beads_report_dotfiles_2026-05-25.md` (untracked, ignorable)
- **Markers**: `.offboard-pending` PRESENT (this offboard clears it)

## What happened this session (~10-hour autonomous research+impl arc)

### Wave 9-10 — model-front sweep closed
- D10 Laguna mlx-lm Blaizzy fork verified empirically on pico (G7 demoted BLOCKED → WORKAROUND-AVAILABLE)
- DeepSeek-V2-Lite full bench: 17/20 Ollama (ties Qwen3-Coder MLX); MLX path BLOCKED (G15)
- DeepSeek-R1:14b bench: 6/20 (bench shape wrong for reasoning models)
- GLM 3-bit revisit confirmed 17.5 tps within margin (44/49 GB Metal device warning)
- DeepSeek-V2-Lite prose probe: 59 tps, coherent literary continuation, VIABLE (N=1)
- AB-verdict v2.1 matrix updated with DeepSeek + R1 rows + license + arch tables

### Wave 11 — research-subagent returns
- `dotfiles-ukx.8` CCR Anthropic transformer source-read: SAFE WITH CAVEAT verdict, but recommended `transformer: { use: ["Anthropic"] }` on backends (WRONG; reversed Wave 15)
- `explore-nfc.6` LSRA fine-tuning landscape 2026 — task #43 Epic C E1 manual dry-run COMPLETED. Pilot: QLoRA on Qwen3-Coder via MLX-LM, ~30-60 min, ~25 GB RAM. "Unsloth on Mac" is marketing (actual = mlx-tune + shim). 8 red flags documented.

### Wave 12 — ukx.9 per-backend curl probe
- Empirical: llama-swap PASSES parallel tool calls; Ollama DEGRADES (drops 2nd call); mlx_lm.server :8081 direct REFUSES
- Created G16 + G17 (CCR-SUBAGENT-MODEL tag unreachable from `claude -p` — root caused to `system[1]` hard-coding)

### Wave 13 — G16 mechanism correction + Trinity unblock
- llama-swap source-read research FALSIFIED initial G16 hypothesis ("injects tool envelope" — wrong; llama-swap does no tool transformation)
- ACTUAL G16 mechanism: lazy-load `mlx_lm.server :8081` (no `--model` flag) silently fails to apply `chat_template.jinja` for tools; llama-swap's `--model X` preloaded instances avoid this. Two `mlx_lm.server` processes on pico verified.
- Trinity re-probe at 2000 max_tokens: emits 2 parallel `<tool_call>` XML blocks correctly. The Wave 5 `trinity_shim.py` is the parser. **Trinity moved from REFUSED → VIABLE-with-shim.**

### Wave 14A — CCR routing impl beads
- `ukx.2` CLOSED — CCR routing config + `dotfiles-ukx.6` §4.1 spec edits landed (commit `edf1964`)
- `ukx.3` CLOSED — smoke-test environment with 10 scenarios + `claude-local` wrapper + `run-scenario.sh` runner + 3-scenario smoke run (subagent commit `59c5023`)
- `ukx.4` CLOSED — `nightly-digest.sh` systemd unit with G17 transport pivot to direct curl (subagent commit `8202a2c`)
- `ukx.5` CLOSED — production-posture README at `claude-code-router/README.md` (subagent commit `a0c2fa1`)
- `ukx.10` DEFERRED — mlx-lm lazy-load chat-template bug; needs more isolation before filing upstream
- `ukx.11` CREATED — Devstral quant swap to `lmstudio-community/Devstral-Small-2507-MLX-4bit` (path b unblock per Wave 14 research)

### Wave 14B — Hermes plugins (cross-repo to explore)
- `7hh.13` CLOSED — pico-tailnet provider plugins: pico-mlx + pico-ollama + **pico-mlx-trinity-shim** (subagent split — `kind:model-provider` plugins don't get `register(ctx)` so hooks need separate plugin; commit `b6f4e38`)
- `7hh.14` CLOSED — heartbeat plugin with daemon thread + atomic state writes + pre_llm_call context injection; SKILL.md companion (commit `04d5213`)
- `7hh.15` CLOSED — beads observability plugin (0-day gap first-mover); ThreadPoolExecutor + atexit pattern from `nhranitzky/hermes_audit_db_plugin`; verified end-to-end with real bead (commit `5420d4f`)
- All cherry-picked into explore (pre-merge-worktree.sh hook is dotfiles-cwd-pinned; trips on cross-repo branches — use `git cherry-pick` per /orchestrator docs)

### Wave 14C — bd-b5p.4 Phase 1 Hermes-autonovel (cross-repo to autonovel)
- CLOSED — Phase 1 minimum-viable migration: skill + cron + runner + smoke-test (commit `a9f4338` in autonovel; submodule pointer bumped in explore via `14e2c74`)
- All 5 testable ACs PASS (T1-T4 + T6). T5/T7 properly delegated to operator.
- 3 OQs empirically answered (OQ-3 filesystem state, OQ-4 delivery channel = local, OQ-6 iteration_budget sufficient); 2 sidestepped for Phase 2 (OQ-1 + OQ-2 — need true delegate_task migration); 1 pending operator observation (OQ-5)
- `hermes cron create` argparse gotcha documented (flags must come BEFORE positional args)
- Sample evidence draft: `~/explore/autonovel/write/runs/phase1-smoke/draft-20260526T044832Z.md` (slop_penalty=0.0 on Karlach POV)

### Wave 15 — ukx.12 CCR transformer fix (THE LOAD-BEARING TURN)
- `ukx.12` CREATED + CLOSED. Smoke env (ukx.3) revealed that tool-using CC requests through CCR returned 404 with `'dict object' has no attribute 'parameters'` — a Jinja template error from mlx_lm.server.
- ROOT CAUSE: `transformer: { use: ["Anthropic"] }` on pico-* providers told CCR "this backend speaks Anthropic" → CCR converted Unified→Anthropic outgoing → mlx_lm.server got Anthropic-shape body with `input_schema` instead of `parameters`. Qwen3 chat template choked.
- FIX: REMOVED the `transformer` block. CCR's default `convertAnthropicToolsToUnified` (visible in cli.js bundle source) correctly produces `{type:function, function:{name, description, parameters}}` shape for OpenAI-compat backends.
- VERIFIED empirically: 2 parallel `tool_use` blocks (Edit + Bash) returned correctly via full pipeline (CCR → llama-swap → mlx_lm.server → Qwen3-Coder).
- Lesson captured in memory + G16 amendment: **source-read research is necessary but NOT sufficient — every load-bearing recommendation needs an empirical wire-test before production**. 2nd reversal this session (G16-original was 1st). The /research SKILL Step 3 (Verify) discipline is structural.

### First end-to-end local-route PASS in production
- After ukx.12 fix: scenario 01 (trivial rename) PASSED via full Claude Code → CCR → llama-swap → mlx pipeline
- 2 runs: 1479s (~25 min) and 3649s (~61 min) — 2.5× variance. Opus baseline: 12s. Slowdown 125-305× per run.
- The smoke environment can now produce real parity data. Phase 3 (10 scenarios × N trials × both backends) is the next-tier benchmark.

### Bead audit (mid-session user critique)
- User flagged 18 open beads with empty descriptions across dotfiles/explore/autonovel as violating /beads "broken handoff" rule.
- Audit-fixed all 18 with proper descriptions (cross-referencing GUARDRAILS + refs/research/ + commit hashes).
- Spot-checked against prior transcripts to confirm descriptions match original creation intent.
- Captured discipline as 2 new memory files:
  - `feedback_read_transcripts_before_guessing.md` — grep prior `~/.claude/projects/<slug>/*.jsonl` FIRST before reconstructing intent from title alone
  - `feedback_preserve_process_artifacts.md` — research record (REVERSED hypotheses, transcripts, bead lifecycle) is as load-bearing as final results; exemplar = `~/cfp/mise/`

## What's next (priority order for next session)

1. **`ukx.11` Devstral quant swap** — pull `lmstudio-community/Devstral-Small-2507-MLX-4bit` (13.3 GB) to pico, update llama-swap config to use it, re-run ukx.9 curl recipe to confirm tool-use unblocks Devstral. ~30-60 min.
2. **`ukx.3` Phase 3+4** — full benchmark: all 10 scenarios × Opus + local × multiple trials (run-to-run variance was 2.5× on a SINGLE scenario; need distribution). Phase 4 synthesis: parity matrix + fine-tune target hypotheses for ZIG-COMPUTER-FOCUSED fine-tune of Qwen3-Coder.
3. **`explore-7hh.16` LSRA-on-Hermes prototype** — can now consume the 3 plugins shipped Wave 14B (pico-tailnet + heartbeat + beads-observability) + bd-b5p.4's runner pattern. 
4. **`bd-b5p.4` Phase 2** — migrate runner to true `delegate_task` (answers OQ-1 + OQ-2), introduce voice-anchor injection via `few_shot_bank`, AO3 staging.
5. **User-blocked items waiting**:
   - `#36` pico disk cleanup go/no-go (referenced from prior session)
   - `#44` CoD (Cleft of Dimensions) credentials when ready
6. **Smoke env hardening (follow-up)**: `run-scenario.sh` had bg-process issues where some runs died silently (`bmkhqzwd7` produced result, `by5eo4np7` produced result, an interactive inline attempt died). Worth a brief pass to harden the runner.

## Warnings / watch-outs

- **CCR config `transformer` block REMOVED** — production config no longer matches what `ukx.5` README + prior research files documented. The G16 amendment captures the reversal; `ukx.5` README still has stale "use Anthropic transformer" guidance that should be amended in a future doc pass.
- **`~/.hermes/skills/autonovel-phase1-smoke`** is now a symlink to the merged-in path `/home/ubuntu/explore/autonovel/hermes-skills/autonovel-phase1-smoke/`. If autonovel ever moves or the link breaks, the cron job will fail. Verified working at session-end.
- **`~/.hermes/plugins/hello-world-observability/`** canary still enabled (intentional — every Hermes session fires its 4 hooks for stack-alive signal). Don't remove.
- **Smoke scenario 01 wall-time variance was 2.5×** (25 → 61 min). Single-shot numbers are not the parity benchmark — need N trials.
- **G16 routing rule + ukx.12 fix are inseparable** — must keep `transformer` block OUT of pico-* providers AND keep `pico-mlx` URL pointing at llama-swap :8090. If either drifts, tool-using local routing breaks again.
- **2 research-agent recommendations got reversed empirically this session** (G16-original mechanism + ukx.8 transformer config). Pattern is clear: source-read recommendations need empirical wire-tests before production. Discipline captured in memory.
- **Pico disk: ~40%** per last healthcheck. Plenty of room. ~73 GB safe-reclaim still available pending user OK on `#36`.
- **The autonovel master branch is now ahead of the explore submodule pointer's bumped state** — if you do `git submodule update` in explore, ensure the pointer matches what's committed.

## /onboard should pick up

- Read this handoff note first (you're doing that)
- Read `~/dotfiles/local-models/GUARDRAILS.md` — G1, G7, G12, G13, G14, G15, G16 (×3 sections w/ Wave 13/14/15 corrections), G17, H1
- Read `~/explore/local-coding-models/refs/research/` — 4 new research notes added this session: research-claude-p-ccr-tag-gap.md, research-ccr-tool-schema.md, research-ccr-tool-schema-followup.md, research-devstral-toolaware-quant.md, research-llama-swap-toolshim.md, research-local-finetuning-2026.md, research-deepseek-prose-probe.md
- Check `dotfiles-5e2` (deferred decisions) for any user replies on remaining D-series
- Check `br list --status open` across all 4 repos for the 30 open beads
- If continuing autonomous: `/research` skill body has the full workflow; scrutinize step (3.5) is MANDATORY — this session proved it (2 reversals saved us from propagating wrong mechanisms)
