---
description: Per-project autonomous heartbeat — a scheduled tick lands in a durable interactive tmux session, routes against the project's pulse table, does at most ONE unit of work with full bead/commit/scrutiny discipline, offboards, and ends. Generalizes autonovel's /heartbeat; the tmux-injection scheduler (systemd timer -> pulse-inject.sh -> send-keys) delivers the ticks. Spec bead dotfiles-mhn carries the full architecture + decisions.
when_to_use: A "/pulse tick" command arrives in a session (injected by the scheduler or typed by Andrew) — run one tick. Also fire for "/pulse setup" when opting a project into pulse (routing table + timer install), and "/pulse status" to report ledger + routing state. NEVER self-invoke ticks in a loop — the timer is the loop.
---

# /pulse — one tick of a self-driving project

A pulse-enabled project runs itself between Andrew's visits: a systemd
user timer fires `pulse-inject.sh`, which types `/pulse tick` into a
durable interactive Claude session in the project's dedicated tmux
window. Each tick does **at most one unit of work** with the full
discipline of any orchestrator session, then goes quiet until the next
tick. Andrew can watch, interrupt, or steer the session at any time —
it's a normal window in his tmux, labeled by the 🧠/✅/🔔/🌀 lexicon.

Parent pattern: autonovel's `/heartbeat` (routing table, one dispatch
per tick, rate caps). /pulse generalizes it; after the pilot, autonovel
migrates onto /pulse and /heartbeat retires. Full architecture +
decisions: `cd ~/dotfiles && br show dotfiles-mhn`.

## The contract: refs/pulse.md

A project opts in by carrying a routing table at `refs/pulse.md`:

```markdown
# pulse routing — <project>

| priority | name | trigger | check | action | cap |
|---|---|---|---|---|---|
| 1 | weekly-report | time: Mon | `[ "$(date +%u)" = 1 ]` | /weekly-report flow per CLAUDE.md | 1/week |
| 2 | inbox | state | `test -s inbox/pending.txt` | process one pending item | 4/day |
| 3 | queue | queue | `bv --robot-next \| jq -e .id` | work the bv --robot-next top pick | 2/day |
```

- **priority** — rows evaluated ascending; first satisfied row fires.
- **check** — a bash one-liner; exit 0 = the trigger condition holds.
- **action** — what to do: a skill invocation, a named flow from the
  project's CLAUDE.md, or "work the top pick".
- **cap** — max fires per day/week, enforced against the ledger.

No `refs/pulse.md` → `/pulse tick` refuses and points at
`/pulse setup`. The table is Andrew's steering wheel: he edits rows,
caps, and priorities; ticks never edit the table themselves.

## The ledger: refs/pulse-ledger.jsonl

Append one line per tick:

```json
{"ts":"2026-06-16T09:00:12Z","row":"weekly-report","outcome":"done","bead":"wr-abc","note":"report drafted + pushed"}
{"ts":"2026-06-17T09:00:09Z","row":null,"outcome":"quiet","note":"no row satisfied"}
```

`ts` is UTC (`date -u +%FT%TZ`). Caps count **only `outcome:"done"`**
entries for the row in the current day/week — a blocked or quiet tick
did no work and must NOT consume a research slot. And because `ts` is
UTC while caps are reckoned in the project's local day, **convert each
ts to the project timezone before matching the day** — a naive
`grep "$(date +%F)"` against UTC stamps mis-buckets ticks near the day
boundary. Canonical count (PT project, today's done-fires):

```bash
TODAY=$(TZ=America/Los_Angeles date +%F)
COUNT=$(jq -r 'select(.outcome=="done" and .row=="<row>") | .ts' refs/pulse-ledger.jsonl 2>/dev/null \
  | while read -r ts; do TZ=America/Los_Angeles date -d "$ts" +%F; done \
  | grep -cx "$TODAY")
# fire only if COUNT < cap
```

Working ticks commit the ledger with their work; blocked ticks commit
it alongside the `human:` bead (audit trail); quiet ticks leave it
uncommitted until the next working tick sweeps it in (don't generate a
commit per no-op).

## Tick procedure (`/pulse tick`)

0. **Honor `.offboard-pending`** if present (retroactive /offboard,
   as /onboard Step 0).
1. **Cheap onboard** — skip what's already in context (the durable
   session accumulates it): CLAUDE.md, TOOLKIT digest,
   `refs/session-handoff.md`, `br list`.
2. **Read `refs/pulse.md` + the ledger.** Refuse politely if no table.
3. **Evaluate rows by priority**: run each `check`; skip rows whose
   cap is exhausted; the first satisfied row fires. None → quiet tick:
   append ledger, say one line, STOP.
