# ss14-wrapper

PROXY-protocol-aware UDP+TCP wrapper that sits between nginx (running on
zig-computer) and SS14's Robust.Server (running on pico). Built per spec
`dotfiles-9g1` (Approach C2: nginx + wrapper-pair + minimal Robust.Server
patches).

## What it does

nginx on zig-computer accepts game traffic on the public face and
forwards it to pico's tailnet IP with a PROXY-protocol header carrying
the real client IP+port. Lidgren (the network stack inside Robust.Server)
has no PROXY-protocol parser, so this wrapper sits in front of
Robust.Server:

1. Listens for UDP+TCP on `tailnet-IP:1212` (PROD) or `tailnet-IP:11214`
   (initial dev — see caveats).
2. Strips the PROXY header (v1 text on UDP, v2 binary on TCP — autodetected
   by `github.com/pires/go-proxyproto`).
3. Forwards the stripped payload to Robust.Server's loopback bind.
4. Maintains a 5-tuple → real-client-IP map and exposes it over a Unix
   Domain Socket so the patched Robust.Server can resolve
   `loopback-peer → real-client-IP` for every moderation read (bans,
   IPIntel, AdminAlertIfSharedConnection, etc.).

## Layout

| Path | What it is |
|---|---|
| `main.go` | Daemon entrypoint — loads env, calls `wrapper.Run` |
| `wrapper/config.go` | Env-loader (`LoadConfigFromEnv`) |
| `wrapper/proxy.go` | UDP+TCP listener + PROXY-header parse + forwarding |
| `wrapper/session.go` | 5-tuple session map with TTL eviction |
| `wrapper/api.go` | UDS server: LOOKUP / ENUMERATE / HEALTH |
| `wrapper/*_test.go` | Go unit tests |
| `integration_test.sh` | End-to-end nginx-stream PROXY-emit test |
| `build.sh` | Cross-compile entry point (`GOOS=darwin GOARCH=arm64`) |
| `com.zig.ss14-wrapper.plist` | LaunchAgent template (placeholders) |
| `deploy.sh` | Live-deploy recipe (build → scp → reload → verify) |
| `docs/ss14-patch-tests.md` | C# test design sketch for the SS14 fork patches |

## Environment variables

The wrapper takes its configuration entirely from environment variables
(set in `com.zig.ss14-wrapper.plist`). Names + defaults are authoritative
in `wrapper/config.go`:

| Var | Required | Default | Meaning |
|---|---|---|---|
| `SS14_WRAPPER_LISTEN` | yes | — | UDP+TCP bind addr (e.g. `100.95.4.73:1212`) |
| `SS14_WRAPPER_UPSTREAM` | yes | — | Where to forward stripped payloads (e.g. `127.0.0.1:1213`) |
| `SS14_WRAPPER_SOCK` | yes | — | UDS path for the LOOKUP API (e.g. `/tmp/ss14-wrapper.sock`) |
| `SS14_WRAPPER_TTL_SECONDS` | no | `120` | Idle-session eviction TTL — matches nginx `proxy_timeout` |
| `SS14_WRAPPER_LOG` | no | (stderr only) | Best-effort structured-log file path |

The 120s TTL default matches nginx's `proxy_timeout 120s` in spec §4.1
(decision via `/check` OQ-01, bead `dotfiles-9cj`).

## Building

### On pico (native — what `mac.setup.sh` runs)

```bash
cd ~/dotfiles/ss14-wrapper
go build -o ~/ss14-wrapper/ss14-wrapper .
```

### From Linux / CI (cross-compile)

```bash
bash ~/dotfiles/ss14-wrapper/build.sh
# produces ./ss14-wrapper-darwin-arm64 (Mach-O 64-bit arm64 executable)
```

Pure Go, no CGO — the resulting binary is a static Mach-O that runs on
Apple Silicon Macs without any runtime install. Per spec §3.6 this is
the explicit reason Go was chosen.

## Deploying (LaunchAgent)

`mac.setup.sh` does this automatically when you re-run it on pico. The
manual recipe (idempotent):

```bash
# 1. Build the binary
cd ~/dotfiles/ss14-wrapper && go build -o ~/ss14-wrapper/ss14-wrapper .

# 2. Render the LaunchAgent plist with the local tailnet IP + HOME
sed -e "s|TAILSCALE_IP_PLACEHOLDER|$(tailscale ip -4)|g" \
    -e "s|USER_HOME_PLACEHOLDER|$HOME|g" \
    ~/dotfiles/ss14-wrapper/com.zig.ss14-wrapper.plist \
    > ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist

# 3. Load (unload first if a prior version is running)
launchctl unload ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist 2>/dev/null || true
launchctl load -w ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist

# 4. Verify it's running
launchctl list | grep ss14-wrapper   # expect "0  <pid>  com.zig.ss14-wrapper"
```

