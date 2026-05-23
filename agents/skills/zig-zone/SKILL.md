---
name: zig-zone
description: Operational runbook for zig-zone — the private Tailscale mesh + workshop/server split. Covers daily ops (who's reachable how, ACL paste workflow, lockout recovery) AND the one-time migration phases (Prerequisites + Phase 0-5) that take pico from "fresh install" through "running every server that used to be on zig-computer." Pairs with `tailscale/acl.jsonc` (the policy file) and `dotfiles-phe` (the closed spec bead, for decision rationale).
when_to_use: User asks about the mesh, the migration, Tailscale ACLs, "what runs where now," "I can't reach pico," "I'm locked out of zig-computer," "what phase are we in," "let's do the next phase." Also load when editing `tailscale/acl.jsonc` or planning a service move between zig-computer and pico.
---

# /zig-zone — Private mesh + workshop/server split runbook

## The model in one paragraph

`zig-zone` is a Tailscale tailnet wrapping 5 devices into one virtual LAN. `zig-computer` (OVH VPS, public IP) is the **workshop + edge**: nginx terminates TLS for `*.zig.computer`, sshd on port 22 is the break-glass, the user's dev environment + tmux + lb-fleet/lb-listener (localhost-bound dev tools) live here. `pico` (Mac Studio M1 Max 64GB, home LAN) is the **server farm**: Ollama, Phoenix, vs14-web, postgres, the SS14 game server, the docker observability stack, and reef-router all run here, bound to pico's tailnet IP. nginx on zig-computer reverse-proxies inbound traffic through the tailnet to pico. SSH primarily goes through Tailscale SSH; public port 22 stays as break-glass with `ufw limit` + fail2ban.

The split exists because the user wants the workshop machine free from interruption — services on the coding box risk accidental kills, port conflicts, resource pressure mid-flow. The Mac Studio is purpose-built for sustained server load. The M1's unified memory makes local LLM inference real.

## Topology

```
   Internet
      │
      ▼
   ┌──────────────────────────────────────────┐
   │  zig-computer  (51.81.33.136, OVH VPS)   │  workshop + edge
   │  • nginx :80/:443 (linearb.zig.computer, │  Linux, tag:server
   │    ss14.zig.computer)                    │
   │  • nginx :7575 → proxy to pico (granola) │
   │  • nginx stream{} :1212 udp → pico (SS14)│
   │  • sshd :22 (LIMIT, fail2ban) break-glass│
   │  • tailscaled                            │
   │  • dev: tmux, lb-fleet, lb-listener      │
   │    (all localhost-bound; stay here)      │
   └──────────────────────────────────────────┘
              │ tailnet (WireGuard, 100.x.y.z)
              │
   ┌──────────┼──────────────────────────────────────────┐
   │          │                                          │
   ▼          ▼              ▼              ▼            ▼
  pico      metis           zig            iPhone        (future)
  M1 Max    macOS           macOS work     iOS+Termius
  • Ollama  client          client         client
  • Phoenix
  • vs14-web :3300
  • postgres :5432 (loopback only — co-located w/ vs14-web)
  • mapserver + 4 obs containers (Colima)
  • reef-router :7575 (granola receiver)
  • ss14-watchdog :1212 (conditional on Phase 4 feasibility test)
  • launchd plists for: tailscaled, ollama, reef-router, ss14
```

## Devices

`zig-computer` `tag:server` · `pico` `tag:server` · `metis` `autogroup:member` · `zig` `autogroup:member` · iPhone `autogroup:member`

MagicDNS: every device is `<hostname>.zig-zone.ts.net` (substitute the actual tailnet name once Tailscale assigns it; if `zig-zone` isn't available, use whatever the admin console offers).

## Daily ops

### SSH to anything

```bash
tailscale ssh ubuntu@zig-computer.zig-zone.ts.net   # Linux box
tailscale ssh <macuser>@pico.zig-zone.ts.net         # Mac box
```

Tailscale SSH requires re-auth every 12h per the ACL `check` action. Existing sessions stay live across re-auth boundaries.

### iPhone (Termius)

The Tailscale iOS app must be in **Connected** state. Termius uses plain SSH to `ubuntu@zig-computer.zig-zone.ts.net` (or pico). Backgrounding Tailscale on iOS under battery pressure can suspend the connection — re-open the Tailscale app to restore. Works equivalently on cellular and WiFi.

### Reach Ollama from anywhere

```bash
curl http://pico.zig-zone.ts.net:11434/api/tags        # list models
curl http://pico.zig-zone.ts.net:11434/api/generate \  # inference
  -d '{"model":"qwen2.5:7b","prompt":"Hello"}'
```

OLLAMA_HOST is set to pico's tailnet IP via `launchctl setenv` (see `mac.setup.sh`), so Ollama binds the tailnet interface only — not 0.0.0.0, not 127.0.0.1.

### Reach the SS14 game

Players connect to `ss14.zig.computer:1212` (DNS to zig-computer's public IP). nginx stream{} forwards UDP+TCP to pico via the tailnet. **Conditional on Phase 4 feasibility test passing** — if SS14 leaked its bind address in handshakes, the game stays on zig-computer.

## ACL change workflow

When `tailscale/acl.jsonc` changes:

1. Open https://login.tailscale.com/admin/acls/file
2. Paste the file contents (replace existing)
3. Click "Preview" — Tailscale validates JSONC + ACL semantics
4. If clean, "Save"
5. Test from one device: `tailscale ping pico` from `zig-computer` should succeed; same from `metis`

The Tailscale admin keeps every prior policy in the changelog. If a paste breaks the mesh, one-click revert.

## Recovery — when something's broken

| Symptom | First check | Recovery |
|---|---|---|
| `tailscale ssh` fails to authenticate | `tailscale status` on the source device — coordination server reachable? | Fall back to public `ssh ubuntu@51.81.33.136` on port 22. Existing tailnet sessions stay live; only NEW Tailscale auth fails. |
| Public SSH (port 22) also unreachable | `nmap -p22 51.81.33.136` from outside | OVH KVM web console → log in directly. Documented as Prerequisites step 0. Credentials in password manager. |
| `pico.zig-zone.ts.net` unreachable but other devices fine | physically check pico — power on? screen sharing? | Mac may have crashed or lost network. `autorestart` recovers from power loss; for soft crashes, manual reboot. |
| ACL push broke all access | `tailscale status` on every device shows "no peers" | Tailscale admin → Access Controls → changelog → revert to previous policy (one-click). |
| nginx 502 on `*.zig.computer` | curl from zig-computer: `curl -I http://pico.zig-zone.ts.net:3300` | If 502 from inside tailnet too: vs14-web crashed on pico, restart via `launchctl kickstart`. If clean from inside: nginx upstream config drifted. |
| reef-router 502 on `:7575` webhook | Same pattern: curl from zig-computer to pico's 7575 | Restart reef-router LaunchAgent on pico. Verify granola can still reach it (granola's URL doesn't change — it always hits the public IP). |
| Ollama latency suddenly bad | `tailscale status` on zig-computer — direct or relay? | If `relay`: home ISP changed, NAT shifted. Investigate Tailscale DERP region or whether home router needs a restart. |

## Migration phases (operational — execute once)

Full spec in bead `dotfiles-phe` § 4.4. The phases are sequential; each completes when its TC# (spec § 5) passes on the live system. Track each phase's start/end with its own `-t task` bead, parented to `dotfiles-phe`.

### Prerequisites (one-time safety checks + pico bootstrap)

**Step 0 — safety checks BEFORE any change:**

- **OVH KVM verify**: log into OVH manager, find your VPS, click "KVM console," see the Ubuntu login prompt, log out. Confirms the nuclear-recovery path works. Document credential location in password manager.
- **Mac safety on pico** (System Settings):
  - FileVault → OFF (in-home server; threat model justifies)
  - Energy → "Start up automatically after a power failure" → ON
  - General → Software Update → Advanced → uncheck "Install macOS updates" + "Install Security Responses and system files"

**Step 1 — pico bootstrap from fresh install:**

1. Enable Remote Login (System Settings → General → Sharing → Remote Login)
2. `xcode-select --install` (interactive)
3. Install Homebrew
4. `git clone https://github.com/azigler/dotfiles ~/dotfiles`
5. `bash ~/dotfiles/mac.setup.sh` — installs ollama, tailscale, colima, docker, docker-compose, plus all workshop tooling; sets pmset; starts tailscaled + ollama; `tailscale up` prompts browser SSO
6. `bash ~/dotfiles/sync.sh` (or per-feature sync) — symlink configs
7. Verify: `brew list | grep -E "ollama|tailscale|colima"`, `tailscale status`, `colima status`

### Phase 0 — Mesh bootstrap

1. Install Tailscale on each remaining device (zig-computer, metis, zig, iPhone). Linux: `curl -fsSL https://tailscale.com/install.sh | sh`. macOS: `brew install tailscale`. iOS: App Store.
2. `sudo tailscale up` on each (plain — no tags, no SSH). Browser SSO; auth all with the same user account so they share one tailnet.
3. Verify (TC01): `tailscale status` on each device lists the other 4
4. Verify (TC02): `dig +short pico.zig-zone.ts.net` from zig-computer returns 100.x.y.z
5. Verify (TC03): `tailscale status` on zig-computer shows `direct` to pico (not `relay`)

### Phase 1 — ACL + tags + SSH

1. Commit `tailscale/acl.jsonc` (this file) + `tailscale/README.md` if not yet
2. Paste `tailscale/acl.jsonc` into Tailscale admin → Access Controls → Save (Tailscale's preview catches syntax errors)
3. Re-run on servers: `sudo tailscale up --ssh --advertise-tags=tag:server` on zig-computer + pico
4. User devices (metis, zig, iPhone): `tailscale set --ssh=true` (no tag advertise needed; they stay untagged → autogroup:member)
5. Verify (TC04): `tailscale ssh ubuntu@zig-computer.zig-zone.ts.net` from metis succeeds
6. Verify (TC05): `ssh ubuntu@51.81.33.136` on port 22 still works (break-glass intact)
7. Verify (TC06): `sudo fail2ban-client status sshd` on zig-computer is active

### Phase 2 — Ollama + Phoenix → pico

1. On pico: `launchctl setenv OLLAMA_HOST "$(tailscale ip -4):11434"` + `brew services start ollama` (this happens automatically in mac.setup.sh; just verify it stuck)
2. `ollama pull llama3.2:3b qwen2.5:7b` (smoke + real model)
3. On pico: install Phoenix (`pip install arize-phoenix` or `uv pip install arize-phoenix`), start bound to tailnet IP on `:4317` gRPC + `:6006` UI
4. Verify (TC07): `lsof -iTCP:11434 -sTCP:LISTEN` on pico shows only tailnet-IP bind
5. Verify (TC08): `curl http://pico.zig-zone.ts.net:11434/api/tags` from zig-computer returns 200 + model list
6. On zig-computer: `sudo systemctl stop ollama lb-phoenix && sudo systemctl disable ollama lb-phoenix`
7. Verify (TC09): `curl http://localhost:11434/api/tags` on zig-computer returns connection-refused
8. Update OTEL env vars and any agentic-loop configs to point at `pico.zig-zone.ts.net`

### Phase 3 — vs14-web + postgres + obs containers + reef-router + timers

This is the chunkiest phase. See spec § 4.4 Phase 3 for the full 11-step procedure. The highlights:

1. **Postgres** on pico via Homebrew, restored from pg_dump. **Exception to the "bind tailnet IP" pattern** — stays on 127.0.0.1 because consumers are co-located on pico.
2. **Docker via Colima** (NOT Docker Desktop): `colima start` once. Restore the 5 obs containers.
3. **Critical** — rewrite the mapserver container's DATABASE_URL from Linux-bridge `172.17.0.1:5432` to macOS-compatible `host.docker.internal:5432`. Verify from inside: `docker exec mapserver psql -h host.docker.internal ...`.
4. **Project timers** — port the 8 known systemd timers (`ss14-backup.timer`, `ss14-replay-rotate.timer`, `vs14-postgres-retention.timer`, `vs14-cookbook-build.timer`, `vs14-guidebook-build.timer`, `vs14-nurseshark-build.timer`, `vs14-writer-build.timer`, `vs14-map-render.timer`) to launchd plists or cron on pico. macOS `StartCalendarInterval` is more verbose than systemd `OnCalendar`; use cron if the schedule is simple. Disable on zig-computer once pico equivalents run.
5. **reef-router**: `git clone` on pico, `bun install`, scp BOTH `.env.local` files (root + `polyps/router/`) — they're gitignored. Create LaunchAgent at `~/Library/LaunchAgents/com.zig.reef-router.plist` mirroring the systemd unit (KeepAlive=true, EnvironmentVariables incl `REEF_HOST=$(tailscale ip -4)`).
6. **vs14-web**: clone, install deps, verify `tailscale ip -4` returns 100.x.y.z, then `next start -H $(tailscale ip -4) -p 3300`.
7. **nginx on zig-computer**: update each vhost's `proxy_pass` upstream to `http://pico.zig-zone.ts.net:<port>`. Add a new server block on port 7575 for the granola webhook → proxy to pico.
8. `sudo nginx -t && sudo systemctl reload nginx`
9. Verify (TC10, TC11, TC17): public URLs render content from pico; postgres remains loopback-only; granola POST reaches pico's reef-router.
10. **Drain window**: `sleep 60` to let in-flight HTTP/2 + WebSocket connections finish on the old upstreams.
11. Stop + disable on zig-computer: `sudo systemctl stop vs14-web postgresql@17-main reef-router && sudo systemctl disable vs14-web postgresql@17-main reef-router`. Stop + remove the 5 obs containers from zig-computer's docker.

### Phase 4 — SS14 game server (conditional on feasibility test)

**Cut over in a no-players window.** UDP doesn't drain via nginx stream{}.

1. Install SS14 watchdog on pico (likely launchd plist mirroring the upstream watchdog config)
2. Configure SS14 to bind `0.0.0.0:1212` for the first test
3. On zig-computer: add nginx stream{} block forwarding UDP+TCP :1212 → pico
4. `sudo nginx -t && sudo systemctl reload nginx`
5. **Feasibility test (TC12)**: stop SS14 on zig-computer. Real client connects to `ss14.zig.computer:1212`. Play 5+ minutes. On the client machine, `tcpdump -n host pico.zig-zone.ts.net or 'src net 100.0.0.0/8'` — verify ZERO packets target the tailnet directly (would indicate SS14 leaked its bind address)
6. **If pass**: disable `ss14-watchdog.service` on zig-computer; port `ss14-backup.timer` + `ss14-replay-rotate.timer` to pico
7. **If fail**: abort SS14 migration. Remove the nginx stream{} block. SS14 stays on zig-computer. File a `-t note` bead with the test output. Other phases stand independently.

### Phase 5 — End state verification

Verify (TC14) on zig-computer post-everything:

- System services running: nginx, sshd, fail2ban, tailscaled, system stuff. NO `ss14-*`, `vs14-*`, `postgresql@*`, `ollama`, `reef-router`, `lb-phoenix`, vs14 docker workload containers.
- User services running: `tmux.service`, `lb-fleet.service`, `lb-listener.service` (the dev-tooling exceptions — explicit "stays here" per spec)

Verify (TC15) the ACL is allowlist-default-deny via Tailscale admin's policy-preview simulator: a future contractor-account device with no autogroup:member membership and no tag gets denied to `pico:22`.

Verify (TC16) keys are local + portable: confirm `tailscaled` private key paths exist (`/var/lib/tailscale/` on Linux, `~/Library/Application Support/Tailscale/` on Mac). This is the Headscale-migration safety net.

## What stays on zig-computer (the workshop + edge)

| Service | Bind | Why it stays |
|---|---|---|
| nginx | :80, :443, :7575, :1212 (stream) | Public TLS edge |
| sshd | :22 (LIMIT + fail2ban) | Break-glass when Tailscale is down |
| fail2ban | — | Protects the break-glass |
| tailscaled | — | Mesh client |
| `tmux.service` | — | Keeps the user's tmux session alive across SSH sessions |
| `lb-fleet.service` | 127.0.0.1:7100 | Internal dev tool (lb-agent-fleet) |
| `lb-listener.service` | 127.0.0.1:7102 | Internal dev tool (lb-agent-listener) |

## Future considerations (not in this spec)

- Move `lb-fleet` / `lb-listener` to pico if the agentic-loop workflow shifts there
- LoRA fine-tuning on pico (MLX-LM + Python venv) — separate spec
- Headscale self-hosted coordination server (drop-in replacement for Tailscale's) — keys are portable
- Subnet routing on pico (if a NAS / Pi appears on the home LAN)
- Tailscale Funnel for selective public exposure (unlikely; zig-computer's edge is what we have)
- Additional VPS for geographic edge redundancy (e.g. `corsair` on a different cloud)

## Reference

- **Spec**: bead `dotfiles-phe` (closed). `br show dotfiles-phe` for the full decision rationale + all 18 test cases
- **ACL policy file**: `~/dotfiles/tailscale/acl.jsonc`
- **Tailscale docs**: https://tailscale.com/kb
- **OVH KVM access**: documented in personal password manager
- **Audit context**: `~/explore/.claude/skills/zig-computer-audit/SKILL.md` for current zig-computer topology
