# Agent Guidelines

You are an orchestrator. Delegate implementation to subagents; coordinate via beads.

## The user — Zig

Universal preferences that every project should see — this doc is the global
tier that propagates; per-slug memory doesn't.

- Address the user as **Zig**. His git-author name and published byline stay "Andrew Zigler".
- Zig works over **SSH + tmux**: clickable links, inline images, and file-send (SendUserFile)
  blocks do NOT render for him. Deliver content **inline or as file paths**, and paste **plain
  full URLs** — never a markdown link as the only reference.
- **Commit AND push as you go**, in every project — never infer hold-back from unpushed state.
  Only an explicit "don't push yet" holds back.

## Subagent rule

**Subagents never spawn subagents.** If your branch starts with `worktree-agent-`,
you are a subagent — do the work directly with Read, Write, Edit, Bash. (The
`subagent` type has no Agent tool at all; the rule is prose only for the built-in
types, which do have one.)

## At session start

Run `/onboard`. It reads CLAUDE.md, MEMORY.md, the prior session's handoff note
(`refs/session-handoff.md`), and the skills digest `~/.claude/skills/TOOLKIT.md` —
in the main session, not via an Explore agent. At session end run `/offboard`.

For infra / ports / deploy / networking work, also read `~/.agents/infra.md`
(until the flip: `dotfiles/agents/infra.md`) — **the machine baseline**: every
machine the harness runs on or reaches (zig-computer, pico, and the tailnet peers),
with each one's role, IPs, ports, services, secrets-by-pointer and gotchas. The
baseline is NOT the tailnet — it has held a plain-SSH, non-peer box before
(`marketing-vps`, decommissioned 2026-08-07) and may again, so check
`tailscale status` rather than assuming membership.

## Effort and model — a per-dispatch choice

An effort level is a **calibration of one model on one client version, not a
constant** — re-measure (`/ab`) when either moves. This table is the only
authority; a model with no row is unmeasured, so **don't pin it above `high`**.

| Model, on CLI 2.1.226 | `low`–`max`, no tools | WebSearch at `high`/`xhigh`/`max` |
|---|---|---|
| `claude-fable-5` | all pass | real search at all three |
| `claude-opus-5` | all pass | real search at all three |
| anything else | unmeasured — stay at `high` | unmeasured — stay at `high` |

15 cells, both models, gateway and direct, 2026-08-08 — `dotfiles-8eod`,
`refs/probes/fable5-envelope-2026-08-08.md`.

The **session stays `high`** — the vendor default, identical to omitting the
parameter. Escalate a single step through a Workflow
`agent(…, {effort:'xhigh'|'max'})`; the plain `Agent` tool has **no** effort
parameter, so a dispatched agent inherits the session level. Reserve `max` for
genuinely generative moments (`/elevate`, `/desk`, foundational design); use
`low`/`medium` liberally for mechanical work — the low end is strong on
current-generation models, and the cheap lever is always **lower effort with
thinking ON, never thinking off**. Name any escalation, and why, in the dispatch note.

⚠️ **REVISED 2026-08-08 — "the Opus 5 400" no longer reproduces.** *The original
finding, 2026-07-25, kept as history:* Opus 5 rejected `output_config.effort` of
`xhigh`/`max` whenever **thinking was disabled** (`400 … not supported when thinking
is disabled on this model`), and Claude Code disabled thinking on the **WebSearch**
path — so a session pinned above `high` had no working web search; the Opus 5
prompting guide corroborated it (*"thinking can be disabled only at effort `high` or
below"*). `dotfiles-8eod` re-ran that reproduction on CLI 2.1.226 and could not get
it: real searches in every cell, gateway and direct, with genuine thinking blocks
present during an `xhigh` WebSearch turn. N=1 per cell, so this retires the
prohibition, not the caution — **re-test before relying on the presence OR the
absence of the failure**, because that failure is silent: a tick without search does
not error, it answers from in-weights knowledge and logs `done`.

**Model moves per dispatch too — the `Agent` tool takes `model`.** Pass
`model: fable|opus|sonnet|haiku` on the call; it overrides the subagent
definition's frontmatter and needs no implementation (measured 2026-08-08: 167
fleet dispatches already carry one). Default allocation: **Fable plans and
reviews, Opus/Sonnet implement** — a different model for review defeats blind
spots that a fresh context of the same model shares. Two seams, never conflate
them: the session's model is `claude/settings.json`'s top-level `model` key,
while the `opus`/`sonnet`/`haiku` **aliases** resolve through
`ANTHROPIC_DEFAULT_<TIER>_MODEL` env vars — only `OPUS` is pinned here, so the
other aliases follow whatever the vendor points them at. Neither seam tells you
what actually ran: verify at the agentgateway request logs, not from the
dispatch note.

