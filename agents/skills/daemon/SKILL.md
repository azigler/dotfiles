---
name: daemon
description: Bootstrap a "daemon + agent" hybrid project — a thin, always-on, LLM-free ingress (webhook receiver / poller / sensor) paired with the Claude Code agentic harness that holds ALL the intelligence. Use when starting a new project of this shape — a small durable service whose only jobs are CAPTURE and TRIGGER, with the coaching/curating/acting logic living in interactive sessions + pulse loops, not in the service. Scaffolds the refs knowledge base, the four architecture-decision forks, the bead roadmap, and the go-live sequence. The reference instance is hevyd (Hevy fitness webhook → coaching agent). - User says "bootstrap a daemon", "new daemon-agent hybrid", "set up an always-on thing that feeds an agent", "build me an X-daemon", or hands over a vision for a small always-on service + an agent on top. Fire as the first-session scaffold for that shape.
---

# /daemon — bootstrap a daemon+agent hybrid

The repeatable shape behind **hevyd**: a **thin ingress + thick agent**. A dumb,
durable, always-on service whose only jobs are **capture** and **trigger**,
bolted to the Claude Code harness (sessions + `/pulse` + beads + skills) that
holds all the intelligence, memory, and judgment.

## The one rule: keep the LLM out of the hot path

The daemon **never calls a model.** It receives an event, acks in milliseconds,
persists to a local store, and (optionally) drops a trigger. ALL reasoning runs
**on-demand** (interactive coaching session) or **on a timer** (`/pulse` loop).
This is what makes the shape cheap, reliable, and infinitely iterable: you change
behavior by editing prompts/skills, not by redeploying the daemon. The daemon is
the part that must never break; the intelligence is the part that changes daily.
Decouple them.

The class generalizes far past fitness: any event/data source (email, RSS, home
sensors, a game server, a SaaS webhook, a price feed) → thin ingress → local
store → agent that curates/coaches/acts. hevyd is the first instance.

## When to use / not

- **Use** when the vision is "an always-on thing that captures X, and an agent I
  talk to / that runs on a schedule on top of it." First-session scaffold.
- **Not** for a pure app (no agent), a pure agent loop (no ingress), or anything
  where the service itself must be smart in real time (then the LLM IS the hot
  path — different shape).

## Step 0 — verify the premise live, then discover topology (do NOT skip)

The two cheapest, highest-leverage moves, learned from hevyd:

1. **Verify the premise with a real call before designing anything.** If there's
   an API key, hit it (`curl`, no secret echoed) and confirm the data exists and
   the account/tier is right. Grounds every later decision in reality and catches
   "this won't work" before you've built on it.
