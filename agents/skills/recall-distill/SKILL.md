---
description: A propose-only "sleep-time" pulse tick that mines recent sessions (via /recall) for durable harness learnings and drafts HUMAN-GATED proposal beads (MEMORY.md entries / skill hardening). It NEVER writes MEMORY.md and NEVER auto-promotes — its only output is proposal beads a human reviews. The slow write-path of the claude-vault arc; the read primitive (/recall) it builds on already ships.
when_to_use: A scheduled "/recall-distill tick" fires (a pulse row) and you distill the window of sessions since the last run into candidate learnings, then file proposal beads for the ones worth a MEMORY entry. NOT for interactive/inline use — this is a slow, scheduled, propose-only loop. Also invoked for "/recall-distill status" (ledger + open proposals).
---

# /recall-distill — the propose-only learning loop

`/recall-distill` is the harness's standing **sleep-time distiller** (spec
`explore-76oc` §4.4, the Phase-4 close of the claude-vault arc). Once per
scheduled tick it mines the sessions that ran **since its last run** for durable
harness learnings — reusable preferences, corrections, gotchas, confirmed
approaches — and drafts **human-gated proposal beads**. A human (Zig / the
orchestrator) reviews each proposal and promotes-or-rejects it.

It is the slow write-path the memory cluster named as a real gap. The read
primitive it stands on — `/recall` — already ships (§4.2); this loop is its first
non-trivial caller.

## THE TRUST-LADDER INVARIANT (read this first)

> **This loop NEVER writes `MEMORY.md` and NEVER auto-promotes.** Its only
> output is **proposal beads a human reviews.** No exceptions.

This is not a nicety — it is the whole reason the loop is safe to run unattended.
The always-loaded memory tier is the harness's most trusted context; an
auto-writer would let an autonomous loop silently poison the tier every session
(the failure the `project_golem_phantom_backlog` memory records — a jailed
distiller re-proposing already-shipped work with no human in the loop). Keeping
the write **proposal-only + human-gated** preserves the trust ladder: the loop
*proposes*, a human *decides*, and the memory tier only ever changes by a
reviewed human action. If you ever feel tempted to "just add the obvious one to
MEMORY.md" — that is exactly the temptation the invariant exists to stop.

## Scope: the CURRENT slug only (confidential-safe MVP)

The tick distills **only the slug it runs in** (`distill.py` defaults to the
current-cwd slug). It does **not** sweep other slugs.

This is deliberate and load-bearing: a proposal bead lands in a git-pushed
`.beads/` (off-box), and the `feedback_linearb_beads_confidential` memory forbids
sweeping `linearb*` / `cfp*` content into off-box / pushed artifacts. (The
2026-07-08 tailnet-dashboard exception is a *tailnet-bound-and-authed* exception,
**not** a github-push exception — a pushed bead is off-box.) So a proposal bead
mined from a confidential slug and pushed to GitHub would violate that rule.
Restricting to the current slug means a tick running in `~/explore` only ever
proposes from explore sessions; run the loop inside each project you want
distilled.

**Future `--all` / cross-slug mode is explicitly OUT of scope here.** If it is
ever built it must be gated on confidential-exclusion (skip `linearb*`/`cfp*`, or
route their proposals to a local-only tracker) BEFORE it sweeps. Do not build it
as part of this loop.

## Sleep-time, not hot-path

This is a **pulse tick** — scheduled, low-frequency, one-unit-of-work, offboard,
done. It is NOT something an interactive session runs inline, and there is **no
standing daemon**. It borrows the `/pulse` discipline wholesale: a ledger, a
per-run offboard, and it **NEVER opens an AskUserQuestion** — an unstaffed tick
that needs a human files a `human:` bead + push and ends (see `/pulse`
"Blocked-on-Andrew protocol"). The proposal beads are themselves the human
touchpoint; they wait in the tracker, they don't block a window.

## The tick procedure

### a. Window selection

Distill only the sessions **newer than the last distill run**, tracked via the
ledger (below):

```bash
LEDGER="$PULSE_DIR/refs/recall-distill-ledger.jsonl"   # anchor to the ABSOLUTE $PULSE_DIR (never a bare relative path)
SINCE=$(test -s "$LEDGER" && jq -r '.ts' "$LEDGER" | tail -1 || true)
```

