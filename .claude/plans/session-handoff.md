# Session handoff — 2026-05-28 (Wave 17-19, ~6h session)

Session id: `beb8609d-14f4-46ce-875f-977f61012bec`

## State at offboard

- **Current branch**: main (dotfiles)
- **Last commit (dotfiles)**: `107ac0d :bug: zig-watchdog: count crashes since last unblock (not lifetime counter)`
- **Last commit (explore submodule)**: `8411bf3 :memo: refs: Hermes conformance canon Wave 18-19 addendum + companion research`
- **Last commit (linearb/weekly-reporting)**: `6188014 :link: refs: symlink shared Hermes conformance canon from local-coding-models`
- **Open beads (dotfiles)**: 11 — 2 new P2 bugs from this session (cho, ns3), 5 existing ukx series, 4 deferred
- **In-flight subagents at offboard**: none (all returned)
- **Markers**: `.offboard-pending` will be cleared by this offboard
- **Hermes gateway**: active (PID 3199445, 3+ hours uptime, but 3 stale `(deleted)` FDs visible — see Wave 19 architectural finding)
- **zig-watchdog timer**: **STOPPED** intentionally (to avoid recreating the write-contention race; redesign as Hermes plugin pending — see Phase C)
- **bench-dashboard SPA**: live at `http://100.98.174.21:8765/` with trial-detail modal (Wave 18 ship)
- **smoke matrix**: 8 of 9 cells completed (more on this below)
- **Phase 2 substrate** (`autonovel-writer` profile + kanban worker): broken; t_7663dee2 blocked; SKILL exec-step bug → `dotfiles-cho`

## What happened this session — Waves 17, 18, 19

### Wave 17 (bench-dashboard SPA + zig-watchdog v1)

- **bench-dashboard SPA SHIPPED** (`60bbc98`, bead `dotfiles-vgb`): tailnet-private Python stdlib-only server at `http://100.98.174.21:8765/`. Parses `/tmp/bench-matrix-smoke-*.log` + `claude/sandbox/results/*.md` filesystem state. JSON state + healthz endpoints + auto-refresh HTML dashboard with log tail panel. 13/13 tests; /scrutinize SHIP zero findings.
- **zig-watchdog v1 SHIPPED** (`bc4de46`, bead `dotfiles-olh`): single Python file + systemd-user timer (5min). Four job classes (BenchMatrix / HfDownload / HermesGateway / BenchDashboard) with probe()+revive(). Extended SPA with `/api/alerts.json` + `/api/watchdog-state.json` + browser Notifications API. 37/37 tests across both files; /scrutinize SHIP zero critical, 3 minor noted.
- **Kimi-Linear pull complete**: was hung in CLOSE_WAIT 8h; killed + restarted; 20 GB landed on pico (5/5 files).
- **Watchdog empirically self-validated**: when my own `pgrep` collision killed the dashboard, the next 5min tick auto-revived it (alerts.json entry is proof).

### Wave 18 (skill-resolver fix + watchdog M2 + cke + trial-detail modal)

- **Hermes `--skills` resolver root cause IDENTIFIED** via novel-research subagent (clean POC from docs): skill exists in BOTH `external_dirs` AND profile-local → `tools/skills_tool.py:1011-1033` refuses to guess → `success=False` → CLI shows misleading "Unknown skill(s)". Fix applied via `rm -rf` of 3 dup skill dirs from profile-local + default-home. External_dirs stays as SSoT. Backup at `/tmp/hermes-skill-backup-20260528T044221Z/`.
- **Dashboard per-trial detail modal SHIPPED** (`da0e277`, bead `dotfiles-a1y`): click any non-queued cell → modal with prompt sent / Claude output / sandbox state / model routing evidence / flagged log excerpt. New `/api/trial/<id>` endpoint (JSON + `?raw=1` text/plain + 404). 9 new tests, 26/26 dashboard tests total. /scrutinize SHIP zero findings.
- **zig-watchdog M2 + Documentation= fixes** (`ac61672`, bead `dotfiles-hpi`): HermesGateway probe now returns OK when only blocked-task crashes exist (was perpetual CRASH); systemd unit Documentation= URL fixed (no more "Invalid URL" warnings). 21/21 tests.
- **zig-watchdog "count crashes since unblock" fix** (`107ac0d`, bead `dotfiles-cke`): watchdog had killed a working Phase 2 retry based on stale lifetime crash counter. Fix parses task event log via new helper `_count_crashes_since_last_unblock(show_text)`. 25/25 tests. Live-verified: HermesGateway=OK with t_360fa078 still blocked.

