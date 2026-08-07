---
description: The harness's weekly SLEEP-TIME CONSOLIDATION loop — a propose-only pulse tick that mines recent sessions (via /recall) for durable harness learnings and drafts HUMAN-GATED proposal beads (MEMORY.md entries / skill hardening). It NEVER writes MEMORY.md and NEVER auto-promotes — its only output is proposal beads a human reviews. The slow write-path of the claude-vault arc; the read primitive (/recall) it builds on already ships.
when_to_use: A scheduled "/dream tick" fires (Sun 04:13 PT, pulse-dream.timer, the `dream` window) and you consolidate the window of sessions since the last run into candidate learnings, then file proposal beads for the ones worth a MEMORY entry. NOT for interactive/inline use — this is a slow, scheduled, propose-only loop. Also invoked for "/dream status" (ledger + open proposals).
---

# /dream — the propose-only learning loop

`/dream` is the harness's standing **sleep-time consolidation** loop (spec
`explore-76oc` §4.4, the Phase-4 close of the claude-vault arc). Once per
scheduled tick it mines the sessions that ran **since its last run** for durable
harness learnings — reusable preferences, corrections, gotchas, confirmed
approaches — and drafts **human-gated proposal beads**. A human (Zig / the
orchestrator) reviews each proposal and promotes-or-rejects it.

**The name is the mechanism.** It replays the week's experience while nothing
else is running, keeps the fragments worth keeping, and wakes with *suggestions*
— never with an edited memory. It was called `/recall-distill` until 2026-07-27
(`explore-w1mn`); Zig renamed it because "distill" describes a step and "dream"
describes the loop. Every artifact moved with the name: the unit
(`pulse-dream.{service,timer}`), the tmux window (`dream`), the ledger row
(`dream` in `refs/dream-ledger.jsonl`), and the handoff note
(`refs/session-handoff--dream.md`). If you find `recall-distill` in a live doc,
that reference is stale — **except** in dated history (digests, ledgers of other
loops, bead bodies, sweep records), which keeps the name it was written with. And
`mud-distill.{service,timer}` is an unrelated loop that was never part of this.

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

