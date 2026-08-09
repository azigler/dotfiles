# <project> — Infra & Network Topology

Operational facts for running <project>. **Verified live <date>.** (See the
global `~/.agents/infra.md` for the machine baseline; this captures project-specific
routing.)

## Where things run
| Host | Role | Address |
|---|---|---|
| <box> | <gateway / harness / dev> | public `<ip>`, tailnet `<ts-ip>` |
| <other> | <where prod usually runs> | tailnet `<ts-ip>` |

- Project lives at `<path>` on **<box>**.
- `<name>.<domain>` **→ `<ip>`** (DNS confirmed).
- nginx runs on **<box>**; existing vhosts: <list>.

## The where-does-the-ingress-run decision
<State the usual prod-location norm, then whether it applies. Often the daemon
should be co-located with the agent harness even if prod usually runs elsewhere,
because the daemon IS part of the harness. Name the deviation; track as a bead.>

## Ports
In use: <list>. **Daemon fixed port: `<port>` — pick high (10000–32767 band):
above dev/service defaults (3000/8000/8080/9000…), below the OS ephemeral floor
(`cat /proc/sys/net/ipv4/ip_local_port_range`). Behind nginx, so it's
internal/arbitrary; never a dev-default. Verify free with `ss -tlnH`.**

**Listen address: `127.0.0.1` (or the tailnet IP) — never `0.0.0.0`.** Post-deploy
assertion, run and paste the output here: `ss -tlnH | grep ':<port>'` → `<addr>:<port>`.
An auth fix at the nginx edge does NOT protect a wildcard-bound service; probe the
service port directly (`curl -si http://127.0.0.1:<port>/<path>` with NO credential
must be rejected).

## nginx plan (not yet built)
`<name>.conf`: server_name `<name>`, certbot TLS, `location /<path> { proxy_pass
http://127.0.0.1:<port>; }`. `nginx -t` before reload. Use `/nginx`.

## The old deployment (to decommission)
<What/where the prior thing is + the teardown command, after cutover.>

## Secrets
`~/.secrets` (600), `source` to load. Relevant: `<KEY>` (verified), `<WEBHOOK_TOKEN>`.
**By pointer only — the NAME here, never the value; no literal in a unit file, a
config, or this doc.** systemd: `EnvironmentFile=%h/.secrets`; anything without that
(launchd, a cron one-liner) gets a wrapper that `source`s the file and `exec`s the
binary.
**Sibling consumers of shared keys:** <project/path + cadence — stay rate-courteous.>

## Timers / units (machine-local, not in git)
`<unit>.service` + `<unit>.timer` in `~/.config/systemd/user/`. If
`Persistent=true`: the persistence stamp is
`~/.local/share/systemd/timers/stamp-<unit>.timer` — **`mv` it on any rename**, or
`enable` fires a phantom catch-up tick. Verify the schedule with
`systemd-analyze calendar '<OnCalendar>'`; run artifacts are named per-RUN
(`YYYYMMDD-HHMMSS`), never per-day, so a same-day retry can't collide.

## Webhook/upstream go-live sequence (gates the human step)
1. Daemon built + listening on `127.0.0.1:<port>` (+ auth verification).
2. **Negative control:** break each new check (stash the fix / drop the credential)
   and confirm it FAILS. Paste what you broke + what failed here.
3. nginx vhost + certbot TLS, reachable.
4. **Then** point the upstream at `https://<name>/<path>` (+ auth header/secret).
   Until then, do NOT — events would 404/retry.
