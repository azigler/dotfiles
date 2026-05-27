# Session handoff — 2026-05-26 post-offboard mini-session (tailscale ACL flip)

## State at offboard
- **Current branch**: main
- **Last commit**: `fdcd888 :card_file_box: beads: close dotfiles-8zx (ACL flip landed in b5121fa)`
- **Open beads (dotfiles)**: 4 open + 3 frozen — `ukx.6` (P1 spec, in-flight), `ukx` (P2 epic), `ukx.11` (P3 task — Devstral quant swap), `5e2` (P3 deferred-decisions); frozen: `ukx.10`, `st2`, `406`
- **In-flight subagents**: none
- **Dirty files**: untracked only — `agents/skills/zig-voice/reference/fusions/checkmarx-2026-seussian-town/`, `beads_report_dotfiles_2026-05-25.md`
- **Markers**: `.offboard-pending` cleared (this offboard handles it)

## What happened (~5 min)
- **`b5121fa` tailscale ACL flip** — `check` → `accept` on SSH rules (user→server + user→self). Driver: granola webhook on pico SSH-pushes transcripts to zig-computer transactionally on every Zapier hit; the 12h `check` re-auth expiry was silently breaking the pipeline. Source-of-truth file is `tailscale/acl.jsonc`; trade-off documented inline in header (compromised user device already has full ACL access — no material blast-radius increase from removing browser re-verify on intra-tailnet SSH). **Must be pasted into Tailscale admin → Access Controls to take effect on the wire.**
- **`fdcd888` close `bd-8zx`** — corresponding bead close commit.

## What's next (priority order unchanged from prior session)
1. **`ukx.11` Devstral quant swap** — pull `lmstudio-community/Devstral-Small-2507-MLX-4bit` (13.3 GB) to pico, update llama-swap config, re-run ukx.9 curl recipe.
2. **`ukx.3` Phase 3+4** — full benchmark across 10 scenarios × Opus + local × N trials (2.5× variance on single scenario; need distribution).
3. **`explore-7hh.16` LSRA-on-Hermes prototype** — can consume the 3 Wave 14B plugins.
4. **`bd-b5p.4` Phase 2** — true `delegate_task` migration, voice-anchor injection, AO3 staging.
5. **User-blocked**: `#36` pico disk cleanup, `#44` CoD credentials.

## Warnings / watch-outs
- **Tailscale ACL `tailscale/acl.jsonc` change requires manual paste** into admin console to take effect. If granola transcripts stop landing, this is the first thing to check.
- All prior session warnings (CCR transformer reversal, G16 inseparability, etc.) still load-bearing — see `dcb1728^` handoff in git for the full Wave 9-15 narrative.

## /onboard should pick up
- This handoff first (you're doing that)
- Prior session's full handoff at `git show dcb1728:.claude/plans/session-handoff.md` if continuing local-coding-models arc
- `~/dotfiles/local-models/GUARDRAILS.md` for G16/G17 rules
- `br list --status open` across all 4 repos for 30 open beads
