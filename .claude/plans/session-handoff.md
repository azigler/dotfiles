# Session handoff — 2026-06-06 beb8609d (matrix-wind-down + Hermes uninstall + scrutiny)

Session id: `beb8609d-14f4-46ce-875f-977f61012bec`

This session ran from **2026-05-31 through 2026-06-06** across multiple wall-clock days, spanning two attempted Phase 3 matrix runs (both bombed), Hermes substrate uninstall, complete pico inference factory-reset, scrutiny dispatch with 4 reports + synthesis, and 10 memory-rule entries codifying the lessons.

## State at offboard

- **Branch**: main (dotfiles)
- **Last commit (dotfiles)**: `fb58461 :card_file_box: beads: close 5e2`
- **Last commit (explore)**: `8e48705 :card_file_box: beads: receive cl8 + ukx.10`
- **Last commit (autonovel)**: `29a6f79 :card_file_box: beads: close bd-b5p tree + file bd-fqi (substrate-free)`
- **Last commit (weekly-reporting)**: `41f00ad :broom: deprecate Hermes pivot — defer 3 beads`
- **Last commit (reef)**: `210bde3 :sparkles: granola+macwhisper — 3 weeks of payloads/transcripts`
- **Open beads (dotfiles)**: 2 (st2 + 406 — both P3 deferred, intentional)
- **In-flight subagents**: none
- **Dirty files**: pre-existing intentional carry-overs only — autonovel keeps cron drafts; explore has 1 untracked local-coding-models/.gitignore
- **`.offboard-pending` marker**: cleared by this offboard
- **`.claude/worktrees/`**: empty (no orphan worktrees anywhere)
- **Hermes**: fully uninstalled (services off + disabled + unit files removed, `~/.hermes` + venv deleted, ~275 MB reclaimed)
- **Pico inference**: **factory reset** — binaries present (ollama, llama-swap, mlx_lm.server), zero models, zero state, zero configs, zero processes. Ready for clean-slate re-attempt.
- **Pico disk**: 63 GB / 8% used (**329 GB freed across the session** — 392 → 63)
- **Zig disk**: 135 GB / 47% used (15 GB freed)
- **CCR**: pinned at 1.0.73 (v2.0.0 has routing regression; see closed `dotfiles-g03`)
- **Tailnet exposure**: only standard ports (22/80/443/7575/1212/44880). All Hermes/matrix/showcase ports closed.

## What happened this session

### Matrix arc (the cause of this whole session)
1. **v2 matrix** (2026-05-31, ran 21h): 270 trials all CCR-500 garbage. Root causes: CCR misrouting to anthropic (Router.background not firing), unset `ANTHROPIC_API_KEY` (literal `$ANTHROPIC_API_KEY` sent as bearer → 401s), llama-swap dead the whole run. Variance check passed because failures clustered perfectly.
2. **v3 + v4** (2026-06-01): aborted after 1-2 cohorts. Surfaced multiple bugs: CCR 2.0.0 routing regression → downgrade to 1.0.73 → `dotfiles-g03`; claude-local routing collapse → patch `--model provider,model` direct → `local-coding-models-8ti`; MLX cohort-transition eviction race → trust llama-swap; Tier 1 PASS-rate parser bug → patch `analyze-bench.py`; MiniCPM4.1 added as candidate #10.
3. **Scrutiny re-read** (2026-06-06): the "10% PASS for trinity + qwen3" was **fake** — 47/60 v3+v4 trials were ConnectionRefused, mislabeled `verdict_tag=OK` by `run-scenario.sh` on exit 1 (silent-success in the harness itself). All 6 actual passes were scenario 01. AB-verdict-v2.md (2026-05-26) already named Qwen3-Coder-30B as winner — we were chasing a verdict we already had.

### Hermes arc (full uninstall)
1. bd-b5p.5.7 (Hermes confabulates fake success) was the kill signal we ignored; should have closed Hermes at Wave 7, not Wave 19.
2. Patterns 1→5 all presupposed `parent_agent`; Pattern 6 (kanban-worker) emerged from Wave 19 tabula-rasa.
3. Phase 1 "PASS" was sidestep validation — runner.py bypassed Hermes entirely. Phase 2 broke on first real load-bearing call.
4. **Full uninstall**: services stopped+disabled+unit files removed, `~/.hermes/` deleted, `~/explore/hermes-agent-trial/` deleted.
5. **bd-b5p tree closed (7 beads)** with rationale; **bd-fqi epic filed** (substrate-free: systemd-timer + bash + runner.py).
6. **Weekly-reporting deprecation**: 3 beads deferred (dsn/cg0/6ju), CLAUDE.md deprecation section added. No active processes (Hermes-managed crons died with uninstall).
7. **autonovel drafts audit**: PROBABLE GENUINE — runner.py uses direct Ollama HTTP, never goes through Hermes terminal_tool path; confabulation bug doesn't apply.

### Cleanup wave (4 parallel subagents → merged + pushed)
dotfiles · explore parent · autonovel · local-coding-models — triage + housekeeping.