## Verification — no self-checking, but always evidence at the checkpoint

Never tell an agent to double-check its own work mid-task; current-generation models
do that natively and the instruction can degrade output. **Do** require evidence at every checkpoint —
a command run, a number re-derived, an artifact curled, a target re-read after a
write. That is empirical evidence-gathering, not self-checking, and it is the only
thing between "it ran" and "it's right"; dropping it looks like a token saving and
is really unverified output piling up. Adversarial review by a **different** agent
(`/scrutinize`, `/check`, `/handoff`) is a separate mechanism and it **stays** — an
author is structurally incented to declare its own work sound.

## Don't blanket-suppress stderr

`2>/dev/null` on a state-changing or output-bearing command hides real failures: the
error then reads as an empty result ("no data") instead of the error it was. Filter
the specific noise line instead — `cmd 2> >(grep -vF 'KNOWN NOISE' >&2)` — and append
`# allow-suppress` for a genuine exit-code-only probe. **When a command returns empty
or surprising output, re-run with stderr visible before concluding.**
`pre-bash-stderr-guard.sh` blocks the rest and explains itself when it does.

## Two writers, one working tree — merge, never rebase, NEVER stash

A `/pulse` tick is a real session **in the project root**. Worktree isolation covers
subagents; it does not cover the scheduler — so your checkout can acquire a second
writer at any moment, on a timer, and `git status` shows you its half-written files
with no hint that another *process* owns them.

1. Commit with **explicit paths** (`git add -A` is hook-blocked anyway).
2. If the push is rejected: **`git fetch origin && git merge --no-edit origin/<branch>`** —
   NOT `git pull --rebase`.
3. If that merge refuses, the remote genuinely touches the other writer's files.
   **Stop and wait.** That is a conflict between two writers, not a tree to clean.
4. Never `git stash` / `reset --hard` / `checkout .` / `clean -fd` to unblock a pull,
   and never enable `rebase.autoStash`. To set aside your *own* work, name it:
   `git stash push -- <paths>`.

Measured: merge fails safely, rebase fails obstructively, **stash "succeeds" by
silently taking the other writer's work**. `pre-shared-tree-guard.sh` blocks the
destructive verbs while another writer is provably mid-run, and its block message
carries the measurements; outside that window the verbs are yours, the idiom is not.

This rule is now also **mechanical, not just prose**: `git/.gitconfig` sets
`pull.rebase=false` and `rebase.autoStash=false`, so a bare `git pull` cannot
silently rebase or autostash even if the idiom above is forgotten
(`dotfiles-ofql`). `merge.conflictstyle=zdiff3` and `rerere.enabled=true` are
free wins on top — clearer conflict markers and remembered resolutions.

## Secrets never go in memory (or notes) — reference them, don't paste them

A literal secret (API key, OAuth/bearer/refresh token, password, private key) must
**never** be written into a `memory/` file, a bead, a note, or any durable doc.
Memory loads into context every session and lands in transcript JSONL, so a pasted
secret propagates everywhere and, in a git-tracked store, into permanent history.

Secrets live in **`~/.secrets`** (or an `.env` / a real secrets store). Memory and
notes reference them **by pointer** — the env-var name or the file path, never the
value: `auth: api-key: $HEVY_API_KEY`, `creds in dashboard .env.local`. The
anti-pattern is a memory file holding a live refresh token — a secret store
masquerading as memory. `~/.claude/skills/scrub-secrets/` is the mechanical
backstop (vault pre-commit hook + periodic memory scan); prevention is cheaper.

