# Session handoff — 2026-05-31 beb8609d (post-compaction; ~36h elapsed wall)

Session id: `beb8609d-14f4-46ce-875f-977f61012bec`

## State at offboard

- **Branch**: main (dotfiles)
- **Last commit (dotfiles)**: `296135b :bug: harness: CCR-completion probe + systemic-failure-detect (advisory)`
- **Last commit (explore)**: `3877bbd :card_file_box: beads: file rw2 (matrix v2 entirely failed; harness missed it)`
- **Last commit (autonovel)**: `93d3514 :sparkles: phase2-worker SKILL: pre-flight pico_lock check (bd-ct8)`
- **Open beads**: dotfiles 3 (ukx.6, 5e2, cl8); autonovel 0 ready; local-coding-models 7 (3p4 study, b17→e21 superseded, yev/rtk/wkw harness follow-ups, ezu+u3y+rw2 + matrix v8k record + b17 migration record)
- **In-flight subagents**: none
- **Dirty**: 4 untracked archive directories + 9 HEALTHCHECK_FAIL markers in results/ + `.claude/worktrees/` shell + 1 pre-existing `beads_report_dotfiles_2026-05-25.md` (all transient; not committed by design)
- **`.offboard-pending` marker**: present at session start (from prior session-end hook); cleared by this offboard
- **Matrix process**: DEAD (cleanly; ran to completion ~21h; data turned out to be 270 garbage trials — see below)
- **Hermes gateway**: still running (PID inherited from earlier session)
- **Autonovel Phase 2 cron**: paused. Phase 1 cron paused (since bd-ju5 fix). `t_41f4bb8f` on autonovel-writer board still BLOCKED (workspace-orient patch landed but never runtime-verified due to CCR issue).
- **CCR (port 3456)**: ⚠ GET / responds with version, POST /v1/chat/completions HANGS. Was broken throughout matrix v2. Status now unclear; needs reboot/restart + investigation.
- **pico**: backends running (ollama + mlx fresh-restarted yesterday); pico itself healthy by ps + memory but CCR-to-pico path broken.

## What happened this session — the candid story

### Three big wins
1. **Hermes work-with-the-substrate codified** — Phase A (caps in `~/.hermes/config.yaml`) + Phase B (autonovel-writer per-workload board) + Phase C-lite (stripped the kanban-touching watchdog probe). Canonical kanban-worker SKILL.md template drafted by tabula-rasa subagent, shared canon reviewed cross-arc with weekly-reporting (Wave 20 ADDENDUM agreed and folded). autonovel-phase2-worker SKILL rewritten Rule-6 docs-style + workspace-orient patch.
2. **Bead-location-discipline corrections** — user caught 3 misplaced beads (m4z, b17, cho all in dotfiles when they belonged in autonovel + local-coding-models). Migrated, initialized `~/explore/local-coding-models/.beads/`, sharpened the memory file. Convention now: dotfiles = infrastructure/orchestrator only.
3. **Harness arc** (the main meta-work) — three pieces of mechanism replacing three "remember to do X" memories:
   - `lib/safe_remote.sh` — `safe_pkill_remote` verifies absence after kill, retries once, fails loudly. **Caught the 7-orphan-`ollama runner` wedge that wasted ~6h of debugging.**
   - `analyze-variance.py` — cross-trial + cross-scenario outlier detection. Smoke-tested against real V1 data, caught contamination.
   - `lib/pico_lock.sh` — exclusive-access lock file convention. matrix acquires + traps release; autonovel-phase2-worker SKILL.md gates on it.