### Scrutiny wave (4 parallel read-only subagents → 4 reports + synthesis)
`/tmp/scrutiny-{matrix-arc,hermes-arc,research-loop,beads-usage}.md` + `/tmp/scrutiny-synthesis-2026-06-06.md` (~9k words analysis).

### Memory entries filed (10 new, indexed in MEMORY.md)
substrate-kill-criterion · pattern-N-means-substrate-wrong · silent-fabrication-disqualifying · sidestep-is-not-validation · skill-body-is-what-not-how · harness-must-not-grow-faster-than-trust · strict-pass-rate-first · refresh-the-canon · defer-needs-trigger · substrate-uninstall-protocol

### Other accomplishments
- **Pico reef reconnected to github** (`.git/` was missing from initial copy; added via ssh:// URL form + per-repo gh-credential helper override). Pushed 3 weeks of granola payloads + transcripts.
- **Dotfiles pulled on zig + pico** (synced to `fb58461`).
- **`gh` auth on pico** (user-action + dotfiles helper override at `/opt/homebrew/bin/gh`).
- **zig-watchdog disabled** (was watching dead jobs).
- **Bead surgery**: `dotfiles-cl8` + `dotfiles-ukx.10` → `local-coding-models-f19` + `local-coding-models-470` (bead-location-discipline; mlx-server bugs belong in the lcm project). `dotfiles-5e2` closed (living-reference bead; future arch decisions go in refs/ or get spec beads).
- **/tmp orphans** cleaned (bench-* logs, dashboard log, kimi-llama-swap-entry.yaml, etc.).
- **Failed unit `hermes-gateway.service`** reset-failed.
- **Disk reclaim**: zig (Docker prune ~12 GB + npm/bun caches ~7 GB = 15 GB), pico (218 GB on first pass + 111 GB on factory-reset pass = **329 GB freed**).
- **Reef remote URL standardized on pico** to `git@github.com:azigler/reef.git` (matches other machines; goes through `insteadOf` rewrite → HTTPS → absolute-path gh helper for pico's non-interactive ssh path).

## What's next

Per the scrutiny synthesis (`/tmp/scrutiny-synthesis-2026-06-06.md`), refactor week starts here:

1. **Decide on the next local-models attempt**:
   - (a) Close the arc entirely — AB-verdict-v2.md is the standing verdict; no v5 needed.
   - (b) Do a 50-LOC, no-CCR, 15-trial probe of scenario 03 against qwen3-coder direct via llama-swap. If it passes, decide if v5 is worth building. If not, model story closed.
2. **autonovel forward**: `bd-fqi` epic captures the substrate-free direction. Re-spec Phase 2 features as substrate-free if/when pain motivates.
3. **Skill edits per S3 + S4**:
   - `/research`: add Step 4.5 "Refresh the canon" + tabula-rasa pivot trigger + dud audit + orchestrator-as-researcher framing.
   - `/beads` + `/triage`: defer-requires-trigger, AC enforcement on `-t impl` close, kill `--design` field OR evangelize it (0/277 usage), demote dead `-t note`, require descriptions on epic children.
4. **Harness work**: replace `bench-matrix.sh` with a tiny strict-by-default probe OR remove harness entirely. Wire `run-scenario.sh` exit-1 → `verdict_tag=FAIL` (the silent-success in the harness itself).
5. **Lessons codified**: the 10 memory entries are indexed. Use them.

## Warnings / watch-outs

- **The 60 captured trinity + qwen3 trials are NOT model-capability data**. They're 47 dead-CCR replays + 6 scenario-01 passes. Do NOT cite as comparative model evidence; AB-verdict-v2.md (2026-05-26) is the standing source of truth.
- **CCR is pinned at 1.0.73**. Do NOT `npm install @musistudio/claude-code-router` (latest) until v2.x is verified.
- **Pico is a clean slate** — first inference request will trigger long cold-loads (model re-download from HF for MLX, fresh `ollama pull` for Ollama). Budget accordingly.
- **Pico reef shows "214 deletions"** in `git status` — those are files pico doesn't have by design (pico is webhook forwarder; zig is canonical storage). Do NOT `git add -u` on pico reef.
- **Stash on pico's ~/dotfiles**: `stash@{0}: pre-pull-2026-06-06: pico-local mac configs (bash/zsh/ssh/git)`. Preserved in case user wants pico-local customizations back.
- **The dotfiles `[include]` ordering** is a known per-machine-override breaker. Per-repo overrides (like reef's gh-helper one on pico) are the workaround. Long-term fix: move `[include]` line in `dotfiles/git/.gitconfig` to AFTER the credential block.
- **autonovel's `write/runs/phase1-smoke/draft-*.md`** is now gitignored — 13 existing drafts kept on disk per user choice; future cron drafts won't pollute git status.
- **`/tmp/scrutiny-*.md` + `/tmp/drafts-audit.md` + `/tmp/weekly-reporting-survey.md`** kept in /tmp for refactor-week reference. Not durable past reboot — copy if needed.
- **Skill drift flagged** (per cleanup subagent S1): global vs canonical drifted for cost-tracking, dispatch, orchestrator, talk. `research` skill exists globally only. User owns reconciliation via `/distribute`.
