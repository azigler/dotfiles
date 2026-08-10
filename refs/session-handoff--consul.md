# Session handoff — 2026-08-10 724edc28 (THE CONSUL 🦅, window "consul")

> SCOPED NOTE (per-window). Plain `refs/session-handoff.md` belongs to the
> Works seat — never overwrite it from this window. This seat was "hardening"
> until 2026-08-09 ~21:5xZ; it is now the registered seat **consul**
> (decision `dotfiles-7ibz`; seats.yml row; sigil 🦅). You are its next
> context: this window pairs with the Master of Works as co-equal consuls.

## State at offboard
- Branch main, pushed through `21ad7b8`+. No dirty files of mine.
- **This offboard precedes a PROCESS RESTART, not a /clear** — deliberate, to
  shed `CC_NO_GATEWAY=1` from the process env (it poisoned child launches;
  the pane shell is clean, so a fresh `claude` launch comes up clean and
  attributes as `zig-computer:consul` / epoch-3). Expect no in-flight
  subagent handles to survive; everything durable is below.
- In-flight at write time: the COMBINED demesne carry gate (hall v1 + o3qj +
  Works' 5gob budget fix + model-guard coldstart) — if demesne HEAD lacks the
  ":twisted_rightwards_arrows: sync: hall v1 tap cell + o3qj…" commit or the
  tree is dirty, that carry needs verifying/retrying (kuog flake class; all
  files staged; message in reflog). Works has the same self-service check.
- Works is executing the MARSHAL PROCESS RESTART (their seat, my go-signal
  sent ~00:40Z) → then the drain, gated on the carry check, hard-stop 00:45 PT.

## What happened this session (post-compaction half; prior half in git history of this note)
- **t5fj CLOSED**: staleness-verified re-fires + loud write-failure live in
  both repos, SHIP on focused re-verify, 14/14 mutants, injector hot.
- **The tap arc, end to end in one evening**: `~/.claude-secondary`
  provisioned (zig@zigler.ai, seat-link staged, attribution verified);
  `kecb` failover core built (Opus) + scrutinized SHIP (Fable) — taps.conf
  (pools/order/seat_home), tap-headroom.sh (5h/7d + the DISCOVERED Fable
  dimension via GET /api/oauth/usage), wrapper consult with loud triple
  attribution; **rotation LIVE and production-tested via forced ceiling**
  (ledger row + stderr + gateway row group=secondary, 21:13Z); marshal
  re-homed to secondary (Zig ruling, supersedes OQ5 — recorded in taps.conf);
  epoch-3 naming (primary/secondary/linearb) live incl. infra.md carry (sn2t
  applied, demesne f0a5e86). `glfx` + `rbci` + `kecb` all CLOSED.
- **THE CONSUL registered** (`7ibz`): peer consuls, no hierarchy, seneschal
  untouched; window renamed; seat row validated; history file initialized.
- **lstn built + SHIP + carried** (demesne 8fe1ff8 on retry): model-canon.sh
  single table (fable/opus/sonnet → [1m]; haiku has NONE — API 400 proof),
  guard restore instructs canonical, injector splices canonical
  (injection-grammar independently attacked), settings-drift alarm, SONNET
  env pin added (dbebf6b). **Bead still OPEN** — AC5 evidence = fresh marshal
  onboard at 1M scale (~12% not 73%); close it once the restart shows that.
- **hall v1 tap cell** merged (oq4n closed by builder? NO — check): marshal
  renders `primary→secondary`, conf-derived, 229/229 + 5/5 mutants.
- **o3qj molt-refusal consumer** merged `21ad7b8` after FIX-FIRST→fix→SHIP
  (tab-collapse field shift fixed via row_fields(); E9 mutant). Second
  refused/failed molt within 90m now pages Zig (P1 human: bead + push).
  **Bead still OPEN** — close after the combined carry lands (needs the
  ## Guard line: suites test-seat-molt 69 + test-pulse-escalate 45 +
  mutate-o3qj 11/11; verdict trail on the bead).
- **Statusline docket** fleet-marked for the drain: 5j0k (W1, ready) → kcto
  (W2) → 2710 (W4); wq1z (W3) unblocked by kecb close. Zig's taste calls
  baked in (→ separator, clock dies, seat name shown).
- **Filed en route**: gu0o (P1 false-green harness gate), kuog (P2 fleet,
  inject-suite shared-server flake), b1cd (P1 index-race, pathspec idiom),
  hzvi (P3 window_note wording), 3dyx (P1 dispatch-alias 200k gap — SONNET
  pin is the half-fix), hdm3 (P2 fleet, 7d filter hole), h1oa (consul docket
  pulse spec — Zig-gated OQs).
- Works coordination throughout: index-race disclosure, drain hold, budget
  seam (their 5gob), carry gaps, restart sequence — all via SendMessage,
  zero collisions.

## Friction
- Demesne commit gate flaked twice on test-pulse-inject legacy cases
  (shared default-tmux-server fixtures racing concurrent gates) → filed
  `dotfiles-kuog` (fleet-marked).
- Background `git add X && git commit` swept another writer's staged files →
  filed `dotfiles-b1cd`; pathspec commits adopted for the rest of the session.
- `diff | head && echo IDENTICAL` pipe ate diff's exit code (the /commit
  anti-pattern, self-inflicted) → one-off; per-file `cmp` loop used since.