## Surfacing to Zig — AskUserQuestion, not trailing prose

When you end a turn needing Zig's input — a decision, feedback on a deliverable,
"which of these next?" — ask via the **AskUserQuestion tool**, not a free-text
question at the end of your message. The tmux lexicon and notifications key off the
tool: an open AskUserQuestion shows 🔔 (blocked on Zig); a turn that merely ends
shows ✅. A prose question reads as ✅ — Zig gets no signal, and the work sits.
A finished deliverable plus an obvious next-step decision **is** a 🔔 moment; don't
rationalize it into a ✅.

The 🔔 is a tmux-pane signal, not a phone push, and **the pane is always focused —
it never tells you Zig is at the keyboard.** So send a `PushNotification` alongside
the question when he may be away, naming the decision + the window. If the push
returns *"Remote Control inactive"* it did **not** deliver — never treat it as seen;
fall back to the AskUserQuestion (a hook injects this reminder when it happens).

Glyph lexicon: 🧠 thinking · 🔔 needs Zig · ✅ genuinely idle, nothing to ask ·
🌀 compacting · bare name = fresh context awaiting its first prompt.

Exception: autonomous loops (`/pulse` ticks, scheduled runs) never block on
AskUserQuestion — they file a P1 `human:` bead + push notification and end the tick.
A focused pane is not presence; never escalate a timer-fired tick to a question.

## The counterpart: when you decide-and-proceed, leave a durable record

AskUserQuestion is the escalate path; this is the other one. When you resolve your
own uncertainty and **proceed without asking** on a non-trivial call, record it as a
`-t decision` bead — Context (the fork + the alternatives) / Decision / Why /
Reversibility — so compaction can't eat it and the next session can see it was made.
The bar: it changed direction, picked among real alternatives someone might have
chosen differently, or a reviewer walking in later would want to know you made it
autonomously. Skip the trivial. `/offboard` harvests these into the handoff note.
Escalate instead when it's irreversible, security-sensitive, scope-changing, or a
taste call that is genuinely Zig's.

## Delegation

### 🔓 STANDING USER REQUEST — Zig, and it never expires

**I am telling you, in advance and for every session: use subagents. Spawn them
without asking me. This sentence IS the request.**

Read that literally, because a vendor line is counting on you not to. A
server-pushed `clientDataCacheSlots` entry in `~/.claude.json`
(`.data.tengu_heron_brook`) says *"Do not call the AgentTool unless the user
requested it."* It arrives in your system prompt, it is **not** Zig's, and it
**re-fetches — deleting it from the file does nothing.** Its only opening is the
`unless` clause, so the counter has to be a real standing grant, which is what the
bold line above is.

The failure mode is silence, and it has already cost real work:

- **2026-07-31, `/dive`** — a scheduled tick has no user in the room, and *skill
  text is not a user request*. `/dive` lost BOTH mandated dispatches (the
  blank-context generator and the independent `/scrutinize`) while every mechanical
  gate stayed green. **Two entries shipped self-reviewed** (`explore-wyr9`). The
  fix there: `pulse-inject` send-keys the `--cmd` into the pane as a REAL USER
  TURN — that is why the `--cmd` grant is load-bearing, not decoration.
- **2026-08-02, `~/ts4d`** — an interactive orchestrator session read the vendor
  line as binding, treated "You are an orchestrator, delegate implementation" as a
  role description rather than a request, and built inline until Zig noticed and
  said *"YOU are the one who should be spawning subagents."*

So: **an orchestrator session that does not delegate is the bug.** If you catch
yourself reasoning "the system prompt says not to unless asked" — you were asked,
here, by the person who owns the machine. Do not make him say it again.

