# Session handoff — 2026-08-09 724edc28 (hardening seat, window "hardening")

> ⚠️ SCOPED NOTE, MANUALLY NAMED (seneschal precedent; per-window opt-in still
> deferred — `dotfiles-ie5a`, now CLAIMED by this lane). Plain
> `refs/session-handoff.md` belongs to the dotfiles/Works seat — never
> overwrite it from this window. If you are the hardening seat onboarding and
> the plain note talks about marshal campaigns: THIS file is yours.

## State at offboard
- Branch main, clean except `refs/seats/dive.history.md` (another lane's, untouched all session); everything pushed through `fcd025f`+.
- **IN-FLIGHT (compaction-molt, handle preserved — do NOT /clear):**
  1. t5fj fix-round builder (worktree agent-a91b8db0dbe87b2ab): branch-1 TTL + loud write-failure + reason-literal confirmation. On return: focused re-verify by the scrutinizer, then guarded merge of its branch; carry ONLY in a Works run gap (live injector).
- Escalate-ext: LANDED COMPLETE before molt — SHIP verdict, merged 9363baa, harness green on main, carried to demesne 63710ef; the armed timer re-reads the script per tick, no re-arm needed. Soft spot for the o3qj wave: blanking `PULSE_ESCALATE_BUSY_MARKER` removes a refusal — documented (:227-231), not mechanically guarded.
- Markers: `.offboard-pending` cleared; last-offboard-session set (shared single slot — ie5a caveat).

## What happened this session (compressed — details on the beads)
- **Gateway outage 12:36–15:08Z**: diagnosed (Tahoe left ALL com.zig.* LaunchAgents unspawned; exit-0 drain + SuccessfulExit=false), fixed, all sessions/ticks re-cut. `kviw` closed.
- **Guards built, scrutinized, ARMED**: gateway-health (even :11) + api-stall-recover (odd :11), AccuracySec pinned; harnessd conn-error classifier deployed (`r856`); rung-0 AskUserQuestion seat-guard live (`9i39`); pulse-escalate ladder armed 16:54Z (`9z3o`, `jisc` closed via real-pane drill). Mutation harnesses committed + gate-armed (`w4z9`); demesne gate caught up from seed copy.
- **t5fj arc**: staleness-verified re-fires built; scrutiny found the lying-🧠 24h-refusal class → two fix rounds in flight (above). Escalate-ext adds already_running + lying-🧠/🌀 reconciliation + builder's own BUSY_MARKER third signal.
- **Model/[1m] root cause (Zig's find, confirmed)**: live settings had drifted to the bare `fable` alias → 200k window → the compaction-thrash multiplier. Live settings RESTORED to `claude-fable-5[1m]` (working tree == HEAD, no gate drift; settings-guard is symlink-only, won't revert). Remaining: `lstn` (canonicalization at tick-launch `--model` + guard restore instruction — **queued behind t5fj merge, same file pulse-inject.sh**).
- **Thrash measured**: ldpn (digest 62%-onboard/7-compactions; 6 beads cut across digestd/hevyd), or6a (seneschal onboard 72–108k vs 100k guard budget — option (b) adaptive threshold chosen, implement queued), qtug closed (quality NOT degraded; throughput cost real; fed to digestd-c2f).
- **Zig's evening asks beaded**: `yrsg` (ceiling-stall recover, build after t5fj+lstn), `rbci` (tap failover spec, OQs DECIDED: two pools gmail{personal,tick}/linearb, ceiling-only, both windows, + fable-allotment dimension), `glfx` (2nd Max 20x reserve tap BEFORE Fable weekly exhausts — Zig at 70%, reset Thu 11pm PT; his half = purchase+OAuth), `ws16` closed (hall does NOT swallow keys — refuted; binding is prefix W not H, CLAUDE.md doc fix pending), `o3qj`+`inqj`+`betl` (molt-lifecycle wave), `t9m7`+`w4ac`+`ie5a` (overhead wave). All claimed out of the marshal pool with comments.

## Friction
- SendMessage to a reaped-worktree agent cannot resume ("isolation fences") — re-dispatch fresh with cold-start context; cost one full prompt rewrite. → one-off (known shape now)
- Offboard marker held a PEER session's id at onboard (seneschal's dead session) — the ixyi family again. → dotfiles-ixyi
- demesne-sync refuses on ANY dirt including own-sync leftovers; two round-trips lost. → one-off (behavior is correct, cost is small)
- `br dep add` direction is easy to invert (created 3 edges backwards, fixed same session). → one-off (close-gate caught it)

## Decisions made this session
- `dotfiles-40ej` — gateway-outage hardening charters (no auto-flip, targeted kickstart, nudge-only recovery)
- Sequencing decisions recorded on beads rather than separate decision beads: o3qj sequenced-not-absorbed; lstn behind t5fj (file collision); glfx front-runs rbci build. Shared-store note: `kjjf`, `t06l`, `b01h` in the harvest window are OTHER seats' decisions (Works/marshal lane).

## Proposed practices — where each landed
- "One re-fire owner / staleness verification" → lives in pulse-escalate.sh SINGLE OWNERSHIP header + t5fj build (mechanical)
- "Alias→canonical model table at every launch/restore seam" → filed `dotfiles-lstn`
- "CLAUDE.md hall binding says prefix H, actually prefix W" → fold into next /housekeeping (small doc fix, no bead)
- none homeless.

## What's next (priority order for this seat)
1. Land the two in-flight rounds: t5fj fix round → scrutinizer re-verify → guarded merge (t5fj branch THEN escalate-ext branch — no file overlap); commit staged `mutate-t5fj-staleness.sh` + its pre-commit arm alongside; demesne carry = PING WORKS FIRST (live injector; run gap protocol), then escalate-ext carry is unglued (script re-read per tick, no re-arm needed).
2. Real-window verify per t5fj AC (repo rule 1) at carry time; close `t5fj`.
3. Dispatch `lstn` (now unblocked); then `yrsg` → `rbci`+`glfx` harness half (deadline: Fable exhaustion, BEFORE Thu).
4. `o3qj`+`inqj`+`betl` molt-lifecycle wave (external-offboard design round); `or6a` implement (adaptive guard threshold) + `t9m7`/`w4ac`/`ie5a` overhead wave.
5. Zig's open decisions: `digestd-c2f` (digest model — qtug verdict attached), `t06l` (bead-trailer exemption).

## Warnings / watch-outs
- Marshal campaign runs serial supervised floor runs all evening (Works session, `kjjf`); failure counter was 2/3 at last sync. NEVER touch marshal window/units/drain-ledger without pinging Works; pulse-inject/pulse-retry demesne carry ONLY in a run gap.
- pulse-escalate is ARMED and live: escalate.conf watches pulse-marshal only; extension changes semantics on merge+carry (no re-arm needed — but the result-line contract changed: `reconciled-unlisted` inserted).
- The seneschal window is CLOSED (Zig, 70% loop) — its next scheduled tick 13:44Z re-creates it; with settings fixed it should launch 1M, but the roster `--model fable` pin may still force 200k until `lstn` lands. If tomorrow's brief thrashes again, that's why.
- Fable weekly allotment: Zig at 70%, reset Thu 11pm PT — `glfx` (reserve tap) is deadline-bound by BURN, not by Thursday.
