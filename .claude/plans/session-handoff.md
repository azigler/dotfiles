# Session handoff — 2026-05-25 beb8609d (LCM re-bench arc + SD on-demand + next-arc planning)

## State at offboard (refreshed after planning round)
- **Current branch**: main (dotfiles); main (explore)
- **Last commit (dotfiles)**: `8aae5fe :card_file_box: offboard: 2026-05-25 LCM re-bench arc + SD permanently on-demand`
- **Last commit (explore)**: `6d4ec62 :card_file_box: beads: open 3 epics + sub-beads for next-arc planning`
- **Open beads (explore)**: 17 — three active epics + sub-beads. Detail below.
- **Open beads (dotfiles)**: 0 in scope (st2/406 still deferred)
- **In-flight subagents**: none
- **Dirty files**: none

## What happened this session

### Two arcs LANDED, one arc PLANNED.

#### Arc 1 (LANDED): SD-WebUI permanent on-demand
Dotfiles change: `a1111/com.zig.a1111.plist` is now `RunAtLoad=false`, `KeepAlive` removed. `sd-up` / `sd-down` helpers installed to /usr/local/bin. User confirmed do NOT re-enable on offboard. Deployed to pico.

#### Arc 2 (LANDED): Local-coding-models methodical re-bench (`explore-4te`)
All 5 candidates re-benched under clean memory, cross-suite reasoning matrix run, GLM 3-bit shipped as alternative to hardware-marginal 4-bit. Synthesis in `~/explore/local-coding-models/refs/AB-verdict-v2.md`. 12 bench result files + per-model training-data doc + reasoning suite (`trinity-eval-prompts.md`) + extended runner (`run-eval.py` with DSL).

**Headline verdicts:**
- Daily-driver: **Qwen3-Coder MLX** (17/20 + 14/15 reasoning @ 35 tps)
- Long-context: **Laguna Ollama** (only model passing 100K) + ties Qwen at 14/15 reasoning
- GLM: **use 3-bit, not 4-bit** (17.5 tps usable vs 0.6 tps unusable)
- Trinity: **MLX over Ollama** for tool-use (`<think>` field handling differs)

#### Arc 3 (PLANNED): Three new epics covering user's three goals

Research from 4 parallel agents (Claude Code + local models, pi.dev, Cleft of Dimensions, background-agent patterns). Synthesized into:

##### Epic A: `explore-sak` — Claude Code wired to local models
**Goal**: use local models for background tasks + long-running work in Claude Code (where token cost matters).

**Decision**: `github.com/musistudio/claude-code-router` is the proxy (NPM-installable, translates Anthropic Messages API ↔ OpenAI-compat, supports per-scenario routing rules). Native `ANTHROPIC_BASE_URL` needs Anthropic-format endpoint which mlx_lm.server/Ollama don't provide.

Sub-beads:
- `.1` (P2) install + smoke-test on zig (route 1 test to local Qwen)
- `.2` (P2) define + ship "use local for background" routing config (per-scenario rules)
- `.3` (P2) define test suite for "does local model in Claude Code actually work for background tasks"
- `.4` (P3) headless mode integration — `claude -p` from launchd, scheduled nightly summarization
- `.5` (P3) dotfiles snapshot — document the production posture

##### Epic B: `explore-yw9` — MUD agent for Cleft of Dimensions (rescoped from deferred)
**Goal**: 24/7 LLM-powered agent that plays CoD via blightmud (or pi.dev). User-stated first target.

