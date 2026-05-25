# Session handoff — 2026-05-25 beb8609d (LCM re-bench → 4-epic next-arc plan with /check passes complete)

## State at offboard
- **Current branch**: main (dotfiles, explore, blightmud); master (autonovel)
- **Last commits**:
  - dotfiles: `892b083 :card_file_box: beads: /check pass on dotfiles-ukx.6`
  - explore: `afe830d :card_file_box: explore: bump submodule pointers`
  - blightmud: `7413201 :card_file_box: beads: /check pass on blightmud-hgi.5`
  - autonovel: `75d7cbc :card_file_box: beads: /check pass on bd-b5p.1`
- **Open beads (dotfiles)**: dotfiles-ukx epic + 6 sub-beads (.1-.6). 2 deferred (st2/406).
- **Open beads (explore)**: explore-nfc epic + sub-beads .1-.5. explore-4te.9 (fine-tuning) + .13 (DeepSeek bench) pending.
- **Open beads (blightmud)**: blightmud-hgi epic + .2-.5. .1 closed (CoD bot approved).
- **Open beads (autonovel)**: bd-b5p epic + .1 (spec).
- **In-flight subagents**: none
- **Dirty files**: `beads_report_dotfiles_2026-05-25.md` (untracked)
- **Markers**: `.offboard-pending` not present

## What happened this session

### Three arcs delivered:

#### Arc 1 (LANDED): SD-WebUI permanent on-demand
`a1111/com.zig.a1111.plist` is `RunAtLoad=false`. `sd-up` / `sd-down` are production controls. Do NOT re-enable LaunchAgent.

