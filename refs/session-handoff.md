# Session handoff — 2026-08-09 538b7ef4 (MID-CUTOVER — fresh session: run the verify, nothing else)

## ⚠️ FIRST ACTION for the onboarding session — post-flip verification

You are the fresh context deliberately cycled to verify the demesne cutover
(860z flip, executed by the Master of Works session). Do NOT start normal
work. The freeze on systemd timers and bead-store MUTATIONS is still on
until you report PASS (reads are fine). Run these five checks and report
PASS/FAIL **per item** to the Works session — find it via ListAgents
(shown last as `dotfiles-85 [cde6f9]`, tmux window "dotfiles-2",
socket uds:/run/user/1000/cc-socks/3301441.sock) and SendMessage:

- (a) Session start: did the session-start header render (seat/office
  line proves hooks fire)? You witnessed this at your own start.
- (b) Statusline renders (check your own pane / statusline output).
- (c) `ls -la ~/.claude` — all six links (CLAUDE.md, agents, hooks,
  skills, settings.json, statusline.sh) resolve into the demesne tier
  (→ ~/.agents → ~/demesne). Same six for `ls -la ~/.claude-work`.
- (d) `br list` works from ~/dotfiles (read-only is enough).
- (e) `echo $CLAUDE_EFFORT` — expected `high` (or empty = default high),
  i.e. unchanged.

On PASS the Works session unfreezes, /clears the remaining windows, and
starts the soak; afterward this lane resumes normal duty under the sbv2
grant (maiden marshal launch is the Works session's step — coordinate
before touching it). On any FAIL: report it exactly; the Works session
stops and restores the freeze snapshot.

## State at offboard
- Current branch: main, clean; last commit 65df27b (pre-flip tier commits are the peer's)
- In-flight subagents: none. Dirty files: none (this note is the only change).
- Markers: `.offboard-pending` cleared by this offboard.

## What happened this session
- Coordination only: onboarded fresh, announced the window cycle to the
  Works session (lifting its cutover freeze condition), negotiated and
  held the quiet-lane hold during its flip sequence, received FLIP DONE,
  offboarded for the verify molt. No code, no bead mutations, no commits
  besides this note.

## Friction
- nothing notable

## Decisions made this session
- `dotfiles-sbv2` — Zig's 2026-08-09 execution grant (the Works session's
  bead, filed in the overlapping window; listed for completeness — not
  this lane's decision)

## Proposed practices — where each one landed
- none this session

## What's next
1. The ⚠️ verify block above — that is the whole job.
2. After PASS + unfreeze: normal orchestrator duty resumes; sbv2 sequence
   continues on the Works session's side (maiden marshal, timer arming).

## Warnings / watch-outs
- The Works session's own offboard will overwrite this note after the
  clear-all step — expected, both land in git history.
- Two war stories from the flip (peer-reported): claude-settings-guard.path
  (a PATH unit, invisible to timer-derived freeze) was reverting the flip
  within 2s — retargeted in explore 2eb1d7b; the rgyy jail symlink wedge
  fired live — fixed host-side, jail suite 33/33.
