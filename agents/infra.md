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
| **marketing-vps** (was `vps-8a9eb245` until 2026-08-03) | **plain SSH, NOT on the tailnet** | Linux VPS | LinearB marketing work; a second writer on shared repos; Claude Code routes through pico's agentgateway over a chained `ssh -L` |
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

## pico — the home production Mac (NO systemd; launchd instead)

Verified live **2026-08-01** (`dotfiles-5da3`). Reach it: `ssh pico` → resolves to
`pico.tailfb4637.ts.net:2222` with `~/.ssh/id_ha`. **Port 2222, not 22** — tailscaled only
intercepts :22 on the tailnet IP and Tailscale SSH has no grammar for tag-src → user-owned-dst
(`com.zig.sshd-alt-port`, `dotfiles-wzh`).

- **hostname `pico`** — macOS 14.4 (23E214), arm64 (T6000), user `pico` (uid 501, admin).
  Uptime 64 d. Disk 175 GiB used / 724 GiB free.
- Tailscale **`100.72.47.4`** (`pico.tailfb4637.ts.net`), tailscale 1.98.3. Home LAN behind
  `192.168.1.1`; WAN egress `172.88.172.160` as of 2026-08-04 (was `172.116.51.187`;
  it moved across that day's outage, so treat this one as **volatile** — derive it from
  `tailscale ping pico` rather than trusting the value here). Path to zig-computer is
  **direct**, not relay.
- **Role:** where most user-facing production runs — Vacation Station 14 (game server, web,
  admin, CDN, maps, keycloak, grafana/loki/prometheus, nightly builds), the **agentgateway**
  LLM/MCP proxy the whole fleet's Claude Code traffic flows through, ollama, the ha-portal LAN
  proxy, and the go-jamming webmention receiver.
- ⚠️ **No systemd.** `launchctl list` is the source of truth — and **`sudo launchctl list` for
  system daemons**, which are invisible from the user domain (the `bd-9qi` trap). User agents:
  `~/Library/LaunchAgents/com.zig.*.plist`. System: `/Library/LaunchDaemons/com.zig.*.plist`.
  A schedule is `StartCalendarInterval` / `StartInterval`, not a `.timer`; a last-exit status of
  0 in `launchctl list` is the only "did it work" signal, so **read the job's log too**.
- ⚠️ **NO HOST FIREWALL.** ALF disabled, pf disabled. A wildcard bind here is genuinely reachable
  from every device on the home LAN — unlike zig-computer, where ufw `INPUT DROP` covers it.
- ⚠️ **SSH password auth is ON** (`sshd -T`: `passwordauthentication yes`,
  `kbdinteractiveauthentication yes`) on both :22 and the wildcard :2222.

### Ports
Tailnet-bound (`100.72.47.4`): **8080** nginx (the vs14 front door), **3300** vs14-web (next/bun),
**11434** ollama (loopback does NOT reach it), **6006** phoenix, **15000** agentgateway admin UI,
**10000** the stale harness PWA.
⚠️ **Wildcard (`*:`) binds — LAN-reachable:** **15001** agentgateway MCP, **15003** agentgateway
LLM, **17017** agentgateway `claude`→api.anthropic.com relay (**no apiKey policy** — transparent
passthrough, caller must supply their own Anthropic key), **14829** go-jamming, **4317** phoenix
OTLP, **5432** postgres@17, **5218 / 5427 / 8087** colima ssh forwards (vs14 mapserver / admin /
cdn), **53** lima usernet, **2222** alt sshd, **50051** multipassd, **5900** Screen Sharing,
**88** kdc. `0.0.0.0:7378` picod-proxy is **intentional** (homeowner ha-portal at
`http://pico.local:7378` → zig-computer:19632). Loopback: 15020/15021 agentgateway,
3100/3200/9090/18080/60121 colima forwards.