- tmux-kill-guard + stderr-guard + bead-body hooks each blocked one command →
  one-off each (guards working as designed; commands reshaped).
- `br comments add` syntax discovery cost two failed calls → one-off.

## Decisions made this session (harvest: 8 since 15:05Z, 44 scanned)
- `dotfiles-7ibz` — THE CONSUL topology (mine; the governing record)
- `dotfiles-40ej` — gateway-outage hardening charters (mine, pre-compaction)
- `dotfiles-1aw8` — roster keeps aliases; canonicalise at the boundary (my lane's builder)
- `dotfiles-kjjf`, `dotfiles-bg71`, `dotfiles-b01h`, `dotfiles-zfgu` — Works-lane decisions (theirs; listed for the window, not harvested into my lane)
- `dotfiles-t06l` — OPEN, genuinely Zig's (bead-trailer exemption)

## Proposed practices — where each landed
- "Pathspec commits in shared trees" → `dotfiles-b1cd` AC 1 (AGENTS.md edit rides its fix)
- "Suites must not fixture the default tmux server" → `dotfiles-kuog`
- "NOT-RUN mutant ≠ killed" → `dotfiles-gu0o`
- none homeless.

## What's next (priority order)
1. Verify the combined carry landed (demesne HEAD + clean tree); byte-verify
   (per-file cmp, never diff|head); then close `o3qj` (Guard line above) and
   confirm carry to Works if they haven't self-served.
2. Marshal restart evidence → close `lstn` (AC5: fresh onboard ~1M scale;
   capture pane or ask Works). Then watch the first REAL rollover (Fable at
   ~81% — likely this week) as kecb's production observation.
3. `yrsg` build (ceiling recovery: detect/wait/restart — consumes
   tap-headroom, reuses pulse-retry/api-stall; zero new re-fire owners).
4. Remaining waves: inqj + betl (molt-lifecycle), or6a implement + t9m7/w4ac/
   ie5a (overhead); drain handles the fleet-marked set (statusline W1/W2/W4,
   wq1z, hdm3, kuog).
5. Zig decisions parked: t06l, digestd-c2f, h1oa's three OQs; his linearb
   re-login (l42h) when convenient.

## Warnings / watch-outs
- **Every marshal launch now emits the rollover triple** (home=primary from
  its config dir, used=secondary) — correct-and-visible, NOT an error. 687p
  normalizes the roster naming later.
- **Escalate pages Zig on a second refused/failed molt within 90m** — before
  molting any seat twice deliberately inside that window, expect a NOTE at
  minimum; the 30m rate limit makes healthy double-molts safe (reviewed).
- Demesne gates: expect the kuog flake until it's fixed; retry once from a
  quiet moment, never bypass.
- The dotfiles→demesne sync REVERTS live-settings drift (theme incident) —
  absorb client-persisted settings into dotfiles FIRST, then sync.
- gu0o (false-green mutation gate) is P1 and unfixed — treat demesne-side
  "all mutants killed" lines with suspicion until it lands.
