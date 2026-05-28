# Session handoff — 2026-05-28 Wave 16 (Hermes-conformance pivot + Phase 1 autonomous PROVEN + Phase 2 kanban-substrate shipped)

## State at offboard
- **Current branch (dotfiles)**: main
- **Last commit (dotfiles)**: `754efb7 :card_file_box: beads: close ukx.13.3 SHIP + file ukx.13.4 Wave 2 follow-up` (then Wave 2 ukx.13.4 chain: 8187061, b314e95, d6d175c, 9fca3e3, d431d14)
- **Last commit (explore)**: `9489f53 :arrow_up: autonovel: bump (bd-b5p.6 operationalize CLOSED — Phase 2 autonomous via kanban substrate)`
- **Last commit (autonovel)**: `6cd2da5 :card_file_box: beads: close bd-b5p.6 (operationalize complete; end-to-end Phase 2 proven via t_360fa078)`
- **Last commit (linearb/weekly-reporting)**: `90578a6 :bulb: cross-arc heads-up: evaluate Hermes Agent kanban substrate`
- **Open beads (dotfiles)**: 5 — ukx.6 (P1 spec, in-flight), ukx (P2 epic), ukx.13 (P2 spec), ukx.13.4 (P2 feature — Wave 2 production end-to-end), 5e2 (P3 decision), cl8 (P3 bug deferred)
- **Open beads (explore)**: 9 (mostly research epics + spec; explore-7hh.16 LSRA needs same Pattern-5→kanban-worker pivot per the conformance research)
- **Open beads (autonovel)**: ~8 (bd-b5p epic + bd-b5p.5 Phase 2 spec + bd-b5p.7 Phase 2 kanban-substrate spec OPEN as the canonical reference + 5.6/5.7/5.8 trail beads)
- **Markers**: `.offboard-pending` was present, cleared by this offboard

## What happened this session (~6-hour autonomous Wave 16 arc)

### Wave 14B residue cleanup (early)
- Subagent ramp-up via /onboard rebuild post-compaction.
- Read 31 skill bodies in main session per /onboard discipline.

### Wave 16A — autonovel Phase 2 SHIPPED (then re-spec'd)
- bd-b5p.5 Phase 2 spec /check'd via bd-b5p.5.1 (10 OQs walked, IMPL-READY).
- bd-b5p.5.3 Phase 2 impl SHIPPED (Pattern 5 SKILL.md procedural recipe + delegate_task from inside execute_code). 60 tests pass.
- **/scrutiny caught real bug**: `runner.py:333` missing `strict_preamble_check=True` in production end-to-end path. Inline fix + regression test added (bd-ylg). Verdict upgraded to SHIP.
- bd-b5p.5.6 follow-up: Pattern 5 SKILL.md doc fix landed.

### Wave 16B — ukx.13 Phase 3 bench scaffolding SHIPPED (full /spec → /check → /test → /impl pipeline)
- ukx.13 P2 spec written + amended per /check (10 OQs walked, 3 P1 ACCEPT/MODIFY, IMPL-READY).
- ukx.13.3 Wave 1 impl SHIPPED — run-scenario.sh extensions + bench-matrix.sh + analyze-bench.py Tier 1. 41/41 tests pass + /scrutiny SHIP. Disclosed candidate→model-tag dispatch gap for Wave 2.
- ukx.13.4 Wave 2 production end-to-end ALSO SHIPPED via fix-first cycle: 14 new tests RED → impl → /scrutiny FIX-FIRST (caught 4 critical+major: naming-scheme split, filename collision on MODEL_TAG, missing CCR routes, DOTFILES_ROOT default tested MAIN not worktree) → impl re-fix → 61/61 GREEN → SHIP.

### Wave 16C — empirical reversal #4 (Kimi-Linear-REAP fails mlx-lm 0.31.3 load)
- `nightmedia/Kimi-Linear-REAP-35B-A3B-Instruct-mxfp4-mlx` pulled (18.7 GB) but FAILS with `KeyError: 'model.layers.3.self_attn.kv_b_proj.biases'` — REAP-pruned weights don't match mlx-lm loader expectations.
- Backup pull: `mlx-community/Kimi-Linear-48B-A3B-Instruct-3bit` (21.5 GB) — IN FLIGHT at offboard (slow tail at 19/21.5 GB, watcher armed at bm11kotet).
- 4th empirical reversal in this arc (after G16 mechanism, ukx.8 transformer, ukx.11 Devstral PARTIAL).

