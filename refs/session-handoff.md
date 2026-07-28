# Session handoff — 2026-07-28 · f331fe58 · the vault-sync alarm was crying wolf

Session id: `f331fe58-8f36-4774-8c66-d6d5c5e05f2d` (on **zig-computer**, not the vps
the previous handoff described)

## State at offboard

- **Branch**: main @ `10c492e`, working tree clean, pushed
- **Open beads**: 34 (1 in-progress: `dotfiles-mhn`, the /pulse spec — pre-existing,
  untouched this session)
- **In-flight subagents**: none. No worktrees.
- **Markers**: `.offboard-pending` cleared

## What happened this session

Zig brought two symptoms. One was a real defect with a false face; the other turned
out not to be on this box at all.

### 1. "The vault sync timer says it's blocked" — FIXED (`dotfiles-tqjk`, closed)

**It was never not-pushing.** Both tiers were 0/0 against `origin/main` with fresh
success stamps the whole time. The dashboard was reporting a *false* alarm:

```
"state": "blocked", "detail": "fired 31m ago, tick BLOCKED — parked on you"
```

Root cause, evidenced from the journal — **two** `vault-sync.sh` runs start in the
same second, from two independent schedulers that are both scheduled on the hour:

```
14:00:43 vault-sync[1083379]: == vault-sync DEGRADED — memory=ok transcripts=deferred (exit 10) ==   <- pulse-dispatch-remote.sh "sync T2/T3 (local push)"
14:00:43 vault-sync[1083457]: == vault-sync OK      — memory=ok transcripts=ok       (exit 0)  ==   <- claude-vault-sync.service
```

The loser of the `flock -w 10` race exits 3 (DEFERRED). `vault-sync.sh`'s verdict
block treated *every* non-zero tier status as bad, so a benign "someone else is
doing this work" became DEGRADED / exit 10 / ledger `outcome:"blocked"`. Both runs
append to the same ledger at the same ts, and harnessd's `newestRow` tie-break
(`internal/gen/loop.go`, `blocked` > `done` at an identical ts) correctly preferred
the `blocked` row — correct logic, fed a wrong row.

The fix **re-aims the alarm rather than weakening it**:

| tier status 3 (deferred) + … | verdict |
|---|---|
| success stamp FRESH (< `STALE_HOURS`) | exit 0, `OK (deferred — concurrent run holds the lock)`, ledger `quiet` |
| stamp >= `STALE_HOURS` old | unchanged: STALE, exit 2x, `blocked` |
| no stamp at all | DEGRADED, exit 1x, `blocked` |

FAILED (1) and BLOCKED (2) are untouched. The stale-stamp backstop is what makes the
green case safe — a permanently wedged lock still reddens the unit within 6h. The
summary line still reads `transcripts=deferred`, so a deferred run never *looks*
like a push that happened.

**Verified end-to-end against the real vaults**, not just the scratch harness — held
the real `.transcripts.lock` and ran the merged script:

```
== vault-sync OK (deferred — concurrent run holds the lock) — memory=ok transcripts=deferred (exit 0) ==
{"ts":"2026-07-28T15:54:28Z","row":"vault-sync","outcome":"quiet",...}
```

and the dashboard then read `"state": "healthy"`. Regression cases T14–T17 added to
`agents/vault/test/vault-sync-alarm-test.sh` (65 passed / 0 failed; demonstrated
FAILING pre-fix with a line byte-identical to the live journal). Suite runtime grew
~2m10s → ~3m20s because the new cases wait on four real `flock -w 10` timeouts.

**Adjacent finding the fix also resolves** (agent's, no separate bead — it is fully
covered): `pulse-dispatch-remote.sh`'s `vault_memory_failed()` treats units digit
1/2 as fatal, so a *memory*-tier deferral (rc 11/12) used to `fail failed-vault 79`
and abort the entire dispatch — not merely mis-render a dashboard row.

### 2. "Every time I cd into a folder the terminal fires a command" — DROPPED, not reproducible

Zig could not reproduce it on demand and called it off. Recording what was ruled out
so nobody re-runs this search:

Symptom was a *second* command line submitted in the same second as one he typed,
where the second is a dictionary-shaped mangling of a word in the first —
`dotfiles`→`dot-files`, `linearv`→`linear`, `cd`→`bcc'd`, and once `cd` arriving
split as `c` then `d`. Confirmed in `~/.zsh_history` (extended timestamps, five
occurrences 14:21–14:37 UTC) and in the pane scrollback.

