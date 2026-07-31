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
- **check** — a bash one-liner. **Three-valued, not boolean** (see below):
  `0` = the trigger holds; `1` = it genuinely does not; `3` = the check
  could not be evaluated at all.
- **action** — what to do: a skill invocation, a named flow from the
  project's CLAUDE.md, or "work the top pick".
- **cap** — max fires per day/week, enforced against the ledger.

No `refs/pulse.md` → `/pulse tick` refuses and points at
`/pulse setup`. The table is Andrew's steering wheel: he edits rows,
caps, and priorities; ticks never edit the table themselves.

### A check is THREE-valued — "didn't fire" and "couldn't tell" are different

| rc | Meaning | What the tick MUST do |
|---|---|---|
| `0` | the trigger condition holds | **FIRE** this row |
| `1` | it genuinely does not hold (empty queue, wrong weekday) | move to the next row; if none fire, `outcome:"quiet"` |
| `3` | **could not be evaluated** — transport/auth/shape failure, the check never saw an answer | **DO NOT FIRE** — log `outcome:"blocked"`, note the check's own stderr, end the tick |

This is the **same rule as the cap helper's rc `2`**, one layer up, and for
the same reason: *"could not determine" is an error, never a permissive
default.* A binary check has no way to say it failed, so every failure is
indistinguishable from an empty queue — and an empty queue is the quietest,
most reassuring thing a loop can report.

⚠️ **This is not hypothetical — it is why the `dive` loop went blind for a
day and looked healthy doing it** (2026-07-27, `explore-pksf`). Its check
piped `curl` straight into `jq -e`. When the qmsy jail flip closed the read
path, `curl` emitted a `403 {"error":"Invalid bearer token"}` body, `jq`
exited non-zero on it, and the tick logged **`quiet` — "no cards"**. Four
fires a day, indefinitely, from a loop that could not see a single card.
Nothing errored; nothing tripped.

The shape that fixes it — fail LOUD on anything that is not a well-formed
answer, and only then ask the real question:

```bash
resp=$(curl -sf -H "Authorization: Bearer $TOKEN" "$URL") || exit 3  # transport/HTTP error
echo "$resp" | jq -e 'has("data")' >/dev/null || exit 3              # not the shape we expect
echo "$resp" | jq -e '[.data[] | select(...)] | length > 0'          # 0/1 = the real verdict
```

`curl -sf` (not bare `curl -s`) is what makes an HTTP 4xx/5xx a non-zero
exit instead of a body that `jq` then misreads as data. **Any check that
crosses a network or reads a file it does not own needs all three rungs.**
A check that can only say yes-or-no cannot report that it is broken —
and per this repo's rule, a probe with no way to fail loudly has no
positive control.

Rows written before this contract return only `0`/`1`, so they are
unaffected; `3` is purely additive.

## The ledger: refs/pulse-ledger.jsonl

Append one line per tick:

```json
{"ts":"2026-06-16T09:00:12Z","row":"weekly-report","outcome":"done","bead":"wr-abc","proof":{"kind":"cmd","cmd":"test -s reports/2026-06-16.md"},"note":"report drafted + pushed"}
{"ts":"2026-06-17T09:00:09Z","row":"weekly-report","outcome":"quiet","note":"cap exhausted (1/1 this week); no lower-priority row satisfied"}
```

**`row` is NEVER `null` — not even on a quiet tick.** `pulse-cap.py` and every
per-row analytic (harnessd, `/pulse status`, the dashboard) key on the row
**name**, so a null-row line is invisible to all of them: the tick happened,
consumed budget, and cannot be attributed. Always name the row the tick
**evaluated** — the row whose cap was exhausted or whose `check` failed — even
though it did not fire. If NOTHING was evaluated (no table rows at all, or a
fire genuinely outside the routing table), write the literal string
`"unattributed"`; that is the honest, visible gap marker and the only escape
hatch. A confabulated row name is worse than `unattributed`, and `null` is
worse than both. (This example itself taught the bug: 23 null rows across three
ledgers, 2026-06-14 → 2026-07-08, were copied verbatim from the line that used
to sit here — `explore-qdo5`.) The mechanical guard is
`~/dotfiles/agents/scheduler/pulse-ledger-lint.py` — run it against any pulse
project, it discovers valid row names by parsing that project's `refs/pulse.md`:

