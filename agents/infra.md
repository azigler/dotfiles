# The computing demesne

Every machine Zig's harness runs on or reaches. Read when work touches infra / ports
/ deploy / networking (the `/daemon` shape always needs it).

**Infra drifts — re-verify a fact with a live command before depending on it.** That
warning is load-bearing, not ritual: on 2026-08-01 this file was claiming a `go 1.25`
toolchain that was `1.24.4`, two nginx vhosts that no longer existed, a public port
that was closed, and — worst — that `pulse-dive` and `pulse-desk` were "prepared but
UNINSTALLED" when both were installed and running. An agent reading it would have
concluded two live loops were switched off.

Last full re-derivation: **2026-08-01** (runtimes, vhosts, ports, timers).

## The demesne at a glance

| Host | Reached by | Kind | Role |
|---|---|---|---|
| **zig-computer** | public IP + tailnet | Linux VPS | the **harness host** — Claude Code, skills, beads, `/pulse` systemd timers, nginx edge |
| **pico** | tailnet only | macOS, **no systemd** (launchd) | **where most user-facing production runs**; home, behind NAT |
| **marketing-vps** (`vps-8a9eb245`) | **plain SSH, NOT on the tailnet** | Linux VPS | LinearB marketing work; a second writer on shared repos |
| metis | tailnet | macOS | — |
| iphone-15-pro | tailnet | iOS | Termius client |
| homeassistant | tailnet, **tag:server** | HAOS rpi5 | "948 Palm" install (`ssh hassio@homeassistant`, key `~/.ssh/id_ha`); managed from `~/picod` |

⚠️ **The demesne is not the tailnet.** `marketing-vps` is reached by ordinary SSH and
does not appear in `tailscale status` — so a mesh-shaped assumption ("everything is a
peer, everything is private") is wrong for exactly the host with a history of
stranding commits. Treat it as a separate machine that happens to share repos.

⚠️ **Two writers, one repo.** `marketing-vps` commits to the same repos as this box.
That is why `/commit` demands a push proof against `git ls-remote` rather than
`git rev-parse HEAD` (4 commits were stranded there 2026-07-31 by a re-detached HEAD),
and why the fleet rule is `git fetch && git merge` — never `pull --rebase`, never
`stash`.

## zig-computer — the harness host
- **hostname `zig-computer`** — a public VPS AND the dev box + Claude Code harness
  host (skills, beads, `/pulse` systemd timers all live here).
- Public IPv4 **`51.81.33.136`** (IPv6 `2604:2dc0:101:200::51fe`).
- Tailscale **`100.98.174.21`** (`zig-computer.tailfb4637.ts.net`).

## Mesh ops — ACL changes, and getting back in

**ACL change** (`tailscale/acl.jsonc`): paste the whole file at
<https://login.tailscale.com/admin/acls/file> → **Preview** (validates JSONC + ACL
semantics) → **Save**. Verify with `tailscale ping pico` from `zig-computer`. Every
prior policy is kept in the admin changelog, so a bad paste is a **one-click revert**.

**Recovery ladder — read this BEFORE you touch ACLs or SSH config:**

| Symptom | Recovery |
|---|---|
| `tailscale ssh` won't authenticate | Fall back to public `ssh ubuntu@51.81.33.136:22`. Existing tailnet sessions stay live; only NEW Tailscale auth fails. |
| Public SSH also unreachable | **OVH KVM web console** → log in directly. Credentials in the password manager. This is the bottom of the ladder — there is nothing below it. |
| An ACL push broke all access (`tailscale status` shows "no peers" everywhere) | Tailscale admin → Access Controls → changelog → revert. |
| `pico.zig-zone.ts.net` unreachable, others fine | Physically check pico (power/screen-sharing). `autorestart` covers power loss; soft crashes need a manual reboot. |
| nginx 502 on `*.zig.computer` | `curl -I http://pico.zig-zone.ts.net:3300` from here. 502 from inside the tailnet too ⇒ vs14-web died on pico (`launchctl kickstart`). Clean from inside ⇒ nginx upstream drifted. |
| Ollama latency suddenly bad | `tailscale status` — if the path says `relay`, the home NAT shifted; check the DERP region / home router. |

Full runbook, incl. the Tailscale gotchas paid for once and the Taildrop file-transfer
route: `~/explore/.claude/skills/zig-zone/SKILL.md`.

## The production norm (and its exception)
Andrew's default: *production runs on **pico** over tailscale, forwarded from
nginx here.* **Exception:** things that ARE part of the agent harness (e.g. a
`/daemon`-shape ingress that triggers the agent) run **here** on zig-computer,
co-located with Claude Code + `/pulse` + nginx — co-location beats a backwards
cross-tailnet trigger. Name the deviation when you make it.

## nginx (here, `/etc/nginx/sites-{available,enabled}/`)
Existing vhosts (live 2026-08-01): `granola.zig.computer`, `hevyd.zig.computer`,
`vs14.zig.computer`, `webmention.andrewzigler.com`, plus `default`.
(`linearb.zig.computer` and `reef-router` are **gone** — reef retired, `dotfiles-13qu`.)

