# Session handoff — 2026-05-25 beb8609d (post mobile-transcripts turn)

## State at offboard

- **Branch**: main, clean working tree
- **Last commit** (dotfiles): `4ec98b7 :broom: gitignore: don't track .claude/scheduled_tasks.lock`
  - prior dotfiles refresh: `5c508b3` (offboard handoff refresh) ← `9eb2f0c` (NUM_PARALLEL=1 + push-notif + remote-control startup) ← `01923ee` (autonomous queue offboard) ← `d2a7954` ← `92dab31`
- **Last commit** (explore): `64b15d5 :card_file_box: step-12: finetuning toolchain research + .9.1 sub-bead stub` (unchanged this turn)
- **Last commit** (explore-simon-willison): `95e3896 :card_file_box: beads: stub simon-v07 — archival viewer fork (deferred)` (NEW this turn)
- **Open beads**:
  - dotfiles: 2 — both ❄ P3 deferred (`dotfiles-st2` iPhone Termius nerdfonts, `dotfiles-406` zig laptop tailnet)
  - simon-willison: 1 — ❄ P3 deferred (`simon-v07` archival viewer fork — NEW this turn)
  - ~/explore: 8 open + 1 deferred + 10 closed (19 total per `br stats`). Open: epic `explore-4te`, spec `.1`, A/B beads `.4 .6 .7 .8`, GLM `.5`, step-12 `.9`. Deferred: `yw9` MUD-agent. Plus child stub `.9.1` exists per JSONL but doesn't appear in default `br list` output. **The .4/.6/.7/.8 work LANDED in commits (`09f0b8e/00d9adb/0ee8785/35cd1f1`) but the beads weren't formally closed — reconcile next session.**
- **In-flight subagents**: none
- **Markers**: `.offboard-pending` not present (was never written today — see continuity note below)
- **Cost tracking**: not enabled for dotfiles project; skipping ledger update
- **Session continuity**: still `beb8609d` per `~/.claude/projects/-home-ubuntu-dotfiles/beb8609d-...jsonl` mtime + lock file's sessionId. PID 11212 alive. **This same `claude` process has been running ALL DAY** through C2 SS14 close → autonomous local-coding-models queue → mobile-transcripts turn. `/offboard` has run multiple times mid-session writing handoff notes; `SessionEnd` hook has not fired today.

## What happened this turn (mobile-transcripts viewing)

User Termius-SSHes into zig from iPhone; CLI scrollback is tedious on mobile. Wanted a browser surface to glance at active transcripts between prompts. Initial pitch was forking Simon Willison's `claude-code-transcripts` (static HTML generator) and hosting on nginx + tailnet.

### Refined into the right surface

