# Session handoff — 2026-08-03 188ce668 (zig-computer)

Machine: **zig-computer**. One long arc: route `marketing-vps` Claude Code through
pico's agentgateway with machine-of-origin attribution — then nine follow-on defects
the arc exposed.

## State at offboard

- Current branch: `main`, pushed, `local == remote` proven via `git ls-remote`
- Last commit: `6535cd3` (merge absorbing another writer's 4 commits)
- Open beads: 65; in-progress: 0
- In-flight subagents: none — 8 dispatched, all merged, all worktrees removed
- Dirty files: `.beads/issues.jsonl` only (the two Step-2.6 beads, committed below)
- `~/explore` also touched and pushed: `0e6152a`
- Markers: `.offboard-pending` cleared

## What happened this session

### The ask (delivered, verified end to end)

`marketing-vps` is not on the tailnet and never will be; pico's agentgateway is
tailnet-only. **One hop, not two** — `ssh -L` resolves its destination on the FAR end,
so zig-computer does the tailnet leg itself:

    ssh -L 127.0.0.1:17017:100.72.47.4:17017 zig-computer

Measured from the VPS: `000` with no tunnel → `401` through it. **401 IS health** — the
`/claude` route is a keyless passthrough, so 401 means the request reached Anthropic.

**Machine attribution: squatted the unused `agentgateway_group` column** — Zig's call,
better than the three options offered. `user` keeps meaning `<tmux session>:<window>`;
all 84k historical rows untouched. Live proof: `group=marketing-vps` and
`group=zig-computer` both recorded; filterability confirmed via `/api/logs/search` with
a positive AND a negative control.

⚠️ **`agentgateway_user` was NEVER a machine label** — its first field is the tmux
SESSION. Both boxes run a session called `work` and metis shares the namespace, so ≥3
machines were already colliding. The request caught a pre-existing defect.

### The defects the arc exposed — every one behind green mechanical gates

- `dotfiles-v93v` — two mutants SURVIVED on the exact branch the VPS now uses: a dropped
  `--dangerously-skip-permissions` (hangs unattended ticks) and an injected
  `ANTHROPIC_AUTH_TOKEN` (moves billing off the subscription). Zero credential coverage.
- `dotfiles-47nf` — `re_escape` entirely untested; neutering it passed 26/26 while an
  unescaped pattern provably matched a *different* forward.
- `dotfiles-xp57` — `Type=oneshot` + default `KillMode` **kills the `ssh -f -N` the
  script just opened**, then logs "Finished". Both configs report `Result=success`; only
  the tunnel's fate differs. Reproduced independently with paired transient units.
- `dotfiles-77s4` — `--dry-run` created a persistent tmux window on a shared production
  box, typed into it, and made a paid `claude -p` call. Zig spotted it as a Monday tab
  open on a Friday. Now removes only the window it created, guarding two ownership doors
  (`new-session -n <row>` creates the window too).
- `dotfiles-20rx` (P1) — `CC_NO_GATEWAY=1` fired in no fresh zsh. The fix had TWO halves;
  the obvious one alone does nothing, because the var is *exported* by the caller.
- `dotfiles-x1fn` — the guarded merge sequence had NO owner (AGENTS.md and `/orchestrator`
  each named the other). Fixed in parallel by Zig's `dc99ec8`.
- Also closed: `9gyw` `ahrd` `qepg` `u9kw` `dajp` `wpu2` `ogkz` `xp57` `47nf` `v1uh`.

### Hostname rename

`vps-8a9eb245` → `marketing-vps` (`dotfiles-v1uh`). Per-host dotfiles are keyed on
`hostname -s`, so a naive `git mv` would have stripped PATH **and** gateway routing from
every new shell — with `claude` dead by policy — exactly where the pulse rows run. Done
as a dual-name transition: copy → relink → rename → delete old. `cloud.cfg` pinned
`preserve_hostname: true` (it was `false` with `set_hostname` active, so a reboot would
have silently reverted it). Existing rows relabelled on pico after a `.backup`.

## Decisions made this session (autonomous decide-and-proceed calls)

- `dotfiles-ucl4` — a VPS gateway tunnel failure fails **HARD**, no silent fallback to
  `api.anthropic.com`. Silent fallback is precisely `dotfiles-t6to`, which blinded pico's
  log for days with nothing alarming. Reversible in one branch.

## Proposed practices — where each one landed (Step 2.6)

- "A mutant must die of the BUG IT NAMES, not merely make the suite red" (+ assert the
  mutation applied first) → **filed as `dotfiles-3afr`**, tier left as an open question
  for Zig (CLAUDE.md rule 1 vs `/scrutinize`).
- "`if ! git push … | tail` can never fire its fallback — the pipe masks the exit code"
  → **filed as `dotfiles-xugk`** against `/commit`.

## What's next

1. **`dotfiles-3afr`** — decide the tier, land the mutation-discipline clauses once.
2. **`dotfiles-xugk`** — `/commit` anti-pattern; a three-line doc fix.
3. Nothing from the gateway arc is open. `br ready` for the rest.

## Warnings / watch-outs

- **A bare `claude` on marketing-vps works because `claude` is the shell FUNCTION.**
  `command claude` or the full path bypasses the gateway silently. All four `work` panes
  were re-sourced and carry the machine header.
- **The pre-commit gate is now slower** — it also runs a 63s mutation harness on
  `ensure-fleet-tunnel.sh` and its suite. Measured ~71s commit on those paths. Expected,
  not a hang.
- **`marketing-vps` claude is fail-hard.** If `claude-gateway-tunnel.timer` is not firing,
  `claude` there is dead by design. `CC_NO_GATEWAY=1` now genuinely works (fixed this
  session); commenting out the export in `zsh/.marketing-vps.zshenv` is the lasting bypass.
- **`.claude/last-offboard-session` was 6 days stale** (Jul 28), so the Step 2.5 harvest
  window spanned other machines' sessions and reported 7 decisions where 1 was this
  session's. Re-run against a real session start when the receipt looks too large.
- This box runs **uutils coreutils 0.2.2**, not GNU — but `stat -c` and `date -d` both
  work. Don't assume the `dotfiles-2ap6` trap explains a failure here without checking.