```bash
python3 ~/dotfiles/agents/scheduler/pulse-ledger-lint.py --project "$PULSE_DIR"
# exit 0 = clean · 1 = violations · 2 = usage/missing file
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

**A `cmd` proof's CONTENT must have distance too, or it is `artifact` wearing a
permitted label.** At least one clause must run something that reaches a verdict
the tick did not author — a test, a linter, a validator, a `--selftest`. A `cmd`
whose every clause only re-reads the tick's own output (`test -s <the thing I
just wrote>`, `<my CLI> | grep -q '<the string I just wrote>'`) is refused for
the same reason `artifact` is, and passing the `kind` check does not save it.
Evidence: autonoveld's tick 1 (`refs/pulse-tick1-postmortem.md` §5c) shipped a
three-clause `cmd` proof where **two clauses had zero distance** — and it still
re-ran green from a clean checkout, because re-runnability and independence are
different axes. Only its pytest clause could have caught a wrong result.

`ts` is UTC (`date -u +%FT%TZ`). Caps count **only `outcome:"done"`**
entries for the row in the current day/week — a blocked or quiet tick
did no work and must NOT consume a research slot. And because `ts` is
UTC while caps are reckoned in the project's local day, **convert each
ts to the project timezone before matching the day** — a naive
`grep "$(date +%F)"` against UTC stamps mis-buckets ticks near the day
boundary. Canonical count (PT project, today's done-fires):

```bash
# $PULSE_DIR = the absolute project dir pulse-inject passed (see Tick procedure).
ROW=weekly-report        # substitute the real row name — never leave a placeholder
TODAY=$(TZ=America/Los_Angeles date +%F)
COUNT=$(jq -r --arg row "$ROW" 'select(.outcome=="done" and .row==$row) | .ts' \
    "$PULSE_DIR/refs/pulse-ledger.jsonl" \
  | while read -r ts; do TZ=America/Los_Angeles date -d "$ts" +%F; done \
  | grep -cx "$TODAY")
# fire only if COUNT < cap.
# No `2>/dev/null` here on purpose: a missing or unreadable ledger must surface
# as an error, not collapse to COUNT=0 — which reads as "under cap" and fires.
```

**Prefer a mechanical helper over hand-rolling this.** The one-liner above is
correct, but it is copy-pasted into every tick and is one slip (a naive
`grep "$(date +%F)"` against the UTC `ts`) from a real boundary bug: the day's
LAST fire (18:00 PT) carries a `ts` on the NEXT UTC calendar day, so a naive
count mis-buckets it forward, and the next day then **refuses its legitimate
final tick as cap-exhausted**. If the project ships a cap helper, call it
instead — `~/explore/bin/pulse-cap.py` is the reference implementation
(`--row <row> --cap <n>`; `--selftest` carries the boundary regression).
Diagnosed 2026-07-23 (Zig) on the explore `dive` loop (then named
`vibe-explore`).

**Branch on ALL THREE exit codes — there is no "else" that is safe.** The
helper distinguishes *under cap*, *at cap*, and *could not tell*, and the
third one is the whole point: a tick that treats "couldn't read the ledger"
as "not at cap" fires blind, forever, and nothing trips.

| rc | Meaning | What the tick MUST do |
|---|---|---|
| `0` | under cap | **FIRE** the tick normally |
| `1` | at cap for this row today | **DO NOT FIRE** — log `outcome:"quiet"`, note `cap reached`, end the tick |
| `2` | **could not determine** (ledger missing/unreadable) | **DO NOT FIRE** — log `outcome:"blocked"`, note the helper's own stderr line, end the tick |

`2` is an error, not a permissive default. Treating a non-zero rc as a plain
"skip" is *almost* right; treating a non-`1` rc as "go" is the bug — a
missing ledger would then read as zero fires today and the loop would fire on
every tick, silently, with no ledger to notice it in.

**Read the helper's stderr — do not suppress it.** The rc `2` path prints
`pulse-cap: ledger not found: <path>` on **stderr** and nothing on stdout, and
that line is the only thing that says WHICH path was wrong. Call it plainly:

```bash
if CAP_OUT=$(python3 ~/explore/bin/pulse-cap.py --ledger refs/pulse-ledger.jsonl --row "$ROW" --cap 2); then
  :                                   # rc 0 — under cap, fire
