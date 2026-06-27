# <project> — Infra & Network Topology

Operational facts for running <project>. **Verified live <date>.** (See the
global `agents/infra.md` for the machine baseline; this captures project-specific
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

## nginx plan (not yet built)
`<name>.conf`: server_name `<name>`, certbot TLS, `location /<path> { proxy_pass
http://127.0.0.1:<port>; }`. `nginx -t` before reload. Use `/nginx`.

## The old deployment (to decommission)
<What/where the prior thing is + the teardown command, after cutover.>

## Secrets
`~/.secrets` (600), `source` to load. Relevant: `<KEY>` (verified), `<WEBHOOK_TOKEN>`.
**Sibling consumers of shared keys:** <project/path + cadence — stay rate-courteous.>

## Webhook/upstream go-live sequence (gates the human step)
1. Daemon built + listening on `127.0.0.1:<port>` (+ auth verification).
2. nginx vhost + certbot TLS, reachable.
3. **Then** point the upstream at `https://<name>/<path>` (+ auth header/secret).
   Until then, do NOT — events would 404/retry.
