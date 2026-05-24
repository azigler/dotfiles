# Session handoff — 2026-05-24 beb8609d

## State at offboard

- **Current branch**: main
- **Last commit**: `f6ab580 :card_file_box: beads: open dotfiles-52c — future SS14-on-pico via home-router DNAT`
- **Open beads** (3, all P3 trackers — no in-progress, no actionable backlog):
  - `dotfiles-52c` (task) — future SS14 → pico via home-router DNAT + DDNS (ARM64 build artifacts preserved on pico)
  - `dotfiles-st2` (bug) — iPhone Termius nerdfont via Tailscale SSH, workaround in place
  - `dotfiles-406` (note) — zig laptop deferred from tailnet at user's discretion
- **In-flight subagents**: none
- **Dirty files**: none (this offboard's pending handoff is the only thing left to commit)
- **Markers**: `.offboard-pending` not present (clean)
- **Working tree**: clean on dotfiles, explore, AND vacation-station-14 (after the cross-repo handoff updates)

## What happened this session

This was a marathon. zig-zone went from "Phase 1 complete" (where the prior session left it) all the way through Phase 5 end-state verification, with the entire infra migration shipped. The arc:

### Phase 2 — Ollama + Phoenix → pico (`dotfiles-ozk`)
- Custom `~/Library/LaunchAgents/com.zig.{ollama,phoenix}.plist` templates (in `~/dotfiles/ollama/`, `~/dotfiles/phoenix/`) so brew's `services restart` regeneration doesn't clobber `EnvironmentVariables.OLLAMA_HOST` / `PHOENIX_HOST` pinning (runbook gotcha #15).
- Phoenix needed Python 3.13 via `uv python install` — system 3.9 silently pinned arize-phoenix to v12.x, which couldn't open the 13.x-migrated 767MB SQLite (gotcha #16).
- 6 factory `.env.local` files (accounts, fastlane, fleet, gtm, listener, product) repointed `PHOENIX_COLLECTOR_URL` from localhost to `http://pico:6006`.
- mac.setup.sh updated to do the dotnet + Phoenix install + plist install at fresh-Mac time.

### Phase 3 — postgres + vs14-web + 6 obs containers + reef-router (`dotfiles-991`, sub-beads `mh9` + `q0c` + `76s`)
- Postgres@17 on pico via brew. Both vacation-station DBs restored via `pg_dump -Fc` + `pg_restore --no-owner` (231KB compressed total). Reassigned ownership to vs14. Locale = C (macOS Homebrew postgres lacks C.UTF-8).
- 6 obs containers on pico via Colima. The two .NET ones (mapserver + ss14-admin) needed `docker build --platform linux/arm64 --no-cache` to produce native arm64 images — `docker-compose build` + `DOCKER_DEFAULT_PLATFORM=linux/arm64` env silently picked amd64 (runbook gotcha #18). ss14-admin's `appsettings.yml` `urls:` config also overrode the env var `ASPNETCORE_URLS` we set in the override (gotcha #21) — patched on pico's clone.
- Colima can't bind macOS-host tailnet IP for container port mappings (gotcha #20) — used `0.0.0.0:PORT:PORT` + container-internal 0.0.0.0 bind.
- Static dirs (`vs14-recipes/guidebook/writer/maps` + nurseshark dist) tarred + streamed to pico via Tailscale SSH (regular `scp` fails on host-key mismatch — gotcha #17).
- vs14-web built on pico + `~/Library/LaunchAgents/com.zig.vs14-web.plist` (template in `~/dotfiles/vs14/`).
- nginx on pico (port 8080) added with `user pico staff;` directive (gotcha #19 — nginx-as-`nobody` can't traverse `/Users/<user>/` mode-700). Serves all pico-routed paths.
- zig-computer's `ss14.zig.computer.conf` cut over atomically — `location /` proxies everything to pico:8080.
- reef-router moved to pico (`mh9` — gigabyte transfer via Tailscale SSH cat-pipe). zig-computer nginx adds `listen 7575` server block that proxies to pico:7575.
- 7 of 8 timer LaunchAgents installed on pico via `vs14/install-timers.sh` (cookbook, guidebook, writer, nurseshark, map-render, postgres-retention, ss14-backup). PDT times derived from original UTC schedules.
- All migrated services stopped + disabled on zig-computer.

### Phase 4 — SS14 → pico — ATTEMPTED + ROLLED BACK (`dotfiles-hdo` + `dotfiles-ier`)
- Built SS14 game server + watchdog natively for darwin-arm64. Critical flag: `-p:FullRelease=True` (without it, Robust.Server's Resources/ path resolution falls back to dev-mode tree-walk — runbook gotcha #22 covers ARM64 build pattern, gotcha specifically for the FullRelease flag is documented in dotfiles-76s notes).
- Watchdog `appsettings.yml` set to `UpdateType: Dummy` so it runs the local binary instead of refetching Linux x64 from cdn.
- Installed nginx stream module (`libnginx-mod-stream`); UDP+TCP `:1212` proxied to pico via `/etc/nginx/streams-enabled/ss14-game.conf`. Critical: do NOT set `proxy_responses 0` on UDP (fire-and-forget; breaks Lidgren handshake).
- Real-player feasibility test: user connected, played; tcpdump confirmed client IP hiding worked; BUT Late MsgEntity Diff: -4250 disconnects + player counter pinned 0/30.
- Research subagent round 1 identified IP-collapse hypothesis; round 2 corrected it: counter was actually SS14's hub-anti-inflation default (`admin.admins_count_in_playercount = false` → `1 player - 1 admin = 0`). Counter "bug" fixed with a one-line cvar in config.toml. The disconnect mechanism wasn't fully isolated — initial "interleaved sessions" claim doesn't hold with one player.
- **The definitive architectural reason for rollback** (independent of any test-time symptom): SS14's moderation subsystem (`ban_address`, `ipintel_cache`, GeoIP region tagging, admin logs) all key off RemoteEndPoint.Address. nginx UDP-proxy collapses every player's IP to nginx's IP → banning one player locks out all; GeoIP/logs/region all lie. Canonical SS14 pattern (Space Wizards docs + impstation production config): TCP /info proxied for TLS, UDP direct via `status.connectaddress`. Honest revision of the Phase 4 runbook section landed in commit `0ae87c4` after user pushback.
- Rolled SS14 back to zig-computer. ARM64 build artifacts preserved on pico for future use.

### Phase 5 — End-state verification
- **TC14** ✓ — zig-computer footprint: only edge services + intentional SS14 exception. Forbidden services (vs14-web, postgres@17-main, ollama, lb-phoenix, reef-router, 7 vs14/ss14 timers) all inactive.
- **TC15** — original spec asked for ACL policy-preview against a hypothetical non-member; Tailscale's preview is limited to defined identities. Alt-verification: structural read of the ACL — no `["*"]` wildcards, only specific `autogroup:member` + `tag:server` grants; Tailscale default-deny handles the rest.
- **TC16** ✓ — tailscaled local state files on both nodes (`/var/lib/tailscale/tailscaled.state` on zig-computer, `/Library/Tailscale/tailscaled.state` on pico). Headscale-migration safety net.

### Future-spec bead opened: `dotfiles-52c`
- The post-Phase-4 architectural conversation about "can we preserve source IP through UDP proxy" led to a properly-scoped future plan: move SS14 to pico via home-router DNAT (the canonical SS14 pattern). Bead has the 8-step procedure + alternatives matrix (PROXY protocol — not viable, Lidgren has zero parsing; TPROXY — viable but complex; DNAT — chosen).

### Cross-repo handoff: `vacation-station-14`
- Appended a "zig-zone infra migration impact" section to `/home/ubuntu/vacation-station-14/.claude/plans/session-handoff.md` (commit `db90b39480`). Includes: pointers to the dotfiles beads + the explore runbook, the where-services-run table, the "two clones can drift" warning, the 5 vs14-touching gotchas. Next vs14 maintainer session will see it.

## What's next

zig-zone is closed. Nothing is in-progress. If a next session wants work, top picks:

1. **`dotfiles-52c`** (P3) — when ready, execute the home-router DNAT plan. Brings SS14 onto pico with full moderation working. Build artifacts already on pico awaiting this.
2. **`dotfiles-st2`** (P3) — file Tailscale upstream issue for the iPhone Termius PTY/glyph problem. Low priority; workaround is fine. Investigation trail in the bead.
3. **`dotfiles-406`** (P3) — bring zig laptop onto the tailnet whenever the user decides.

If none of the above is interesting, the project's at a natural pause. Plenty of "future considerations" from the original spec are also options for new specs: Headscale self-hosted coordination, LoRA fine-tuning on pico, subnet routing, etc.

## Warnings / watch-outs

- **TWO clones of `vacation-station-14`** now exist: `/home/ubuntu/vacation-station-14` (zig-computer, the original) and `/Users/pico/vacation-station-14` (pico, where most builds + vs14-web actually run). When you `git pull` on one, also pull on the other or services will drift. The vs14 handoff note flags this.
- **vs14 has a `.offboard-pending` marker** at the repo root from a prior maintainer session that didn't /offboard cleanly. I deliberately did NOT clear it — that's the maintainer's marker for their next session's onboard. The handoff content is up to date; the marker just signals "next session, also do offboard for the prior one."
- **gotcha #22 source fix landed end-of-session**: the `[admin] admins_count_in_playercount = true` cvar was also added to vs14's source template at `instances/vacation-station/config.toml.example` (bead `vs-ar6`, vs14 commit `b8c8c54d48`). Live config on zig-computer and source template now match; fresh deploys will carry the fix.
- **SS14 server-side connect_address is currently empty**: if you ever revisit `dotfiles-52c` and set `status.connectaddress = "udp://...:1212"`, the launcher will dial that. Empty = launcher uses the same address it hit /info on (current behavior; fine for now).
- **Pico's nginx config is NOT in dotfiles** — it lives at `/opt/homebrew/etc/nginx/nginx.conf` on pico, edited live during Phase 3. If you ever rebuild pico from scratch, refer to the runbook + the existing config; consider templating into `~/dotfiles/nginx/pico.conf` with the same TAILSCALE_IP_PLACEHOLDER pattern as the LaunchAgent templates.
- **The 8th timer (ss14-replay-rotate) is on zig-computer**, not pico — because ss14-watchdog (which generates the replay files) stays on zig per Phase 4 rollback. `vs14/install-timers.sh` has a comment noting this; if SS14 ever moves via `dotfiles-52c`, re-add the 8th entry.
- **`pico.tailfb4637.ts.net` is the tailnet hostname** (free-tier Tailscale auto-assigned). If the user upgrades + customizes the tailnet name, ALL hardcoded references need updating: nginx configs (zig + pico), config.toml `pg_host`, Phoenix collector URLs in factory `.env.local`s, the LaunchAgent plists (those use IPs not hostnames, so they're safer). Hostname-vs-IP usage is intentionally mixed — IPs where stability matters, hostnames where readability does.