### Secrets — `~/.secrets` (600, sourced by `~/.local/bin/agentgateway-run`)
`AGW_GOOSE_KEY` · `AGW_CC_KEY`. That is the whole file. `~/.config/agentgateway/config.yaml` is
600 and references them as `${…}` (3 key lines, 2 vars — lines 58 and 129 share the goose value);
expansion is **verified working** (goose key → HTTP 200 on `15003/v1/models`; the literal string
`${AGW_CC_KEY}` → 401). ⚠️ agentgateway's apiKey policy accepts **`Authorization: Bearer`, NOT
`x-api-key`** — an `x-api-key` probe 401s and looks like a config failure.
⚠️ `~/gojamming/config.json` still holds a plaintext token and is **not** a `~/.secrets` pointer.

### Request attribution — `user` is the SESSION, `group` is the MACHINE
Verified live 2026-08-03 (`dotfiles-ogkz`). `config.standardAttributes` maps two request
headers into two columns of `~/.local/share/agentgateway/requests.db`:

| header (sent by `claude-identity-wrapper.sh`) | CEL → column | value |
|---|---|---|
| `X-Session-Identity` | `user` → `agentgateway_user` | `<tmux session>:<window>` |
| `X-Machine-Origin` | `group` → `agentgateway_group` | `hostname -s` |

⚠️ **`agentgateway_user` is NOT a machine name**, however much `zig-computer:hevyd` looks
like one — the first field is the tmux SESSION. zig-computer and marketing-vps both run a
session called `work`, and metis shares the namespace, so ≥3 machines collide there. That
is why `group` exists. `src.addr` cannot substitute: tunnelled traffic arrives as
zig-computer's tailnet IP.

⚠️ **Querying that DB — two traps, both paid for on 2026-08-04 (`dotfiles-9o46`).** The
table is **`request_logs`** (not `requests`) and the time column is **`started_at`** (not
`start_time`/`timestamp`). `started_at` is **ISO8601 with a `T` and an offset** —
`2026-08-04T14:21:22.688368+00:00` — so a bare string comparison against SQLite's
`datetime('now',…)` (`2026-08-04 14:01:27`) compares `'T'` > `' '` at position 10 and
silently matches **every row with today's date**, not the window you asked for. Measured
side by side: `started_at > datetime('now','-20 minutes')` returned **2903** rows where
`datetime(started_at) > datetime('now','-20 minutes')` returned **18**. Always wrap the
column in `datetime()`. `date(started_at)` and `strftime(…, started_at)` parse it fine.

⚠️ **Verifying gateway routing from a session started with `CC_NO_GATEWAY=1` is
worthless** — the hatch is exported, so every shell and every `claude -p` you spawn
inherits it and goes direct while looking like a successful gateway test. The request
answers normally and simply never appears in `request_logs`. Strip it explicitly:
`env -u CC_NO_GATEWAY …`. The log is the only honest check.

⚠️ **The identity is NOT in `attributes_json`** — 0 of 78,848 rows ever matched
`%session-identity%`. It is a COLUMN, via the CEL expression. Query
`agentgateway_user` / `agentgateway_group`, and filter the admin API through
`filters.attributes` (`agentgateway.group`), verified with a positive and negative control.

A client whose wrapper predates the machine header logs `group='unknown'` (the CEL
default), which is indistinguishable from a client that never sent one.

⚠️ **`config:` applies ONLY AT STARTUP** — agentgateway hot-reloads `modelCatalog` and
nothing else, so any `standardAttributes` change needs
`launchctl kickstart -k gui/501/com.zig.agentgateway` (≈10 s, `KeepAlive` recovers it) and
drops every in-flight fleet request. Validate first: `agentgateway --validate-only -f <cfg>`
exits non-zero on bad CEL and names the offending field — pair it with a deliberately
broken control, since a validator you have not watched reject anything proves nothing.

⚠️ **The gateway's healthy signature on `/claude/v1/models` is `401`, not `200`** — it is a
transparent passthrough with no key attached, so 401 means the request reached Anthropic.
`/claude/` and `/v1/models` both 404 (the route matches `pathPrefix: /claude` and rewrites
to `/`), so a probe that omits the prefix reads as broken when it is fine.

### The kill switch — `gateway-switch.sh` (when pico is the outage)

