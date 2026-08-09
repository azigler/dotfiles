# Session handoff — 2026-08-09 1c899e2f (marshal, night run 5)

## State at offboard
- Current branch: main (dotfiles); harnessd main at 87271df, pushed
- Last commit (dotfiles): 7066d65 at session start; this session's dotfiles writes are beads-jsonl only (gn64/lkb6, committed below)
- Open beads: run `br ready` (never a list here)
- In-flight subagents: none — g7qd builder completed, scrutiny was synchronous, worktree reaped
- Dirty files: .beads/issues.jsonl (committed in the offboard commit)
- Markers: `.offboard-pending` cleared

## What happened this session (bullets)
- **Marshal night 2026-08-09, run 5 (kjjf serial supervised floor-run campaign): harnessd-g7qd LANDED and CLOSED** — seat-aware roster joining fleet[] to seats.yml. Merge 3d4cd5f on harnessd main, MARSHAL_VERIFY_RESULT=ok, go test + make test (335/335 UI) green ON MAIN, fable scrutiny ACCEPT (model-diverse from the opus builder), pushed 87271df. First clean landing since run 1; ledger failure streak reset 3→0.
- Wave-1 pick harnessd-9gvd was NOT dispatched — parked earlier tonight (park-repeat-failure, yyv9 holds Zig's option-2 ruling). The planner still offered it; the ledger read caught it → filed dotfiles-gn64.
- Budget was degraded (150k floor, weekly-cap-unset) and exhausted by the single wave (builder 243.4k + scrutiny). Waves 3–12 of the plan remain queued for a funded night. Night-start/dispatched/merged/night-end/molt rows all in the drain ledger.
- Builder findings routed: harnessd-edwu comment (pulse-escalate/marshal/seneschal are enabled timers with no manifest row — make audit exits 1 on main today), harnessd-m2lt (specs/state-bus.md §4 drifted four sections behind the bus), harnessd-l1zj (parity goOnlyKeys is name-global, wants panel scoping).
- **harnessd is NOT deployed** — the live daemon predates even b1v6; nothing from b1v6 or g7qd is user-visible until `make deploy` (deploy_drift audit finding). Deliberately left to Zig/a funded session.
- Main moved under the campaign mid-build (6cd1fd5→9706edf, bead-state commits incl. Zig rulings); the guarded merge absorbed it cleanly — the two-writers idiom held.

## Friction
- marshal-drain plan re-offered the parked 9gvd as wave-1 → filed dotfiles-gn64 (friction)
- Harness resets shell cwd to the project root after EVERY Bash call, voiding AGENTS.md's mandatory standalone-cd step 0; worked around with `cd <root> && …` per call → filed dotfiles-lkb6 (friction)
- `br comment` vs `br comments add` CLI shape; pre-bead-create gate rejected a description missing `## Acceptance Criteria` (gate working as designed) → one-off

## Decisions made this session (autonomous decide-and-proceed calls)
- Per the marshal charter ("writes no specs and no decisions"), this seat filed no `-t decision` beads; its three non-trivial calls are durably recorded in the g7qd close reason + drain-ledger rows instead: (1) skip parked 9gvd, no third attempt; (2) ACCEPT the builder's parity goOnlyKeys deviation (4-precedent mechanism, comparator logic unchanged; hardening → harnessd-l1zj); (3) do NOT deploy at night.
- `dotfiles-t06l` — decision needed: Bead-trailer exemption for routine unattended-daemon output commits (filed since session start by a CONCURRENT writer, not this seat; left open)

## Proposed practices — where each one landed (Step 2.6)
- none this session

## What's next
- Next marshal tick: re-run `marshal-drain.sh plan`; waves 3–12 queued (next up: harnessd-wfyx, pwa rename to 'Demesne'). Skip anything the tonight-ledger parks until dotfiles-gn64 lands.
- `make deploy` in harnessd needs a decision — live daemon is now two landed waves behind main.
- harnessd-yyv9 carries Zig's option-2 ruling on 9gvd; whoever owns that lane should action it.

## Warnings / watch-outs
- Budget stays degraded (weekly-cap-unset) — every run tonight blew past the 150k floor on builder+scrutiny; the floor bounds dispatch count, not landing cost. Knobs are Zig's, in marshal.conf.
- Failure streak is 0 now, but three-strikes counts distinct beads across the NIGHT (2026-08-09) — a same-night restart inherits ledger history, which is correct; read the ledger before trusting the plan.
- A boundary molt was initiated detached (seat-molt --mode auto) and fires when this pane idles; verdict in /tmp/seat-molt.log, not claimed in the ledger (betl).
