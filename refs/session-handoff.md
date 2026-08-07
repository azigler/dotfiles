# Session handoff — 2026-08-07 188ce668 (zig-computer, work:retreat, LinearB seat)

> ⚠️ This file overwrites whatever note was here — `dotfiles` still has no
> `refs/.handoff-per-window` (`dotfiles-fmq6`). Check `git log -- refs/session-handoff.md`
> for the note this replaced.

**One session, five days, three machines.** Started on zig-computer 08-02, ran ON
marketing-vps for most of the retreat, then was **moved back to zig-computer on 08-07** by
pushing the transcript to the vault and resuming it in `work:retreat` on the LinearB seat.

## State at offboard

- Branch `main`, pushed, `local == remote` proven
- Open beads: ~85; in-progress: 0
- In-flight subagents: none — 21 dispatched across the session, all merged, worktrees removed
- **marketing-vps: RETREAT COMPLETE.** Phases 1–4 done. `ssh` returns rc=255.

## THE RETREAT — done

| phase | result |
|---|---|
| 1 RESCUE | 6 orphan beads → `~/retreat-rescue-mvps-beads.jsonl` (sha `aedf5173`, matched). `~/work`/`~/bin` discarded per Zig. |
| 2 STOP | 5 timers disabled, both tunnels killed, Linger=no, tmux server gone (took `di-fable`) |
| 3 WIPE | **14G → 16K.** Order held: final sync (`memory=ok transcripts=ok`, stamps 0min, both `local==remote`) → disable sync timer → wipe with `~/dotfiles` LAST |
| 4 SEVER | `4d → 4a → 4b → 4c`. All exit checks pass. |

**The migration inside the retreat**: all seven LinearB pulse rows now run on zig-computer,
`work:<row>` windows, LinearB seat (`~/.claude-work`), through pico's gateway. Verified in
pico's request log (`group=zig-computer user=work:di-thursday`). All 7 timers scheduled.

## Decisions this session (`-t decision` beads)

- `dotfiles-ucl4` (open) — gateway failure fails HARD. **Its cost landed within a day**:
  pico lost internet 6.5h and claude died fleet-wide. Decision stands; outcome recorded on
  the bead. Lesson filed as `dotfiles-17k3`.
- `dotfiles-dkmc` (open) — mutation-discipline clauses land in CLAUDE.md rule 1.
- `dotfiles-volw` (closed, MOOT) — resolved a question about a guard that turned out not to
  exist. See `dotfiles-aq6d`.

Conversational decisions not filed as beads: rollout by force-fire not natural fire;
gateway routing for the work seat; emptied-but-present end state; `--session work` not
`zig-computer`; drop the 3 stale skills-library commits; leave the unidentified ecdsa key.

## Filed after the first offboard (this note was re-written 2026-08-07)

- **`dotfiles-effn`** — the six silent-wrong-answer tool idioms, see Watch-outs.
- **`dotfiles-vhys`** — the unidentified ecdsa key, below.
- memory `feedback-on-the-record-means-a-bead`, indexed in `MEMORY.md`.
- `dotfiles-9o46` appears in the decision harvest for this span but belongs to the
  **marketing-vps session**, not this one.

## OPEN — and the first one is the only security item

1. **`dotfiles-vhys` — an UNIDENTIFIED ecdsa key has unrestricted inbound access to
   zig-computer.** Matches neither GitHub account, nor pico, nor any local `.pub`. metis and
   the iPhone (Termius, which generates ecdsa-nistp256) were NOT checked. Left in place at
   Zig's instruction. Backup with the key still in it:
   `~/.ssh/authorized_keys.bak.2026-08-07`.
2. **`/etc/sudoers.d/90-andrew-nopasswd` was removed but NEVER VALIDATED.** The removal
   revoked my own sudo, so `visudo -c` could not run afterwards. Risk is low (pre-removal
   state parsed OK; a `rm` of one independent drop-in cannot corrupt the others) but it is
   an argument, not a check — on a box shared with kevin/mike/ben. **Zig chose to proceed
   and disclose to the box owner.** The correct form was one invocation:
   `sudo -n sh -c 'rm -f … && visudo -c'` — the retreat doc has the same flaw.
3. **Phase 7 paperwork** — `dotfiles-xi5b` (3 per-host files), `dotfiles-y3u8` (conduit
   machinery; ⚠️ `pulse-dispatch-remote.sh` is referenced by `pre-commit-checks.sh`),
   `dotfiles-9neb` (files that keep living), `dotfiles-mmxy` (infra.md, P1).
4. `dotfiles-3137`, `dotfiles-g2vg`, `dotfiles-folq`, `dotfiles-fmq6`, `dotfiles-17k3`.
5. **The repo is PUBLIC** with 26 files carrying IPs and 6 carrying colleague names.
   Raised; Zig said nevermind. No bead filed — deliberately, it is his call.

## What shipped besides the retreat

CLAUDE.md rule 1 (mutation discipline) and rule 2 (run the example as committed);
`/commit`'s pipe-masked-push anti-pattern; `lb-claude`; the statusline seat indicator;
`claude-seat-link.sh`; `lb-granola-publish-guard.sh`; the Monday routing fix; and 14+ defects
closed, every one of which had green mechanical gates.

## Watch-outs

**→ `dotfiles-effn` is the record.** Six tool idioms on this fleet that return a confident
WRONG answer instead of an error — `find` without `-L` on the project-slug symlinks,
`deferred` in the vault ledger, `rm` aliased to `-iv`, self-matching `pkill -f`,
leading-dash arguments, and uutils `ps`. Each with the wrong answer it actually produced
and the correct form. Cross-referenced from `dotfiles-cxle`, its consumer-side twin.

*This section used to duplicate that list. Zig's correction, 2026-08-07: a durable finding
belongs in a queryable bead, and prose points AT it rather than copying it — a handoff is
overwritten by the next `/offboard`, so anything only recorded here is already half-lost.
Filed as memory `feedback-on-the-record-means-a-bead`.*

Session-specific, not in that bead:

- **The seat is the ACCOUNT, not the path** — `~/.claude` is personal on zig-computer and
  the LinearB seat on marketing-vps. A path-based statusline rule labelled a company
  session `(me)`; Zig caught it. Fixed in `b0b95da`; the reasoning is in the script.
- **The recurring shape, five days running:** every defect had green mechanical gates, and
  the tell was always silence rather than error.