**Hard gate**: email cleftofdimensions@gmail.com (or Discord https://discord.gg/cSqkpbu) for bot policy clarity. Wiki/FAQ don't address it.

**Architecture (per research)**:
- Inference: Trinity Mini (52 tps, fast impulse layer) + Qwen3-Coder (instruction-following for command output). Both already on pico.
- Harness: **try pi.dev first** (built-in state mgmt + tool-calling). Fallback: Blightmud + external Rust daemon (read MUD output → call LLM → write commands via named pipe).
- Latency budget: 1-2 sec per agent decision. Combat tight; planning happens in safe rooms.

Sub-beads:
- `.1` (P1) email CoD staff re: bot policy — **GATE**
- `.2` (P2) manual character creation + 2h play log
- `.3` (P2) pi.dev evaluation as MUD-agent harness
- `.4` (P2) prototype mapper for CoD

More sub-beads (.5-.9) sketched in the bead body for: combat loop, persistence, fine-tuning, 24-hour autonomous run, design lessons writeup.

##### Epic C: `explore-nfc` — 24/7 scientific research agent on local models
**Goal**: long-running (8+ hour) research arcs on user-chosen topics, leveraging "tokens are free when owning the model."

**Harness options**:
- Heartbeat router (autonovel pattern, JSON disk state)
- pi.dev (Earendil, MIT-licensed, built for this shape)
- LangGraph (heavier, used in linearb agent-dev-interrupted)

Sub-beads:
- `.1` (P2) choose first research topic (user-driven) + acceptance criteria
- `.2` (P2) harness decision — heartbeat-pattern vs pi.dev vs LangGraph
- `.3` (P2) prototype 8-hour research run (single topic, persistence-tested)
- `.4` (P3) domain-specific fine-tuning evaluation (depends on `explore-4te.9`)

### Cross-cutting: Phase 2 fine-tuning (`explore-4te.9`)
Pre-existing bead, now load-bearing for both Epic B (MUD-agent fine-tune) and Epic C (research-agent fine-tune). Should unblock once Epic A's foundations land.

## What's next (user-recommended path)

**Start with Epic A** — `explore-sak.1` install + smoke claude-code-router. That's the foundation all three epics ultimately rest on. Without local-model integration into Claude Code, the harness story for Epics B + C is more fragmented.

**Then Epic C** — `explore-nfc.1` pick a research topic. User has explicit interest in scientific research as a primary use case; once Claude Code can route to local models cheaply, this is the natural extension.

**Then Epic B** — `explore-yw9.1` email CoD staff (gated). User has stated this is the fun project, lower urgency than Epic A/C. The bot-policy gate may take days for a response.

Pre-existing carryover:
- **DeepSeek bench** (`explore-4te.13`) — candidate #6, license note (DeepSeek License, not Apache/MIT). Run after current arcs settle.
- **Task #36** (pico disk cleanup, ~90 GB potential reclaim) — discuss with user before deleting.

## Warnings / watch-outs

- **SD-WebUI stays permanently on-demand.** Per user explicit instruction. Don't re-enable LaunchAgent. `sd-up` / `sd-down` are the production controls.
- **GLM 4-bit weights superseded** by 3-bit at `~/glm-3bit/` on pico. `~/glm-flat/` 4-bit is dead weight; discuss cleanup with user.
- **`hf download` truncates `.incomplete` files on resume.** Use the curl-resume scripts (`~/local-coding-models/glm-resume-download.sh` and `~/local-coding-models/glm-3bit-resume-download.sh` on pico). Both robust.
- **Trinity Ollama vs Trinity MLX have different `<think>` behavior**: MLX uses separate `reasoning` field (clean for JSON parsers); Ollama embeds inline in `content` (breaks parsers). Always prefer Trinity MLX for tool-use agents.
- **Laguna MLX is BLOCKED** — `LagunaForCausalLM` not in mlx-lm 0.31.3. Laguna is Ollama-only locally until upstream adds support.
- **Memory hygiene discipline**: restart `mlx_lm.server` between models so only one is resident. GLM 4-bit needs ~50 GB headroom; GLM 3-bit needs ~30 GB.
- **CoD bot policy unknown** — don't build the MUD agent's automation pieces past prototype before getting an answer from staff. Email is the hard gate.
- **Pico disk: 286/926 GB used** — lots of headroom but Task #36 cleanup discussion pending before next big downloads.

## Files written during planning round
- `~/explore/.beads/issues.jsonl` — three new epics + sub-beads (committed in `6d4ec62`)
- This handoff note (updated)

## Files referenced
- `~/explore/local-coding-models/refs/AB-verdict-v2.md` — synthesis of bench arc
- `~/explore/local-coding-models/refs/models-training-data.md` — per-model training data + licenses
- `~/dotfiles/a1111/{README.md, com.zig.a1111.plist, sd-up, sd-down}` — SD on-demand