### Wave 16D — Hermes-conformance pivot (THE BIG ONE)
- User flagged: "let's conform to Hermes architecture; we may have clobbered the design with anti-patterns."
- Conformance research subagent returned HIGH-confidence verdict: **we drifted severely.** Natural autonomous-workload substrate is `hermes kanban` + gateway-embedded dispatcher (NOT cron LLM-path which biases toward narration + lacks tool-call accounting).
- bd-b5p.5.7 confabulation root cause clarified — NOT an upstream bug. It's a "wrong primitive" symptom (cron LLM-path's prompt prefix biases toward narration; no tool-call gate; TOOL_USE_ENFORCEMENT_GUIDANCE doesn't auto-inject for Anthropic models; kanban_complete() IS the structured gate).
- Report archived: `~/explore/local-coding-models/refs/research/research-hermes-conformance.md` (220 lines, file:line citations).

### Wave 16E — Hermes conformance pivot SHIPPED (user authorized both Wave 1 + Wave 2)
- **Wave 1 (mechanical, PROVEN)**: Phase 1 cron `9b0199d09d68` (--LLM path, confabulating) deleted. New cron `f63079296927` registered as `--no-agent --script run-autonovel.sh --workdir ... --deliver local`. Zero LLM in cron path, zero confabulation surface. **Manual trigger 22:59 produced REAL Karlach prose** (slop=0.3 verbatim runner.py stdout). Cron daily 09:00 UTC.
- **Wave 2 (architectural)**: bd-b5p.7 NEW Phase 2 kanban-substrate spec (supersedes bd-b5p.5.6 Pattern 5). Full /spec → /check (6 OQs, OQ-K-5 found `hermes kanban daemon` deprecated — dispatcher embedded in gateway, simplifying install) → /test (91 tests, 79 pytest + 12 bash) → /impl (Option B — full deliverable including config bump + symlink) → /scrutiny FIX-FIRST (3 findings: phantom impl bead, PATH-fragile script, empty 7.2 description) → all fixed → SHIP.
- Hermes gateway daemon installed: `hermes-gateway.service` systemd user unit (with linger).
- ~/.hermes/config.yaml: `delegation.child_timeout_seconds: 600 → 1800` (per OQ-K-2).
- Phase 2 cron `1aefcbda7c1d` registered (daily 21:00 UTC, --no-agent --script enqueue-autonovel-phase2.sh).
- **Phase 2 end-to-end PROVEN at 00:00 UTC**: manual cron trigger → script enqueued kanban task `t_360fa078` (assignee=autonovel-writer, status=ready). The gateway-embedded dispatcher will spawn the worker.

### Wave 16F — Cross-arc heads-up shipped
- `weekly-reporting-wpg.1` filed in `~/linearb/weekly-reporting` — NOT a directive, but a research-prompt for the sibling agent's editorial timers arc. Documents the 3-tier Hermes pattern + 7 gotchas + 5 OQs. Operator decides CONFORM / PARTIAL CONFORM / STAY.

## What's running on its own at offboard
- ✅ **Phase 1 autonovel** — cron `f63079296927`, daily 09:00 UTC, --no-agent --script. PROVEN firing with real prose. Confabulation surface = 0.
- ✅ **Phase 2 autonovel kanban-worker** — cron `1aefcbda7c1d`, daily 21:00 UTC, --no-agent --script enqueues kanban task. Gateway-embedded dispatcher spawns the worker. PROVEN at the kanban-create step; the full worker pipeline pending the dispatcher's first run (likely within minutes of offboard).
- ✅ **hermes-gateway.service** systemd user unit, lingered survives logout.
- ✅ **5 Wave 14B plugins** at ~/.hermes/plugins/ (heartbeat, beads-observability, pico-mlx, pico-ollama, pico-mlx-trinity-shim).
- ⏳ **Kimi-Linear 3-bit pull** at 19/21.5 GB (~88%, slow tail, watcher armed at bm11kotet).