2. **Discover the machine topology** (or read `agents/infra.md` if it's current):
   which box am I, what's the public IP / DNS, tailnet peers, nginx vhosts, used
   ports, installed runtimes, and **who else already consumes this resource**
   (a sibling project sharing the API key changes rate-limit posture). The
   ingress location decision depends on all of this.

## The standard refs/ knowledge base

Build these (decision-independent → write them first; they make every future
session effective). Skeletons in `reference/templates/`:

- **`<service>-api.md`** — the upstream API: auth, endpoints, the event/webhook
  contract + exact payload shape, the data model, units, undocumented gotchas.
- **`topology.md`** — hosts, public IP/DNS, tailnet, nginx plan, ports, secrets
  location, the go-live sequence, what-to-decommission.
- **`data-posture.md`** — the store choice + schema sketch + persist-vs-re-pull.
- **`<old-thing>.md`** — if rebuilding: a salvage-vs-discard distillation of the
  prior implementation (treat it as *reference, not template*).

Plus `CLAUDE.md` (north star, architecture, the locked decisions, refs index),
`README.md`, `.gitignore` (secrets / `var/` / `*.db` / build artifacts), and
`br init --prefix <project>`.

## The four decision forks (present with recommendations, then lock to beads)

Make a strong recommendation on each, surface via **AskUserQuestion**, record the
answer on a typed `decision` bead, and reflect it in `CLAUDE.md`:

1. **Daemon language** — default **Go, pure-static** (`CGO_ENABLED=0`, stdlib
   `net/http`): one ~12MB binary, `systemctl enable`, zero runtime deps,
   daemon-true. Alternatives only for a real reason (Python if the daemon itself
   does heavy data work; TS to reuse an existing client).
2. **Run location** — default **co-located with the harness** (the box that runs
   Claude Code + `/pulse` + nginx), so the trigger reaches the agent locally. A
   "production runs elsewhere" norm often does NOT apply here, because the daemon
   *is* part of the harness. Name the deviation explicitly.
3. **Data layer** — see below.
4. **Risk appetite** — for anything touching an unsanctioned/ToS-gray surface
   (private APIs, social automation): default **human-in-the-loop** (agent drafts
   / surfaces, human acts). No automated writes to systems that can ban you.

## Data-layer default: SQLite core + DuckDB lens

Proven on hevyd, empirically verified:
- **Daemon writes SQLite (WAL)** via a pure-Go driver (`modernc.org/sqlite`, no
  CGO → keeps the binary static). WAL = daemon writes while the agent reads,
  concurrently, no locking dance. Store raw JSON (lossless) **+** flattened rows
  (fast queries).
- **DuckDB (CLI) is the analytics engine** the agent queries — `ATTACH
  'var/x.db' (TYPE sqlite, READ_ONLY)`. DuckDB v1.5.4+ **reads through the SQLite
  WAL correctly** (no staleness dance needed). Do NOT link DuckDB into the daemon
  (its Go driver needs CGO + ~50MB).
- **Match the tool to the WORKLOAD SHAPE, not the data SIZE.** "It's only a few
  hundred rows, SQLite is fine" is the trap — if the questions are analytical
  (trends, progression, time-series, nested JSON), DuckDB is the right engine
  even at tiny scale, and it's as zero-ops as SQLite.

## Vet durable builtins before hand-rolling (a standing gate)

Before writing app/SQL code for anything an engine already does, **research the
substrate's builtins.** The DuckDB toolkit (`refs/duckdb-toolkit.md` in hevyd)
exists for exactly this. Examples that bite: `arg_max(date, metric)` finds *when*
a max happened with no self-join; `regr_slope`/`regr_r2` fit trend lines
in-engine; `fts`/`vss` do text/vector search natively. The principle is general
across every substrate: *vet against pre-existing builtins, then build.*

## The bead roadmap (typical wave order)

`MVP ingress (capture→ack→hydrate→persist + tests)` → `nginx vhost + TLS` →
`human: configure the upstream to point at the endpoint` (blocked until live) →
`decommission the old thing` → `the agent layer (interactive playbook + /pulse
loop)` → robustness follow-ups (reconciliation loop, panic-recovery hardening).
Wire deps so blocked items don't show in `br ready`.

## Build pattern

Code → **worktree subagent** (`subagent_type: "subagent"`, `isolation:
"worktree"`) with a crisp contract loaded into the bead. Gate the merge with an
adversarial **/scrutinize** pass (the daemon's invariants — ack-before-work,
auth-can't-silently-open, idempotency — deserve real verification). Then merge,
close the bead with the verdict recorded, clean up the worktree.

## Go-live sequence (what gates the human step)

1. Daemon built + running (systemd user unit, `EnvironmentFile` for secrets,
   `Restart=always`). **Bind a high fixed port — the 10000–32767 band:** above the
   dev/service cluster (3000/5000/8000/8080/9000…), below the Linux ephemeral floor
   (32768; `/proc/sys/net/ipv4/ip_local_port_range`). It lives behind nginx, so the
   number is internal/arbitrary — pick high + uncommon so the daemon never collides
   with a dev loop or an outbound ephemeral allocation. **Never a dev-default like
   8080/3000** (that's what every ad-hoc loop grabs).
2. nginx vhost `<name>` → `127.0.0.1:<port>` + certbot TLS, reloaded & reachable.
3. **Only then** the human points the upstream at `https://<name>/<path>` (+ any
   auth header/secret). Don't repoint earlier — events would 404-and-retry.
4. Decommission the old deployment after cutover.

## Process notes (hard-won)

- Present the **complete proposed stack for review as its own checkpoint**
  *before* offering build-vs-wrap. Design review precedes build.
- A 5-line **FACTS header** from the user (host/IP/DNS, secret keys, related
  existing projects, the one MVP outcome) up front saves a session of discovery;
  the vision dump belongs *after* it, and is still the most valuable part.

Reference instance: **hevyd** (`github.com/azigler/hevyd`) — read its `CLAUDE.md`
and `refs/` as the worked example.