### The one big loss
- **Matrix V2 (Phase 3) was 21h of garbage.** All 270 trials returned the same CCR 500 error. No model ever did real work. My variance harness reported "no anomalies" because uniform failure clusters perfectly — variance alone cannot distinguish uniform success from uniform failure.
- Caught it just in time by validating Tier 1 (analyze-bench.py PASS/FAIL) BEFORE dispatching a Tier 2 quality subagent. Subagent would have produced an elaborate analysis of CCR error messages.
- **Healthcheck layer-mismatch was the proximate cause**: healthcheck probed Ollama directly at pico:11434 (always healthy), bench runs through CCR at zig:3456 (broken). Different code paths; only one was checked.
- V1 (the run before this session, archived) ALSO has the same issue: file edits happened (real work) but "DONE" ack errored on the final claude turn — so Tier 1 says FAIL even though work was done. Useful as a partial signal but not as a clean comparison.

### What this taught us about the harness
The user's framing landed hard mid-session: **memories are weak; mechanisms are stronger; harnesses are best.** My initial response was a memory file (the anti-pattern). User called it out. I rebuilt as three actual code mechanisms. The harness then caught its OWN silent-success bugs during smoke-test (analyze-variance regex matched 6 of 30 files; pico_lock same-owner refresh skipped PID check; my own test ran a real matrix call parallel to the live one). Mechanisms validated themselves — but ALSO have remaining gaps (the absolute-PASS-rate check is the missing fourth habit).

## What's next (priority order for the next session)

1. **Diagnose + fix CCR.** It's wedged on the POST path right now. Restart it (`ccr restart` or kill + restart). Verify with `curl -X POST http://127.0.0.1:3456/v1/chat/completions -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"ok"}],"max_tokens":5}'` returns a real completion within ~30s. **The new healthcheck.sh CCR-completion probe will catch any future occurrence at H1 — but this current wedge predates that fix.**
2. **Re-run Phase 3 matrix from clean state.** Confirm healthcheck passes (now includes the CCR completion probe). Use the v2 code which has cross-backend eviction + pico_lock. Expect ~24h.
3. **Wire absolute-PASS-rate into the harness** (the missing 4th habit). Integrate analyze-bench.py Tier 1 into analyze-variance.py — after each cohort, assert Tier 1 PASS rate > N%. If <N%, flag as systemic failure. Closes the rw2 acceptance criterion.
4. **Loosen the "DONE in final output" Pass criterion** OR add a CCR-error retry on the final ack turn. The current strictness penalizes legitimate work whenever CCR errors on the last turn.
5. **Then and only then**: dispatch Tier 2 quality analysis subagent + put on researcher cap to answer "which model wins for coding agent + which model wins as a fine-tune base."
6. **Runtime-verify the autonovel Phase 2 SKILL** — unblock `t_41f4bb8f`, re-enqueue, watch it complete on autonovel-writer board. Depends on (1) — CCR must work.

## Warnings / watch-outs

- **Do NOT trust the variance harness alone** — it validated 270 garbage trials this session. Always cross-check with analyze-bench.py Tier 1 before concluding anything from a matrix run.
- **Matrix v1 results in `~/dotfiles/claude/sandbox/results-archive-phase3-v1/`** are partial-signal (real file edits but missing DONE acks). Useful as a sanity check for which scenarios + candidates produced ANY work, NOT as a clean comparison.
- **Matrix v2 results in `~/dotfiles/claude/sandbox/results-archive-phase3v2-failed-ccr-500/`** are GARBAGE. Do not analyze them; only useful as a reference for the "what 270 identical-failure trials look like" pattern.
- **`/tmp/pico-busy.lock`** may or may not be released — if the matrix's trap fired, it's gone. If next session sees `pico_check: BUSY` from an old PID, the lock is stale + safe to ignore (or `rm /tmp/pico-busy.lock`).
- **`.claude/worktrees/`** has leftover dispatched-worktree state from the bd-b2p + b2p-workspace-fix subagents. Both subagents already merged + closed; cleanup safe via `git worktree list` + `git worktree remove --force --force`.
- **Hermes gateway** still running from earlier session (~36h uptime). Check FDs for `(deleted)` stale before next matrix run; restart if needed.
- **autonovel Phase 1 cron is paused** but bd-ju5 was fixed + verified. Resume with `hermes cron resume f63079296927` once you're ready for daily fanfic drafts (which will fail until CCR + pico are both healthy + the autonovel-phase2-worker pico_lock check is runtime-verified).
- **autonovel Phase 2 cron is paused** intentionally — keep paused until step (1)+(6) above are done.
- **My memory files** (`feedback_silent_success_pattern.md`, `feedback_tabula_rasa_cross_arc_convergence.md`, `feedback_bead_location_discipline.md`) all landed this session — `/onboard` next time will see them.

## Cross-arc state

- **weekly-reporting agent**: aligned on Wave 20 ADDENDUM (testing/eval pattern). Reading from the same shared canon (`refs/research-hermes-conformance.md`, `research-hermes-kanban-worker-canonical-template.md`). No outstanding coordination items.
- **autonovel project**: 3 beads closed this session (bd-ju5, bd-b2p, bd-ct8). Phase 2 worker SKILL is now docs-style + workspace-oriented + pico_lock-aware, but never run successfully end-to-end. The runtime verification is the unblock condition.

## Commits this session (rough summary)

- dotfiles: ~15 commits — Phase A+B+C-lite, healthcheck timeout, eviction fixes, harness pieces (safe_remote, analyze-variance, pico_lock + autonovel-side gate)
- explore: ~8 commits — bead migrations, canonical template, Wave 20 ADDENDUM fold, harness follow-up beads
- autonovel: ~5 commits — bd-ju5 (Phase 1 cron path), bd-b2p (SKILL rewrite + workspace patch), bd-ct8 (pico_lock pre-flight)
- weekly-reporting: 1 commit — Wave 20 ADDENDUM sibling reply

## What /onboard should pick up

1. Read this handoff first
2. Read the latest `feedback_silent_success_pattern.md` and `feedback_tabula_rasa_cross_arc_convergence.md` memories — both are this session's lessons
3. `curl -fsS -X POST http://127.0.0.1:3456/v1/chat/completions ...` to verify CCR is OK before any matrix work
4. If healthy, `bash ~/dotfiles/local-models/healthcheck.sh` to confirm the new CCR probe passes
5. Then: kick off Phase 3 matrix v3 (now with the new harness checks)
6. While matrix runs: think about how to integrate analyze-bench Tier 1 into the variance harness so the 270-trial-garbage scenario CANNOT happen again