The tick distills **only the slug it runs in** (`dream.py` defaults to the
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

**Every seam inherits this, and it is enforced in code, not prose.** Each seam is
scoped to the current slug (`memory-history` is pathspec-scoped to
`<slug>/memory`) or the current repo, and every path a seam opens, globs, or hands
to git passes through `dream.py`'s `guard_path()` — which refuses any component
naming a `linearb*` / `cfp*` project. A confidential `--slug` is a hard exit 2.
Set `DREAM_PATH_AUDIT=<file>` to log every permitted traversal (and every
`REFUSED:` one); that audit is how the test suite proves the negative, with the
explore paths in the same file as the positive control.

⚠️ The seam sizes quoted when this was designed (560 handoff revisions across 7
repos, 329 twice-revised memory files) were measured **fleet-wide**. That was a
measurement, **not** a licence to traverse.

## Sleep-time, not hot-path

This is a **pulse tick** — scheduled, low-frequency, one-unit-of-work, offboard,
done. It is NOT something an interactive session runs inline, and there is **no
standing daemon**. It borrows the `/pulse` discipline wholesale: a ledger, a
per-run offboard, and it **NEVER opens an AskUserQuestion** — an unstaffed tick
that needs a human files a `human:` bead + push and ends (see `/pulse`
"Blocked-on-Zig protocol"). The proposal beads are themselves the human
touchpoint; they wait in the tracker, they don't block a window.

## The tick procedure

### a. Window selection

Consolidate only the sessions **newer than the last run**, tracked via the
ledger (below):

```bash
LEDGER="$PULSE_DIR/refs/dream-ledger.jsonl"   # anchor to the ABSOLUTE $PULSE_DIR (never a bare relative path)
SINCE=$(test -s "$LEDGER" && jq -r '.ts' "$LEDGER" | tail -1 || true)
```

- **Subsequent runs:** `--since <the last run's ts>` — only sessions active since
  then are scanned (`dream.py`'s session-level window; a session is in-window if
  any of its files was modified after `since`).
- **First run** (no ledger): omit `--since` and let `dream.py` apply its bounded
  **7-day lookback** (`--lookback-days`), so the first tick does not distill all
  history at once.

### b. Candidate gathering — `collect`, over five seams

Run `dream.py collect` — the stdlib-only helper — to surface candidate durable
learnings from every **seam** at once:

```bash
python3 "$SKILL_DIR/dream.py" collect --since "$SINCE" --slug="$SLUG" \
  --max-candidates 20000 \
  > "$SCRATCH/candidates.json"
# first run: drop --since (7-day lookback kicks in)
```

⚠️ **`--max-candidates 20000` is load-bearing — do not drop it.** The library default
is **200** (`dream.py`'s `DEFAULT_MAX_CANDIDATES`), a token-blowout guard sized for a
single slug's quiet week. A real window is far larger: the 2026-07-26 run judged
**5,761** candidates and the 2026-08-02 run **4,638**, both only because the override
was passed by hand. The two runs that used the default (2026-07-13, 2026-07-19) were
**capped at 200 — roughly 4% of their window — and the second produced zero proposals.**

The override survived only as prose in `refs/session-handoff--dream.md`, a file
`/offboard` **overwrites every session** ("it's a snapshot, not a log"). So the working
configuration was one rewrite away from being lost, while the skill kept prescribing the
crippled one. That is this lab's own two-copies defect, with the authoritative copy in
the more perishable place. It lives here now.

#### The seams

A **seam** is one place durable learnings leave a trace. Until `dotfiles-jx71`
there was exactly one, and it was already drained: `/offboard`, `/dive` and
decision beads harvest corrections *in-session*, so by the time the weekly tick
grepped the transcripts the good material had been taken (run 4's ledger note:
the sweep found **zero** uncaptured corrections). Precision was 100% — 5 proposals,
5 promoted — and **recall** was the problem. The four added seams are all
**churn histories**, where the signal *is* what changed.

| seam | source (current slug / current repo ONLY) | why it carries signal |
|---|---|---|
| `session-recall` | `recall.py` over this slug's transcripts | the original seam: turns matching a learning-signal regex |
| `offboard-history` | `git log -p -- refs/session-handoff*.md` in the current repo | `/offboard` **overwrites** its note, so the friction it recorded survives only in git |
| `memory-history` | `git log -p` over `<slug>/memory/*.md` in the claude-vault memory repo | what we believed, then **un**believed |
| `skill-history` | `git log -p -- agents/skills/*/SKILL.md` in `~/dotfiles` | which prompt wording keeps getting **re-fixed** — harness rot, directly |
| `findings-corrections` | `## Corrections` / `## Scrutiny` blocks in `*/FINDINGS.md` | the highest-density corrections surface in the compendium |

Toggle them with `--seams a,b,c` (default: all). Each is independent and each
**degrades to empty rather than erroring** when its source is absent.

Two things the git seams emit that a grep never could:

- **diff-line candidates** — an added/removed line matching a learning signal,
  carrying `occurrences` (how many revisions repeated it);
- **churn candidates** — *"this file was revised N times in the window"*,
  signal label `churn`. No single revision says "this keeps getting re-fixed";
  only the count does. That is recurrence detection, which is what consolidation
  *means* — and it is also what a rot detector is.

The git seams get their **own** window: `--history-days` (default 90) or an
explicit `--history-since`. `--since` stays the *session* window. A churn history
one week long says nothing about recurrence — but friction density in the handoff
notes was ~0% in May and ~45–55% by August, so the default deliberately favors
recent history over all of it.

#### `searched` is reported separately from `found` — always

```json
{"since":"…","history_since":"…","slug":"…","repo":"/home/ubuntu/explore",
 "scanned_sessions":144,"window_sessions":9,
 "seams":{"session-recall":{"searched":true,"found":40,"note":"144 sessions scanned, 9 in-window"},
          "skill-history":{"searched":false,"found":0,"note":"skills repo not found: …"}},
 "seams_requested":5,"seams_searched":4,
 "n_candidates":40,"truncated":false,
 "candidates":[{"seams":["offboard-history"],"signals":["gotcha"],"ts":"…","text":"…",
                "source":"…","n_sources":1,"detail":{"commit":"…","file":"…","kind":"diff-line"}}],
 "memory_digest":{"path":"…","exists":true,"n_entries":12,"n_qualified":3,"entries":[…]}}
```

**Exit contract: `0` = found · `1` = searched and found nothing · `3` = could not
search** (no seam was able to look) · `2` = error or confidentiality refusal.
This is the positive control, and it is the whole reason `searched` is a separate
field: a seam that looked and found nothing is a quiet week; a seam that *could
not look* is a broken instrument, and a shape that conflates them reports the
second as the first forever. **A `3` is an incident, not a quiet run.**

The helper is **recall-biased on purpose** (surface generously; a missed learning
is worse than a noisy candidate) because the next step is a conservative human-
gated filter. It makes no judgment and files nothing.

**Legacy invocation.** Bare `dream.py --since … --slug …` (no subcommand) still
runs session-recall only and emits the old flat JSON, unchanged, for any caller
that has not moved. New work uses `collect`.

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

### c2. Recurrence memory — the two-phase `collect` → `remember` flow

Before `dotfiles-jx71` this loop's **only durable state was `--since`.** It could
ask *"is this turn durable?"* and never *"has this come up three times?"* — and
recurrence is what consolidation MEANS.

`refs/dream-memory.jsonl` (sibling of the ledger; path via `--memory`, default
`<repo>/refs/dream-memory.jsonl`) is that state. One JSON object per learning:

```json
{"key":"flock-drops-on-fork","gist":"one line, the tick's own words","count":3,
 "first_seen":"2026-07-19T…","last_seen":"2026-08-07T…",
 "runs":["run-2026-07-19","run-2026-08-07"],"run_seams":{"run-2026-08-07":["skill-history","offboard-history"]},
 "seams":["session-recall","skill-history"],"disposition":"observed","beads":["explore-ab1"]}
```

`disposition` is one of `observed` | `proposed` | `promoted` | `rejected`.

**The flow is two-phase, and the model is the matcher in the middle:**

1. **`collect`** emits `memory_digest` — every existing key, its gist, count, seam
   list, disposition, and whether it currently clears the bar. Keys and gists
   ONLY, never bodies.
2. **You (the tick) judge**, and while judging you match each fresh observation
   against the digest **semantically** — "this is the same lesson as
   `flock-drops-on-fork`, worded differently." That is deliberately your job, not
   the helper's: lexical fingerprinting is brittle and is exactly the keyword-grep
   failure this bead was filed to fix. Do **not** add it to `dream.py`.
3. **`remember`** merges the run back:

```bash
cat > "$SCRATCH/observations.json" <<'EOF'
{"run_id":"run-2026-08-09","observations":[
  {"key":"flock-drops-on-fork","gist":"flock silently releases across fork",
   "seams":["skill-history","offboard-history"],"disposition":"observed"},
  {"key":"pulse-row-never-null","gist":"…","seams":["session-recall"],
   "disposition":"proposed","bead":"explore-ab1"}
]}
EOF
python3 "$SKILL_DIR/dream.py" remember --observations "$SCRATCH/observations.json"
```

It prints what it created/updated and, crucially, **which keys now clear the bar**.
`--dry-run` computes the merge without writing. Record the human's verdict on a
later run by re-observing the key with `"disposition":"promoted"` or `"rejected"`.

#### The recurrence bar

A learning qualifies as a **proposal** when EITHER:

- it has been seen in **≥ 2 distinct runs** (recurrence over time), **or**
- it was seen in **≥ 2 distinct seams within one run** (independent corroboration —
  the same lesson in a skill diff *and* a FINDINGS correction).

Two standing suppressions, both phantom-backlog guards:

- **`rejected` stays suppressed until its count DOUBLES.** A human said no once;
  re-asking on the very next sighting is how a propose-only loop trains its
  reviewer to ignore the channel. Doubling is the evidence bar for re-asking.
- **`promoted` stays suppressed outright.** Re-proposing shipped work is
  `project_golem_phantom_backlog` exactly.

The bar is a **filter on what you propose, not on what you record**. Record every
observation; propose only what clears the bar. A first sighting that is
overwhelming on its own merits may still be proposed — say so in the bead and note
that it was below the bar.

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
`br update <id> --add-label dream-proposal`.

⚠️ **The label has two spellings in the wild.** Proposals filed before the
2026-07-27 rename carry `recall-distill-proposal`, and they were deliberately
NOT relabelled — bead bodies are the historical record. New proposals take
`dream-proposal`. So anywhere you *read* the label — the dedupe check below,
`/dream status`, any review sweep — **query both**, e.g.
`br list --label dream-proposal; br list --label recall-distill-proposal`.
Querying only the new one silently under-reports open proposals, which is
exactly the dedupe failure the phantom-backlog guard exists to prevent. Drop the
old spelling only once no open bead carries it.

**Never** edit `MEMORY.md`, never open an AskUserQuestion, never mark a proposal
as accepted yourself. The bead IS the proposal; the human's promote/reject IS the
gate.

### e. Ledger + dedupe (the phantom-backlog guard)

Append **one line per run** to `refs/dream-ledger.jsonl`:

```json
{"ts":"2026-07-08T09:00:00Z","row":"dream","since":"2026-07-01T00:00:00Z","slug":"-home-ubuntu-explore","scanned_sessions":12,"window_sessions":3,"seams_searched":5,"seams_requested":5,"candidates":4,"observations":3,"proposals":2,"proposal_beads":["explore-ab1","explore-ab2"],"note":"2 memory proposals filed"}
```

**Carry `seams_searched` / `seams_requested` from the `collect` output.** A run
where they differ searched fewer places than it thinks it did — and that is
invisible in `candidates` alone, which is the failure the positive control exists
to surface. `observations` is how many keys the run handed `remember`.

**`row` is MANDATORY and never null.** The canonical row for this loop is
**`dream`** (declared in the pulse project's routing doc — for
`~/explore`, `refs/pulse.md` → "Non-pulse ledger rows"). Every ledger line
names the row it EVALUATED, including a run that proposed nothing: it still
ran and still spent budget. The only permitted escape hatch is the literal
`"unattributed"` — never `null`, never a missing key, never a guessed name. A
null row is invisible to every per-row counter and dashboard, so the run is
unattributable; this ledger's first two lines were written that way and had to
be back-filled (`dotfiles-ldag`; the pulse-ledger twin is `explore-qdo5`).

`ts` (UTC, `date -u +%FT%TZ`) is what the **next** run reads as its `--since` —
that is the primary re-proposal guard: sessions older than the last run are never
re-scanned.

**A `done` row MUST carry a `proof` token, and `pre-commit-checks.sh` re-runs it.**
This ledger was outside the gate until 2026-08-01 (the selector was
`*pulse-ledger.jsonl`; it is now `*-ledger.jsonl`) and had 3 `done` rows and 0
proofs — `explore-z1k6`. A tick is the generator AND writes its own outcome, so an
unproven `done` is a self-report. `artifact` and `commit` are REJECTED fleet-wide as
zero-distance (`explore-len0`). Use `kind:cmd`, and pick by what the run produced:

Proposals filed → the beads themselves are the deliverable; check they exist **and
are proposals**, not any bead id that happens to resolve:

```jsonc
{"proof":{"kind":"cmd","cmd":"for b in explore-ab1 explore-ab2; do br show $b | grep -qi 'propose' || exit 1; done"}}
```

Nothing worth proposing (the common, correct outcome) → the deliverable is the judged
run itself; grep this run's own date out of the handoff note it wrote:

```jsonc
{"proof":{"kind":"cmd","cmd":"grep -q '2026-08-02' refs/session-handoff--dream.md"}}
```

A run that cannot produce either did not reach its wrap step — log `blocked` or
`quiet`, which are exempt because they claim no work. Never invent a proof to
clear the gate; that is the failure the gate exists to catch.

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

## `/dream status`

Read-only: last 5 ledger lines, count of open proposal beads (**both** the
`dream-proposal` and legacy `recall-distill-proposal` labels — see the warning
above), and the `since` the next tick would use. No writes.

Add the recurrence state — it is the part a human cannot get from `br list`:

```bash
python3 "$SKILL_DIR/dream.py" collect --seams=findings-corrections --max-candidates=0 \
  | jq '.memory_digest | {n_entries, n_qualified,
        qualified: [.entries[] | select(.qualified) | {key, count, disposition}]}'
```

(`--seams` is narrowed only to keep `status` fast; the digest is read from
`--memory` regardless of which seams ran.)

## Scheduling — WIRED, weekly, Sun 04:13 PT

`pulse-dream.timer` is **enabled** and fires `OnCalendar=Sun *-*-* 04:13:00
America/Los_Angeles` with `Persistent=true`. `pulse-dream.service` injects
`/dream tick` into the durable **`dream`** tmux window (cwd `~/explore`),
unjailed — this loop reads transcript history, not the web, so it sits outside
the untrusted-input threat the `bwrap` jail addresses. Which tmux **session**
that window lives in is whatever `pulse-dream.service`'s `--session` flag names
(`zig-computer` since 2026-07-31, `work` before it) — **read the unit, not this
line.** This sentence said `work:dream` for two days after the units moved
(`explore-6abm`), which is why it now points at the flag instead of restating it.

It has fired 2026-07-13, 07-19 and 07-26 (all under the old name). Templates live
at `~/dotfiles/agents/scheduler/templates/pulse-dream.{service,timer}`; the loop
is registered in `~/harnessd/refs/harness-manifest.json` (weekly, 180-minute
grace) and declared in `~/explore/refs/pulse.md`.

**Weekly, not daily.** The original sketch here proposed daily; Zig chose weekly
and it has stayed weekly. A distiller that mines "sessions since its last run"
wants a window with something in it, and the output is *human-review work* — a
daily cadence spends Zig's attention faster than it earns it. Because it emits
review work, honor the `/pulse` structural-review nudge (surface the last few
proposals for Zig to sample periodically) — that keeps the human capable of
saying "no" before comprehension rot (the cognitive-surrender guard).

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
  `propose-*` beads first (phantom-backlog guard), and honor the `promoted` /
  `rejected` suppressions in `refs/dream-memory.jsonl`.
- ❌ **Reading a seam's `found: 0` as a quiet week without checking `searched`** —
  that is the exact conflation the exit contract exists to break. `searched:false`
  is a broken instrument; fix it, don't log `done`.
- ❌ **Running `collect` without `remember`** — a run that judges and never records
  its observations leaves the loop stateless again, and the recurrence bar can
  never fire. Both phases or neither.
- ❌ **Adding lexical fingerprinting to `dream.py` to match observations to
  memory keys** — the model in the loop does that matching, semantically. A regex
  matcher here is the keyword-grep limiter, re-introduced one layer up.
- ❌ **Bare relative ledger path** — anchor to the absolute `$PULSE_DIR` (a durable
  pulse session's cwd drifts; a relative path crosses into another project's
  ledger).
- ❌ **Running it inline in an interactive session** — it's a scheduled sleep-time
  tick, not a hot-path tool.

## See also

- `/recall` (`~/.claude/skills/recall/SKILL.md`) — the read primitive this loop
  calls; `dream.py` invokes `recall.py` via subprocess.
- `/pulse` — the tick discipline (ledger, offboard, never-AskUserQuestion) this
  loop follows.
- Spec + decisions: `br show explore-76oc` (§4.4; the propose-only trust-ladder
  rationale; §1 the claude-vault arc).
- `project_golem_phantom_backlog` (MEMORY) — why propose-only + dedupe-first.
- `feedback_linearb_beads_confidential` (MEMORY) — why current-slug-only.
