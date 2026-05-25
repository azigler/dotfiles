# Session handoff — 2026-05-25 beb8609d

## State at offboard

- **Branch**: main, clean working tree
- **Last commit**: `3a785a7 :card_file_box: beads: close 52c, jjd, r8k — C2 exploration arc fully closed`
- **SS14 production**: ON ZIG-COMPUTER, round 25, 1 player (the user), map "Reach", run_level 1, stable. Robust.Server pid 1321781, fork binary, all-listeners green.
- **Open beads**: 2 — both deferred (st2 iPhone Termius nerdfonts; 406 zig laptop tailnet)
- **In-flight subagents**: none
- **Markers**: `.offboard-pending` not present
- **Cost tracking**: not enabled for this project (no `.claude/plans/cost-tracking.md`); skipping the ledger update

## What happened this session (the C2 arc — landed + rolled back)

This session resumed after compaction with the C2 cutover paused mid-Step-8 due to wrapper-impl bug `dotfiles-jc5`. The arc completed end-to-end: fix → spec correction → cutover → latency-driven rollback → fork-binary redeploy → wrapper relocation. All beads closed.

### 1. Fix `dotfiles-jc5` (wrapper PROXY-per-session bug)

- Dispatched worktree subagent against `ss14-wrapper/wrapper/proxy.go` + `session.go`
- Added `LookupBySrcTuple` to `SessionStore` (thread-safe write-lock + bumps `LastSeen`)
- Introduced `ErrNoProxyHeader` vs `ErrMalformedProxyHeader` classification — parse-failure becomes a *routing signal* (look up established session) rather than a drop signal
- Added 4 new tests: 2 error-classification + 2 live-`ServeUDP` (regression guard + orphan-drop guard)
- Extended integration test with multi-datagram-same-src-port stage (pinned src port, 1 headered + 2 headerless → all 3 must reach upstream)
- `/scrutinize` verdict: **SHIP**. Reviewer independently reproduced pre-fix failure by reverting only the parse-failure branch body — confirmed real regression guard, not just additive coverage.
- Merged `eb4ff2a` + closure `43deecf`

### 2. Spec correction (`dotfiles-9g1` §3.8)

- Appended **POST-jc5 CORRECTION** block to spec's `--description` documenting that nginx UDP `proxy_protocol on` emits headers ONCE per nginx-UDP-session (keyed on client `<src-ip, src-port>`), NOT per datagram as the spec originally claimed
- Listed every affected section (§1.3, §3.6, §3.8, §4.1, §4.2, §5 TC03, §6 OQ-03 resolution)
- Appended SUPERSEDED pointer to closed bead `dotfiles-9cj` `--notes` (the /check decision whose OQ-03 conclusion drove the bug)
- Test-fixture lesson: the OQ-03 synthetic test used `nc` invocations that allocated a fresh ephemeral src port per datagram → each got its own nginx UDP session → each got its own header (masking the per-session-only behavior). Real Lidgren uses ONE src port for the entire handshake. **General rule**: any UDP test sending multiple datagrams MUST pin the src port to honestly exercise session-reuse.
- Commit `24e48d2`

### 3. Cutover (`dotfiles-oxe`) — executed cleanly