#### Arc 2 (LANDED): Local-coding-models methodical re-bench (`explore-4te`)
5 candidates re-benched + reasoning matrix. Synthesis at `~/explore/local-coding-models/refs/AB-verdict-v2.md`. **Verdicts:**
- Daily-driver: **Qwen3-Coder MLX** (17/20 + 14/15 reasoning @ 35 tps)
- Long-context: **Laguna Ollama** (only model passing 100K) + 14/15 reasoning
- GLM: **3-bit (17.5 tps usable)**, not 4-bit (0.6 tps unusable)
- Trinity: **MLX over Ollama** (Ollama's `<think>` inline breaks JSON parsers)

#### Arc 3 (PLANNED + CHECKED): 4 epics + 4 specs + 4 adversarial /check passes
Bead-store discipline applied — each epic lives in the repo it belongs to:

##### Epic A: `dotfiles-ukx` (dotfiles repo) — Claude Code wired to local models
**Spec**: `dotfiles-ukx.6` + /check notes. **Decision**: claude-code-router proxy (Anthropic Messages ↔ OpenAI-compat). **Key /check findings:**
- Drop `Router.subagent` config key (not in CCR's documented surface); rely on `CLAUDE_CODE_SUBAGENT_MODEL` env var + `CUSTOM_ROUTER_PATH` as belt-and-suspenders
- Bump pico `OLLAMA_CONTEXT_LENGTH=65536` (Laguna passes 100K; 32K too conservative)
- Hard gate: `tooluse` transformer fidelity test must split into T4a/b/c (single Read, multi-line Edit, parallel Read+Bash)
- 15 tests → 20; 9 spec edits queued

##### Epic B: `blightmud-hgi` (blightmud submodule) — CoD MUD agent
**Spec**: `blightmud-hgi.5` + /check notes. **CoD bot activity is APPROVED** (user supervising closely). **Key /check findings:**
- **OQ-11 mis-rated LOW → should be HIGH**: daemon belongs on **ubuntu** (where blightmud + named pipe are), model calls go HTTP-LAN to pico. ssh-streaming the event pipe risks 100% data loss on tcp drop.
- Drop monolithic 3-run graduation streak → per-mode (combat / explore / social-NEVER / quest-last)
- Quest acceptance: verb whitelist not blacklist (matches §3 action-whitelist philosophy)
- Death push-notification must fire ≤10s; otherwise "halt-always" silently degrades to "stuck"

##### Epic C: `explore-nfc` (explore repo) — 24/7 scientific research agent (LSRA)
**Spec**: `explore-nfc.5` + /check notes. **Heartbeat pattern over pi.dev/LangGraph.** **Key /check findings:**
- **Selector starvation bug**: §4.2 row 4 CRITIQUE trigger as written never fires (no note flips below confidence 0.6 because synthesis writes null). Fix: `confidence is null OR < 0.6`
- **Saturation via Trinity self-judgment is wrong**: asking weakest reasoner (12/15) to arbitrate "novel" is backwards. Use Jaccard-shingle dedup
- **NEW OQ-13 (P1)**: model-residency policy across action types. Pico cliff at 30 GB weight-footprint; routing 4 models (Laguna 17 / Qwen 15 / Trinity 13 / GLM 44 GB) requires explicit eviction policy
- Broken-seed policy: log+skip, don't halt (fail-fast contradicts test #8)

##### Epic D: `bd-b5p` (autonovel submodule) — autonovel custom pi.dev harness
**Spec**: `bd-b5p.1` + /check notes. **Replaces Claude Code in-harness orchestrator with pi.dev.** **Key /check findings:**
- **HARD BLOCKER 1**: OQ-02 slop-eval was calibrated against Claude output. Promote test 6 to Phase-0 gate; if Qwen3 prose breaks correlation, build Qwen3-tells supplement bank before any 24h run. **#1 silent-failure risk** (drafts pass eval, readers smell AI)
- **HARD BLOCKER 2**: OQ-03 voice transfer. Mandate prompt-augmentation via `identity/few_shot_bank/` — style-transfer literature: smaller models need *demonstrations*, not *descriptions*
- **Drop Trinity-as-router**: routing-table is deterministic Python (per heartbeat/SKILL.md Step 3); LLM router wastes a call + adds non-determinism for zero benefit
- Phase 1 = local-only (no Claude Code hybrid); decouple from dotfiles-ukx launch risk

### Bead location discipline (now correct)
Earlier in session beads were sloppy — Claude Code + MUD epics placed in umbrella explore beads. User caught it. Migrated 9 beads to correct stores (folder children → umbrella, submodules → own beads, dotfiles only for true dotfiles work). Supersession trail preserved.

## What's next (recommended path — updated)

The 4 specs are spec'd + checked. Each has a **Spec updates needed** list (9 / 6 / 9 / 7 edits) ready for re-dispatch to `/spec` before `/test` waves.

**Recommended order:**

1. **Epic A first** (`dotfiles-ukx.6`) — Wave 1: verify before building. `ssh pico` to confirm OLLAMA_CONTEXT_LENGTH, dispatch one-off worktree subagent to probe `$CLAUDE_CODE_SUBAGENT_MODEL` propagation, read CCR source for `Router.subagent` support. These are 30-min checks that gate spec edits.

2. **Epic C in parallel** (`explore-nfc.5`) — resolve OQ-01 (selector trigger), OQ-13 (residency policy), then /test wave. Research agent has no external dependencies. User's stated primary use case.

3. **Epic B after Epic A's W3** (`blightmud-hgi.5`) — depends on tooluse transformer verdict (subagent dispatch model needs to handle JSON cleanly). Daemon-on-ubuntu means setup is independent of pico router stability.

4. **Epic D last** (`bd-b5p.1`) — depends on Phase-0 calibration pass (OQ-02). User has running autonovel today via Claude Code; pi.dev swap is enhancement not blocker.

Pre-existing carryover:
- **DeepSeek bench** (`explore-4te.13`) — candidate #6, run after current arcs settle
- **Task #36** (pico disk cleanup, ~90 GB potential reclaim: ~/glm-flat 56GB, ~/trinity-gguf 15GB, residual cache 2GB, Laguna mxfp4 unused 17GB) — discuss with user before deleting

## Warnings / watch-outs

- **SD-WebUI stays permanently on-demand.** Per user explicit instruction. Don't re-enable LaunchAgent.
- **CoD bot activity APPROVED** (user supervising closely). No gate.
- **Hosted APIs RULED OUT** for local-model work. User explicit: "do NOT use a hosted API."
- **GLM 4-bit weights superseded** by 3-bit at `~/glm-3bit/` on pico. Cleanup pending Task #36.
- **Memory hygiene**: restart `mlx_lm.server` between models. Don't bench concurrently.
- **`hf download` truncates `.incomplete`** on resume. Use curl-resume scripts on pico.
- **Trinity MLX > Trinity Ollama** for tool-use (Ollama's inline `<think>` breaks JSON parsers).
- **Laguna MLX BLOCKED** — `LagunaForCausalLM` not in mlx-lm 0.31.3. Ollama-only locally.
- **Long jobs go to log files** on target host (memory pattern saved): >5min jobs use nohup-to-log; tail on demand; never harness-tracked timeouts.
- **Bead location discipline**: folder children → umbrella, submodules → own beads, dotfiles only for true dotfiles work. Worktree subagents dispatched from target repo.

## Cross-cutting: Phase 2 fine-tuning (`explore-4te.9`)
Now load-bearing for Epic B (MUD-agent fine-tune) and Epic C (research-agent fine-tune). Should unblock once Epic A's foundation lands. Probably wave 7+.

## Files written / referenced
- `~/dotfiles/.beads/issues.jsonl` (dotfiles-ukx + sub-beads + .6 spec + /check notes)
- `~/explore/.beads/issues.jsonl` (explore-nfc + sub-beads + .5 spec + /check notes; explore-4te.9, .13)
- `~/explore/blightmud/.beads/issues.jsonl` (blightmud-hgi + sub-beads + .5 spec + /check notes)
- `~/explore/autonovel/.beads/issues.jsonl` (bd-b5p + .1 spec + /check notes)
- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — synthesis of bench arc
- `~/explore/local-coding-models/refs/models-training-data.md` — per-model training data + licenses
- `~/dotfiles/a1111/{README.md, com.zig.a1111.plist, sd-up, sd-down}` — SD on-demand
- `/tmp/spec-bodies/{dotfiles-ukx-6, explore-nfc-spec, blightmud-hgi-spec, autonovel-spec}.md` — spec bodies (also in bead --notes)
- `/tmp/check-notes/{dotfiles-ukx-6, explore-nfc-5, blightmud-hgi-5, bd-b5p-1}-check.md` — /check pass results (also in bead --notes)