4. **Execute the action with full discipline** — beads for the work,
   worktree subagents for code, /scrutinize gate on impl, commit AND
   push (always-push), exactly as an interactive session would. ONE
   row per tick, no matter how tempting the backlog looks.
5. **Wrap**: append the ledger entry; write `refs/session-handoff.md`
   (/offboard Steps 3+5 — the handoff is per-tick; the session itself
   persists for the next tick, so don't exit or /clear).
6. **End with a one-line state report** ("tick: weekly-report fired,
   wr-abc closed, pushed; next eligible rows: inbox").

## Blocked-on-Andrew protocol

A tick **never** blocks on AskUserQuestion — there's nobody at the
keyboard, and an open dialog would freeze the window until Andrew
happens by. Instead:

1. `br create -p 1 "human: <what's needed + why>"` in the project.
2. Push a notification (PushNotification tool / remote control) naming
   the project and the bead.
3. Append the ledger entry with `"outcome":"blocked"`, end the tick.

The 🔔 lexicon + the `human:` bead + the push are the same "needs
Andrew" signal everywhere. (Interactive sessions do the opposite —
AGENTS.md "Surfacing to Andrew" says use AskUserQuestion. The split is
deliberate: dialogs for staffed sessions, beads for unstaffed ticks.)

## Setting up a project (`/pulse setup`)

1. Confirm the project has beads + CLAUDE.md (pulse assumes the full
   discipline stack).
2. Draft `refs/pulse.md` WITH Andrew — rows, caps, priorities are his
   call. Start with one row; grow after the first week of ledger.
3. Install the per-project units from the templates:
   ```bash
   cp ~/dotfiles/agents/scheduler/templates/pulse-example.service \
      ~/.config/systemd/user/pulse-<project>.service
   cp ~/dotfiles/agents/scheduler/templates/pulse-example.timer \
      ~/.config/systemd/user/pulse-<project>.timer
   # edit ExecStart (--dir, --cmd "/pulse tick") and OnCalendar, then:
   systemctl --user daemon-reload
   systemctl --user enable --now pulse-<project>.timer
   ```
4. Dry-run the injector once by hand and watch the window:
   ```bash
   ~/dotfiles/agents/scheduler/pulse-inject.sh \
     --dir /home/ubuntu/<project> --cmd "/pulse status"
   ```
5. Commit `refs/pulse.md` in the project; the units stay machine-local.

## `/pulse status`

Read the table + ledger and report: rows with caps remaining today,
last 5 ledger entries, open `human:` beads, timer state
(`systemctl --user list-timers 'pulse-*'`). No work, no writes.

## Session durability and context

The dedicated window's session receives many ticks and its context
grows. The compact-awareness guard (wave 4, shipped 2026-06-10:
`stop-context-guard.sh`) watches the official context % — statusline
persists it per-session — and at 85% an exit-2 Stop tells the agent
to /offboard immediately. When that fires mid-tick: finish nothing
new, /offboard, and `/clear` deliberately — the next tick re-onboards
from the handoff note. A PreCompact backstop runs in observe mode
(logs would-block decisions to /tmp/claude-compact-observe.log) until
a real auto-compact confirms blockability. Never let auto-compaction
surprise a tick mid-work.

## Anti-patterns

- ❌ **Two dispatches in one tick** — the backlog is the timer's
  problem, not this tick's. One row, stop.
- ❌ **AskUserQuestion in a tick** — freezes the window for hours.
  `human:` bead + push, end the tick.
- ❌ **Self-invoking the next tick** (ScheduleWakeup loops, recursive
  /pulse) — the systemd timer is the loop; a session that loops itself
  defeats the caps and the steering wheel.
- ❌ **Editing refs/pulse.md from inside a tick** — the table is
  Andrew's; propose changes via a `human:` bead.
- ❌ **Work without a bead / commit without a push** — unstaffed work
  needs MORE audit trail, not less.
- ❌ **Treating quiet ticks as failure** — quiet is the system working;
  log it and stand down.

## See also

- Spec + decisions: `cd ~/dotfiles && br show dotfiles-mhn`
- [scheduler/pulse-inject.sh](../../scheduler/pulse-inject.sh) — the injection primitive (tested)
- [/onboard](../onboard/SKILL.md), [/offboard](../offboard/SKILL.md) — the per-tick brackets
- [/orchestrator](../orchestrator/SKILL.md), [/scrutinize](../scrutinize/SKILL.md) — the work discipline inside a tick
- autonovel `/heartbeat` — the parent pattern (retires after migration)
