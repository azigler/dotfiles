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
{"ts":"2026-06-16T09:00:12Z","row":"weekly-report","outcome":"done","bead":"wr-abc","proof":{"kind":"cmd","cmd":"test -s reports/2026-06-16.md"},"note":"report drafted + pushed"}
{"ts":"2026-06-17T09:00:09Z","row":null,"outcome":"quiet","note":"no row satisfied"}
```

Every `done` line MUST carry a **`proof`** token — a machine-verifiable
claim that the work actually landed, enforced at commit by
`pre-commit-checks.sh` (a `done` line without a checkable proof is
**blocked**; `quiet`/`blocked` are exempt). A valid `done` proof must have
real verifier-**distance** — the checker must reach a verdict the generator
can't just assert. Two kinds qualify, strong on **different axes** (so neither
is unconditionally "strongest" — pick by work class):
- `{"kind":"cmd","cmd":"<shell>"}` — the hook **re-runs** it from the repo root; must exit 0. The un-fakeable **existence/structure** floor (a test, a grep of the deliverable for a required marker, an assertion; even `test -s <path>` beats file-exists because it re-runs). But it is **self-authored** — it proves the deliverable *exists and is shaped right*, not that it is *correct*: a mock-the-unit test or a well-formed-but-wrong output still passes. Best for research/output ("did the deliverable land").
- `{"kind":"scrutinize","bead":"<id>"}` — a `SHIP` verdict from an **independent** fresh-context reviewer. Catches the wrong / fabricated / mock-the-unit a self-authored `cmd` cannot (independence, not re-runnability). For **code / substantive** work this is the *stronger* proof — prefer it over `cmd`. (the `explore-umlu` two-axis reframe)

`artifact` (file exists) and `commit` (sha resolves) are **rejected for `done`** —
both are zero-distance no-ops a stub passes (the `explore-len0` hole): the generator
authored the very file/commit the checker inspects, so they prove *progress*, not
*done*. A report-only done with no gradeable deliverable uses `cmd` with a minimal
`test -s <path>`.

`ts` is UTC (`date -u +%FT%TZ`). Caps count **only `outcome:"done"`**
entries for the row in the current day/week — a blocked or quiet tick
did no work and must NOT consume a research slot. And because `ts` is
UTC while caps are reckoned in the project's local day, **convert each
ts to the project timezone before matching the day** — a naive
`grep "$(date +%F)"` against UTC stamps mis-buckets ticks near the day
boundary. Canonical count (PT project, today's done-fires):

```bash
# $PULSE_DIR = the absolute project dir pulse-inject passed (see Tick procedure).
TODAY=$(TZ=America/Los_Angeles date +%F)
COUNT=$(jq -r 'select(.outcome=="done" and .row=="<row>") | .ts' "$PULSE_DIR/refs/pulse-ledger.jsonl" 2>/dev/null \
  | while read -r ts; do TZ=America/Los_Angeles date -d "$ts" +%F; done \
  | grep -cx "$TODAY")