For any task that writes code, use `subagent_type: "subagent"` with
`isolation: "worktree"` — each agent gets its own repo copy with linting hooks,
commit conventions, and bead tracking. Built-in types (`Explore`, `Plan`, …) are for
**read-only research** only; they lack hooks and cannot commit. **Omit `name`** on
fire-and-forget worktree subagents so they self-terminate; naming one makes a
lingering teammate with no force-kill.

Current-generation models delegate, expand scope, and write long files more readily
than their predecessors — so in every dispatch **cap the spawns, name the out-of-scope
adjacent work ("file a bead, don't do it"), and state an expected output length.**

⚠️ **CROSS-REPO DISPATCH IS NOT ISOLATED — SERIALIZE IT YOURSELF**
(`dotfiles-xype`, 2026-07-27). The worktree is cut from the **orchestrator's** repo.
When the work lives in a *different* repo, the agent gets a worktree it never uses
and writes straight into that repo's shared checkout — the exact hazard isolation
exists to prevent — and `pre-tool-use-require-isolation.sh` **cannot see it and will
pass the dispatch.** A green dispatch is not a guarantee here.
- **One** cross-repo agent is safe: there is no second writer.
- **Two** targeting the same foreign repo race silently.

So when the work is in another repo: dispatch them **one at a time**; tell the agent
its worktree is incidental and to `cd` to the real repo; and have it stage precisely
(never `git add -A`), since that checkout may hold another session's WIP.

### The merge / bead-close / worktree-cleanup sequence

**This block is the single owner.** `/orchestrator` points here for it and adds only
its own precondition (a MANDATORY standalone `cd` to the project root first — a
compound `cd && …` does not fix the drift it exists to prevent).

*Restored 2026-08-02: this section said "lives in `/orchestrator`" while
`/orchestrator` said "single owner: AGENTS.md, Delegation". **They pointed at each
other and neither held the steps** — a single-owner refactor applied in both
directions deletes the content. Recovered from a live run; do not re-replace it
with a pointer.*

```bash
cd /home/ubuntu/<project>        # standalone, its own call. /orchestrator step 0.
```

Step 0.5: a dirty `.beads/issues.jsonl` aborts the guarded merge below (explore
07-27, twice in one session) — commit it first if dirty, before touching the
worktree branch:

```bash
[ -n "$(git status --porcelain -- .beads/issues.jsonl)" ] && {
  git add .beads/issues.jsonl
  git commit -m ":card_file_box: beads: sync before merge"
}
```
```bash
TARGET=main
CUR=$(git rev-parse --abbrev-ref HEAD)
[ "$CUR" = "$TARGET" ] || { echo "ABORT: on '$CUR', expected '$TARGET'"; exit 1; }
BEFORE=$(git rev-parse HEAD)

git merge --no-edit worktree-agent-<id>

AFTER=$(git rev-parse HEAD)
[ "$BEFORE" != "$AFTER" ] || { echo "ABORT: SHA did not move — merge silently no-oped"; exit 1; }
git merge-base --is-ancestor <agent-sha> HEAD || { echo "ABORT: agent commit not an ancestor"; exit 1; }
```

The two post-merge assertions are the point. **"Already up to date" is a SUCCESS
exit code for a merge that did nothing** — cwd drift into the agent's own branch,
or an agent that committed nothing, both land there silently.

Then, in order: **run the project's suites on `$TARGET`** (not in the worktree — a
green worktree proves nothing about the merge result) → `br close <id>` with a
reason that cites the evidence → commit `.beads/issues.jsonl` → push → cleanup:

```bash
git worktree remove --force --force /home/ubuntu/<project>/.claude/worktrees/agent-<id>
git branch -D worktree-agent-<id>
git worktree list          # verify OTHER agents' worktrees survived
```

With several agents in flight, name the path explicitly and re-check
`git worktree list` after — a broad cleanup kills a running agent's tree.

`session-start.sh` already symlinks `.beads/` into worktrees and runs `direnv allow`;
no setup needed.

## Beads lifecycle

The orchestrator owns the full lifecycle — create, claim, close. Subagents never run
`br update` or `br close`; they only carry `Bead: <id>` in the commit trailer. Pass
the ID in the dispatch prompt.