- Built fresh wrapper binary with jc5 fix (`53b9083...`), deployed to pico via `scp` + `launchctl kickstart -k`
- Loaded pico's ss14-watchdog (Robust.Server pid 38327 bound `127.0.0.1:1213` UDP, `*:1213` TCP)
- Synthetic UDP smoke test (3 datagrams from src `:56000` → pico:11214) created ONE session with real IP `192.0.2.99` — jc5 fix verified live on production hardware
- Wrote `/etc/nginx/streams-enabled/ss14-game.conf` (upstream `100.72.47.4:11214`, `proxy_protocol on`, `proxy_timeout 120s`)
- Stopped zig watchdog → `:1212` freed → reloaded nginx → bound `:1212` cleanly
- **User connected via launcher** — 3 wrapper sessions attributed to real IP `172.116.51.187:54724` (Lidgren multiplexed 3 channels through 3 fanout ports). Zero drops in wrapper log since startup.
- /status via public endpoint returned valid JSON through nginx → wrapper → Robust.Server
- Test ban (`/ban yourself 1 jc5-test`) confirmed: `ban_player` + `ban_hwid` recorded; `ban_address` empty (SS14's `/ban` doesn't populate IP scope — that's a separate `/banip` codepath, not a wrapper failure)
- `player.last_seen_address` recorded user's real IP `172.116.51.187` — proves `IRemoteAddressOverride` flowed through the moderation read path end-to-end

### 4. The latency disqualifier

- Captured cutover-active baseline: `zig→pico tailnet RTT ~76ms avg` (direct WireGuard, NOT DERP), `public /status RTT ~193ms avg`
- **Per-packet add of ~76ms** to every game packet (cross-country round trip: Ashburn ↔ user's home in Pacific)
- User feedback: "pretty laggy actually" — for the operator specifically, who lives at pico's location, their packets traverse the continent twice (~150ms total vs ~75ms pre-cutover)
- Decision: **roll back**. C2 architecture is technically proven; deployment topology was geographically wrong.

### 5. Rollback executed

- Unload pico watchdog + replay-rotate (frees `pico:1213`)
- Remove `/etc/nginx/streams-enabled/ss14-game.conf`
- `nginx -t` + reload (frees `zig:1212`)
- Re-enable + start zig's ss14-watchdog → Robust.Server back on `*:1212`
- Post-rollback baseline: `/status RTT ~108ms` (saved ~85ms by removing the pico hop)
- Round 21 started fresh on zig

### 6. Spec/study capture (`dotfiles-v1i`)

- Created and populated comprehensive study bead: topology diagram, A/B/C/D measurements (tailnet ping, /status, postgres SELECT), what-we-learned (5 lessons), what-not-to-undo, recommendations
- Closed with full receipt

### 7. Rules issue diagnosis (the surfaced latent bug)

- Post-rollback, user got empty rules screen on reconnect. Diagnosed two compounding causes:
  - `admin.server_ban_reset_last_read_rules = true` (default) — the test ban reset `last_read_rules` to NULL, forcing re-acceptance
  - Zig's deployed `bin/Resources/ServerInfo/` directory was **entirely missing** — latent stale-deployment bug. Rules path resolved to a missing file → empty content shown
- **Fix A**: rsync `Resources/ServerInfo/` from vs14 source → zig bin. Rules now load (content is upstream stub "This server has not written any rules yet" — user's editorial choice to write real ones later)
- User confirmed the rules were *always* empty (their guidebook web app at ss14.zig.computer/guidebook/DefaultRuleset.html also shows the stub) — this was never cutover-caused data loss

### 8. Zig binary rebuild from fork source

- User wanted zig's binary to match source (include the fork code, sitting inert)
- Previous zig binary was from 2026-04-12, six weeks pre-fork
- Ran `dotnet run --project Content.Packaging -- server --platform linux-x64` (the canonical SS14 packaging path; raw `dotnet publish Content.Server` is incomplete — missing libe_sqlite3.so, libsodium.so, deps.json, etc.)
- Extracted `release/SS14.Server_linux-x64.zip` → zig bin/
- First restart attempt: Robust.Server crash-looped on launcher-connect attempts — missing `Content.Client.zip` for the ACZ provider
- Built client zip with `Content.Packaging -- client --hybrid-acz`, placed at `bin/Content.Client.zip`
- Killed persisted Robust.Server child (PersistServers=true kept the broken one alive across systemctl restart)
- Fresh spawn picked up Content.Client.zip → stable, no ACZ crashes
- Binary now contains IRemoteAddressOverride patches but they sit inert (`net.use_wrapper_remote_address` cvar not set in zig's config)

### 9. Wrapper relocation

- Unloaded `com.zig.ss14-wrapper` LaunchAgent on pico (binary kept in place for forensics)
- Moved `dotfiles/ss14-wrapper/` → `vacation-station-14/ops/ss14-wrapper/`
- Updated Go module path: `github.com/azigler/dotfiles/ss14-wrapper` → `github.com/azigler/vacation-station-14/ops/ss14-wrapper`
- Sed-updated all imports across 5 source files
- Build + tests verified at new location
- Removed wrapper section from `dotfiles/mac.setup.sh` (lines 125-152)
- Two commits: vs14 `8946f652b0` (import), dotfiles `7eb20c4` (delete + setup.sh)

### 10. C2 arc closure

- jjd (GRE/IP-in-IP test) closed not-viable per tailscale#14006
- r8k (TPROXY test) closed not-viable (no clean asymmetric routing)
- 52c (parent study) closed once children done
- Final commit `3a785a7`

## What's next

No active arc. Two deferred beads remain (st2, 406) — both P3, both ❄ frozen until the user decides to revisit. Routine `/onboard` next session will surface them as deferred.

If pico-as-game-server ever comes up again (e.g., the Mac Studio gets colocated near zig), the path is:
1. Re-enable wrapper LaunchAgent on pico (binary is still at `~/ss14-wrapper/ss14-wrapper`; or redeploy from vs14/ops/ss14-wrapper/deploy.sh)
2. Set `net.use_wrapper_remote_address=true` + `wrapper_socket=/tmp/ss14-wrapper.sock` in pico's config.toml
3. Re-add nginx stream block on zig → forward `:1212` to pico:11214
4. Stop zig ss14-watchdog
5. Connect; verify real-IP in wrapper ENUMERATE
6. The C# patches in zig's binary will activate; on pico-side, the binary that's already there has them too

The wrapper code (vs14/ops/ss14-wrapper) and patches (azigler/RobustToolbox fork) are the durable artifacts of this arc.

## Warnings / watch-outs

- **Zig's Robust.Server now runs fork binary** (built today). Patches are inert because cvar not set, but the binary is no longer upstream-vanilla. If you ever want to revert to upstream, rebuild with the submodule pointed at `space-wizards/RobustToolbox` instead of `azigler/RobustToolbox`.
- **Source/binary skew possible**: future SS14 updates from upstream might pull in incompatible changes. The fork's branch `ss14-fork/wrapper-remote-address-vs-4h1` will need rebasing on upstream periodically. Not urgent (we're not actively pulling SS14 upstream).
- **The pico wrapper LaunchAgent is unloaded but the binary still exists at `~/ss14-wrapper/ss14-wrapper` on pico**. If you want to fully clean up pico's filesystem of the wrapper artifacts, `rm -rf ~/ss14-wrapper /tmp/ss14-wrapper.* ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist*` — but that throws away the working configuration if you ever want to redeploy.
- **Pico's `config.toml` still has `[net] use_wrapper_remote_address=true bindto=127.0.0.1 port=1213 wrapper_socket=/tmp/ss14-wrapper.sock`** — harmless because the pico watchdog stays unloaded. If you ever want pico's SS14 to run standalone again (no wrapper), revert config.toml + watchdog appsettings to the pre-cutover state.
- **The `/etc/systemd/system/ss14-watchdog.service` on zig has `KillMode=process`** — combined with the watchdog's PersistServers=true behavior, this means `systemctl restart ss14-watchdog` does NOT kill Robust.Server child processes. If you need a clean child restart, manually `kill $(pgrep -f "Robust.Server.*config-file")` first.
- **Rules content is the upstream stub** — "This server has not written any rules yet. Please listen to the staff." If you want real rules, edit `vacation-station-14/Resources/ServerInfo/Guidebook/ServerRules/DefaultRules.xml` in source, rebuild + redeploy (or rsync just that file to zig's `bin/Resources/...`).
- **dotfiles `.beads/issues.jsonl` has many closed beads from this arc** — visible via `br list --all` if you ever need to grep history. Don't delete the JSONL.
- **Latency follow-up**: if the user ever wants to re-attempt the C2 architecture, the geographic mismatch must be solved first. Don't repeat the latency mistake — file a `study` bead exploring colo vs US-East wrapper relay before any redeployment.