### Wave 19 (kanban DB corruption + architectural diagnosis + canon update)

- **kanban DB corrupted ~04:53 UTC**: "sqlite refused to open file: database disk image is malformed". Hermes auto-created 6+ `.corrupt.bak` files in 30 sec; `.recover` yielded SCHEMA only (0 INSERTs). All task history lost (t_360fa078, t_2d3dcc3e, t_093c0add). Recovered via fresh `hermes kanban init`.
- **Architectural-fit research subagent** returned with structural diagnosis at `~/explore/local-coding-models/refs/research/research-hermes-architectural-fit.md`: our harness fights WAL's design contract. Hermes ships single-writer dispatcher; we layered 4 extra writers (watchdog CLI fan-out, cron enqueue, ad-hoc CLI, worker spawn-crash cycles). WAL = 1 writer + many readers; we routinely run 4-6 short-lived writers. Live evidence: gateway PID 3199445 holds 8 FDs on kanban.db, 3 labeled `(deleted)` — the corruption-prone state.
- **Recommended structural fix**: Options 1+2+4 (in-process Hermes plugin instead of systemd-timer CLI fan-out + per-workload board partition + concurrency caps `max_in_progress: 3 / max_spawn: 2`). All authorized by user; NONE applied yet (deferred to next session).
- **Hermes canon updated** (`8411bf3` on explore submodule): research-hermes-conformance.md extended with Wave 18-19 ADDENDUM §A-E (six failures, WAL contract, 7 architectural rules, proto-skill caveats, cross-arc alignment). Companion docs `research-hermes-architectural-fit.md` + `research-hermes-skills-novel.md` canonized into refs/research/.
- **Cross-arc symlink shipped** (`6188014` on weekly-reporting): `~/linearb/weekly-reporting/refs/` now has INDEX.md + symlinks to all 3 conformance docs + the autonovel-phase2-worker proto-skill bundle. Sibling agent reads same canon — no more parallel re-derivation.
- **Phase 2 SKILL exec-step bug filed** (`dotfiles-cho`, P2): worker calls `kanban_show()` ✓ then `exec(import sys ...)` → truncated traceback → LLM retries → 30min wall → killed → re-spawn → same. The autonovel-phase2-worker SKILL.md's procedural-recipe pattern is the anti-pattern; canon §C Rule 6 codifies this.
- **Smoke matrix corruption-write-contention bug filed** (`dotfiles-ns3`, P2): proposed F1 (filelock OR read-only sqlite OR plugin) / F2 (rolling daily snapshot) / F3 (operational discipline) defenses.

### Smoke matrix — 8 of 9 candidates COMPLETED (this is huge)

While the Hermes Phase 2 work was thrashing, the bench matrix quietly ran 9 candidates on scenario 01-trivial-rename. Results at `claude/sandbox/results/01-trivial-rename-*-trial1-*.md`:

| Candidate | Wall time | Verdict |
|---|---|---|
| trinity-mini (initial) | 685s | OK |
| trinity-mini (resumed) | 690s | OK |
| qwen3-coder MLX (initial) | 705s | OK |
| qwen3-coder MLX (resumed) | 704s | OK |
| qwen3-coder-ollama | 722s | OK |
| devstral MLX | 738s | OK |
| deepseek-coder-v2-lite-ollama | 740s | OK |
| glm-4.5-air 3-bit MLX | 744s | OK |
| deepseek-r1-14b ollama | 764s | OK |
| laguna-xs2 ollama | 826s | OK |
| **kimi-linear MLX** | **1200s** | **TIMEOUT** (hit 20min cap) |

**This is the first real parity data we have.** 8 of 9 candidates can do scenario-01 trivial-rename. Kimi-Linear hit the cap — could be slow first-load OR genuinely heavier than the 20m budget. Range is 685s–826s for the working set (1.21× spread). Opus baseline was ~12s, so we're at ~55-70× multiplier — fails the hypothesis of <10× as a starting point.

**The dashboard's trial-detail modal is the right surface to validate these.** Click each cell at `http://100.98.174.21:8765/` to see the actual prompt + Claude output + sandbox state.

## What's next (priority order)

