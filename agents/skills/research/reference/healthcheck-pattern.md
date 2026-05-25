# Healthcheck pattern (Step 1 of /research)

A pre-flight probe script that catches stale / hung state in the
substrate BEFORE wasting research compute on garbage results.

## Why

Research on live systems is corrupted by stale state. Examples from
the local-coding-models arc:
- mlx_lm.server hung silently for 4+ hours → wasted Wave 7 #5 budget
  retrying DeepSeek loads against a wedged server
- A DeepSeek download was misplaced (snapshots/main/ instead of
  snapshots/<hash>/) → 8 GB wasted + retry cycle

Both would have been caught by a 10-second pre-flight probe. The cost
of one healthcheck is one wasted iteration.

## Template

For a research arc targeting infrastructure X (model server, daemon,
API, library), build a small `healthcheck.sh` that probes:

1. **Reachability** — can we connect to the substrate at all?
2. **Handshake** — does it respond to a trivial GET / metadata
   endpoint?
3. **Functional roundtrip** — can we do the actual workload? (e.g.,
   chat completion for a model server; query for a database; pull
   for a package registry)
4. **Resource pressure** — is the substrate close to OOM / disk full
   / over its budget?
5. **Process health** — is the daemon process alive AND making
   progress (not hung)?
6. **Dependency state** — are the things this substrate depends on
   also healthy? (e.g., Ollama for Hermes Agent's custom provider)

## Reference implementation

`~/dotfiles/local-models/healthcheck.sh` is the canonical example
for our local-models stack. Key patterns it uses:

- **Probe with hard timeout** (`curl --max-time 5`) so a hung
  endpoint doesn't hang the healthcheck itself
- **Color-coded output** (green/yellow/red) for quick scan
- **Exit codes 0/1/2** (healthy/warning/critical) for CI integration
- **Functional probe** (not just handshake) — confirms the stack
  actually serves, not just connects
- **Per-component cheatsheet** in GUARDRAILS for "if X fails, run Y"

## Running pattern

- At the start of every iter when relevant systems are in scope
- After any failed probe before retrying
- Before dispatching benchmarks or long-running experiments
- After a system restart (verify it came back clean)
- Include as a check in research dispatches that touch the substrate

## When the healthcheck flags a problem

| Severity | Action |
|---|---|
| Warning | Note it. Continue if non-blocking. Track if it persists. |
| Critical | **Fix before researching.** Garbage in / garbage out. |
| Unknown | Investigate manually. Don't proceed on hope. |

## When you don't have a healthcheck for the substrate

**Build one the first time you hit an avoidable bug from stale
state.** The cost of one script is one wasted iter; the cost of
ignoring it is N wasted iters.

The minimum viable healthcheck is ~30 lines of bash:
1. ping the host
2. curl the API
3. confirm a basic operation
4. check disk pressure
5. exit code

You can grow it as failure modes accumulate.

## Anti-pattern: "I'll just try the thing and see"

If the substrate is in a bad state, the thing you try will fail in a
way that looks like YOUR fault, not the substrate's. You'll spend
debug cycles on your code when the actual problem is the daemon.
Healthcheck first — it costs nothing and resolves these confusions
upfront.