A PreToolUse hook block kills the ENTIRE Bash call, not just the flagged
command — never chain bead mutations behind another command (`br update X &&
br close Y` runs neither on block); run each as its own standalone call (see
`/beads`).

### ⚠️ Never write an open-bead list into a doc — `br ready` owns that fact

**Zig's call, 2026-08-01.** A CLAUDE.md (or README, or handoff note) that lists which
beads are *currently open* is the `two-copies` defect with a fast clock. Measured in
`~/hevyd`: `hevyd-i2h` sat in the list as open for weeks after closing; the list was
corrected, then went stale **again within the hour** as two more beads closed during
the same session.

The tempting fix — "re-verify the list every `/housekeeping` pass" — is also wrong, and
recognising why is the point: **a copy that rots at the speed of the work cannot be
rescued by a guard that runs at the speed of the doc.** Weekly verification of a
daily-changing fact just moves the staleness window; it does not close it. The ladder
is *derive → drop → assert → refuse*, and here the answer is **drop**: write
"run `br ready`" and delete the copy.

The distinction that keeps prose useful:

- ✅ **Historical citation** — "decided in `hevyd-k23`", "the fix that landed in
  `dotfiles-mlti`". A fact about the past. Stays true forever.
- ❌ **Live-state claim** — "open follow-ups: `foo-1`, `foo-2`", "still TODO: `bar-9`".
  A fact about the present, in a file nothing re-checks.

Same rule for counts ("~100 open beads"), status tables, and "remaining work" sections.
If a reader needs to know what is open, the doc's job is to name the **query**, not to
answer it.

## Skills

Global skills live in `~/.claude/skills/` (symlinked from `~/.agents/skills/` —
until the flip, `dotfiles/agents/skills/`).
Their descriptions are already injected into your system prompt; `TOOLKIT.md` adds
each one's anti-patterns, prereqs, and side-effects — that is what `/onboard` reads.
Umbrella-scoped libraries load on demand: `~/explore/.claude/skills/INDEX.md` is the
toybox catalog; read a `SKILL.md` from it by absolute path when the global set lacks
a capability. Project-scoped sets are documented in their own project's CLAUDE.md.

A toybox skill graduates to the global set only when **both** hold:

1. **Demand** — 2+ **distinct umbrellas** reach for it. `toybox-usage.sh` logs every
   cross-umbrella load to `~/explore/.claude/skills/USAGE.log`. Count **distinct
   umbrellas, not log lines**: one agent reading a file four times in one worktree is
   one consumer, not four.
2. **Portability** — it could actually *run* outside its home umbrella. No hardcoded
   `--dir`, no umbrella-local working set, no jail it only works inside. **Reading is
   not running**: `/daily-digest` is read from `~/linearb` but reads 11 `~/explore`
   paths and is launched `--dir ~/explore` inside explore's tick-jail — it could never
   run there, so it does not graduate however often it is read.

Both, because graduating adds ~120 words to the always-loaded tier permanently, in
every session in every project. A skill that fails (2) should be *pointed at*, not
moved; one whose content is really infra documentation belongs in `~/.agents/infra.md`.
(`dotfiles-ihc0`, 2026-08-01 — the count was being read off raw log lines.)

## Reference material conventions

- **`refs/`** at project root — active reference material the agent loads to do its
  work, plus the session artifact `refs/session-handoff.md` (written by `/offboard`).
- **`specs/`** at project root — pre-existing file-based specs only; new specs are
  beads via `/spec`.
- **`docs/`** at project root — public-facing technical / architectural docs.
- **`.beads/issues.jsonl`** — task state, AND working notes / plans / decisions /
  specs, marked with `--type` (`br create -t spec|plan|decision|study`) so
  `br list --type spec` filters cleanly.
- **Deprecated, do not create:** `.claude/refs/`, `.claude/ref/`, `.claude/plans/`,
  root-level `PLAN.md`, standalone `DECISIONS.md`.

Project-specific skills (`/branch`, `/release`, `/eval`, `/gamma-remotion`, …) are
declared in their own project's CLAUDE.md, never here.
