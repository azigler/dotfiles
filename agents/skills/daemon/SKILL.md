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

## The trigger must be FULL-STACK (spawn-if-absent), not best-effort

The daemon's two jobs are **capture** and **trigger**. Capture is easy to get
right (persist first, ack fast). The trigger is where daemons quietly rot, and
there is exactly one correct shape for it.

**The pitfall (a real hevyd incident, 2026-07-15).** hevyd's inject was written
"best-effort": it typed the coaching prompt into the agent's tmux window **only
if that session + window + a live `claude` pane already existed**, else it logged
`skip: window … absent` and exited 0 — on the theory that "the daemon stays light,
and the durable queue is the source of truth." A workout hydrated perfectly, the
DB row enqueued, and **no proactive coaching ever fired**, because the window
happened to be closed (the *normal* state — the human closes sessions and expects
to pick back up later). The event sat in the queue for hours. The `/pulse` fleet,
running the same minute, cold-booted a fresh session and landed its tick — because
pulse-inject.sh **spawns the whole stack.** The daemon didn't.

**The lesson: a durable queue is necessary but NOT sufficient.** It guarantees you
don't lose the *data*; it does nothing to guarantee the agent ever *acts*. A
proactive daemon whose trigger only fires when a session is already open isn't
proactive — it's a manual tool with extra steps. The trigger must be able to
**materialize the agent**, idempotently, from nothing.

**The ideal form** (the `/pulse` scheduler primitive, `dotfiles/agents/scheduler/
pulse-inject.sh`): no tmux server / no session → `new-session -d`; no window →
`new-window`; the pane isn't running claude → launch it **and wait for the
composer to be input-ready** (typing into a still-booting TUI drops the keystrokes
silently); only then inject; and **defer** (don't inject) when the window is
blocked on a human modal (🔔 AskUserQuestion / permission), so the trigger can't
mis-answer an open question. It's idempotent and graceful — it works whether the
session is warm, cold, or the tmux server is dead.

**The recommendation for any daemon of this shape:**
- **Delegate to the shared `pulse-inject.sh`; do not hand-roll the tmux dance.**
  One injector, one place to fix bugs (its input-ready-race fix, the 🔔 guard,
  lexicon-aware window matching all come for free). Every `/pulse` unit already
  references it directly; a co-located daemon can too.
- **Detach the spawn so the daemon stays light.** A cold boot (launch + input-ready
  poll) takes 30–60 s — far past any sane *inline* inject timeout (hevyd bounds its
  injector at 10 s, and the scheduler calls it inline). So the daemon's inject
  script should `setsid` the `pulse-inject.sh` call into the background and return
  in <1 s. The daemon *triggers* the spawn; it never *waits* for it. Correctness
  still rides on the durable queue, so a detached best-effort spawn is safe.
- **Keep the queue as the backstop, not the mechanism.** The row is what heals a
  missed/failed spawn (a later event or a periodic drain re-fires). It is not a
  substitute for a trigger that actually materializes the agent.

Worked example: hevyd's `ops/hevyd-inject.sh` is a ~40-line wrapper that forwards
`--session/--window/--cmd` (+ the required `--dir`) to `pulse-inject.sh`, detached.
No daemon rebuild needed — the script is exec'd fresh per inject. Anti-pattern to
copy from nowhere: the original "stripped-down sibling … do NOT launch a session"
comment that *rationalized* the gap. Staying light is not worth a trigger that
silently never fires.

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

## Optional arc — a PWA cockpit with cross-platform push + badges

A daemon that already serves HTTP can grow an **installable web-app cockpit** with
real push notifications + app-icon badges on **every** platform (iPhone Home Screen,
macOS Safari, desktop Chrome — tab AND installed PWA), **auto-updating on use** — so
the thin service can *reach* the human, not just wait to be visited. No app-store, no
native build. Full playbook + the hard-won gotchas (TLS/secure-context, VAPID + the
`mailto:` trap, the service worker, the badge rules, the opt-in/test UX, deploy
discipline, the delivery-vs-display debug split) **plus the act-now half — a
watcher that decides WHEN to push** (diff the attention set on each state swap;
in-memory dedup with prime-silent-on-first, clear-on-resolution, retry-on-failure;
full-detail because a push to the user's own devices is E2E-encrypted) in
[`reference/pwa-cockpit-push.md`](reference/pwa-cockpit-push.md). **The load-bearing
lesson: use a CLASSIC Web Push payload, not Declarative Web Push** — the declarative
`app_badge` is a silent no-op on iOS 18.7 (even with `mutable:true`); a classic push
fires the SW so `setAppBadge()` runs. Worked example: **harnessd**.

## Process notes (hard-won)

- Present the **complete proposed stack for review as its own checkpoint**
  *before* offering build-vs-wrap. Design review precedes build.
- A 5-line **FACTS header** from the user (host/IP/DNS, secret keys, related
  existing projects, the one MVP outcome) up front saves a session of discovery;
  the vision dump belongs *after* it, and is still the most valuable part.

Reference instance: **hevyd** (`github.com/azigler/hevyd`) — read its `CLAUDE.md`
and `refs/` as the worked example.
