# Session handoff — 2026-08-03 188ce668 (zig-computer)

Machine: **zig-computer**. One arc: route `marketing-vps` Claude Code through pico's
agentgateway with machine-of-origin attribution — then every defect that arc exposed,
including the follow-ups and the follow-ups' follow-ups. **Nothing from it is open.**

## State at offboard

- Current branch: `main`, pushed, `local == remote` proven via `git ls-remote`
- Last commit: `c19083c`
- Open beads: 66; in-progress: 0
- In-flight subagents: none — 12 dispatched, all merged, all worktrees removed
- Dirty files: none **of mine** — but see the second-writer warning below
- `~/explore` also touched and pushed: `0e6152a` (explore main has since moved on
  under another writer)
- Markers: `.offboard-pending` cleared; `last-offboard-session` refreshed (it was
  6 days stale at the first offboard this session — see watch-outs)

## What happened this session

### The ask (delivered, verified end to end)

`marketing-vps` is not on the tailnet and never will be; pico's agentgateway is
tailnet-only. **One hop, not two** — `ssh -L` resolves its destination on the FAR end,
so zig-computer does the tailnet leg:

    ssh -L 127.0.0.1:17017:100.72.47.4:17017 zig-computer

`000` with no tunnel → `401` through it. **401 IS health** — `/claude` is a keyless
passthrough, so 401 means the request reached Anthropic.

**Machine attribution: squatted the unused `agentgateway_group` column** (Zig's call,
better than the three options offered). `user` keeps meaning `<tmux session>:<window>`;
84k historical rows untouched. `group=marketing-vps` and `group=zig-computer` both
recorded live; filterability confirmed via `/api/logs/search` with positive AND negative
controls.

⚠️ **`agentgateway_user` was NEVER a machine label** — its first field is the tmux
SESSION. Both boxes run a session called `work`, metis shares the namespace, so ≥3
machines were already colliding. The request caught a pre-existing defect.

Host renamed `vps-8a9eb245` → `marketing-vps` via a dual-name transition (per-host
dotfiles are keyed on `hostname -s`; a naive `git mv` would have stripped PATH **and**
gateway routing from every new shell). `cloud.cfg` pinned `preserve_hostname: true` —
it was `false` with `set_hostname` active, so a reboot would have silently reverted it.

### Every defect the arc exposed — all closed

| Bead | What it was |
|---|---|
| `v93v` | two mutants SURVIVED on the branch the VPS now uses — dropped permissions flag, injected auth token. Zero credential coverage. |
| `47nf` | `re_escape` untested; neutering it passed 26/26 while an unescaped pattern matched a *different* forward |
| `xp57` | `Type=oneshot` + default `KillMode` **kills the tunnel it just opened**, logs "Finished", reports success |
| `77s4` | `--dry-run` created a tmux window on a production box, typed into it, made a paid call. Spotted as a Monday tab on a Friday. |
| `20rx` | `CC_NO_GATEWAY=1` fired in no fresh zsh. Fix had TWO halves — the obvious one alone does nothing. |
| `x1fn` | the guarded merge sequence had NO owner; fixed in parallel by Zig's `dc99ec8` |
| `qepg` `u9kw` `ahrd` `dajp` `wpu2` `9gyw` `v1uh` `ogkz` | see closed beads |
| `3afr` `xugk` | the two standing practices, landed |

## Decisions made this session (autonomous decide-and-proceed calls)

- `dotfiles-ucl4` — a VPS gateway tunnel failure fails **HARD**, no silent fallback.
  Silent fallback is precisely `dotfiles-t6to`, which blinded pico's log for days.
- `dotfiles-dkmc` — the mutation-discipline clauses land in **CLAUDE.md rule 1**, not
  `/scrutinize`. Zig delegated the tier back rather than answering it.

## Proposed practices — where each one landed (Step 2.6)

- Mutation discipline (assert applied; die on the case it NAMES) → **shipped**, CLAUDE.md
  rule 1 (`ecbe235`), pointing at `mutate-tunnel-ownership.sh` rather than restating it.
- Pipe-masked push guard + `PIPESTATUS` is bash-only → **shipped**, `/commit` SKILL.md
  (`781aef5`) + one TOOLKIT line.
- "Run the example VERBATIM — extract from the committed file, don't retype" →
  **filed as `dotfiles-g2vg`** (rule 1 already took an addition today; a second rules
  change to the same always-loaded file deserves Zig's eye).

## What's next

1. **`dotfiles-3137`** — `mutate-scrutiny-guards.sh` does not meet the rule now governing
   it: 0 named-case assertions vs the reference harness's 4. It is wired into pre-commit.
2. **`dotfiles-g2vg`** — the rule 2 refinement above, if Zig wants it.
3. **`dotfiles-aq6d`** (P3) — the isolation guard forces rule-2 verification into script
   files. Decide: relax, narrow, or just improve the block message.
4. `br ready` for the other 63.

## Warnings / watch-outs

- **A bare `claude` on marketing-vps works because `claude` is the shell FUNCTION.**
  `command claude` or the full path bypasses the gateway silently. All four `work` panes
  were re-sourced and carry the machine header.
- **`${PIPESTATUS[0]}` is bash-only and expands EMPTY in this fleet's zsh 5.9** — a guard
  using it fails open. zsh's is lowercase `$pipestatus`, 1-indexed, and **clobbered by
  the very next command**. Now documented in `/commit`.
- **The pre-commit gate is slower** — a 63s mutation harness runs on
  `ensure-fleet-tunnel.sh` / its suite. ~71s commit on those paths. Expected, not a hang.
- **`marketing-vps` claude is fail-hard.** If `claude-gateway-tunnel.timer` is not firing,
  `claude` there is dead by design. `CC_NO_GATEWAY=1` now genuinely works (fixed this
  session); commenting out the export in `zsh/.marketing-vps.zshenv` is the lasting bypass.
- **`.claude/last-offboard-session` was 6 days stale** at the first offboard, so the
  Step 2.5 harvest spanned other machines' sessions and reported 7 decisions where 1 was
  this session's. It is refreshed now — but re-check the receipt against a real session
  start whenever it looks too large.
- This box runs **uutils coreutils 0.2.2**, not GNU — but `stat -c` and `date -d` both
  work. Don't blame `dotfiles-2ap6` for a failure here without checking.
- ⚠️ **A SECOND WRITER WAS LIVE AT OFFBOARD — do not clean up after it.** At the moment
  this note was committed, `agents/skills/pulse/SKILL.md` was dirty in this tree and
  `~/explore` held five locked `agent-*` worktrees at `8762e13` (a `dive` tick #137 that
  had just committed). **None of that is this session's** — my worktrees were all removed
  and my trees were clean. Per AGENTS.md "two writers, one working tree": leave it alone,
  never `stash`/`reset`/`checkout .` to tidy it, and if a push is rejected, `git fetch &&
  git merge` rather than rebase. It will most likely be committed and gone by the time
  anyone reads this.
- **The recurring shape, worth carrying forward:** every defect this session had green
  mechanical gates. A test fixture using `env -i` (a shell shape that exists nowhere in
  production), a guard with no coverage at all, a unit reporting success while killing
  its own child, a dry-run documenting its side effects in source but never in output,
  and — twice — the orchestrator's own verification wrong before it was right. The
  common tell in every case was **silence**, not error.
