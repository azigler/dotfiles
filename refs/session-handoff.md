# Session handoff — 2026-08-04 899c6004 (marketing-vps)

**This session ran ON marketing-vps**, not zig-computer. Worth stating up front because
most of the work targeted both hosts and the reflex is to assume the harness host.
zig-computer was reached throughout as `ssh zig-computer`.

## State at offboard

- Current branch: `main`, pushed, `local == remote` proven via `git ls-remote`
- Last commit: `e5d3494` — `:white_check_mark: beads: close dotfiles-odq0 — gateway-switch.sh shipped`
- Open beads: 73; 7 created this session, 3 of those closed
- In-flight subagents: none — 2 dispatched (1 impl, 1 read-only reviewer); the impl
  worktree `agent-ab1ee00e64a99a4e9` merged and removed, `git worktree list` shows only
  the main tree
- Dirty files: none
- Markers: `.offboard-pending` cleared; `last-offboard-session` refreshed (it was a
  **week** stale — see the harvest note below)

## What happened this session

pico lost its internet for ~6.5h — last gateway request `07:23:49Z`, first after
`14:00:07Z`, **zero rows in between**. Routing is fail-hard with no fallback by policy
(`dotfiles-ucl4`), so claude died fleet-wide. Zig asked for a bypass; pico came back
mid-session so he then asked for the revert; and finally for a real kill switch.

- **Bypassed then reverted both hosts**, each direction verified end-to-end rather than by
  reading config: `DIRECT-OK`/`WRAPPER-OK` while bypassed, `GATEWAY-BACK` after, and rows
  actually landing in pico's `request_logs` for both machines. Arc: `dotfiles-9o46`.
- **Shipped `agents/scheduler/gateway-switch.sh`** (`off|on|status`, `--dry-run`) with a
  52-case suite and an `agents/infra.md` runbook. One command per host; it detects
  marketing-vps's extra tunnel-timer step itself, so the two hosts are symmetric to the
  user. Scrutiny returned FIX-FIRST on a real blocker (see below) → fixed → SHIP.
- **Wrote `~/.break-glass.txt`** on both boxes (`/home/andrew`, `/home/ubuntu`), host-aware,
  every command in them executed before being written.
- **Reran today's `pulse-digest`** — the 14:00 tick had been injected into an API-dead
  session and was lost. The rerun completed in 25m11s and filed `explore-87d3`,
  `explore-nktt`, `explore-o2gy`.
- **Corrected two of my own claims to Zig**, both of which had already been stated as
  evidence: a "2876 requests in 20 minutes" figure that was really every row dated today
  (bare string compare against an ISO8601 `started_at` — measured 2903 vs 18 side by side),
  and a "marketing-vps verified on the gateway" that had actually gone direct, because this
  session runs with `CC_NO_GATEWAY=1` and every spawned shell inherits the hatch.

## Decisions made this session (autonomous decide-and-proceed calls)

- `dotfiles-9o46` — kill switch: zig-computer + marketing-vps bypass pico's agentgateway,
  direct to api.anthropic.com _(closed this session — installed AND reverted the same day)_

⚠️ The Step 2.5 harvest window was a **week** wide (`last-offboard-session` stamped
2026-07-28), so it also surfaced `dotfiles-7awu`, `dkmc`, `ucl4`, `28jw`, `bzax`, `5q7c`,
`tant`, `hi81`. **Those are prior sessions', not this one's.** Only `9o46` is mine. Re-check
the window before treating that harvest as a session list.

## Proposed practices — where each one landed

- Gateway kill-switch procedure → **`agents/infra.md` "The kill switch"** (tracked), plus
  its executable form in **`agents/scheduler/gateway-switch.sh`**
- `request_logs` query traps — table is `request_logs`, time column `started_at`, and it is
  ISO8601 with a `T` and an offset so it MUST be wrapped in `datetime()` → **`agents/infra.md`**
- "Never verify gateway routing from a `CC_NO_GATEWAY=1` session" → **`agents/infra.md`**
- "Commenting the export out cannot de-gateway a running shell; `exec zsh` INHERITS the
  environment, so only an explicit `unset` works — and only in that direction" →
  **`zsh/.zig-computer.zshenv`**, both break-glass cards, and the script's own output
- pico's WAN egress moved and will move again → **`agents/infra.md`**, corrected to
  `172.88.172.160` and marked volatile with the command to derive it
- Break-glass cards are untracked `$HOME` copies that can rot → **`dotfiles-2p51`**

## What's next

1. **`dotfiles-dt5q`** — sessions launched before their host had a per-host zshenv route
   DIRECT and log nothing. One live offender at offboard: marketing-vps pane
   `work:✅ di-tuesday` (pid 1623429). The fix is just restarting the pane, but it needs
   Zig's say-so because a restart destroys context. `gateway-switch.sh status` lists these
   and marks hatch-direct separately from unexplained-direct.
2. **Open question awaiting Zig** — whether to put `gateway-switch` on `$PATH` as an alias,
   so the break-glass command is one word rather than a path. Offered, not answered.
3. The three gateway-switch follow-ups: `dotfiles-nrrp` (warn that `off` dirties a
   repo-tracked file), `dotfiles-ncsn` (heredoc bodies), `dotfiles-it8l` (mutation harness
   + pre-commit trigger arm).

## Warnings / watch-outs

- **This window's own claude still runs with `CC_NO_GATEWAY=1`** — direct, unlogged, and
  invisible in `request_logs`. Restarting this pane puts it back on the gateway. Anything
  spawned from it inherits the hatch; that is what produced the false "verified" above, so
  strip it with `env -u CC_NO_GATEWAY` before trusting any routing check.
- **A fixture `HOME` does NOT isolate `gateway-switch.sh`.** Its hermeticity comes from the
  PATH fakes. Testing it with only `HOME` overridden disabled the LIVE tunnel timer twice
  today — once by me, once by the reviewer. Use `--dry-run`.
- `dotfiles-jfqq` was closed earlier this session as "disconfirmed, no reproduction" — then
  `dotfiles-dt5q` reproduced the same shape with a better-supported cause. If this comes up
  again, read `dt5q`, not `jfqq`.
- **The pre-close gate on `-t impl` beads blocks the ENTIRE compound Bash command**, so a
  `br update --notes … && br close …` one-liner fails with "no recorded scrutiny verdict"
  because the update never ran. Split them into separate tool calls. The verdict must also
  match its documented grammar (`Verdict: FIX-FIRST -> addressed -> SHIP` on its own line).
- `claude` and `curl` are not on `PATH` in a non-interactive `ssh zig-computer '…'` shell —
  use `~/.local/bin/claude` and `/usr/bin/curl` there. This produced a false "not installed"
  reading mid-session.
- The scrutiny blocker is worth remembering as a class: `on` would have un-commented ANY
  comment containing `export ANTHROPIC_BASE_URL=`, turning a commented-out example into a
  second live export and a prose mention into syntax garbage — in a file every
  non-interactive shell sources, i.e. it would have broken remote pulse dispatch silently.
  `zsh -n` **accepts** that garbage line; only sourcing it fails. Same hazard as this repo's
  "a documented example is executable" rule, pointed the other way.