1. **Click through smoke matrix results in the dashboard** (~10-15 min). Validate which candidates actually did the task correctly (verdict=OK is grep-based Tier 1; real quality check needs human eye on outputs). This is THE user-facing payoff of the dashboard shipped today.
2. **Apply Phase A architectural caps** (5 min inline): edit `~/.hermes/config.yaml` to add `kanban.max_in_progress: 3` + `kanban.max_spawn: 2`. Restart gateway (this flushes the 3 stale `(deleted)` FDs visible right now — required hygiene).
3. **Apply Phase B per-workload board partition** (30 min): `hermes kanban boards create autonovel-writer`. Update `~/.hermes/scripts/enqueue-autonovel-phase2.sh` to set `HERMES_KANBAN_BOARD=autonovel-writer`. Future tasks on isolated DB.
4. **Phase C — port zig-watchdog to a Hermes plugin** (~1 day, dispatch subagent): `~/.hermes/plugins/zig-watchdog/__init__.py` with `on_session_start` daemon thread inside the gateway process. Shares FDs. Zero new opener processes. Delete the systemd timer once plugin is proven. Recommended template: `~/.hermes/plugins/heartbeat/__init__.py`.
5. **Fix the autonovel-phase2-worker SKILL** (`dotfiles-cho`): SKILL.md is written as procedural recipe ("then call exec(...) then call delegate_task..."). Replace with documentation-style (what the worker DOES) + let `KANBAN_GUIDANCE` (auto-injected at `agent/prompt_builder.py:188-257`) drive the lifecycle. Or: convert Phase 2 to deterministic `--no-agent --script` like Phase 1 (the autonovel use case may not need an LLM at all).
6. **Run ukx.13 Phase 3 full matrix** (~100h): 9 candidates × 10 scenarios × 3 trials. Smoke proved 8/9 candidates work at all on scenario 01. Now go wide.
7. **File Hermes upstream issue**: `unblock_task` should inject a synthetic `reclaimed` marker so `_rule_repeated_crashes` resets. Would have prevented the entire bd-cke scramble.

## Warnings / watch-outs

- **Hermes gateway has 3 stale `(deleted)` FDs on kanban.db RIGHT NOW**. Restart on next session to flush (pair with Phase A config edit).
- **zig-watchdog timer is STOPPED**. Re-enabling without Phase A caps + the plugin-port redesign will likely re-corrupt kanban.db within hours. If you must restart it, do `max_in_progress`/`max_spawn` caps first.
- **Phase 2 substrate is BROKEN** end-to-end. Phase 1 (`--no-agent --script`) still works autonomously and proved overnight. The autonovel cron at 21:00 UTC will fail with the SKILL bug (`dotfiles-cho`) — either fix the SKILL OR pause the cron via `hermes cron pause 1aefcbda7c1d` until fixed.
- **Six failures pattern** documented in Wave 18-19 ADDENDUM §A of the conformance ref. The sibling agent (weekly-reporting) has been notified via symlinked refs/. Read it before building any new Hermes worker on this stack.
- **Skill backup at `/tmp/hermes-skill-backup-20260528T044221Z/`** (6 tgz files). Can restore the deleted profile-local skills via `tar xzf` if the external_dirs SSoT model needs reversion. Cleanup at end of week if all working.
- **`.offboard-pending` marker** existed at session start (from prior session-end hook). Cleared in Step 5 of this offboard.
- **Smoke matrix RESULT files are untracked** in dotfiles. They're not in .gitignore but conventionally aren't committed (transient bench data). The HEALTHCHECK_FAIL marker from the aborted run is also there. Leave or clean up next session.
- **Beads `weekly-reporting-dsn` + `weekly-reporting-cg0` need re-check** against new canon Rule 1 (no systemd-timer watchdogs) + Rule 2 (per-workload board). Sibling agent now has the symlinked refs to do this.

## /onboard should pick up
- Read this handoff first
- Read `~/explore/local-coding-models/refs/research/research-hermes-conformance.md` Wave 18-19 ADDENDUM (§A-E)
- Check smoke matrix results via the dashboard (`http://100.98.174.21:8765/`)
- Decide on Phases A/B/C application order (user pre-authorized all three; restart of gateway loses the in-flight worker which is currently blocked anyway)
- `br ready` for action-eligible work across 4 repos (dotfiles, explore, autonovel, linearb/weekly-reporting)