Ruled out, each with evidence:

- `chpwd` hooks — only `_direnv_hook`; direnv has **no** `.envrc` in `~/dotfiles`,
  `~/linearb` or `~`, empty whitelist, `direnv status` = "No .envrc or .env loaded"
- tmux hooks — zero set (global and both sessions); no `send-keys` source
- `~/.oh-my-zsh/custom/` — empty but for the stock `example.zsh`
- key bindings — stock; nothing bound to `autosuggest-execute`
- `auto_cd` (on, working) and `cdpath` (empty, never set in this repo)
- `~/.zshrc.zwc` — a compiled zshrc written **Jul 28 00:32**, i.e. inside the
  "started in the last day" window, so it was a prime suspect. Its string table is
  **identical** to a fresh compile of the readable `.zshrc` (only the embedded path
  differs) — no hidden content. Nobody knows who compiled it; it is benign, and zsh
  falls back to the plain file whenever `.zshrc` is newer, so it cannot strand a
  future edit.
- processes able to write to his pane's tty (`lsof /dev/pts/24`) — only his own
  `zsh` and p10k's `gitstatus` helper

The discriminating control: driving the **exact** commands (bare relative
`cd dotfiles`, `cd ..`, `cd linearv`) through `tmux send-keys` into a real shell in
his own `work` session — same pty, same ZLE — never reproduced it, across three
attempts. His keystrokes produced it; identical bytes originating on the box did
not. A `cat -v` probe window was set up to settle client-vs-server definitively;
by the time he ran it the symptom had stopped.

**If it returns**, start from the probe (a `cat -v` cannot execute or correct
anything, so anything appearing in it arrived as input over the wire) rather than
re-auditing the shell tier.

## Decisions made this session

- None filed as `-t decision` beads. (`dotfiles-qydv` shows up in the harvest window
  but belongs to the **previous** session, not this one.)
- One judgment call worth naming, recorded here rather than as an ADR because it is
  a decision *not* to act: I had announced moving `claude-vault-sync.timer` off
  `:00` to stop the routine collision, then **did not**, because the classification
  fix makes the collision harmless and the timer file is untracked machine state.
  See "What's next".

## Proposed practices — where each one landed

- "A deferral is not a failure; re-aim the alarm, don't weaken it" → **written into
  `agents/vault/vault-sync.sh`'s header** as the `DEFERRAL IS NOT FAILURE
  (dotfiles-tqjk)` block, at the site it governs, with the three-case table and the
  stale-stamp rationale. Not left in this note.

## What's next

1. **Optional, now low-value**: `claude-vault-sync.timer` still fires at `:00:00`, so
   it still races the on-the-hour pulse-dispatch loops every time both run — the race
   is now harmless (one run does the work, the other logs `quiet`) but it is wasted
   work. Moving the primary to `:07` and the peer to `:22` preserves the documented
   15-min offset. The live unit at `~/.config/systemd/user/claude-vault-sync.timer`
   is untracked, so the template at
   `agents/scheduler/templates/claude-vault-sync.timer` must change with it.
2. `dotfiles-qcfx` (P2) — carried from the prior session: the hourly repo-refresh
   timer still runs the 49-line untracked stub at `~/bin/vps-repo-refresh.sh`.
3. `dotfiles-6wdw` (P0, pre-existing) — unauthenticated internet→tailnet pivot on
   :7575. Untouched again this session.

## Warnings / watch-outs

- The vault-sync alarm test suite now takes **~3m20s** (was ~2m10s) — the new cases
  spend ~50s waiting on real `flock -w 10` timeouts. That is deliberate: it exercises
  the real lock path in `vault-lib.sh` / `transcripts-lib.sh` rather than a stub. If
  it ever needs to be faster, a stub injector is the trade, at the cost of no longer
  testing the thing that actually broke.
- The `quiet` outcome is new for the `vault-sync` ledger row. It is in
  `pulse-ledger-lint.py`'s `ALLOWED_OUTCOMES` (asserted mechanically by T14, not by
  eye), and harnessd ranks it below both `blocked` and `done`, so a `quiet` row can
  never mask a same-ts `blocked` one.
- harnessd was deliberately **not** touched. Its `newestRow` tie-break is correct;
  it was being fed a wrong row. Don't "fix" it there.
- `~/.zshrc.zwc` exists and is newer than `.zshrc` (see above). Harmless, but if you
  ever wonder why a `.zshrc` edit seems not to apply, check whether the `.zwc` won
  the mtime comparison before hunting anything subtler.
