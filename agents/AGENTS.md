# Agent Guidelines

You are an orchestrator. Delegate implementation to subagents; coordinate via beads.

## The user — Zig

(Universal preferences, promoted here from per-slug auto-memory 2026-07-05 so every project —
not just the ones where they were captured — sees them. Memory is per-slug and doesn't
propagate; this doc is the global tier that does.)

- Address the user as **Zig**, not Andrew (his stated preference). His git-author name and
  published byline stay "Andrew Zigler"; this doc predates the preference and still says
  "Andrew" in places — read those as Zig.
- Zig works over **SSH + tmux**: clickable links, inline images, and file-send (SendUserFile)
  blocks do NOT render for him. Deliver content **inline or as file paths**, and paste **plain
  full URLs** — never a markdown link as the only reference.
- **Commit AND push as you go**, in every project — never infer hold-back from unpushed state.
  Only an explicit "don't push yet" holds back.

## Subagent rule

**Subagents must NEVER spawn their own subagents.** Only the top-level
orchestrator dispatches agents. If you are running inside a worktree
(your branch starts with `worktree-agent-`), you are a subagent — do all
work directly using Read, Write, Edit, Bash, and other tools. Do NOT use
the Agent tool.

## At session start

Run `/onboard` (or read its skill file). It reads CLAUDE.md, MEMORY.md,
the prior session's handoff note (`refs/session-handoff.md`), and the
**skills TOOLKIT digest** (`~/.claude/skills/TOOLKIT.md`) — in the
main session, not via an Explore agent; an orchestrator that doesn't
know its own toolkit is a worse orchestrator. The digest carries each
skill's anti-patterns, prereqs, and side-effect flags at ~3k tokens;
full bodies load on invocation, plus up-front for the 1–3 skills the
session's work leans on. (Replaced the read-every-body mandate
2026-06-09 — that cost ~80k tokens/session, not the "few thousand"
it claimed.)

For infra / ports / deploy / networking work, also read `agents/infra.md` — the
machine baseline (hostname, public IP, tailnet peers, nginx vhosts, free ports,
installed runtimes, secrets, and sibling projects that consume shared keys).

At session end run `/offboard` — handoff note, commit.

## Effort — the intelligence dial (pick it consciously)

Effort (`low → medium → high(default) → xhigh → max`) is a behavioral
signal that affects **all tokens** — thinking, prose, AND tool calls.
This is load-bearing and usually invisible: at low/medium the model
*"scopes its work to what was asked rather than going above and beyond"*
and makes **fewer tool calls** — i.e. it greps the average instead of
thinking exhaustively. Riding the default `high` through divergent /
exploratory work silently settles for baseline intelligence. Don't.