else
  rc=$?
  # rc 1 = at cap -> quiet;  rc 2 = unreadable ledger -> blocked.
  # $CAP_OUT is EMPTY on rc 2 by design; the diagnosis is on stderr, which
  # is deliberately NOT redirected here so it reaches the tick's transcript.
  [ "$rc" -eq 1 ] && echo "cap reached — logging quiet" || echo "cap UNDETERMINED (rc=$rc) — logging blocked"
fi
```

Never `2>/dev/null` this call. Same reasoning as the canonical count above:
suppressing the error turns a real failure into an empty result, and an empty
result reads as permission to fire.

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

0. **Honor the offboard-pending marker** if present (retroactive /offboard, as
   /onboard Step 0). ⚠️ **Resolve it with the helper — the marker is
   WINDOW-SCOPED, so the bare filename is the wrong file in exactly the
   projects that run a pulse loop.** A per-window project's marker is
   `.offboard-pending--<window>` (e.g. `.offboard-pending--dive`), and a tick
   that tests `[ -f .offboard-pending ]` finds nothing and reports a clean
   start:

   ```bash
   _HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
   type offboard_pending_path >/dev/null 2>&1 || offboard_pending_path() { printf '%s/.offboard-pending' "${1:-.}"; }
   PENDING=$(offboard_pending_path "$PULSE_DIR")
   [ -f "$PENDING" ] || [ -f "$PULSE_DIR/.offboard-pending" ]   # check BOTH, as /onboard does
   ```

   Missed live on 2026-07-27 in `~/explore`: the tick checked the bare path,
   found nothing, and ran a full tick while `.offboard-pending--dive` sat
   beside it — surfacing only at offboard, when the helper deleted a marker
   nobody had honored. Same failure as this skill's Step 5 handoff path
   (fixed 2026-07-26): a path that looks right, resolves wrong, and reports
   success. `/onboard` Step 0 already does this correctly — copy it, don't
   re-derive it.
1. **Cheap onboard** — skip what's already in context: CLAUDE.md, TOOLKIT
   digest, **the handoff note (resolve it, see below)**, `br list`.

   ⚠️ **Resolve the note with `handoff_read_path`, never the bare
   `refs/session-handoff.md`.** Step 5 *writes* through the helper and explains
   the per-window rule; this step used to *read* a hardcoded literal — a
   read/write asymmetry inside one skill. In a per-window project the bare file
   **does not exist at all** (`~/explore` has five: `--dive`, `--desk`,
   `--digest`, `--dream`, `--elevate`, and no plain one), so a tick following
   the literal finds nothing and concludes there is no prior handoff — or, in a
   project mid-transition, reads *another window's* session. The reader helper
   prefers the scoped file and falls back to the legacy path, which is exactly
   what /onboard uses:

   ```bash
   _HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
   type handoff_read_path >/dev/null 2>&1 || handoff_read_path() { printf '%s/refs/session-handoff.md' "${1:-.}"; }
   handoff_read_path "$PULSE_DIR"
   ```

   **Check, don't assume.** A
   loop running `--fresh` (see "Session durability and context") gets a
   `/clear` before every tick, so its context holds the always-loaded tier
   and *nothing else* — the handoff note in particular is NOT in it and must
   be read. A loop without `--fresh` accumulates across ticks and can skip
   more. Either way the handoff note is the continuity mechanism, not recall.
2. **Read `refs/pulse.md` + the ledger.** Refuse politely if no table.
3. **Evaluate rows by priority**: run each `check`; skip rows whose
   cap is exhausted; the first satisfied row fires. None → quiet tick:
   say one line, STOP.
   ⚠️ **A check that exits `3` STOPS the whole tick** — it did not fail to
   fire, it failed to *evaluate*, so falling through to the next row would
   report a lower-priority `quiet` while a higher-priority row is broken.
   Log `outcome:"blocked"` naming THAT row, carry the check's stderr into
   the note, and end the tick. Do not suppress that stderr — it is the only
   thing that says which leg broke. (See the three-valued table above.)
   **Decide the row first; write ONE ledger line, at step 5.** Do not append
   mid-evaluation. A row can pass its `check` and still do no work — its
   action scans and finds nothing — and a lower-priority row then fires
   instead, which makes the line you already wrote wrong. (Observed:
   autonoveld's tick 1 appended a `mail`/`quiet` line here and had to delete
   it when `voice-correction` turned out to be the firing row.) One tick, one
   line, written last, naming the row that did the work — or, if nothing
   fired, the last row evaluated.
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
5. **Wrap**: append the ledger entry (only `done` once 4.5's proof holds), then
   **assert the row is REGISTERED** (5.5 below);
   write the handoff note (/offboard Steps 3+5 — the handoff is per-tick).
   **Never `/clear` or exit the session yourself**: the window is durable and
   the injector owns context lifecycle (a self-clear mid-tick kills the tick).
   Under `--fresh` the *next* tick's `/clear` is sent by the injector before
   the command arrives — which makes the handoff note load-bearing, not
   optional, because nothing else survives into that tick. Resolve the path
   with the shared helper — **`~/dotfiles/agents/lib/handoff-path.sh`**, the
   same one /onboard and /offboard source (it is under `agents/lib/`, NOT
   `agents/scheduler/` with the other pulse machinery; a tick that guesses from
   the "See also" list below gets exit 127):

   ```bash
   _HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
   handoff_path "$PULSE_DIR"
   ```

   NOT a hardcoded `refs/session-handoff.md`: a pulse project that also runs
   another durable session (e.g. `~/explore` runs the `dive` pulse window AND
   the `desk` window) opts in with `refs/.handoff-per-window`, and the handoff
   is then `refs/session-handoff--<window>.md` so the two sessions don't
   clobber each other's resume doc. Anchor it to `$PULSE_DIR`, like the ledger.

   **A STANDING proposal must not live only in the handoff — promote it here,
   or it evaporates.** Run **/offboard Step 2.6** as part of this wrap; it is
   not optional for a loop. The per-tick handoff is the one artifact that
   *looks* durable while being overwritten every tick, so a practice proposed
   in it ("worth adopting as the standing second check…") reads, one tick
   later, exactly like a practice that was adopted — except nothing enforces
   it. Under `--fresh` it is worse, not better: the note is all that survives,
   so an unpromoted proposal dies the moment a tick doesn't happen to re-read
   it. Every hit goes into the loop's own contract / SKILL if mechanical, or a
   bead if it's a judgment call, **during this tick**; the handoff then records
   only *where it landed*. It fails in the same silent way the four loop costs
   do — nothing errors, nothing trips, and a practice everyone assumes is
   running was in fact never adopted (`explore-zl07`).

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
   canonical example: `~/explore` delegates the `dive` review to the
   **weekly `/desk` pass** (Fri), which re-reads the week's finished work
   anyway and can key the review off *signal* (an output that drifted /
   overclaimed / recommends a build) rather than a tally — see the explore
   pulse table. Prefer a signal- or absence-keyed review to the count where
   one exists.
5.5. **Assert the row is REGISTERED, not just well-formed.** Everything up to here
   checks the row you WRITE — `pulse-ledger-lint.py` checks the name is canonical,
   `pre-commit-checks.sh` re-runs the `done` proof. **Nothing checks that the dashboard
   can FIND it.** A registration defect — a `~/harnessd/refs/harness-manifest.json` entry
   whose `ledger_row` doesn't match what this loop actually writes, or `null` there — is
   invisible while every local gate passes green: the matcher returns **zero** rows, so
   the loop reads `stale` / *"no ledger row within grace (exit-0 lie)"* immediately after
   writing one.

   That is not cosmetic. On 2026-07-26 the `daily-digest` loop correctly logged
   `outcome:"blocked"` with a P1 `human:` bead — a genuine parked-on-Zig signal — and the
   dashboard rendered it as an infrastructure alarm for **12 hours**, because its manifest
   entry had `ledger_row: null`. **A needs-Zig signal was masked as a plumbing failure.**
   (`explore-4x39`.) The failure mode is doubly bad: a false alarm on a healthy loop trains
   you to discount the alarm that will matter.

   ```bash
   LOOP_ID=pulse-<project>          # the systemd timer stem
   ROW=<the row this tick just wrote>

   ~/harnessd/bin/harness-assert-registration "$LOOP_ID" "$ROW"
   # exit 0 registered · 1 registration gap · 2 published state not trustworthy yet · 3 usage
   ```

   **A failure here is NOT a reason to rewrite the row** — the row is fine. Fix the
   manifest (it lives in a *different repo*, which is why the `/pulse` relocation checklist
   already calls it "the piece most easily forgotten"), then re-assert.

   ⚠️ **Do NOT hand-run `harness_state.py` first — that is the FALSE GREEN this script
   exists to remove** (`explore-vuro`, fixed 2026-07-31). `harnessd` publishes `state.json`
   itself; your own regen reads the fix while the daemon keeps writing the broken value
   into the same file (measured 2026-07-27: a hand run reported the corrected row while the
   daemon's regen *seconds later* wrote the stale one). The script reads only what the
   daemon published, and gates every assert behind a freshness check keyed to the newest of
   the **manifest and ledger** mtimes — the old `until [ … state.json -gt … manifest ]`
   wait exited instantly whenever the manifest was older than what actually changed, and
   had no timeout, so a dead daemon hung the tick forever. The wait here is bounded
   (`--timeout`, default 180s), fails loud, and fails immediately if `harnessd` is not
   active. No manifest edit → no wait.

   (The daemon hot-reloads a changed manifest per regen since `harnessd-rtx8`, so no
   restart is needed. The assertion stays regardless: it also catches a row name that
   drifts from the manifest, which no daemon fix covers.)

   **The sibling failure, for a row that is NEW rather than mis-registered:** a brand-new
   row name has no history behind it, so a carried-over systemd stamp file (see the rename
   warning in `/pulse setup` step 3) makes `last_fire` point at the *predecessor* loop's run
   with zero rows of its own — reading `stale` before it has ever fired. Fix is the seed row
   the relocation checklist prescribes: append one `outcome:"quiet"` row saying exactly
   that, **before** the first real fire. This bit `desk` after the 2026-07-26 rename.

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
   ⚠️ **RENAMING an existing `Persistent=true` timer? Carry its STAMP FILE.**
   systemd's persistence state is `~/.local/share/systemd/timers/stamp-<unit>.timer`,
   **not** the unit file's mtime. A new unit name has no stamp, which reads as an
   elapsed slot, so it fires an immediate **phantom catch-up tick** on enable:
   ```bash
   mv ~/.local/share/systemd/timers/stamp-pulse-<old>.timer \
      ~/.local/share/systemd/timers/stamp-pulse-<new>.timer
   systemctl --user daemon-reload
   systemctl --user list-timers pulse-<new>.timer   # LAST must show the OLD run
   ```
   This step is what makes a rename invisible to the loop. Verified on the
   `pulse-elevate` → `pulse-desk` rename, 2026-07-26 (`explore-mqvu`); the
   `/daemon` skill carries the same rule for non-pulse timers.
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

**Two independent variables, and only one of them costs anything:** *process
liveness* (is `claude` running in the pane?) and *context accumulation* (how
much conversation is that process carrying?). They were conflated for a long
time — "warm session" was assumed to mean "cheap, the cache is reused". It does
not: the prompt cache TTL is ~1h and pulse cadences are hours apart, so at
every scheduled tick the cache is already dead. Measured on the explore slug
(2026-07-25, `~/explore/refs/warm-session-collapse.md`): a warm resume after a
≥3h gap re-creates a **443k-token median** prefix — 84% of such resumes
re-create ≥99% of their context — against a **78k** first-turn floor. A warm
process buys **zero** cached tokens and pays full cache-creation on everything
it has accumulated.

**`--fresh` — warm process, cold context (opt-in per loop).** `pulse-inject.sh
--fresh` sends `/clear` to a warm pane before the tick command. The window,
the process, and Andrew's scrollback all survive; only the model's context
resets. There is no relaunch, so the cold-boot readiness race never enters the
hot path. Enable it in the loop's `.service` `ExecStart`; **default is off**
and no loop changes behavior without opting in.

Two verified consequences (bead `dotfiles-6ycc`, tested end-to-end 2026-07-25):

- **`/clear` re-resolves the always-loaded tier from DISK.** A sentinel line
  edited into a project `CLAUDE.md` *after* session start was quoted correctly
  by the post-`/clear` tick, with no file read in its tool log; same for a
  `memory/MEMORY.md` created after start. Each `/clear` mints a new session id
  in the same process. So a `--fresh` loop **cannot** act on a stale
  always-loaded snapshot — the session-age staleness bug (`explore-6wwu`)
  simply does not arise for it. (It still stands for durable sessions that do
  not clear, Andrew's interactive windows included.)
- **The ledger row survives the clear.** Row attribution comes from
  `$PULSE_DIR/refs/pulse.md` on disk, not from conversational memory, so a
  cleared tick names its row exactly as a warm one does. Verified: three
  consecutive ticks across two `/clear`s, all `"row":"e2e-probe"`.

**If you edit an always-loaded file — any `CLAUDE.md`, a `MEMORY.md`, a skill's
frontmatter description — the RUNNING windows will not see it until they
`/clear`.** That tier is read from disk once, at session start; every later
request carries the in-memory copy. So an edit made to fix a rule does not
reach the durable sessions still acting on the old rule, and nothing announces
the mismatch. Since 2026-07-26 the Stop hook `stop-always-loaded-check.sh`
(decision `explore-0z6r`) fingerprints that tier at session start and names, on
each Stop, exactly which file drifted and how long ago — it does **not** repair
anything and does **not** block, because a typo in a `CLAUDE.md` must never be
able to interrupt a running tick. When you see that warning: `/clear` the
window, or re-READ the named file before relying on any rule it states.

A loop that clears every tick also **cannot reach the 85% context guard**, so
for it the human-unblock step below is not a steady-state loop feature.

The compact-awareness guard (wave 4, shipped 2026-06-10:
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
- [scheduler/pulse-ledger-lint.py](../../scheduler/pulse-ledger-lint.py) — the ledger attribution gate (`--project <dir>`; row names discovered from that project's `refs/pulse.md`, never hardcoded)
- [lib/handoff-path.sh](../../lib/handoff-path.sh) — resolves the per-tick handoff note path (`handoff_path "$PULSE_DIR"`). Note the directory: **`agents/lib/`**, not `agents/scheduler/` like the three above — it is shared with /onboard and /offboard rather than being pulse machinery.
- [/onboard](../onboard/SKILL.md), [/offboard](../offboard/SKILL.md) — the per-tick brackets
- [/orchestrator](../orchestrator/SKILL.md), [/scrutinize](../scrutinize/SKILL.md) — the work discipline inside a tick
- autonovel `/heartbeat` — the parent pattern (retires after migration)
