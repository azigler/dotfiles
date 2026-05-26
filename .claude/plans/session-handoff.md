# Session handoff — 2026-05-26 beb8609d (local-coding-models multi-wave research arc + /research skill landed)

## State at offboard
- **Current branch**: main (dotfiles), main (explore + blightmud), master (autonovel)
- **Last commit (dotfiles)**: `a600201 :zap: cost-tracking: cost = inference only (input + output); cache excluded`
- **Open beads**: 9 dotfiles + 20 explore + 7 blightmud + 6 autonovel = 42 total
- **In-flight subagents**: none (Wave 8 research all returned, Wave 9 bench done)
- **In-flight on pico**: llama-swap on :8090, mlx_lm.server on :8081, Ollama serve on :11434, Ollama backend serving deepseek-r1:14b (loaded warm)
- **Dirty files**: `beads_report_dotfiles_2026-05-25.md` (untracked, ignorable)
- **Markers**: no `.offboard-pending`

## What happened this session (~9-hour autonomous research arc)

### Skills shipped (most durable artifact)
- **`/research` global skill** at `~/.claude/skills/research/` — SKILL.md + 8 reference files codifying the orchestrator research harness pattern (frame → pre-flight → dispatch → verify → scrutinize → fold → layer → loop). Distinct from `/explore` (goals + iterate vs compile + publish). User feedback incorporated: mandatory scrutinize step, cost-tracking onboarding ask, "research tree not single report" framing.
- **`/cost-tracking` revised** — cost now = INFERENCE only (input + output × standard rates). Cache infra tracked as reference counters but excluded from cost total. Matches "raw API call" intent.
- **`~/dotfiles/local-models/`** toolkit: GUARDRAILS.md (G1-G15 + H1), `trinity_shim.py`, `qwen_sampler.py`, `healthcheck.sh`

