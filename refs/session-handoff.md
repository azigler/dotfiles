# Session handoff — 2026-08-09, session d7033a72 → RESTART TO FABLE (dotfiles, personal tap)

> Written to hand this session to a FRESH Fable session mid-flight. The founding arc
> continues under Zig's standing cutover authority. Main is clean at HEAD, pushed.
> `git log -- refs/session-handoff.md` for prior notes.

## ⚠️ RESTART RECOVERY — DO THESE TWO THINGS FIRST (they did NOT survive the process)

**1. RE-ARM THE SCHEDULED AUTOMATION (was a session-only cron, now GONE).**
The old session held a one-shot cron (`4373abdb`, 11:37 UTC / ~04:37 PT today) that
(a) verifies tonight's MAIDEN FLEET DREAM tick then (b) runs pico's Tahoe upgrade.
A new process does NOT inherit it. **Re-create it** with CronCreate, one-shot, same
time (`37 11 9 8 *`) and this intent:
- Verify the 04:13 PT dream tick: `dream` window/ledger row has `slug:"(fleet)"` +
  `n_slugs`/`denied` keys (the lint now knows this shape — iyhh closed); cross-check
  the tick's model at pico's gateway `requests.db` vs the dream seat pin; spot-check
  its filed proposal beads for ZERO linearb/cfp content.
- If clean AND `/tmp/tahoe-download.log` on pico shows the payload finished: run the
  pico **Tahoe 26.6.1** upgrade per `dotfiles-xh18`'s recorded plan. Credential is
  STAGED: `pico:~/.secrets` → `$PICO_LOGIN_PASSWORD` (verified `dscl . -authonly pico`
  = AUTH-OK; account is `pico`, there is no `kevin`). Fully autonomous:
  `sudo softwareupdate -i 'macOS Tahoe 26.6.1-25G76' --restart --user pico --stdinpass`.
  FileVault off + auto-login → services return hands-free. Post-checklist: ports
  re-listening, gateway 401-healthy, vs14 200s, colima autostart VERIFIED, RomM up.
- Anomaly anywhere = stop and surface. Never improvise past a failed gate.

**2. HARVEST THE IN-FLIGHT WORKTREES (agent handles died; COMMITTED work survived).**
The old session had ~7 builders running. Their live handles are gone, but every
commit they made is durable on `worktree-agent-*` branches. Procedure:
```
cd /home/ubuntu/dotfiles && git fetch --all
for wt in $(git worktree list --porcelain | grep '^branch' | sed 's|branch refs/heads/||' | grep worktree-agent); do
  echo "== $wt : $(git rev-list --count main..$wt) commits ahead"
  git log --oneline main..$wt
done
```
For each branch WITH commits → run the guarded merge (below), suites on main, close
its bead(s) with evidence, cleanup. For each dispatched bead whose branch is EMPTY
(agent killed before committing) → the bead is still OPEN; **re-dispatch it**.

### The guarded merge (unchanged, the house sequence)
Standalone `cd /home/ubuntu/dotfiles`; commit dirty `.beads/issues.jsonl` first;
assert on main; BEFORE/AFTER sha moved; `git merge-base --is-ancestor <agent-sha> HEAD`;
run the touched suites ON MAIN; `br close` with `## Guard` evidence (from dotfiles cwd,
standalone calls); push; `git worktree remove --force --force <path>` + `git branch -D`.

## The dispatched builders at handoff — branch → bead → what to expect

