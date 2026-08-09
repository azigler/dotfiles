# Session handoff — 2026-08-09 75c87999 (marshal window, night tick)

## State at offboard
- Current branch: main (dotfiles clean; last commit `31595ca`)
- harnessd: main at `302e345`, pushed
- In-flight subagents: none (wave-1 builder completed, landed, worktrees reaped)
- Dirty files: none
- Markers: `.offboard-pending` cleared

## What happened this session (bullets)
- **Marshal night 2026-08-09 ran and closed: 1 merged, 0 parked, 0 failed, ended on budget.**
- Plan verdict `planned:12` (all `serial:harnessd`), budget **degraded at the 150k floor**
  (`brake-5h`, u5h 0.88 → 0.90 by night end). Night ran at the floor per the rule.
- Wave 1 `harnessd-wfyx` (PWA → "Demesne") built by sonnet subagent, commit `846b3a4`,
  guarded-merged as `311d1a2` (verify=ok), suites green on main (`go test ./...` all,
  render suite 335/335), bead closed with evidence, pushed.
- Scrutiny **skipped** on wfyx: mechanical string-rename per /scrutinize's own exemption +
  floor budget could not fund it — recorded in close reason and marshal ledger.
- Follow-ups filed from builder's out-of-scope findings: `harnessd-oped` (geometry-harness
  fixture still says "Harness"), `harnessd-jkeq` (default push title — Zig's call). Unmarked;
  fleet certification stays Zig's.
- Ledger rows: night-start / merged / night-end all recorded; molt row + seat-molt follow
  this offboard.

## Friction
- The wave-1 builder alone consumed ~123k of the 150k floor budget — a degraded night
  funds exactly one sonnet builder on a task this size, so 11 planned picks went untouched.
  Not a defect (the floor is deliberately conservative) but worth knowing when reading
  "1 merged" nights. → one-off (budget-model tuning is Zig's knob, `marshal.conf`)
- Shell cwd resets to /home/ubuntu/dotfiles after every Bash call, so the mandated
  standalone `cd` before the guarded merge cannot persist; worked around with
  `cd <repo> && …` compounds per call. Recurs every cross-repo landing. → filed dotfiles-780x

## Decisions made this session (autonomous decide-and-proceed calls)
- No decision beads filed by this tick. The scrutiny-skip call on `harnessd-wfyx` is
  recorded in the bead close reason + marshal ledger (the marshal's review surface).
- Harvest over the wider since-last-offboard window surfaced two from the prior consul
  session, listed for continuity: `dotfiles-7ibz` (seat topology: THE CONSUL),
  `dotfiles-1aw8` (model-canon: aliases kept; canonicalisation at launch/restore boundary).

## Proposed practices — where each one landed (Step 2.6)
- none this session

## What's next
- Next marshal tick: 11 certified picks remain queued (waves 2–12 of tonight's plan);
  re-plan fresh — do NOT reuse tonight's wave numbers.
- If budget is still degraded at floor, expect another 1-bead night; the brief should say so.
- `harnessd-jkeq` needs Zig's taste call before anyone builds it (seneschal surface, not drain).

## Warnings / watch-outs
- harnessd SW cache is now `demesne-shell-v11` — installed clients update on next load;
  any hardcoded old cache-name reference elsewhere would be stale (builder grepped served
  assets clean; repo-internal identifiers deliberately kept).
- The 5h brake was tightening (0.88 → 0.90) during the night — daytime spend is high;
  early-morning ticks may see `no-budget`.
