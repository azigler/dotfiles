# Machine & infra baseline — zig-computer

The box this harness runs on. Read when work touches infra / ports / deploy /
networking (the `/daemon` shape always needs it). **Infra drifts — re-verify a
fact with a live command before depending on it.** Last verified 2026-06-27.

## This box
- **hostname `zig-computer`** — a public VPS AND the dev box + Claude Code harness
  host (skills, beads, `/pulse` systemd timers all live here).
- Public IPv4 **`51.81.33.136`** (IPv6 `2604:2dc0:101:200::51fe`).
- Tailscale **`100.98.174.21`** (`zig-computer.tailfb4637.ts.net`).

## Tailnet peers
| Peer | Tailnet IP | Kind | Note |
|---|---|---|---|
| pico | `100.72.47.4` | macOS | **where most user-facing production runs** (home, no systemd) |
| metis | `100.106.120.98` | macOS | — |
| iphone-15-pro | `100.102.6.100` | iOS | — |

## The production norm (and its exception)
Andrew's default: *production runs on **pico** over tailscale, forwarded from
nginx here.* **Exception:** things that ARE part of the agent harness (e.g. a
`/daemon`-shape ingress that triggers the agent) run **here** on zig-computer,
co-located with Claude Code + `/pulse` + nginx — co-location beats a backwards
cross-tailnet trigger. Name the deviation when you make it.

## nginx (here, `/etc/nginx/sites-{available,enabled}/`)
Existing vhosts: `linearb.zig.computer`, `ss14.zig.computer`, `reef-router` (:7575).
Pattern: per-project `<name>.zig.computer.conf` + certbot TLS; `nginx -t` before
reload. Use the `/nginx` skill.

## Ports
In use (public): 22, 80, 443, 7575 (reef). Localhost-only: 7100, 7102, 8642, 53.
hevyd daemon: 8080. Pick a free high port for new daemons; verify with `ss -tlnH`.

## Installed runtimes (verify versions with `--version`)
node 22, bun 1.3, python3 3.13 + uv, go (1.25 toolchain), cargo 1.96,
sqlite3 3.46, **duckdb v1.5.4** (`~/.local/bin/duckdb`, installed 2026-06-27).

## systemd USER timers (the `/pulse` fleet + builds)
`pulse-explore`, `pulse-daily-digest`, `pulse-di-{tuesday,thursday,friday}`,
`pulse-weeklies`, `pulse-elevate`, `hermes-watchdog`, `andrewzigler3-build`
(daily 03:00). `systemctl --user list-timers`.

## Projects on this box (selected)
- `~/andrewzigler3` — personal site; daily "now page" build **consumes
  `HEVY_API_KEY`** (03:00). Tested TS Hevy transforms (`tests/hevy-transforms.spec.ts`).
- `~/hevyd` — Hevy webhook daemon + coaching agent (the `/daemon` reference instance).
- `~/explore` — exploration compendium (DuckDB, agent-memory, honcho research, etc.).
- `~/linearb`, `~/reef`, ss14 game server, `~/hermes` (VPS agent, archived).

## Secrets — `~/.secrets` (mode 600, `source` to load)
`HEVY_API_KEY` (Pro, verified) · `HEVYD_WEBHOOK_TOKEN` · `FLEET_API_TOKEN` ·
`AIRTABLE_PAT` · `GAMMA_API_KEY`/`GAMMA_DEFAULT_THEME_ID` · `FIGMA_PAT` · `HF_TOKEN`.
No Hevy *session* token stored (private-API/social automation is not used — ToS risk).
