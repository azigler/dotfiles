# Session handoff — 2026-08-09 a491e4bf (verify lane → normal duty, window dotfiles-2)

## State at offboard
- Current branch: main, clean; last commit pushed and ls-remote-verified (24516d1 lineage; peers commit constantly — fetch+merge to absorb)
- In-flight subagents: none (all four returned, merged, worktrees reaped)
- Other repos touched: harnessd (main 67e5110, pushed), demesne (dc9375b lineage, pushed)
- Markers: `.offboard-pending` cleared; `.claude/last-offboard-session` = a491e4bf…

## What happened this session
- **860z post-flip verify: 4/4 PASS**, reported to the Works session; it closed 860z. Filed `dotfiles-iqro` (seat-resolve half-loaded-lib guard; proven PRE-existing via old-vs-new-path discriminating check — shell snapshot drops underscore helpers, `command -v` guard then skips re-sourcing).
- **ypbc fixed and closed**: demesne-freeze derives both unit forms (escaped dot), set restored 2→32, mutant-killed guards; carried LIVE via demesne-sync (gate IDENTICAL). Filed `dotfiles-k0tc` (sync-era gaps: root-file drift + --delete eats gitignored live-state; second instance recorded when claude/systemd/README's private copy was sync-deleted — rule: depublishing from INSIDE the synced set requires move-in-demesne FIRST).
- **zga2 + vtx4 closed** (Zig-ratified plan on the bead): 39 files depublished, 3 shell configs on bare MagicDNS names, sd-up restored (mac.setup.sh:340 installs it; its .ts.net was a placeholder), THE DEMESNE MAP live at `~/.agents/infra.md` (demesne ROOT — sync-safe), zig-zone DNS drift zero in both repos. Criterion grep = exactly the 12 k579-deferred files; grep-returns-nothing closes at k579.
- **harnessd marshal-prep complete** (Zig's directive): all 106 drainable-type beads assessed. Wave 1 = 11 campaign-verdict marks + 4 dupe closes; wave 2 = Fable assessor extended campaign-2026-08 over 79 beads (all verdicts on beads), 31 more marks, 6 same-file lanes wired as deps, yfg+shzl closed (shzl's systemic ACs refiled → `dotfiles-v052` scrub-secrets multi-source denylist, `dotfiles-iu2h` environ-read guard).
- **qmrp D1–D7 ran with Zig** (verdicts VERBATIM in harnessd-uzff notes): D1 demote ✓, **D2 KEEP Intake** (override: heavy tabs stay, panels consolidate), D3 delete-the-lie ✓ (ifs7 marked), D4 zen-pond all 12 closed, D5 renderers all 3 closed, **D6 freeze REJECTED** (override: fully fund — campaign epic `harnessd-eyu2`, matrix `dtub`, substrate decision `1ps2`), D7 close 2 keep v8o.15 ✓. Funding: soak under kjjf; computed budget is the Works session's job (Zig, relayed).
- **Matrix tranche 1 done**: 18 rows (4 BROKEN/6 DEGRADED), fixtures + TestMatrixProbe merged (harnessd a9c64fb, suites green). Zig's named bug has a deterministic trigger → `harnessd-b76g` (P1, fleet, after 9gvd). MultiSelect keystrokes fully measured (Space/Enter/digit all TOGGLE; Tab→review; Enter submits there) — relayed to run #3's live 9gvd builder via Works session. Also filed: `8lwe` (smoke-live 7 gaps, fleet), `4kqq` (clip-drop, gated on 1ps2), `gdy4` (JSON-latency hazard study: tool_use record absent ≥75s while widget shown, 2/13, intermittent).
- b1v6 FIX-FIRST finding (3) adjudicated for run #3's re-pick: AC4 scoped to own drift; unregistered_loop owned by edwu/90vm.

## Friction
- pre-bead-close hook resolves the bead store from session cwd (~/dotfiles), blocking harnessd closes; its own `cd <path> && br close` follow-regex doesn't match a `(cd …)` subshell → use the bare `cd path && br close` form → one-off (documented behavior, bd-8euh regex; not worth a bead)
- zsh: `set -- $pair` doesn't word-split; `echo ===` triggers zsh =-expansion → one-off
- `br comment` vs `br comments add -m` syntax; `-d` leading-dash trap → one-off (hook messages self-explain)
- /offboard newest-mtime session-id heuristic remains wrong in this multi-session project → bd dotfiles-ixyi (already filed by prior lane; this offboard derived the id from the session-specific scratchpad UUID and VERIFIED by content grep — qmrp-hits=10)

## Decisions made this session
- Recorded on beads rather than as -t decision beads: sd-up restore-and-reword (zga2 close reason), mrjo NEEDS-GROOMING→proof-campaign re-scope (comment on mrjo), m3e5 marked without 0gch dep while 0gch is unmarked (comment on m3e5), b1v6 finding-3 adjudication (comment on b1v6).
- Harvested from the shared store, NOT this lane's: `dotfiles-kjjf` (drain continuation), `dotfiles-40ej` (gateway-outage hardening) — both the Works session's, listed for completeness.

## Proposed practices — where each one landed
- "depublish from inside the synced set ⇒ move-in-demesne first" → recorded on `dotfiles-k0tc` (second-instance note + AC)
- "groom-first-mark-last / claim-check per mutation" → already the Works session's mid-run rules; verdicts + lanes live on the harnessd beads themselves
- none homeless in this note

## What's next
1. **Run #3+ ledger rows** — the Works session relays; b76g/8lwe join run #4's pool; qvvf/fpmn stay fenced until matrix reconciliation.
2. **Matrix tranche 2** (notification/ping interleaving, markdown/table prompts) + the eyu2 reconciliation of ~14 old parser beads — dispatch when 9gvd + b76g land.
3. **1ps2 substrate walk with Zig** once gdy4's latency study runs (needs N≥30 sampling).
4. Grooming leftovers, verdict comments say exactly what: 0keb (reconcile vs closed zl9c), lry.5 (write body), l3wx (split pico half), 4icj (spec session).
5. **Needs Zig**: 8fca phone pass (11 device-tailed beads), 4c7b viewport check, iiqb.1 ratify-and-close (releases Silicon Keep chain).

## Warnings / watch-outs
- The marshal drains nightly (timer armed 01:07 PT) + supervised runs anytime — harnessd/.beads and harnessd main have a standing second writer; claim-check before ANY marked-bead mutation.
- Handoff notes are moving to the demesne per Zig (ie5a) — this may be the last offboard writing refs/session-handoff.md in this repo.
- dotfiles worktrees agent-a0a2aff8… and agent-a7526839… belong to the MARSHAL (locked) — never reap them from this lane.