Routing is deliberately **fail-hard with no fallback** (`dotfiles-ucl4`), so when the
gateway HOST goes away every box loses `claude`. On 2026-08-04 pico was off the internet
for ~6.5h and flipping the fleet off by hand took ~15 steps across two hosts plus a
per-pane fix (`dotfiles-9o46`). `agents/scheduler/gateway-switch.sh` is those steps,
idempotent and symmetric:

```bash
~/dotfiles/agents/scheduler/gateway-switch.sh status         # read-only; no LLM call
~/dotfiles/agents/scheduler/gateway-switch.sh off --dry-run  # print every action, perform none
~/dotfiles/agents/scheduler/gateway-switch.sh off            # bypass: go direct to api.anthropic.com
~/dotfiles/agents/scheduler/gateway-switch.sh on             # restore, then verify with the 401 probe
```

**Run it ON each host — there is no fleet-wide driver**, deliberately: driving the other
box needs `ssh` FROM here, the least reliable thing during the outage it exists for.

⚠️ **A fixture `HOME` does NOT make it safe to try.** Only the zshenv path comes from
`$HOME`; the timer step talks to the real `systemctl --user` and the pane step enumerates
the real tmux server. `HOME=/tmp/x gateway-switch.sh off` on a live box disables the live
tunnel timer and types into live panes — measured in review. Use `--dry-run` instead. (The
test suite is hermetic because it puts fakes on `PATH`, not because of `$HOME`.)

Three things hold the routing and all three must move, which is what the script does:
the per-host `~/.$(hostname -s).zshenv` export; `claude-gateway-tunnel.timer` **if this
host has one** (marketing-vps does, zig-computer does not — the script keys on unit
existence, never on a hostname); and the environment of **already-running shells**, since
the durable tmux panes hold zsh processes that are days old, exported the old value at
start, and will never re-read the file.

⚠️ **A running `claude` cannot be re-routed.** Its routing was fixed at exec time
(`/proc/<pid>/environ`, which is what `status` reads). Panes holding a live claude are
REPORTED, never typed into — `send-keys` there submits a prompt. Restarting them is a
human's call.

⚠️ **`on` reverses only the line `off` wrote** (marked `#gateway-switch:off#`). A
hand-commented export is refused with exit 67 and named for you, because a plain
`# export ANTHROPIC_BASE_URL=…` is indistinguishable from a commented-out **example** —
and this file, per CLAUDE.md rule 2, is exactly where examples get pasted in commented
out. Activating one leaves two conflicting exports; rewriting prose that merely contains
`export ANTHROPIC_BASE_URL=` yields a line that `zsh -n` accepts and every `ssh host cmd`
then fails on.

`status` deliberately spends no LLM call; `--check-request` adds one real end-to-end
request under `env -u CC_NO_GATEWAY` (see the false-pass warning above — without the
`-u` that check passes while going direct).

### Gotchas
- **pico cannot run Claude Code** — no `claude` CLI. `~/.claude/*` symlinks into `~/dotfiles`
  exist but are inert, and that clone is pinned at **2026-06-05** with 8 staged modifications and
  no `core.hooksPath`. Harness changes do NOT propagate here.
- `com.zig.harness` (:10000, `--auth none`) serves `state.json` pushed by zig-computer's
  `harness-refresh` — whose `state-bus.timer` is **masked**, so the data is frozen since
  2026-07-29. A `KeepAlive=true` job serving stale state looks identical to a healthy one.