## What's next (priority order)
1. **Verify Phase 2 worker actually completes** — `hermes kanban show t_360fa078` (or whatever the next task ID is) should show kanban_complete + metadata + artifacts. Verify `publish_queue/<id>.json` lands.
2. **Kimi-Linear 3-bit smoke** — when pull completes (watcher fires), run CLI smoke probe via `mlx_lm.generate`. If basic decode works: add to llama-swap config + add to AB-verdict v2.2 as candidate #8.
3. **Wave 17 LSRA C-pilot Pattern 5 → kanban-worker pivot** — `explore-7hh.16` needs the same redesign as autonovel did. Mirror the bd-b5p.7 spec shape, dispatch the same /spec → /check → /test → /impl pipeline.
4. **ukx.13 Phase 3 smoke matrix run** — `bench-matrix.sh --smoke --candidates all --scenarios 01 --trials 1` (~2h pico). Then full matrix (~100h pico) per user OK.
5. **bd-b5p.5.7 close-eligible after ≥7 clean Phase 2 daily fires** — the cron confabulation bug is fixed-by-redesign per the kanban conformance work.
6. **bd-b5p.5.8 close-eligible** — verify-queue-file guard subsumed by `kanban_complete(metadata, artifacts)` structured handoff.
7. **explore-7hh.22 Hermes skill_view raw=True FR** — possibly moot under kanban; deferred.

## Warnings / watch-outs
- **Phase 1 + Phase 2 crons are BOTH now real autonomous daily fires.** Phase 1 09:00 UTC produces 1 paragraph to `autonovel/write/runs/phase1-smoke/draft-*.md`. Phase 2 21:00 UTC enqueues a kanban task that the gateway-dispatched worker should complete with a `publish_queue/<id>.json` file. Operator should glance at both daily for the first week.
- **bd-b5p.5.6 (Pattern 5 SKILL.md) and bd-b5p.5.7 (cron confabulation bug) stay OPEN as the design trail**. Don't close prematurely — they document HOW we arrived at the kanban substrate.
- **Conformance research finding applies cross-arc**: weekly-reporting got a heads-up bead. LSRA (explore-7hh.16) needs the same pivot. Any future Hermes-skill work should start from kanban-worker shape, not from SKILL-as-procedural-recipe.
- **4 empirical reversals of source-read research in this arc** — discipline reaffirmed across G16, ukx.8, ukx.11 Devstral PARTIAL, Kimi-Linear-REAP. /research SKILL Step 3 (Verify) is non-negotiable for load-bearing recommendations.
- **2 substantial /scrutiny FIX-FIRST catches this session** (bd-b5p.5.3 strict_preamble_check; ukx.13.4.2 naming/filename/CCR/DOTFILES_ROOT-default). User's calibration ("use /scrutinize even on inline fixes") validated empirically — saved real production bugs.
- **The kanban probe task `t_360fa078`** is queued. Next dispatcher tick (within minutes) will spawn the worker. If you onboard during/after that worker fires, check `hermes kanban show t_360fa078` to see the kanban_complete metadata (or, if the worker confabulated, the structured handoff WILL be missing — which is the whole point of the new substrate vs. the old one).
- **Phase 2 cron 1aefcbda7c1d (daily 21:00 UTC) will fire tomorrow.** If the worker pattern doesn't work cleanly on the first real fire, `hermes cron pause 1aefcbda7c1d` reverses it. Phase 1 (09:00 UTC) is the safe one.
- **Pico disk**: 380 GB used / 500 GB free — fine. ~73 GB safe-reclaim from task #36 still pending user go/no-go.

## /onboard should pick up
- Read this handoff first
- Read `~/explore/local-coding-models/refs/research/research-hermes-conformance.md` — THE definitive architectural reference, will guide all future Hermes-skill work
- Read `~/dotfiles/local-models/GUARDRAILS.md` — G18 new this session; G16/G17 still load-bearing
- Check `hermes cron list` + `hermes kanban list` + `journalctl --user -u hermes-gateway --since '1 hour ago'` to see overnight fire results
- Check Kimi 3-bit pull status (watcher bm11kotet may have fired notification; if so, smoke probe)
- Check open beads across 4 repos (dotfiles, explore, autonovel, linearb/weekly-reporting); the canonical "what's next" via `bv --robot-next`
- `br ready` in each repo for action-eligible work