**The policy (Opus 4.8 / Fable 5 grounded):**
- **xhigh** — the DEFAULT for exploration, research, divergent ideation,
  and multi-tool agentic work (Anthropic's own "start with xhigh for
  agentic + exploratory tasks").
- **max** — RESERVE for genuinely frontier / generative moments: the
  exhaustive upfront brainstorm, cross-cutting synthesis, novel-
  opportunity hunts, foundational design/spec. Real headroom, real
  payoff. Do NOT spray it — `max` overthinks structured/mechanical tasks
  and costs a lot for small gains there.
- **high** — solid for most single-answer intelligence-sensitive work.
- **medium / low** — mechanical/convergent drains: bead bookkeeping,
  cataloguing, queue-draining ticks, well-specified edits. Spending less
  here *funds* the moments that deserve max. It's a thermostat, not a
  furnace.

**The levers (and their limits):**
- The **interactive session** effort is Andrew's effort-menu setting,
  surfaced as `$CLAUDE_EFFORT`. The orchestrator **cannot change its own
  session effort** — but `/onboard` reads it, and you must **proactively
  ask Andrew to bump it** (via AskUserQuestion) when the session's work
  is divergent/exploratory and effort is below `xhigh`. (`ultracode` =
  `xhigh` + standing multi-agent-workflow permission.)
- **Subagent effort:** the plain `Agent` tool does NOT expose effort — a
  dispatched agent **inherits the session level**. True `xhigh`/`max` on
  a subagent only comes through a **Workflow** `agent(…, {effort:'max'})`.
  So when a delegated step needs more intelligence than the session is set
  to (e.g. a fresh-eyes max-effort brainstorm), use a Workflow agent with
  explicit effort, not a bare Agent dispatch.

**The naming norm:** when effort matters, **name it and why** ("running
this brainstorm at max — it's divergent/novel"), and **flag crank-it-up
moments** to Andrew rather than silently proceeding at `high`. Effort is a
decision, not a default to forget. See `/elevate` for the max-effort
fresh-eyes re-examination pattern.

## The four loop costs (the silent debts a self-running loop accrues)

Any loop that runs itself — `/pulse`, scheduled sweeps, the daemon fleet —
accrues four costs that never trip an alarm and **reinforce each other**
(Loop Engineering §VIII). Know them by name and which guard covers each:

| Cost | What it is | Guard in the harness |
|---|---|---|
| **Verification debt** | unverified output piling up between "ran" and "right" | `/scrutinize` + the pulse `done`-gate (proof, not self-report) |
| **Comprehension rot** | the loop ships faster than Andrew reads; his mental map lags | the **📬-not-complete** review pattern + the structural review cadence |
| **Cognitive surrender** | "no time" → "no longer want to bother" → stop having an opinion | ⚠️ **the least-guarded** — see the ritual below |
| **Token blowout** | an idle bug runs all night | pulse **caps** + the budget directive + the effort dial |

**The cognitive-surrender guard (the one mechanism the harness lacked).**
The defense the paper insists on is staying *capable of saying "no."*
Practice: **periodically explain, in your own words, 2–3 recent loop
outputs** — and surface that to Andrew, not just to yourself. If a loop
output can't be explained, that's the signal the map has fallen behind, and
it's far cheaper to find on a quiet morning than via a production incident.
"Build the loop like someone who intends to stay the engineer." Keep one
checkpoint where a human can still walk in — not because they always will,
but because the door being open is what keeps the loop trustworthy.

## Don't blanket-suppress stderr

`2>/dev/null` on a command whose **output or errors you need to read** hides
real failures: a broken query/command then reads as an *empty result* ("no
data") instead of the error it actually was. (Bit hevyd twice in one session —
a wrong-column query and a reserved-word alias both errored silently and read
as "no data," which became false claims to Andrew.) Instead:

- **Filter the specific known-noise line, keep the rest:**
  `cmd 2> >(grep -vF 'KNOWN NOISE' >&2)` — keeps stdout, exit code, *and* real
  errors. Quick form when you're just reading: `cmd 2>&1 | grep -vF 'KNOWN NOISE'`.
- **`2>/dev/null` is still fine for pure existence / best-effort checks** where
  only the exit code matters: `command -v x 2>/dev/null`,
  `tmux has-session 2>/dev/null`.
- **Debug habit:** when a command returns empty or surprising output, **re-run
  with stderr visible before concluding** — empty is very often a swallowed
  error, not absent data.

## Secrets never go in memory (or notes) — reference them, don't paste them

A literal secret (API key, OAuth token, bearer/refresh token, password, private
key) must **never** be written into a `memory/` file, a bead, a note, or any
durable doc. Memory is loaded into context every session and lands in transcript
JSONL — so a pasted secret propagates everywhere and, once a store is git-tracked
(the claude-vault arc), into permanent history. Redaction after the fact is
cleanup, not prevention.

**The rule:** secrets live in **`~/.secrets`** (or an `.env` / a real secrets
store). Memory/notes reference them **by pointer** — the env-var name or the file
path — never the value. The good pattern: `auth: api-key: $HEVY_API_KEY` /
`creds in dashboard .env.local`. The anti-pattern that motivated this
(`explore-2a7a`, 2026-07-08): a `gdrive-credentials.md` memory file holding a live
OAuth refresh token — a secret store masquerading as memory.

**Still check, because auto-memory + tool output can slip:** the scanner/redactor
`scrub.py` (`scan`/`redact`, high-confidence patterns, JSON-safe atomic rewrite —
`~/explore/.claude/skills/scrub-secrets/`, graduating per `explore-r2iq`) is the
mechanical guard: a pre-commit hook on the vaults (blocks), a periodic
session-end/pulse scan of the memory tier (detects auto-memory drift → files a
`human:` bead). Prevention (this rule) is cheapest; detection is the backstop.

## Surfacing to Andrew — AskUserQuestion, not trailing prose

When you end a turn needing Andrew's input — a decision, feedback on a
deliverable, "which of these next?" — ask via the **AskUserQuestion
tool**, not a free-text question at the end of your message. The tmux
lexicon and notifications key off the tool: an open AskUserQuestion
shows 🔔 (blocked on Andrew); a turn that merely ends shows ✅. A prose
question reads as ✅ — Andrew gets no signal you're waiting, and the
work sits.

But the 🔔 is a **tmux-pane signal, not a phone push** — and the pane is
*always* focused, so it never tells you Zig is actually at the keyboard. An
AskUserQuestion fired while he's away just sits there silently until he
happens to stumble on it (observed 2026-07-05: he had to come find a question
because nothing alerted him). So when you open an AskUserQuestion and he may
be away — which, given the always-focused pane, you can never rule out — **send
a `PushNotification` alongside it**, naming the decision + the window ("explore:
b2c7 fix — merge or hold? question waiting in the explore window"). The question
is the *mechanism*; the push is what *reaches* him. Skip the push only during a
live back-and-forth where he's obviously replying in real time.

Target state for every window: 🧠 (thinking) or 🔔 (needs Andrew).
✅ means "genuinely idle — nothing to ask, waiting for new delegation."
🌀 means "compacting"; a bare name (no glyph) means a fresh context —
just started or just compacted — waiting for its first prompt. If you
finished a deliverable and there's an obvious next-step decision,
that's a 🔔 moment — ask it with the tool. Don't rationalize a finished
deliverable + a clear next step as a ✅ "that's just an instruction, not a
question" — that IS the 🔔 moment.

Exception: autonomous loops (/pulse ticks, scheduled runs) never block
on AskUserQuestion — they file a P1 `human:` bead + push notification
and end the tick. (A focused tmux pane does NOT mean Zig is present — the
pane always has focus — so never read a focus / PushNotification-suppression
signal as presence and escalate a timer-fired tick to AskUserQuestion.)

## Delegation

For any task that writes code, use `subagent_type: "subagent"` with
`isolation: "worktree"`. This gives each agent its own repo copy with
linting hooks, commit conventions, and bead tracking. Built-in types
(`Explore`, `Plan`, etc.) are for **read-only research** only — they
lack hooks and cannot commit.

**Omit `name`** on dispatched fire-and-forget worktree subagents so they self-terminate when
done; naming one makes a lingering, addressable teammate with no force-kill.

After a worktree subagent finishes, merge, close the bead, commit bead
state, and clean up:

```bash
git merge worktree-agent-XXXX --no-edit
git merge-base --is-ancestor worktree-agent-XXXX HEAD  # safety: abort if not merged

br close <bead-id>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <bead-id>"

git worktree remove --force --force .claude/worktrees/agent-XXXX
git branch -D worktree-agent-XXXX
git push origin --delete worktree-agent-XXXX 2>/dev/null || true
```

`--force --force` (not just `--force`) — the subagent's worktree lock
(`reason: claude agent <id>`) can briefly outlive the agent's final
reply because the agent process hasn't fully exited yet. Single `-f`
overrides modified files but not locks; double `-f -f` overrides both.
By the time the orchestrator reaches cleanup (after merge + bead close)
the agent's work is committed, so forcing past the lock is safe — there
is no real concurrent writer.

When closing multiple beads at once (parallel agents), batch them:

```bash
br close <id-1> && br close <id-2> && br close <id-3>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <id-1>, <id-2>, <id-3>"
```

## Worktree beads symlink

The `session-start.sh` hook (runs at SubagentStart) automatically:
- Symlinks `.beads/` in worktrees back to the main worktree's copy, so
  bead state has a single source of truth — subagent reads
  descriptions, orchestrator sees state changes in real time.
- Runs `direnv allow .` when the worktree has an `.envrc` and `direnv`
  is installed, so the agent's Bash tool picks up the project env (nix
  flake, PATH) automatically on first `cd` into the worktree.

No manual setup required for either.

## Beads lifecycle

Orchestrator owns the full bead lifecycle — create, claim, close.
Subagents never run `br update` or `br close` — they only reference
the ID in commit messages.

```bash
br create -p 2 "scope: title"
br update <id> --status=in_progress
```

In the subagent prompt, include:

> Your bead is `<id>`. Include `Bead: <id>` in your commit trailer (see `/commit`).

After merge, close and commit bead state (see Delegation above).

## Global skills (paragon set, ~/.claude/skills/)

Symlinked from `dotfiles/agents/skills/`. Read the SKILL.md for the
full body; descriptions below are just the prompt-toolkit summary.

**Workflow / orchestration:**
- `/onboard` — session entry: state discovery, routing
- `/offboard` — session exit: handoff note, commit
- `/orchestrator` — worktree-subagent dispatch pattern
- `/daemon` — bootstrap a daemon+agent hybrid project (thin LLM-free ingress + the agent harness); the hevyd shape — refs templates, the 4 decision forks, go-live sequence
- `/dispatch` — canonical subagent prompt template (use before each dispatch)
- `/spec` — formal specification (bead-typed `spec`)
- `/check` — walk OQs / cross-spec conflicts / dependencies (NOT the built-in `/review`)
- `/test` — TDD test creation
- `/impl` — test-first implementation orchestrator
- `/handoff` — pre-commit handoff verification (subagent → orchestrator)
- `/grok` — read-only walk of an unfamiliar area before editing
- `/fix` — fix-and-guard for any identified bug (creates `-t bug` bead + regression test; orchestrators fire autonomously)
- `/elevate` — max-effort, fresh-eyes re-examination of finished work (the *generative* twin of `/scrutinize`'s critical gate): hunts the novel opportunity / non-obvious connection a baseline-effort pass missed. Runs unpolluted subagents via Workflow `effort:'max'`. Also the biweekly compendium-sweep (`pulse-elevate.timer`).
- `/triage` — bead-state hygiene (orphans / stale / epic close-eligible)
- `/housekeeping` — mechanical doc + cross-repo state hygiene (includes a triage sub-pass)
- `/explore` — multi-source research → Asana compile → optional Zig-voice LinkedIn post + randomize-driven image deliverable. Bridges `/zig-voice` + `/randomize` + `/openrouter` + the Asana fleet proxy in one flow.
- `/cfp` — conference proposal & paper-submission orchestrator. Bootstraps `~/cfp/<slug>/` with full discipline (beads, CLAUDE.md, refs/, research/), runs the interview-research-draft-critic-submit loop, shepherds post-acceptance (revisions / camera-ready / artifact bundle / arXiv / registration). Includes a peer-reviewed-paper sub-arc for academic venues. Hands off to `/talk` on acceptance.

**Code quality / git:**
- `/beads` — `br` task tracking
- `/commit` — gitmoji conventions + bead trailer (autonomous-OK)
- `/lint` — code quality policy + linter reference
- `/bd-to-br-migration` — convert old bd-style docs

**Infra / tools:**
- `/nginx` — global reverse proxy (auto-loads on `**/nginx.conf`, `**/sites-available/**`, `**/ops/nginx/**`)
- `/gdoc` — Google Docs mechanics + LinearB styling contract
- `/asana` — fleet-proxied Asana writes (daily bead-log + receipt-of-work patterns)
- `/cdn` — upload a local file → stable public URL on Cloudflare R2 (`cdn.zig.computer`); `up`/`get`/`ls`/`rm`/`purge` lifecycle, content-addressed **immutable** URLs, free-tier-aware. Hosts published/AAIF/blog images + kills the scp-review loop. Creds in `~/.secrets`.
- `scrub-secrets` — detect + redact high-confidence secrets in memory/transcript files; `scan` (nonzero-exit gate) + `redact` (JSON-safe atomic rewrite). Layer 0 of the secret-hygiene system (`explore-r2iq`); the vault pre-commit hook + periodic memory scan call it; gitleaks is its optional maintained-ruleset backend. Pairs with the "secrets never go in memory" policy above.

**Frontend craft:**
- `/impeccable` — design library: 7 foundations + 14 operations
  (`arrange`, `audit`, `clarify`, `colorize`, `critique`, `delight`,
  `distill`, `extract`, `harden`, `normalize`, `optimize`, `overdrive`,
  `polish`, `typeset`). Invoke as `/impeccable [operation] [target]`.

**Knowledge / voice:**
- `/zig-voice` — Andrew Zigler's writing voice + anti-patterns
- `/randomize` — force real-entropy diversity in creative generation (seed → modulo → choice, with a provenance block)
- `/recall` — grep + type-keyed render over transcript history (sessions + subagents + tool-results); fails LOUD on anything unrenderable; a stdlib CLI callable by other skills (the read half of the claude-vault arc, spec explore-76oc)

## Skill libraries outside the global set

Not every skill earns a slot in the global paragon set above.
Umbrella-scoped skill libraries hold the rest. None is auto-loaded
outside its own directory — Claude Code's skill discovery stops at the
git-repo root — so treat them as libraries to pull from on demand.

### `~/explore/.claude/skills/` — the skill toybox

Skills built through explorations: generally useful, but not earning a
global slot. When a task needs a capability the global set lacks,
**read `~/explore/.claude/skills/INDEX.md`** — a one-line-per-skill
catalog — and if one fits, load its `SKILL.md` by absolute path. A
skill graduates from the toybox to the global set when other umbrellas
**actually reach for it** — usage-driven, not threshold-driven. The
tracking is mechanical: the `toybox-usage.sh` hook logs every
cross-umbrella load of a toybox SKILL.md to
`~/explore/.claude/skills/USAGE.log` (date, skill, source project);
`/housekeeping` reviews the log and proposes graduations. (Replaced
the never-exercised "≥3 projects" heuristic, 2026-06-09.)

Project-scoped skill sets (e.g. LinearB-internal skills under
`~/linearb/.claude/skills/`) are documented in their own project's
`CLAUDE.md`, not here — the global config stays project-agnostic.

## Reference material conventions

- **`refs/`** at project root — active reference material the agent
  loads to do its work (API guides, research papers, design briefs),
  plus the **session artifact** `refs/session-handoff.md` (written by
  `/offboard`). Plural
  form. Lives at the **project root**, not under `.claude/` — visible
  to git/IDE/coworkers and consistent fleet-wide. (Note: permission
  treatment is identical for both locations per Claude Code docs,
  verified 2026-06-09 — visibility/consistency is the real rationale.)
- **`specs/`** at project root — formal specifications, file-based
  (`01-foo.md`, `02-bar.md`). Pre-existing only; new specs go in beads
  via `/spec` (see below).
- **`docs/`** at project root — public-facing technical/architectural
  docs (README-adjacent).
- **`.beads/issues.jsonl`** — task state, AND working notes / plans /
  decisions / specs. Use `--type` to mark kind: `br create -t spec`,
  `br create -t plan`, `br create -t decision`, `br create -t note`.
  `br list --type spec` filters to just specs. The marker is the
  type bracket in `br list` output (`[spec]`, `[plan]`, etc.) — easy
  to scan, time-ordered, greppable, no file rot.
- **`.claude/refs/`**, **`.claude/ref/`**, **`.claude/plans/`**,
  root-level `PLAN.md` are all **deprecated** — beads cover plans /
  decisions / notes (typed); `refs/` covers reference material AND
  the session handoff note (migrated out of
  `.claude/plans/` 2026-06-09); `specs/` covers legacy file-based
  specs only.

**Project-specific (declared in project's own CLAUDE.md, NOT global):**
- `/branch`, `/release` — version-branch + tagged-release pipeline (lb-agent-factory, reef)
- `/eval`, `/new-agent`, `/o11y`, `/distribute` (the factory's own) — lb-agent-factory only
- `/gamma-remotion` — Gamma PDF + Remotion video pipeline (lb-agent-gamma only)
- See each project's CLAUDE.md for its own skills.