| Branch (agent) | Bead(s) | State at handoff |
|---|---|---|
| a76b89a0 | `dotfiles-front-desk-faty` (seneschal v0) | DONE, 1 commit `d775c01`, timer installed live. MERGE + close. Note: seats.yml seneschal row `schedules:[]` now stale → file bead to add `unit: pulse-seneschal`. |
| a09fe9bf | works batch: `9h8n` (journald) done; `6384`,`3sc4` may follow | partial — merge what's committed, re-dispatch unfinished. |
| a8ccfee4 | small batch: `bi2i` done; `o9vi`,`v8k8` may follow | partial — same. |
| ab9ee62446 | `dotfiles-sb6s` (hall v0) | was still running — branch may be empty; re-dispatch if so. |
| a21ef03749 | `dotfiles-kkpq` (pico-health, **P0**) | still running; re-dispatch if empty. |
| af51a0e86a | `dotfiles-1x4g` (pico backup pull, **P0**) | still running; re-dispatch if empty. |
| a352c65cde | `dotfiles-415c` (orphan reaper) | still running; re-dispatch if empty. |
| a855826cf | `dotfiles-7qif` (cleanroom polish; trailer uses 7qif) | still running; re-dispatch if empty. |
| a82c251c2f | `vs14d-k8q`,`vs14d-b4s`,`vs14d-np2` | commits to **vs14d** (pushed there), 0 dotfiles commits is NORMAL. Read its report / vs14d git log; close those 3 beads in vs14d after verifying. |
| a9084a47 | `lin-euc` | DONE + already merged/closed (guard chmod fix, commit 477d9e2). Its worktree is harvest-none — just clean it. |

Anything already merged+closed this session must NOT be re-dispatched — check `br show`
before acting (closed = done).

## STANDING AUTHORITY (Zig, on `dotfiles-agent-brain-split-ezeu` notes) — STILL IN FORCE
"i want it all built and then you can proceed with the full cutover when its ready, you
have my authority." Proceed without per-gate approval; stop on any failed gate; anomaly
= surface, never improvise. Model policy: **Fable plans+reviews, opus/sonnet implement**
(the sandwich). Seneschal AND marshal are `fable`. linearb seat = fable all schedules.

## Remaining sequence after the harvest
1. Finish merging the wave above; close beads with evidence.
2. **`dotfiles-69qr`** — the fleet-drain spec (Fable-authored; consumes the molt `it06`
   + marshal `4d57`, both now closed). This is the last pre-cutover design piece.
3. **THE CUTOVER** (epic `ezeu`, full order on the prior handoff / `ocm7` runbook):
   freeze (`demesne-freeze.sh`) → demesne re-sync + identity gate (`diff -r` empty) →
   flip `860z` (evict aaif lock per 32j4 → `~/.agents`→`~/demesne` → six `~/.claude`
   links → neuter sync.sh clobber + session-start re-assert) → `n3b6`+`6ttp` → `kvrl`
   → `n77t`+`5tn3` → `zwvu` (serialized cross-repo) → unfreeze → `/clear` all → soak →
   `k579` (prune agent tier from PUBLIC dotfiles) + `zga2`(P0 depublish)+`vtx4` (one
   motion, vtx4 rides zga2) → `pvlp`+`1vpm`. Estate lexicon ratified (`gadu`): ESTATE /
   KEEP (zig-computer) / WORKS (pico) / ROADS (zig-zone). ONE tmux session per server
   (`work` abolished 2026-08-09). After k579, ALL skills are PRIVATE → un-split gdoc
   (`4fx8`, blocked on k579).

## Merge gates still open
- **`dotfiles-pulse-row-model-seat-d0bk`** merged but NOT closed — its gateway-verified
  AC rides tonight's live pinned dream tick. Close it on that evidence (the re-armed
  cron should capture it; else verify by hand at pico requests.db).

## What landed this session (query, don't trust prose)
`git log --oneline --since=2026-08-09` in dotfiles/vs14d/linearb/demesne/harnessd.
Highlights: seat-resolve + reverse-rename guard (btti/tzfr), Remembrancer fleet-scope
(xicr, gate ran clean), socket sweep + fleet tmux-kill guard (2v8h, the 01:06 incident
class closed), model pins (d0bk), THE MOLT (it06 — seats self-cycle; 75% guard now
self-service, frozen-window exception retired), marshal reserved (4d57), works audit
(3 P0s: xh18 patch / 1x4g backups / kkpq watcher), the hevyd-orphan → 42 leaked
scratchpad procs reaped → reaper class (415c), lin-euc (keep now 0 failed units),
ledger-lint fleet row (iyhh). harnessd PWA audit (13 beads) — that campaign is
POST-cutover per Zig.

## Awaiting Zig (nothing blocks the harvest)
- metis attribution (`7zk1`) needs a way to reach metis (his access).
- HA version token (`ys6x`) — 1-min mint in the HA UI.
- Codex is config+auth-blocked on `codex login` (his interactive step); d3ky's build
  list is ready, no duplication of the harness (his ruling, on d3ky).
