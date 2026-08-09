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

## IN-FLIGHT NOW (3 builders — MERGE AS THEY LAND, guarded sequence, close with evidence)

1. **btti + tzfr** (Opus): seat-resolve lib (R1-R13, session+window separate fields) + reverse-rename
   guard. Merged prerequisite already on main: seats.yml (18 seats) + validator (lbxa closed),
   session-start window-aware (k50m closed), uikg spec CLOSED as spec-of-record.
2. **2v8h HARDENED** (Sonnet): socket sweep after the 2026-08-09 01:06 INCIDENT — the first attempt
   killed the LIVE tmux server via bare `tmux kill-server` under inherited $TMUX (precedence over
   TMUX_TMPDIR). Contract now: env -u TMUX -u TMUX_TMPDIR + explicit -S everywhere, sweep includes
   the incident debris (42 sockets), and a fleet-wide PreToolUse guard blocking bare kill-server.
3. **xicr** (Opus): dream fleet-scope + --dry-run flag. MERGE GATE: run its dry-run against the
   REAL fleet pre-merge (denylist proven: zero linearb*/cfp* in output) — clean -> merge BEFORE
   the 04:13 PT Sun tick so the maiden run dreams fleet-wide; anomalous -> hold, tick runs baseline.

## STANDING AUTHORITY + NEXT WAVES (Zig, recorded on ezeu notes)

Cutover authority GRANTED — proceed without per-gate approval, stop on any failed gate.
After this wave merges: **d0bk** (inject honors seats.yml pins, gateway-verified) → **faty**
(seneschal v0: skill + 06:45 timer + brief) + **4d57** (marshal reservation, orchestrator-inline)
+ **sb6s hall v0** (court view + visit) → **69qr** fleet-drain spec (Fable-authored) → THE CUTOVER
(freeze → demesne re-sync + identity gate → 860z flip (evict aaif lock per 32j4) → n3b6+6ttp →
kvrl → n77t+5tn3 → zwvu serialized → unfreeze → /clear all → soak → zga2+vtx4 in one motion →
k579+pvlp+1vpm). Estate lexicon ratified (gadu): the ESTATE / the KEEP (zig-computer) / the WORKS
(pico) / the ROADS (zig-zone); hosts do NOT get seats. linearb seat = fable on ALL schedules.
Codex: config-and-auth job (d3ky filled by probe; codex-cli 0.145.0 present, unauthenticated).
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
