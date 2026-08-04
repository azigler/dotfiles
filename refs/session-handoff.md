# Session handoff — 2026-08-04 188ce668 (zig-computer)

> ⚠️ **This file replaced another session's note, and that is a known bug
> (`dotfiles-fmq6`).** The note previously here was `899c6004` (marketing-vps,
> the pico-outage + kill-switch session) — read it at **`git show 26d08d8:refs/session-handoff.md`**.
> `dotfiles` runs two durable sessions and has no `refs/.handoff-per-window`, so each
> `/offboard` clobbers the other. Neither note is lost; only the *current* file is
> partial. **Read both before assuming you have the picture.**

Machine: **zig-computer**. One arc: route `marketing-vps` Claude Code through pico's
agentgateway with machine-of-origin attribution — then every defect it exposed, and the
standing practices those defects earned. **All of it is closed.**

## State at offboard

- Branch `main`, pushed, `local == remote` proven via `git ls-remote`
- Open beads: ~70 (the count moves — another session is committing); in-progress: 0
- In-flight subagents: none — 17 dispatched this session, all merged, all worktrees removed
- Dirty files: none of mine
- `~/explore` also touched and pushed: `0e6152a`

## What shipped

**The ask.** `marketing-vps` reaches pico's tailnet-only agentgateway over **one hop, not
two** — `ssh -L` resolves its destination on the far end, so zig-computer does the tailnet
leg. `000` with no tunnel → `401` through it (401 IS health: keyless passthrough).
Machine attribution squatted the unused **`agentgateway_group`** column, leaving `user`
(`<session>:<window>`) and 84k rows untouched. Host renamed to `marketing-vps` via a
dual-name transition, `cloud.cfg` pinned `preserve_hostname: true`.

**Fourteen defects it exposed, all closed** — `v93v` (two mutants surviving on the branch
the VPS now uses), `47nf` (`re_escape` untested), `xp57` (oneshot `KillMode` killing its
own tunnel while reporting success), `77s4` (`--dry-run` creating windows on a production
box), `20rx` (a hatch that fired in no fresh zsh, fix had two halves), `x1fn`, `qepg`,
`u9kw`, `ahrd`, `dajp`, `wpu2`, `9gyw`, `v1uh`, `ogkz`.

**Four standing practices, landed** — `3afr` (rule 1: assert the mutation applied; die on
the case it NAMES), `g2vg` (rule 2: run the example *as committed*, extracted not
retyped), `xugk` (`/commit`: a push guard behind a pipe can never fire; `PIPESTATUS` is
bash-only and empty in zsh), `3137` (`mutate-scrutiny-guards.sh` brought up to rule 1 —
which exposed a **live false kill**: the old harness counted an unparseable mutant as
`killed` at exit 0, in a gate wired into pre-commit).

## Decisions made this session (autonomous decide-and-proceed calls)

- `dotfiles-ucl4` — gateway routing fails **HARD**, no silent fallback. **Its cost landed
  within a day**: pico lost internet ~6.5h on 08-04 and `claude` died *fleet-wide*, not
  just on the VPS. I weighed a dead tunnel and never weighed a dead gateway. The decision
  still stands — the other session's `gateway-switch.sh` is a loud one-command bypass,
  strictly better than the silent fallback it rejected — but the outcome is recorded on
  the bead, and the lesson is filed as `dotfiles-17k3`.
- `dotfiles-dkmc` — the mutation-discipline clauses land in CLAUDE.md rule 1, not
  `/scrutinize`.
- `dotfiles-volw` — _(closed as MOOT: it resolved a question about a guard that turned out
  not to exist — see below.)_

⚠️ The Step 2.5 harvest also surfaced `dotfiles-9o46`, which is the **marketing-vps
session's** decision, not this one's. Same shared-marker root cause as `fmq6`.

## Proposed practices — where each one landed (Step 2.6)

- Mutation discipline → **shipped**, CLAUDE.md rule 1 (`ecbe235`)
- Run the example as committed → **shipped**, CLAUDE.md rule 2 (`e7865a6`)
- Pipe-masked push guard / `PIPESTATUS` → **shipped**, `/commit` + TOOLKIT (`781aef5`)
- "A 'fail hard' decision must enumerate WHO dies" → **filed as `dotfiles-17k3`**

## What's next

1. **`dotfiles-fmq6`** — two sessions, one handoff file *and* one last-offboard marker.
   Decide the key: window, or `<hostname>--<window>`. Both boxes run a `work` session, so
   plain window-keying still collides.
2. **`dotfiles-17k3`** — the blast-radius line for decide-and-proceed beads.
3. **`dotfiles-folq`** (P3) — pre-commit advertises ~90s for a harness that measures ~130s.
4. `br ready` for the rest.

## Warnings / watch-outs

- **A bare `claude` on marketing-vps works because `claude` is the shell FUNCTION.**
  `command claude` or a full path bypasses the gateway silently.
- **`${PIPESTATUS[0]}` is bash-only and expands EMPTY in this fleet's zsh 5.9** — a guard
  using it fails open. zsh's is lowercase `$pipestatus`, 1-indexed, clobbered by the very
  next command. I made this mistake three times *in the session where I documented it*;
  the tell each time was a pipeline's exit code read as the command's.
- **`dotfiles-aq6d` was closed as PREMISE FALSE** — it claimed "the isolation guard blocks
  multi-command inline git". That guard governs *agent dispatch*; no hook blocks git that
  way, verified empirically. I filed it from a subagent's adjacent note without checking.
  If a similar claim appears, test it before filing.
- **The pre-commit gate is slow now** — ~63s (tunnel) and ~130s (scrutiny) mutation
  harnesses on their keyed paths. Expected, not a hang.
- **`marketing-vps` claude is fail-hard.** `gateway-switch.sh off` and `CC_NO_GATEWAY=1`
  are the two working escapes; neither helps a session already wedged mid-turn.
- **The recurring shape:** every defect this session had green mechanical gates. A fixture
  using `env -i` (a shell shape existing nowhere in production), a guard with no coverage,
  a unit reporting success while killing its own child, a dry-run documenting its side
  effects in source but never in output, and a mutation harness counting an unparseable
  mutant as a kill. The tell was always **silence**, not error.
