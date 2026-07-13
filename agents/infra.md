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
| homeassistant | `100.83.136.26` | HAOS rpi5, **tag:server** | "948 Palm" HA install (`ssh hassio@homeassistant`, key `~/.ssh/id_ha`); managed from `~/explore/shell-home-assistant` (joined 2026-06-27) |

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
hevyd daemon: **14389**. Fixed daemon ports belong in the **10000–32767 band** —
above the dev/service cluster (3000/5000/8000/8080/9000…), below the Linux
ephemeral floor (32768; `/proc/sys/net/ipv4/ip_local_port_range`). They sit behind
nginx, so the number is internal — pick high + uncommon so a daemon never collides
with a dev loop or an outbound ephemeral allocation; verify free with `ss -tlnH`.

## Installed runtimes (verify versions with `--version`)
node 22, bun 1.3, python3 3.13 + uv, go (1.25 toolchain), cargo 1.96,
sqlite3 3.46, **duckdb v1.5.4** (`~/.local/bin/duckdb`, installed 2026-06-27).

## systemd USER timers (the `/pulse` fleet + builds)
`pulse-explore`, `pulse-daily-digest`, `pulse-di-{tuesday,thursday,friday}`,
`pulse-weekly-report`, `pulse-elevate`, `hermes-watchdog`, `andrewzigler3-build`
(daily 03:00). `systemctl --user list-timers`.

**Timer-rename gotcha:** rename a timer's stamp/unit with `mv` (not
recreate) — `mv` preserves mtime, so the renamed timer inherits its
run-history and won't fire a phantom catch-up tick on next activation.

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