## Operating

### Logs

| Path | Source |
|---|---|
| `/tmp/ss14-wrapper.log` | StandardOutPath + StandardErrorPath (combined) |

Tail with `tail -f /tmp/ss14-wrapper.log`.

### Reload

After an env-var change in the plist (or a new binary):

```bash
launchctl kickstart -k gui/$UID/com.zig.ss14-wrapper
```

`kickstart -k` sends SIGTERM + restarts under KeepAlive without
unloading the agent, so it's the fastest live-restart verb. For a full
re-load (e.g. after rendering the plist template afresh), use the
`launchctl unload && launchctl load -w` pair instead.

### Probe the UDS API

The wire format is newline-delimited text (spec §4.2), trivially
debuggable with `nc -U`:

```bash
# Health: returns "OK active_sessions=N uptime_s=X\n"
echo "HEALTH" | nc -U /tmp/ss14-wrapper.sock

# Enumerate: lists every known session
echo "ENUMERATE" | nc -U /tmp/ss14-wrapper.sock
# expect: zero or more "<proto> <port> <real-ip>:<real-port>\n" then "END\n"

# Lookup by fan-out port (this is what Robust.Server's patch calls):
echo "LOOKUP udp 33000" | nc -U /tmp/ss14-wrapper.sock
# expect: "OK <real-ip>:<real-port>\n" (hit) or "MISS\n" (no such session)
```

The full wire-format spec (with proto/port grammar, error responses, and
the C# test surface that consumes it) is in `docs/ss14-patch-tests.md`.

## Caveats

### Initial-dev port `:11214` vs cutover `:1212`

The bundled plist ships with `SS14_WRAPPER_LISTEN=TAILSCALE_IP:11214`
and `SS14_WRAPPER_UPSTREAM=127.0.0.1:11215` — both in the test-port
range (per `/check` `dotfiles-9cj` convention) to avoid colliding with
the still-live SS14 on `:1212` until the full Robust.Server cutover is
staged.

At cutover (spec §4.6):
- `SS14_WRAPPER_LISTEN` flips to `TAILSCALE_IP:1212`
- `SS14_WRAPPER_UPSTREAM` flips to `127.0.0.1:1213` once Robust.Server
  moves its bind (per ss14-watchdog `config.toml` diff in §4.5)
- `SS14_WRAPPER_SOCK` may move from `/tmp/` to `/Users/pico/run/` for a
  more durable location (spec §4.4 prefers the latter).

Edit `~/dotfiles/ss14-wrapper/com.zig.ss14-wrapper.plist`, re-render via
the install recipe above, and `kickstart -k` the agent.

### Wrapper restart cost

The wrapper is stateless across restarts (ratified `/check` OQ-02, bead
`dotfiles-9cj`). On crash + KeepAlive restart, every active player's
session map is empty until their next UDP datagram arrives bearing a
fresh PROXY header. Lidgren's `ConnectionTimeout` (~25s with defaults)
will reconnect any session that gets dropped in the gap; new connects
during the gap have wrong IPs in `ban_address` etc. and need to retry.

### `SS14_WRAPPER_SOCK` lifecycle

The wrapper does **not** unlink a stale socket at the path before
binding. If `launchctl load -w` is called on a freshly-rebooted pico
this is fine (`/tmp` is wiped on reboot); on a hot re-load you may need
to `rm /tmp/ss14-wrapper.sock` first if the previous instance didn't
clean up. The deploy script (`deploy.sh`) handles this.

## See also

- Spec: `br show dotfiles-9g1` — the formal specification for Approach C2
- /check artifact: `br show dotfiles-9cj` — empirical PROXY v1 evidence + OQ decisions
- Parent: `br show dotfiles-52c` — Approach C2 rationale
- Test bead: `br show dotfiles-qts` — TDD test surface (this directory)
- Deploy bead: `br show dotfiles-b9o` — this artifact set (deploy + plist + README)
- `docs/ss14-patch-tests.md` — C# test design for the SS14 fork patches
- `~/dotfiles/mac.setup.sh` — the install block that drops this into place on pico