### Research outputs (11 reports archived in `~/explore/local-coding-models/refs/research/`)
- `research-mlx-repetition.md` — G13 fix (repetition_penalty body param)
- `research-ccr-subagent-routing.md` — G12 fix (CCR `<CCR-SUBAGENT-MODEL>` tag in body.system[1])
- `research-trinity-toolcalls.md` — G1 fix (hermes-shim pattern)
- `research-laguna-mlx.md` — G7 workaround path (Blaizzy's branch)
- `research-mlx-unload.md` — G14 workaround (llama-swap)
- `research-pidev-tools.md` — pi.dev gap nuance
- `research-hermes-vs-pidev.md` — substrate decision (Hermes)
- `research-hermes-primer.md` — Hermes plugin/skill/session conventions + 4 live upstream bugs
- `research-autonovel-on-hermes.md` — bd-b5p Phase-by-Phase migration map
- `research-writing-harness-landscape.md` — NousResearch/autonovel ancestry discovered
- `research-hermes-plugin-deepdive.md` — empirical plugin authoring walkthrough
- `research-hermes-pidev-plugin-ecosystem.md` — 0-day gaps for our .13/.15

### Empirical infrastructure
- **CCR (claude-code-router) installed** at zig, smoke-verified end-to-end (Anthropic Messages → CCR → pico Qwen3 → "PONG")
- **Hermes Agent installed** at `/home/ubuntu/explore/hermes-agent-trial/.venv/` + `~/.hermes/`. Empirically verified Hermes + Qwen3 Ollama tool-use works end-to-end. `hello-world-observability` plugin enabled as permanent canary at `~/.hermes/plugins/`.
- **llama-swap installed** on pico:8090 (G14 solved — TTL-eviction working, 4 models registered, model-swap smoke verified)
- **DeepSeek-Coder-V2-Lite pulled via Ollama** + benched: **17/20 standard suite pass (85%), 0 errors, median 44 tps** — ties Qwen3-Coder MLX. MLX path blocked per G15 (MoE arch unsupported).
- **DeepSeek-R1:14b pulled** + benched: 6/20 (30%), 1 error — reasoning models exceed test max_tokens budgets; bench design doesn't suit them.

### Spec / plan deliverables
- **bd-b5p.4** — Phase 1 spec for Hermes-autonovel migration (D2 pivot): 1 cron + 1 skill + 1 delegate; 7 acceptance tests; 6 OQs; exit criteria defined
- **explore-7hh.20** — llama-swap client migration plan (3 phases, per-phase rollback)
- **bd-b5p.2** — autonovel-on-Hermes architecture map (Phase 0 gap audit)
- **bd-b5p.3** — writing-harness landscape; NousResearch/autonovel discovered as user's ancestor pipeline

### Cross-cutting
- **explore-7hh epic RESCOPED** from "fix pi.dev" to "ship Hermes Agent" — 8 legacy sub-beads closed as superseded, 9 new sub-beads opened
- **dotfiles-5e2** — deferred-decisions bead with D1-D12 open architectural questions
- **`~/explore/refs/cross-epic-overlap-2026-05-25.md`** — canonical shared reference, updated with post-research-sweep findings
- **Pico hung mlx server** (4h+ wedged on DeepSeek load attempt) — fixed via `launchctl kickstart -k gui/501/com.zig.mlx`

## What's next (priority order for next session)

1. **Wave 9 remaining**: D10 Laguna mlx-lm branch test (`pip install git+https://github.com/Blaizzy/mlx-lm.git@pc/add-lg` in isolated venv on pico), GLM revisit (3-bit only, confirm still 17.5 tps), DeepSeek-V2-Lite prose probe (one autonovel-style continuation to position in routing pool), AB-verdict-v2 matrix update (add DeepSeek rows, R1:14b note)
2. **User-blocked items waiting** (Task list #36/#43/#44):
   - #36 — pico disk cleanup go/no-go (`/tmp/pico-cleanup-2026-05-25.md` sent; ~73 GB safe-reclaim)
   - #43 — Epic C E1 manual research dry-run (needs user-picked seed topic)
   - #44 — Epic B E2 authenticated CoD check (needs character credentials)
3. **bd-b5p.4 Phase 1 implementation** — ready for `/test` or `/impl` waves when user OKs (~1 week of work). Hermes Agent installed; skill authoring template proven via `~/.hermes/plugins/hello-world-observability/`.
4. **explore-7hh.13/.14/.15 plugin work** — pico-mlx + pico-ollama provider plugins (two profiles per primer §7.3), heartbeat-skill mirror, beads observability. All have ecosystem-context cross-refs already folded into bead descriptions.
5. **D11 Hermes upstream bug tracking** — #32239 cron auth propagation, #32220 subagent costs, #32217 SSRF, #32236/.35 cron skills scoping. Check status periodically.

## Warnings / watch-outs

- **llama-swap on :8090 is alternate, not replacement.** Existing launchctl `com.zig.mlx.plist` keeps mlx_lm.server on :8081 alive. Don't decommission :8081 until Phase 3 of explore-7hh.20 migration plan (multiple production clients on :8090 first).
- **DeepSeek-R1:14b is NOT a drop-in replacement for V2-Lite.** R1 is reasoning-tuned (much longer outputs), fails our coding-eval suite's max_tokens budgets. If autonovel ever wants reasoning models, design separate eval.
- **Hermes Agent canary plugin** at `~/.hermes/plugins/hello-world-observability/` is intentionally left enabled — every Hermes session fires its 4 hooks and appends to `~/.hermes/logs/hello-world-observability.log` as a stack-alive signal. Do NOT remove.
- **`/dispatch` skill enhancement (D1)** for local routing via CCR tag is documented but NOT implemented per user direction (deferred). When ready: ~10 LOC change to inject `<CCR-SUBAGENT-MODEL>` tag conditionally.
- **Cost-tracking model revised mid-session.** New cost number is inference-only (~$676 for this 9hr arc). With-cache-infra reference is ~$5663. Future `/offboard` rows use the new (lower, more accurate "actual work") number.
- **Healthcheck-before-action discipline now codified as H1.** Run `~/dotfiles/local-models/healthcheck.sh` before any local-model work — past failure mode (4+ hour wedged mlx_lm.server) won't repeat.
- **Pico disk: 333 GB used / 926 GB total (36%).** Plenty of room. ~73 GB safe-reclaim available pending user OK.
- **Bead-location discipline** (per user feedback): cd to target repo before `br create/update/commit`. Research dispatches with `general-purpose` agents stay no-commit; orchestrator handles bead updates after agent returns.
- **NousResearch/autonovel is the ANCESTOR** of user's autonovel (PR #2 from erhnysr/master in git log). Shared 5-layer architecture (voice/world/characters/outline/canon) + evaluate.py slop_score core. NOT Hermes-based; uses direct Anthropic API. Pattern-mining value preserved.

## /onboard should pick up

- Read this handoff note first (you're doing that now)
- Read GUARDRAILS.md G1-G15 + H1 to internalize the cross-arc invariants
- Read `~/explore/refs/cross-epic-overlap-2026-05-25.md` for the 5-epic cross-fold state
- Check `dotfiles-5e2` (deferred decisions) for any user replies on D6/D8/D9 that unblock work
- Check `br list --status open` across all 4 repos for the 42 open beads
- If continuing autonomous: `/research` skill body has the full workflow; scrutinize step (3.5) is MANDATORY