⚠️ **Granola terminates HERE, not on pico** — `granola.zig.computer` :443 proxies to
`127.0.0.1:8787` (lb-granola), cutover 2026-07-26. The old `:7575 → pico` route is
retired and the port is closed. The webhook's header key is enforced **in lb-granola**
(`internal/server/server.go` `safeCompare` — sha256 both sides, then constant-time, so
the compare can't short-circuit on length), not at the nginx edge. And there are
deliberately **no read routes** on that listener: mounting one beside an authenticated
webhook is what leaked a 73 KB client transcript from reef (`lb-granola/AGENTS.md`).
Pattern: per-project `<name>.zig.computer.conf` + certbot TLS; `nginx -t` before
reload. Use the `/nginx` skill.

## Ports
Public (ufw-allowed): **22, 80, 443** only — INPUT policy is DROP and there is no
ufw rule for any daemon port. 7575 is closed (reef retired).
Tailnet-bound (`100.98.174.21`): 14174 + 14443 (harnessd), 8766, 19632, 46032.
⚠️ hevyd currently listens on **`*:14877`** — a WILDCARD bind, so it is reachable
tailnet-wide though not from the internet. Its own docs still say `127.0.0.1:14389`;
both the port and the bind have drifted (`dotfiles-dpbn`). Fixed daemon ports belong in the **10000–32767 band** —
above the dev/service cluster (3000/5000/8000/8080/9000…), below the Linux
ephemeral floor (32768; `/proc/sys/net/ipv4/ip_local_port_range`). They sit behind
nginx, so the number is internal — pick high + uncommon so a daemon never collides
with a dev loop or an outbound ephemeral allocation; verify free with `ss -tlnH`.

## Installed runtimes (verify versions with `--version`)
node 22.22.3, bun 1.3.14, python3 3.13.7 + uv, **go 1.24.4** (NOT 1.25 — `romd`
flagged this 2026-07-26 and it stayed wrong until 2026-08-01), cargo 1.97.1,
sqlite3 3.46.1, **duckdb v1.5.4** (`~/.local/bin/duckdb`).

## systemd USER timers (the `/pulse` fleet + builds)

`systemctl --user list-timers --all` is the source of truth; **31 units** live as of
2026-08-01. The `/pulse` fleet: `pulse-{dive,desk,digest,dream,retry,stall}`,
`pulse-di-{monday,tuesday,wednesday,thursday,friday}`, `pulse-autonoveld-{mail,conceive,voice,write}`,
`pulse-{aaif-radar,andrewzigler3,biweekly-content,hevyd-recap,weekly-report}`.
Non-pulse: `andrewzigler3-build`, `claude-vault-sync`, `harnessd-tlscert`,
`hevyd-social-tick`, `lb-granola-commit`, `picod-health`, `vs14d-backup-health`,
`gateway-host-update`, `restart-loop-check`, `zettel-refresh`.

**The 2026-07-26 rename is DONE, not pending.** `pulse-dive` and `pulse-desk` are
installed and running; `pulse-explore`, `pulse-elevate`, `pulse-daily-digest` and
`hermes-watchdog` no longer exist. This file claimed the opposite until 2026-08-01 —
an agent reading it would have concluded two live loops were switched off.

**Timer-rename gotcha:** rename a timer's stamp/unit with `mv` (not recreate) — `mv`
preserves mtime, so the renamed timer inherits its run-history and won't fire a
phantom catch-up tick. Same reason a re-armed timer needs its stamp touched first
(see `~/autonoveld/CLAUDE.md`, 2026-08-01).


## Projects on this box (selected)
- `~/andrewzigler3` — personal site; daily "now page" build **consumes
  `HEVY_API_KEY`** (03:00). Tested TS Hevy transforms (`tests/hevy-transforms.spec.ts`).
- `~/hevyd` — Hevy webhook daemon + coaching agent (the `/daemon` reference instance).
- `~/explore` — exploration compendium (DuckDB, agent-memory, honcho research, etc.).
- `~/harnessd` — harness observability daemon + PWA dashboard (state-bus SSOT).
  Graduated from `~/explore` 2026-07-04; co-located on this box (NOT pico) per
  `~/harnessd/refs/topology.md`. Live now via `state-bus.timer` →
  `~/harnessd/bin/harness-refresh`; Go daemon binds the tailnet IP at Phase 1.
- `~/linearb`, `~/reef`, ss14 game server, `~/hermes` (VPS agent, archived).

## Secrets — `~/.secrets` (mode 600, `source` to load)
`HEVY_API_KEY` (Pro, verified) · `HEVYD_WEBHOOK_TOKEN` · `FLEET_API_TOKEN` ·
`AIRTABLE_PAT` · `GAMMA_API_KEY`/`GAMMA_DEFAULT_THEME_ID` · `FIGMA_PAT` · `HF_TOKEN`.
No Hevy *session* token stored (private-API/social automation is not used — ToS risk).
