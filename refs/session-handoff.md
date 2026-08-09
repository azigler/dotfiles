# Session handoff — 2026-08-09, session 2cc9586e (zig-computer, dotfiles, personal tap)

> ⚠️ Overwrites the prior note (retreat-era). `git log -- refs/session-handoff.md` for history.

**The founding session.** Two days, ~36 agents dispatched/reviewed/merged, Fable orchestrating
per the sandwich (Fable plans+reviews, Opus/Sonnet implement — now AGENTS.md doctrine).
Main is clean and pushed at `771e429`; demesne, harnessd, explore, andrewzigler3, romd, aaif,
creaturesd all pushed. No unmerged worktrees with content. Beads synced.

## What this session built (query, don't trust prose)

`git log --oneline --since=2026-08-08` in dotfiles + demesne + harnessd. Highlights: demesne
seeded (triple-verified) + CONSTITUTION ratified (`~/demesne/docs/constitution.md`); seat spec
uikg authored+scrutinized+corrected (colon addresses, seat/tap, R1–R13); Wave 0 6/6 (probe
retired the Opus-5 400 on CLI 2.1.226 — `refs/probes/fable5-envelope-2026-08-08.md`); freeze
runbook (demesne-freeze.sh, 61 tests); hooks armed (agents_root resolver, symlink-triple);
AGENTS.md rewritten (Effort de-universalized, model doctrine, glyph rule, machine baseline);
config quick-wins ×6; home cleanup (~5.5G freed, worktree sweep, hermes retired); Audit N
(548 handoff versions) → offboard Friction destinations discipline; roster of offices+sigils
(ojjf); charter palette→constitution; endeavors epic; the HALL spec (sb6s); tap-type
abstraction w/ codex baked in (d3ky); model-pin table (d0bk notes).

## ⚠️ IN-FLIGHT WORK STOPPED PRE-COMPACTION — RE-DISPATCH FRESH

Six agents stopped by Zig before auto-compaction; **zero commits ahead in any worktree**
(verified) — nothing to merge, nothing lost. Their contracts are ON THE BEADS. Re-dispatch:

1. **btti + tzfr** (one Opus agent): seat-resolve lib + reverse-rename guard. Contract = uikg
   R1–R13 + both beads. Don't touch session-start.sh (k50m owns it).
2. **k50m** (Sonnet): session-start window-awareness via handoff-path helpers (source, don't edit).
3. **lbxa + seats.yml seed** (Sonnet): roster file per uikg schema + ojjf roster + d0bk-notes
   model pins + **d3ky tap types** (`type: claude` REQUIRED per tap, failover personal→work,
   work never→personal) + validator incl. sigil emoji rule + pre-commit data arm.
4. **2v8h** (Sonnet): reap ~35 leaked tmux test sockets + fixture traps; never touch `default`.
5. **fkxf** (Sonnet, read-only): codex interop probe — fills d3ky's [PENDING] cells.
6. **xicr** (Opus): dream fleet-scope per the v1 design on the bead. **MERGE ONLY AFTER the
   2026-08-09 04:13 PT dream tick lands clean** (the jx71 rebuild's maiden run — check
   explore's ledger row + gateway `gen_ai_request_model` for the dive/digest/dream users).

Stale worktrees from the stopped agents: remove `agent-{a581…,a677…,aa63…,aba7…,ae14…}`
(0 commits ahead each — re-verify at removal per vqz8 discipline).

## Then, in order

- **d0bk** (pulse-inject honors seats.yml model pins, gateway-verified) → **hall v0** (sb6s —
  court view + visit; spec carries the Zig-approved walkthrough + tap failover).
- **The cutover evening** (Zig schedules): phases in this transcript + ocm7's runbook —
  freeze → demesne re-sync + identity gate → flip (860z: evict aaif lock per 32j4, symlink,
  six ~/.claude links, neuter sync.sh clobber) → retargets (n3b6+6ttp, kvrl, n77t, 5tn3,
  zwvu serialized) → unfreeze → /clear all → soak → zga2 (P0) + k579 + pvlp + 1vpm.
- Marshal (4d57) + fleet-drain spec (69qr) + outward gate (htqt) + seneschal v0 (faty) follow.

## Awaiting Zig (nothing blocks)

Model-pin vetoes (table on d0bk notes / in transcript); cutover scheduling; his cut-off
rationale tails if he wants them on record (1iir "benefit from them" — recorded).

## Friction (destinations per the new discipline)

- PreToolUse hook-block killed compound br calls 3× this session → `dotfiles-fdvs` (doc landed)
- Shell cwd resets between Bash calls → foreign-repo sequences must be single-call → one-off
  (harness behavior; standalone-cd rule holds)
- pre-bead-close lint evaluated the WRONG STORE when a compound cd'd to another repo first →
  one-off (same class as fdvs; the split-calls rule covers it)
- Context guard fired at 100% with 6 agents in flight → the fleet-drain spec should define
  in-flight handoff conventions → noted on `dotfiles-69qr` scope (predict recurrence)
- Nerdfont glyph fallbacks required 3 corrections → AGENTS.md glyph rule + lbxa validator arm

## Decisions

All on beads (the on-the-record rule held all session): `br list --type decision` +
closed-bead reasons. Constitution = `~/demesne/docs/constitution.md`.