---

# 2026-06-06 cleanup pass (post-Hermes-uninstall)

Major cleanup since the May 31 handoff above. The user is in cleanup mode
preparing for refactor week.

## State at end of this cleanup window

- **Branch**: main (dotfiles); last commit on main `3c1ab2f :broom: gitconfig: use bare 'gh' for credential helper`
- **Open beads (dotfiles)**: 1 (`dotfiles-5e2` — living deferred-decisions backlog; KEEP OPEN). Was 3 (ukx epic, cl8, 5e2) before this triage.
- **Deferred beads**: 4 (ukx.10 chat-template upstream bug, cl8 Mistral envelope parser, st2 tailscale-ssh nerdfonts, 406 zig-zone tailnet)
- **In-flight subagents**: none (this triage subagent is the last one)
- **Worktrees**: only main + this triage agent. No orphan worktrees.

## What got cleaned

1. **Hermes fully uninstalled** (~275 MB reclaimed on pico). Autonovel-as-Hermes substrate path ABANDONED. Successor TBD — no current candidate. `dotfiles-5e2` D2/D3/D11/D12 are now MOOT (tracked in bead's notes section).
2. **Pico disk reclaim**: 218 GB reclaimed (`dotfiles-5e2` D6 RESOLVED). Sweep of `~/glm-flat`, `~/trinity-gguf`, and other superseded model weights.
3. **Tailnet ports cleaned**: 9119/8765/8766 closed (related to Hermes + autonovel handoff endpoints that no longer exist).
4. **Session matrix arc fully wound down**: all matrix v2-related beads closed or deferred. The harness pieces (`safe_pkill_remote`, `analyze-variance.py`, `pico_lock.sh`, plus the May 31 absolute-PASS-rate Tier 1 check) stayed shipped — they remain useful even though we're not running matrix v3 right now.
5. **CCR pinned to 1.0.73** (`dotfiles-g03` closed). v2.0.0 has a routing regression that bit the matrix arc. Any future CCR upgrade should re-validate the per-scenario routing before promotion.
6. **reef git reconnected to github** (cross-arc fix from this cleanup window — not in dotfiles tree directly).
7. **Misc dotfiles polish** (the recent `:broom:` run): gitconfig credential-helper, zsh/tmux portability fixes, gpg.program moved to local include, VSCode extension swap, cursor/tmux color pinning.

## Triage pass 2026-06-06 (this subagent)

- **`dotfiles-ukx` epic CLOSED (force).** All AC sub-beads .1-.5 satisfied (CCR installed, routing config shipped, test suite via Phase 3 bench, headless via systemd nightly-digest, README dotfiles snapshot). `.10` left DEFERRED (upstream isolation bug); production routes around it via llama-swap per G16. Closure rationale in bead `--notes` (TRIAGE 2026-06-06 section).
- **`dotfiles-cl8` DEFERRED to 2027-01-01.** Bead's own description says "DEFERRED — investigate before filing upstream"; Mistral-envelope parser is upstream-blocked + Devstral was nice-to-have anyway. Production tool-tier path is Qwen3-Coder via llama-swap; no current need.
- **`dotfiles-5e2` KEEPING OPEN.** Living-list of D1 (/dispatch --local), D4 (CCR sampler-defaults transformer), D5 (Trinity shim — now moot tag), D7-D9 (awaiting-user items), D10 (RESOLVED). The Hermes-related items (D2/D3/D11/D12) flagged MOOT in `--notes`. Bead remains the canonical place to log new deferred decisions.
- **Orphan check**: only 5e2 (intentional living-list reference).
- **Stale check (14 days)**: 0.
- **In-progress**: 0 (clean — no zombies).

## Skill drift (informational; do NOT auto-sync)

Global (`~/.claude/skills/`) vs canonical (`~/linearb/skills/.claude/skills/`):

- **DRIFT**: `cost-tracking`, `dispatch`, `orchestrator`, `talk`
- **MISSING in canonical**: `research` (exists only globally)

Per `/distribute` workflow these get reconciled separately — flagged here for the user's next distribution pass.

## Memory + handoff state

- `MEMORY.md` index matches the 7 feedback files in the project memory dir (verified).
- This handoff is the freshest available; next `/onboard` should read everything BELOW the `2026-06-06 cleanup pass` separator and treat the matrix-v2 narrative above as historical.

## What's next (revised, post-cleanup)

The "Phase 3 matrix" was the May 31 plan; that arc is fully wound down now. The next session is **refactor week**:

1. Consume the `/scrutinize` fleet's reports on (a) the matrix-v2-was-garbage arc, (b) the Hermes-as-autonovel arc — both being studied by parallel scrutinize subagents per the user's plan
2. Decide autonovel substrate (no current candidate; not Hermes, not custom pi.dev, not heartbeat)
3. Triage `dotfiles-5e2` D1 (/dispatch --local flag) — small, scoped, autonomous-OK when ready
4. Decide if/when to revisit Phase 3 bench with v3 harness now that pico is clean

## Watch-outs

- **Don't run `bv` bare** — it opens an interactive TUI that blocks the agent loop. Use `bv --robot-next` etc.
- **CCR remains pinned at 1.0.73**. Any `npm update -g` could silently break routing.
- **`refs/` is not a dotfiles convention** — skip the housekeeping refs/INDEX.md step for this repo.
- **`dotfiles-5e2` is a deliberately-open living list**, not an orphan to clean. Don't close it in the next triage.
