# Session handoff — 2026-08-10 9fe69435 (dotfiles, Master of Works) — THE CUTOVER EVE

> DELIBERATE PROCESS RESTART, not a molt: this seat is being cut onto the SECONDARY tap per
> Zig's directive (2xvq). A restarter script drives /exit + relaunch in this pane; the fresh
> context should see a TAP ROLLOVER stderr sentence at its own launch — that is the directive
> WORKING, not an anomaly. Single handoff slot still live (ie5a): this overwrites the marshal's
> 21:21Z molt addendum (ac4dca1, in git), and the marshal's night-end will overwrite THIS —
> read from git history if needed after ~09:30Z.

## ⚠️ FIRST DUTIES for the fresh context (time-ordered, tonight)
1. **RE-ARM THE 00:43 PT GATE** — the prior session's one-shot reminder DIED with its process.
   At ~00:43 PT (07:43Z) verify: (a) `git -C ~/demesne status --porcelain` clean; (b) marshal
   pane (zig-computer:5) runs claude with CLAUDE_CONFIG_DIR=~/.claude-secondary (check
   /proc/<pid>/environ); (c) `systemctl --user list-timers | grep pulse-marshal` armed for
   08:07Z. ALL green → do nothing. ANY red → `systemctl --user stop pulse-marshal.timer`,
   note on dotfiles-bg71, re-arm after fixing. (As of offboard ~01:50Z: all three green.)
2. **AC5 HARVEST (~01:10 PT)**: after the 01:07 tick, capture the marshal pane's onboard
   context pct (`tmux capture-pane -t 'zig-computer:5' -p | grep '%'`). Expect ~12% at 1M
   scale (vs 73% on the 200k alias window). Drop the number on `dotfiles-lstn` — either this
   seat or the consul closes lstn on it.
3. **Supervise the first funded night by exception**: derived budget ≈5.45M on secondary
   (5gob live line; scrutiny-verified). Read the morning drain ledger + seneschal brief;
   watch for seneschal's 06:44 PT tick landing on secondary (2xvq AC — first ORGANIC
   timer-seat roll; check the rollover ledger).

## State at offboard
- Branch main, clean, pushed (ls-remote == local at every step; last commits fcb9c44,
  2304302, 2083662). Demesne main 1a5c3ff pushed + verified; tree clean; ~/.agents live
  copies byte-match dotfiles main for everything this session shipped.
- Open beads: `br ready` owns that fact. Zero worktrees owned (list holds other lanes').
  No in-flight subagents. The one-shot cron dies with this process (duty 1 above).
- Markers: cleared at offboard; last-offboard-session = 9fe69435.

## What happened this session (Zig's P1 diagnostics + the cutover eve)
- **Four P1s closed, all merged/scrutinized/pushed**: gxqc (stall-reconcile per-trigger
  matching; false verdicts gone, spam 9→2), c9yi (pico-health build-keyed softwareupdate
  cache + :dynamic port grammar; 27/27+8/8), 8x8l (model-guard cold-start write race; blind
  6/7→0, live A/B 4/9→0/9; 3-pass scrutiny incl. lstn merge-resolution), 5gob (marshal
  budget launch-pool resolution + epoch-3 predicates + cross-pool cap transfer; live-derived
  5,450,192 tokens for tonight vs ZERO on old code — the counter-factual was measured).
- **Marshal restarted onto secondary** (Zig-directed): 1M canonical fable id, env-pinned
  CLAUDE_CONFIG_DIR (interim for qwq9), X-Tap: secondary verified on the process.
- **qwq9 filed (P1, consul lane)**: seat_home is DEAD CODE on the launch path — consulted
  only for candidate order after a ceiling hit. Consul confirmed root cause; tops their docket.
- **Fable cutover armed (Zig directive, 2xvq)**: fable_ceiling=0.97 committed + live in
  demesne; **the Fable leg's first LIVE firing succeeded organically** (01:43:14Z ledger row,
  home=primary used=secondary, real completion served) — also the first organic rollover
  ever. Even-trio aliases added: claude / claude-secondary / claude-linearb (lb-claude idiom).
- **l42h closed**: Zig's linearb seat launch self-refreshed the token; pool 3 reads
  state=ok u5h=0.06 u7d=0.14 fable=0.04. Third rollover rung is lit.
- Coordination: consul's combined carry landed (0ef9183) + their zsh/tmux sync-set change
  absorbed; o3qj live (2nd refused molt in 90m pages Zig); ancestry 21ad7b8⊇dad9f86 verified.

## Friction
- Guarded merge refused on 8x8l (lstn ba8146f touched the same hook) — resolved by sending
  the conflict back to the ORIGINAL builder (context intact), then delta-scrutiny; clean
  pattern, no repeat expected → one-off
- Worktree remove-guard blocked on an orphaned `until grep; do sleep` poll loop a builder's
  background probe left behind — killed the loop, removed clean; single occurrence → one-off
- 5gob builder reported a SYNTHETIC "production dry run" number (scrutineer proved it
  irreproducible; real number was 3.5x smaller) — the scrutiny gate caught it and the
  report-accuracy note lives on dotfiles-5gob → one-off (the gate is the guard)
- zsh ate a bare `echo ===` separator (`=cmd` expansion) → one-off

## Decisions made this session (autonomous decide-and-proceed calls)
- `dotfiles-bg71` — cross-pool cap transfer (not hand-set cap); hold pulse-marshal.timer if
  readiness chain incomplete by 00:45 PT
- `dotfiles-zfgu` — pico CLT patch posture options (agent-filed, awaits Zig's tier-2 call)

## Proposed practices — where each one landed
- Fable pre-exhaustion rollover as permanent posture → written into taps.conf
  (fable_ceiling=0.97 + rationale comment) + directive bead dotfiles-2xvq
- Mid-flight recovery = restart-onto-next-tap → recorded as re-scope comment on
  dotfiles-yrsg (P1)
- none homeless

## What's next
1. Duties 1-3 above (gate, AC5, supervise).
2. Cut-over confirmations for 2xvq: this seat lands secondary at its own relaunch (verify
   X-Tap in own env or the rollover ledger ~01:5xZ row); consul post-restart; seneschal 06:44.
3. Zig's tier-2 queue when he's about: nneb, qcg0 (defaultMode, due 2026-08-14), zfgu (CLT
   posture), pm33 + sf86 OQ walks, dlca week-reset anchor reconcile (conf Wed 00:00 vs Zig
   Thu 11pm PT — now feeds the budget window math).
4. Fleet-marked queue (~62) feeds the drain — don't hand-dispatch what it can drain.

## Warnings / watch-outs
- **This fresh context runs on SECONDARY** — statusline/attribution shows secondary; that is
  correct. Primary Fable ~97% until Thu 11pm PT reset; all fable-named launches roll.
- First organic 429/ceiling behaviors tonight are WATCH items, not alarms; yrsg (restart-onto-
  next-tap) is the P1 that closes the mid-flight gap — detection exists, recovery doesn't yet.
- qwq9 open: seat_home overrides do nothing at launch until the consul's fix; marshal's env
  pin + this pane's organic roll are the interims. Env pin comes OFF after qwq9 verifies.
- dlca still open: Fable % not yet surfaced in budget reasons/briefs; the 0.97 ceiling is the
  interim brake.
- Consul may still be mid-restart; its scoped note session-handoff--consul.md carries its state.