# fire only if COUNT < cap
```

**Prefer a mechanical helper over hand-rolling this.** The one-liner above is
correct, but it is copy-pasted into every tick and is one slip (a naive
`grep "$(date +%F)"` against the UTC `ts`) from a real boundary bug: the day's
LAST fire (18:00 PT) carries a `ts` on the NEXT UTC calendar day, so a naive
count mis-buckets it forward, and the next day then **refuses its legitimate
final tick as cap-exhausted**. If the project ships a cap helper, call it
instead — `~/explore/bin/pulse-cap.py` is the reference implementation
(`--row <row> --cap <n>`; exit 0 = under cap, exit 1 = skip; `--selftest`
carries the boundary regression). Diagnosed 2026-07-23 (Zig) on the explore
`vibe-explore` loop.

Working ticks commit the ledger with their work; blocked ticks commit
it alongside the `human:` bead (audit trail); quiet ticks leave it
uncommitted until the next working tick sweeps it in (don't generate a
commit per no-op).

## Tick procedure (`/pulse tick <project-dir>`)

pulse-inject passes the project's **absolute** directory as the argument
(you'll see e.g. `ARGUMENTS: tick /home/ubuntu/explore`). Take that path as
`PULSE_DIR` and **anchor every ledger/table read and write to it** —
`$PULSE_DIR/refs/pulse.md`, `$PULSE_DIR/refs/pulse-ledger.jsonl`, absolute,
throughout the tick. (If no dir was passed, fall back to the current
directory.) **Never use a bare relative `refs/...` path:** a long-lived
pulse session's shell cwd drifts — a stray `cd` in one tick persists into
the next — so a relative ledger path silently resolves against another
project and crosses ledgers. (Observed 2026-06-19: an explore tick whose
cwd had drifted read the local-coding-models ledger and nearly double-fired
the daily cap.)

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
4.5. **Verify before you log `done` (don't self-declare).** A tick is the
   generator AND, by default, the thing that writes its own
   `outcome:"done"` — that is the **nodding loop** (Loop Engineering §VI):
   the doer grading its own homework. Before writing `done`, produce a
   **concrete, checkable proof**, not a self-report:
   - the commit is actually pushed (`git log/status` confirms), the test
     is green (re-run it), the artifact exists, the card/bead state
     actually changed — assert it, don't assume it.
   - for **substantive/code** work, the proof is the **/scrutinize**
     verdict (an independent fresh-context reviewer) — gate `done` on its
     SHIP and record `"proof":{"kind":"scrutinize","bead":"<id>"}`.
   - for **research/curation** ticks, the proof is a `cmd` the hook re-runs
     that greps the deliverable for a required marker (or `test -s <the
     FINDINGS/report file>` at minimum) — `"proof":{"kind":"cmd","cmd":"…"}`.
   **This is not advisory — it's enforced.** Write the `proof` token (see
   the ledger spec above) on the `done` line; `pre-commit-checks.sh` blocks
   a `done` commit whose proof doesn't verify. If you cannot produce a
   real proof, log `blocked` or `quiet`, not `done`.
5. **Wrap**: append the ledger entry (only `done` once 4.5's proof holds);
   write the handoff note (/offboard Steps 3+5 — the handoff is per-tick; the
   session persists for the next tick, so don't exit/clear). Resolve the path
   via `handoff-path.sh` (`handoff_path "$PULSE_DIR"`), NOT a hardcoded
   `refs/session-handoff.md`: a pulse project that also runs another durable
   session (e.g. `~/explore` has the pulse window AND the elevate window) opts
   in with `refs/.handoff-per-window`, and the handoff is then
   `refs/session-handoff--<window>.md` so the two sessions don't clobber each
   other's resume doc. Anchor it to `$PULSE_DIR`, like the ledger.
   **Structural review cadence.** Human review is a *permanent* loop
   feature, not only the blocked-tick exception (Loop Engineering §XI.C:
   "keep one door open") — it keeps Andrew capable of saying "no" before
   comprehension rot sets in. The DEFAULT trigger is a count: every **5th**
   `done` tick for a row, surface a lightweight review nudge (a `human:`
   review bead + push, or — interactive — an AskUserQuestion) listing the
   last 5 outputs for him to sample. **But a count is an arbitrary default,
   not sacred** — it reviews the 5th output regardless of whether any of the
   5 mattered, and it fires even while Andrew is actively watching the loop
   (when he *is* the review). So **a loop MAY delegate this review to a
   better-keyed mechanism** by declaring it in its `refs/pulse.md`; a tick
   whose row is so delegated **skips the count nudge entirely**. The
   canonical example: `~/explore` delegates the `vibe-explore` review to the
   **weekly `/elevate` sweep** (Fri), which re-reads the week's finished work
   anyway and can key the review off *signal* (an output that drifted /
   overclaimed / recommends a build) rather than a tally — see the explore
   pulse table. Prefer a signal- or absence-keyed review to the count where
   one exists.
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

## Relocating a pulse loop's home (moving it between projects)

Moving a pulse loop from one project to another (e.g. daily-digest
weekly-reporting → explore) is a **single atomic unit** — a loop has FOUR
coupled pieces that must all move together, or the dashboard desyncs. This is
not hypothetical: on 2026-07-07 the daily-digest ledger was migrated into
`~/explore` by one session while another had just pointed the manifest at the
*old* path, so the manifest dangled at a deleted file and the loop read
"unknown — ledger unreadable." Move all four, in one session:

1. **The ledger file** — move `refs/<ledger>.jsonl` to the new project's `refs/`
   **with its full history** (`git mv`, don't recreate — you lose the streak).
2. **The skill + steering** — move them and repoint every path inside
   (`$WR`/`$EX`/absolute) to the new home, so the skill *writes* the ledger at
   the new project-relative path.
3. **The harnessd manifest** (`~/harnessd/refs/harness-manifest.json`) — move the
   loop's entry into the new project's `loops[]` **and update its `ledger` to the
   new project-relative path** (prefer relative over a cross-project absolute).
   This is the piece most easily forgotten because it lives in a *different repo*.
4. **The timer** — only if `--dir`/`--window` in the systemd unit changed; the
   ledger move alone doesn't touch it. (A brand-new ledger needs a seed `quiet`
   row so it doesn't read stale before the first fire; a *moved* ledger carries
   its history and needs none.)

**Verify + coordinate:**
- Regenerate and check: `python3 ~/harnessd/bin/harness_state.py` → the loop must
  read a real outcome, **0 "unknown/unreadable"**; then `~/harnessd/bin/harness-refresh`
  to push to the dashboard.
- **If another durable session shares the working tree, claim the move first** (a
  bead or a handoff line). A cross-cutting relocation half-done from two sessions
  is exactly how the manifest pointer and the files desync — the shared-tree
  version of the graduation `.service`-moved-but-`.timer`-dropped bug (`/graduate`
  step 4d.5 is the systemd-symlink analogue of this checklist).

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

**The /clear is a HUMAN action — you must SUMMON Andrew with an
AskUserQuestion, not just prose (Zig, 2026-07-22).** The agent CANNOT
issue `/clear` itself; the window is a durable session that keeps
receiving ticks, so it will sit context-full and defer every future
tick until Andrew physically comes and clears it. Therefore, once you
have offboarded (handoff written + committed + pushed), **end the turn
with an `AskUserQuestion`** asking him to `/clear` (or `/compact`) the
window — e.g. *"explore session is context-full at 85% and offboarded;
clear it so the loop resumes? [Clear it now / Leave it]"*. This is the
**one sanctioned exception** to the "ticks never AskUserQuestion" rule
(below), and it is exactly right here: the AskUserQuestion is the
*notification mechanism* — the tmux 🔔 **and** the harness app
notification fire on it regardless of Remote Control state, where a
`PushNotification` may silently no-op and a `human:` bead sits unseen —
and "freezing the window" is a feature, not a bug, because the session
is offboarded and has **nothing else to do** until it is cleared.
Stopping one step short (a prose "please /clear" with no
AskUserQuestion) leaves Andrew un-notified and the loop stalled. Send a
`PushNotification` alongside it too (best-effort), but the
AskUserQuestion is the load-bearing summon.

## Anti-patterns

- ❌ **Two dispatches in one tick** — the backlog is the timer's
  problem, not this tick's. One row, stop.
- ❌ **AskUserQuestion in a tick** — freezes the window for hours.
  `human:` bead + push, end the tick. **ONE exception (Zig, 2026-07-22):
  when the session is context-full at the 85% guard and needs Andrew to
  manually `/clear` it, DO end with an AskUserQuestion to summon him —
  see "Session durability and context" above. The window is offboarded
  with nothing else to do, so the freeze is the point, and the dialog is
  the only notification that reliably reaches him.**
- ❌ **Self-invoking the next tick** (ScheduleWakeup loops, recursive
  /pulse) — the systemd timer is the loop; a session that loops itself
  defeats the caps and the steering wheel.
- ❌ **Editing refs/pulse.md from inside a tick** — the table is
  Andrew's; propose changes via a `human:` bead.
- ❌ **Work without a bead / commit without a push** — unstaffed work
  needs MORE audit trail, not less.
- ❌ **Treating quiet ticks as failure** — quiet is the system working;
  log it and stand down.
- ❌ **Bare relative ledger/table paths** — anchor to the absolute
  `$PULSE_DIR` pulse-inject passes. A durable session's cwd drifts, so
  `refs/pulse-ledger.jsonl` can resolve to another project's ledger
  (observed 2026-06-19: an explore tick read the local-coding-models
  ledger and nearly double-fired the daily cap).

## See also

- Spec + decisions: `cd ~/dotfiles && br show dotfiles-mhn`
- [scheduler/pulse-inject.sh](../../scheduler/pulse-inject.sh) — the injection primitive (tested)
- [/onboard](../onboard/SKILL.md), [/offboard](../offboard/SKILL.md) — the per-tick brackets
- [/orchestrator](../orchestrator/SKILL.md), [/scrutinize](../scrutinize/SKILL.md) — the work discipline inside a tick
- autonovel `/heartbeat` — the parent pattern (retires after migration)