- Nightly `vs14-guidebook-build` (exit 128, `/var/lib` permission denied) and
  `vs14-cookbook-build` (exit 1, `spawn git ENOENT` — launchd's PATH has no git) have been
  failing every night with no alarm.
- `ollama --version` **on pico** says "could not connect to a running Ollama instance" even when
  ollama is up — it binds the tailnet IP only, not loopback.
- The tailscale "can't reach the configured DNS servers" health warning is **zig-computer's**,
  not pico's. pico reports no health warnings.

## marketing-vps — the LinearB company seat

**NOT on the tailnet.** Plain SSH only, by the `marketing-vps` host alias.
`tailscale status` lists zig-computer, homeassistant, iphone-15-pro, metis, pico
— this box is not a mesh peer.

⚠️ **Renamed `vps-8a9eb245` → `marketing-vps` on 2026-08-03** (`dotfiles-v1uh`) so
agentgateway's `group` column reads the name the box is actually called. The OVH FQDN
`vps-8a9eb245.vps.ovh.us` and the bare old name are kept as `/etc/hosts` aliases, and
`/etc/cloud/cloud.cfg` now sets `preserve_hostname: true` — it was `false` with
`set_hostname`/`update_hostname` active, so cloud-init would have silently reverted the
rename at the next reboot. Per-host dotfiles are keyed on `hostname -s`
(`zsh/.zshrc:10`, `zsh/.zshenv:14`, `sync.sh:52,233,237`), so the three
`zsh/.marketing-vps.*` / `bash/.marketing-vps.bashrc` files were added as COPIES and the
old names deleted only after the rename was verified — moving them first would have
stripped PATH and the gateway routing from every new shell in between.

**Claude Code routes through pico's agentgateway** (since 2026-08-03, `dotfiles-ogkz`)
via `ANTHROPIC_BASE_URL=http://127.0.0.1:17017/claude` in `zsh/.marketing-vps.zshenv` —
a **loopback** address, because this box is not a tailnet peer. `claude-gateway-tunnel.timer`
is the ONLY thing that opens that forward (`ssh -L 127.0.0.1:17017:100.72.47.4:17017
zig-computer`; ssh resolves a `-L` destination on the FAR end, so zig-computer does the
tailnet leg). Routing fails HARD with no fallback (`dotfiles-ucl4`). `CC_NO_GATEWAY=1`
bypasses it for one session (fixed 2026-08-03, `dotfiles-20rx`); to bypass the box
lastingly use `agents/scheduler/gateway-switch.sh off` rather than editing the export by
hand — `sed -i` on `~/.marketing-vps.zshenv` replaces the symlink and detaches the host
from the repo. See "The kill switch" under pico, above.

| | |
|---|---|
| hostname | `vps-8a9eb245` |
| public IP | `15.204.114.210/32` on `ens3` (OVH; gw `15.204.112.1`) |
| OS / kernel | Ubuntu 26.04 LTS · `7.0.0-14-generic` |
| resources | 8 vCPU · 22 GiB RAM · 193 GB `/` (16 G used, 9%) |
| accounts | `ubuntu`, `kevin` (Kevin Fayle), `andrew`, `mike` (Mike Noel), `ben` (Ben Lloyd Pearson) — **a genuinely shared box** |
| `andrew` sudo | **passwordless root** (`sudo -n whoami` → `root`) |

**Role.** Executes the five migrating Dev-Interrupted + weekly-report pulse rows
on the LinearB company seat (`explore-7iz9` architecture (c)). zig-computer's
`pulse-dispatch-remote.sh` drives them; `vps-preflight.sh` gates every dispatch
from zig-computer, never from here. It is a **read-only consumer** of dotfiles —
`vps-repo-refresh.sh --self-update` dies if the tree has local commits.
Interactive work happens in the durable tmux session `work`
(`di-monday`, `di-wednesday`, `pipeline-website`, `imc-aug26`).

**Ports.** `0.0.0.0:22` sshd — the only internet-reachable port.
`127.0.0.1:7100` is a **loopback-only** `ssh -L` to zig-computer's fleet proxy,
opened from this side by `ensure-fleet-tunnel.sh` so the box can self-heal when
zig-computer's reverse `-R` forward dies. `gatewayports no`. No web server, no
nginx, no other listener.

**User timers** (all enabled, all firing; `crontab -l` is empty):
`lb-granola-pull` every 2 min · `imc-pull` every 10 min ·
`vps-repo-refresh` hourly (+300 s jitter) · `claude-vault-sync` at `*:15:00`
(offset from zig-computer's `*:00:00`, so the two never clobber each other's push).

**Repos.** `~/dotfiles` (main, read-only consumer) · `~/linearb` umbrella with
`dashboard-dev-interrupted` + `weekly-reporting` + `agent-factory` as submodules
(detached HEADs are normal for submodules) · `~/marketing-vps` · `~/work/`
(pulse-dispatch run dirs, fable-*, vet drafts).

⚠️ **`~/marketing-vps` is NOT a git repo** (measured 2026-08-04). This file called it
"the team's shared `lb-marketing/marketing-vps` setup repo" — there is no `.git` there
at all, which is consistent with the PAT gotcha below: the clone could never have
succeeded. It is a plain directory (`setup.sh`, `sync.sh`, `upgrade.sh`, `config`,
`.backup/`) **plus its own `.beads/` store** — 6 rows in `issues.jsonl` and a
`beads.db`, last touched 2026-07-20. Those beads are replicated NOWHERE: they are not
in the `dotfiles` store and there is no remote to push them to. Anything that wipes
that directory destroys them (see `~/.in-case-of-retreat.txt` on zig-computer).

**Secrets, by pointer.** `~/.secrets/google-service-account.json` (0600) ·
`~/.config/gh/hosts.yml` — `oauth_token` for `azigler` ·
`~/linearb/pipeline-website/.env.local` — `STRAPI_URL`, `STRAPI_API_TOKEN`.
All `0600`. Nothing pasted into a doc, bead, or memory file.

**Gotchas.**
- ⚠️ **It has re-detached HEAD before, stranding 4 commits (2026-07-31).** Prove a
  push against `git ls-remote`, never `git rev-parse HEAD`. (Clean as of
  2026-08-01: on `main`, tree clean.)
- ⚠️ **Its GitHub PAT 404s on every `lb-marketing/*` repo**, so `agent-factory`,
  `weekly-reporting` and six other submodules cannot be initialized from here
  (`explore-lc15`).
- **`core.hooksPath`**: SET on `~/dotfiles` (`tools/githooks` — the gate fires here;
  observed live 2026-08-04, `verdict: CLEAN` on a doc commit), still **unset on
  `~/linearb`**. This file previously said unset on both. It is a per-clone local
  setting, so it stays easy to get wrong — check it rather than assuming, in either
  direction: believing the gate is off invites hand-running suites that already ran,
  and believing it is on invites shipping ungated.
- ⚠️ **`~/bin/vps-repo-refresh.sh` is a 49-line stub, not the tracked 604-line
  script** (`dotfiles-qcfx`, still open 2026-08-01). The hourly timer runs the
  stub, which writes no receipt; `vps-preflight` invokes the tracked path
  directly, which is why dispatch still works.
- ⚠️ **Password SSH is on and there is no firewall** — see the P0 in
  `refs/audit/H-marketing-vps.md`. Do not assume this box is hardened.

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
  `~/harnessd/refs/topology.md`. **LIVE and healthy** — harnessd generates state
  **in-proc in Go** (`HARNESSD_GEN_MODE=go`) and serves it same-origin on
  `100.98.174.21:14174/state.json` (verified 2026-08-01: HTTP 200,
  `generated_at` minutes old).
  ⚠️ **`state-bus.{timer,service}` are `masked` ON PURPOSE** — that is the migration
  off the Python generator, documented at `~/harnessd/CLAUDE.md:51`. Masked here does
  NOT mean broken; do not "fix" it by unmasking. The old
  `state-bus.timer` →
  `~/harnessd/bin/harness-refresh`; Go daemon binds the tailnet IP at Phase 1.
- `~/linearb`, `~/reef`, ss14 game server, `~/hermes` (VPS agent, archived).

## Secrets — `~/.secrets` (mode 600, `source` to load)
`HEVY_API_KEY` (Pro, verified) · `HEVYD_WEBHOOK_TOKEN` · `FLEET_API_TOKEN` ·
`AIRTABLE_PAT` · `GAMMA_API_KEY`/`GAMMA_DEFAULT_THEME_ID` · `FIGMA_PAT` · `HF_TOKEN`.
No Hevy *session* token stored (private-API/social automation is not used — ToS risk).