- **Subsequent runs:** `--since <the last run's ts>` — only sessions active since
  then are scanned (`distill.py`'s session-level window; a session is in-window if
  any of its files was modified after `since`).
- **First run** (no ledger): omit `--since` and let `distill.py` apply its bounded
  **7-day lookback** (`--lookback-days`), so the first tick does not distill all
  history at once.

### b. Candidate gathering (the deterministic helper)

Run `distill.py` — the stdlib-only helper — to surface candidate durable-learning
turns via `/recall` over the window:

```bash
python3 "$SKILL_DIR/distill.py" --since "$SINCE" --slug="$SLUG" \
  > "$SCRATCH/candidates.json"
# first run: drop --since (7-day lookback kicks in)
```

`distill.py` (i) lists in-window sessions, (ii) runs `recall.py` once per curated
**learning-signal pattern** (correction / preference / gotcha / confirmed / rule —
see `distill.py`'s `SIGNALS`, each with a documented rationale), and (iii)
dedupes + emits candidate turns as JSON:

```json
{"since":"…","slug":"…","scanned_sessions":12,"window_sessions":3,
 "n_candidates":4,"truncated":false,
 "candidates":[{"slug","session","ts","role","line","text","signals":["correction","preference"]}]}
```

The helper is **recall-biased on purpose** (surface generously; a missed learning
is worse than a noisy candidate) because the next step is a conservative human-
gated filter. It makes no judgment and files nothing.

### c. Judgment (the LLM tick — be conservative)

For each candidate, decide: **is this a DURABLE learning or a one-off?** Keep only
high-signal, generalizable learnings; the bar is HIGH (a low-signal proposal costs
Zig review attention and erodes trust in the loop). A keeper is one of:

- a **reusable preference** ("Zig prefers X", "always do Y") that will recur;
- a **correction** that should never happen again (→ a `feedback_*` MEMORY entry);
- a **hard-won gotcha / footgun** worth preserving so it isn't rediscovered;
- a **confirmed approach / root-cause** that generalizes beyond this one task;
- a **skill-hardening**: the learning is really "skill Z's SKILL.md should say W".

Reject (do NOT propose): task-specific facts, one-off debugging, anything already
in MEMORY.md, restatements of the global tier (call-him-Zig, always-push, etc.),
and anything you can't tie to a concrete recalled quote. **Especially reject
skill-injection boilerplate** — turns that are really the harness echoing a
SKILL body into the transcript (text opening with `<command-message>` /
`<command-name>` / `<skill-format>`, or a bare `[tool_result] …` block). On the
live corpus these are the dominant false positives: skill docs are full of
"always / never / confirmed / verified", so the signal patterns light up on them,
but they encode no new learning. When in doubt, **drop it** — under-proposing is
cheap, over-proposing is the failure mode.

### d. Propose (human-gated) — file a proposal bead, NEVER write MEMORY.md

For each keeper, file **one proposal bead** (the orchestrator owns bead
lifecycle). Two shapes:

**MEMORY-entry proposal** — `-t note`, titled `propose-memory: <short>`:

```bash
br create -t note -p 3 "propose-memory: <short handle>"
br update <id> --description "$(cat <<'EOF'
## Proposed MEMORY entry
- [<Title>](<suggested_filename>.md) — <one-line summary in the MEMORY.md house style>

(optional) full body for the linked note file, if the learning warrants its own file.

## Evidence
- recall: <slug> / session <uuid> / <ts>
- quote: "<short verbatim quote from the recalled turn — the durable-learning moment>"
- signals: <correction|preference|gotcha|confirmed|rule …>

## Why durable
<one line: why this generalizes across sessions rather than being a one-off>

## Review
Zig / orchestrator: PROMOTE (add to MEMORY.md by hand) or REJECT (close). NEVER auto-applied.
EOF
)"
```

**Skill-hardening proposal** — `-t note`, titled `propose-harden: <skill>`: same
body, but "Proposed MEMORY entry" becomes "Proposed skill change" naming the
`SKILL.md` and the concrete edit.

Label every proposal so they're a scannable review surface:
`br update <id> --add-label recall-distill-proposal`.

**Never** edit `MEMORY.md`, never open an AskUserQuestion, never mark a proposal
as accepted yourself. The bead IS the proposal; the human's promote/reject IS the
gate.

### e. Ledger + dedupe (the phantom-backlog guard)

Append **one line per run** to `refs/recall-distill-ledger.jsonl`:

```json
{"ts":"2026-07-08T09:00:00Z","since":"2026-07-01T00:00:00Z","slug":"-home-ubuntu-explore","scanned_sessions":12,"window_sessions":3,"candidates":4,"proposals":2,"proposal_beads":["explore-ab1","explore-ab2"],"note":"2 memory proposals filed"}
```

`ts` (UTC, `date -u +%FT%TZ`) is what the **next** run reads as its `--since` —
that is the primary re-proposal guard: sessions older than the last run are never
re-scanned.

**Dedupe against already-proposed / shipped learnings** before filing (the
`project_golem_phantom_backlog` guard — a distiller that can't see prior state
re-proposes forever). Two layers, both mandatory:

1. **Window (mechanical):** `--since` = last run's `ts` means already-distilled
   sessions don't come back. On its own this is not enough — a long-running
   session can span windows.
2. **Semantic (in the tick):** before filing a keeper, check it isn't already
   covered:
   ```bash
   grep -Fq "<key phrase>" ~/.claude/projects/$SLUG/memory/MEMORY.md   # already in memory?
   br list --type note | grep -i 'propose-'                            # already an open proposal?
   ```
   If it's already in `MEMORY.md` or an open `propose-*` bead already covers it,
   **do not re-file.** (Optionally note the residual on the existing bead instead —
   the same "describe the RESIDUAL, don't re-file as unshipped" discipline the
   phantom-backlog fix installed.)

## `/recall-distill status`

Read-only: last 5 ledger lines, count of open `recall-distill-proposal` beads, and
the `since` the next tick would use. No writes.

## Scheduling (a documented follow-up — NOT wired here)

This skill does **not** install a systemd timer or edit `refs/pulse.md`; Zig opts
the loop into the pulse cadence when he's ready. To wire it later, add a `/pulse`
row (see `/pulse` "The contract"), e.g.:

```markdown
| 5 | recall-distill | time: daily | `[ "$(date +%u)" -le 7 ]` | /recall-distill tick | 1/day |
```

A **daily** cadence fits the sleep-time framing (it pairs naturally with the
transcripts vault's daily push, §4.3 OQ-C4). Keep the cap at 1/day: this is a
slow distiller, not a firehose. Because it emits human-review work, honor the
`/pulse` structural-review nudge (every 5th `done` tick, surface the last few
proposals for Zig to sample) — that keeps the human capable of saying "no" before
comprehension rot (the cognitive-surrender guard).

## Anti-patterns

- ❌ **Writing MEMORY.md from the tick.** The invariant. Propose only.
- ❌ **Auto-promoting a proposal** (closing it as accepted + editing memory
  yourself). The human is the gate; the bead waits.
- ❌ **AskUserQuestion in a tick** — freezes the window. File the proposal bead
  (and, if genuinely blocked, a `human:` bead + push) and end.
- ❌ **Cross-slug / `--all` sweep** — pushes confidential (`linearb*`/`cfp*`)
  content off-box. Current slug only until a confidential-exclusion gate exists.
- ❌ **Over-proposing** — a flood of low-signal proposals is worse than none; it
  trains Zig to ignore the channel. Conservative bar; when in doubt, drop.
- ❌ **Re-proposing shipped learnings** — always dedupe against `MEMORY.md` + open
  `propose-*` beads first (phantom-backlog guard).
- ❌ **Bare relative ledger path** — anchor to the absolute `$PULSE_DIR` (a durable
  pulse session's cwd drifts; a relative path crosses into another project's
  ledger).
- ❌ **Running it inline in an interactive session** — it's a scheduled sleep-time
  tick, not a hot-path tool.

## See also

- `/recall` (`~/.claude/skills/recall/SKILL.md`) — the read primitive this loop
  calls; `distill.py` invokes `recall.py` via subprocess.
- `/pulse` — the tick discipline (ledger, offboard, never-AskUserQuestion) this
  loop follows.
- Spec + decisions: `br show explore-76oc` (§4.4; the propose-only trust-ladder
  rationale; §1 the claude-vault arc).
- `project_golem_phantom_backlog` (MEMORY) — why propose-only + dedupe-first.
- `feedback_linearb_beads_confidential` (MEMORY) — why current-slug-only.