- Clarified Simon's tool is a static generator, not a server — would need a daemon for live use.
- User mentioned a possible first-party feature called "Claude Code dispatch." Dispatched `claude-code-guide` subagent to research.
- Findings:
  - **Dispatch** is real but is async task-delegation in the Desktop Cowork tab — NOT session viewing.
  - **Remote Control** (https://code.claude.com/docs/en/remote-control.md) is the actual fit: live mobile-optimized transcript view via claude.ai/code or the Claude iOS/Android app. Messages relay through Anthropic cloud (code/context stay local). Three invocation modes (server `claude remote-control`, interactive `claude --remote-control`, in-session `/remote-control`) plus a global enable via `/config` → "Enable Remote Control for all sessions".

### Enabled globally

User typed `/config` → toggle set to true. Prerequisites verified (Claude Code v2.1.150 ≥ 2.1.51 floor, no blocking env vars, no policy override, claude.ai OAuth auth). **NOTE**: the autonomous-queue commit `9eb2f0c` had already added "remote-control startup" config to claude/settings.json earlier today — likely related but the user's manual `/config` toggle this turn was the explicit on-switch.

### Stubbed simon-v07 in explore-simon-willison

Live use case solved by Remote Control. Archival/review angle (grep past convo from mobile, share past-session URL, multi-session compare) is NOT — Remote Control is live-only. Stubbed parking-spot bead:
- ID: `simon-v07` (P3 task, ❄ deferred indefinitely), in `~/explore/simon-willison/.beads/`
- Full handoff packet: default path (fork Simon as submodule under `~/explore/simon-willison/`) vs alternative (/grok 2026 ecosystem first), why-deferred + revisit triggers, constraints (mobile, tailnet, 2.8 GB / 1062 sessions / 453K turns input), 7-item acceptance criteria
- External-ref → github.com/simonw/claude-code-transcripts

### Resolved session-start dirty state

- `ollama/com.zig.ollama.plist` 2→1 was a transient mid-queue state — committed cleanly in `9eb2f0c` before this turn acted. No-op this turn.
- `.claude/scheduled_tasks.lock` — investigated, found ACTIVE (PID 11212 alive, sessionId matches THIS conversation). Not stale. Added to dotfiles `.gitignore` in the "session state" block alongside `.offboard-pending`. Commit: `4ec98b7`.

## What's still in flight from the autonomous-queue arc

(Captured from the prior handoff revision `5c508b3`. The autonomous queue's wake-up cycle may continue these unattended.)

- **GLM-4.5-Air download on pico** — was at 14 GB / 57 GB target at last check. PID 5721 originally; may have new PID after restarts. **Be VERY conservative about kills** — multiple stalls + kill-restart cycles cost ~18 GB of progress this morning due to hf-cli GCing `.incomplete` files on restart.
- **`explore-4te.5`** (GLM bench) blocked on download.
- **`explore-4te.9` + child `.9.1`** — step-12 finetuning validation. `.9.1` is stub-only; actual fine-tune is a user-driven QLoRA experiment (~2hr on M1 Max for 100 examples on Qwen3-Coder). Toolchain doc in `~/explore/local-coding-models/refs/finetuning-toolchain.md`.
- **Hourly wake-up scheduled at 12:59** — wakes with prompt to continue queue; will check GLM state, run bench if downloaded, else re-schedule. Loop continues until queue closed. This is the schedule that holds the `.claude/scheduled_tasks.lock`.
- **Empirical finding from the queue (still load-bearing)**: spec `.1` originally said Phase 1 = Ollama. **MLX wins for the primary daily-driver** (Qwen3-Coder-30B-A3B on MLX). Final recommended stack:
  - Daily-driver: Qwen3-Coder-30B-A3B on MLX (+ claude-code-router proxy)
  - Reliability fallback: Devstral on Ollama (95% pass rate)
  - Long-context: Laguna XS.2 on Ollama (only model passing 100K context)
- Detail in `~/explore/local-coding-models/refs/AB-verdict.md`. Spec `.1` was amended in --notes; no FINDINGS.md update yet — consider whether to also amend that doc.

## What's next (priority order)

1. **Reconcile the .4/.6/.7/.8 open-bead state in ~/explore.** Bench work landed in commits (`09f0b8e`, `00d9adb`, `0ee8785`, `35cd1f1`) but beads weren't formally closed. Either close them now if work is genuinely done, or document why they're still open. `br orphans` may also catch this.
2. **Next /onboard from `~/explore/local-coding-models/`** (active arc home), not from dotfiles.
3. **Test Remote Control from phone**: `/mobile` shows iOS app download QR. Sign in with claude.ai account. Open a session from the app's Code tab. Validates global toggle worked.
4. **GLM check** — read `refs/AB-verdict.md` methodology section first, then check download (`ssh pico 'du -sh ~/.cache/huggingface/hub/models--mlx-community--GLM-4.5-Air-4bit'`). Run bench if done; only kill if truly dead.
5. **Revisit `simon-v07`** when forcing function appears (grep past convo from mobile, share session URL, compare closed sessions). `br undefer simon-v07` from `~/explore/simon-willison/`.

## Warnings / watch-outs

- **Session beb8609d alive ALL DAY** — multiple `/offboard` cycles wrote handoff notes mid-session; `SessionEnd` hook has not fired. The handoff note revisions track checkpoint state, not lifecycle. Don't conclude a "next session" exists just because a handoff was written — the same `claude` process may still be running.
- **Remote Control is GLOBALLY ON** — every new `claude` invocation auto-registers as remote-controllable. Sessions appear on claude.ai/code session list under your account. Lifecycle gotchas: dies when `claude` process exits; 10-min network outage → process exits; ultraplan disconnects Remote Control (only one can occupy claude.ai/code at a time); `/mcp`, `/plugin`, `/resume` are CLI-only.
- **GLM download is the highest-risk pending op** — be conservative on kills. Notify-only watchers from now on; only kill if truly dead (no sockets + log silent 10+ min). See `refs/AB-verdict.md` for the methodology lesson.
- **Bead-state divergence (ENHANCEMENT NEEDED)**: prior handoff claimed 9/11 closed; `br stats` says 10 total closed; visible benchmark work in commits not reflected in bead closures for `.4 .6 .7 .8`. Either the autonomous queue under-recorded closures or those beads have remaining work. Reconcile with the bead authors (probably just close them).
- **MUD-agent (`explore-yw9`)** still deferred. DO NOT start until user explicitly re-opens — the coding-models foundation is the prereq per user direction.
- **Ollama + MLX both running on pico** (ollama:11434, mlx:8081). Don't kill either; bench runner needs both reachable.
- **`.claude/scheduled_tasks.lock` is now gitignored** (commit `4ec98b7`). If you ever wonder why it exists but doesn't show in `git status`, that's why. It's protecting the hourly wake schedule.
- **Context budget**: synthesis writeup work was heavy on tokens this morning; the mobile-transcripts turn was light. Should be fine into next wake/session.
