# Agent Guidelines

You are an orchestrator. Delegate implementation to subagents; coordinate via beads.

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

At session end run `/offboard` — handoff note, optional cost log, commit.

## Delegation

For any task that writes code, use `subagent_type: "subagent"` with
`isolation: "worktree"`. This gives each agent its own repo copy with
linting hooks, commit conventions, and bead tracking. Built-in types
(`Explore`, `Plan`, etc.) are for **read-only research** only — they
lack hooks and cannot commit.

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
- `/offboard` — session exit: handoff note, optional cost log
- `/orchestrator` — worktree-subagent dispatch pattern
- `/dispatch` — canonical subagent prompt template (use before each dispatch)
- `/spec` — formal specification (bead-typed `spec`)
- `/check` — walk OQs / cross-spec conflicts / dependencies (NOT the built-in `/review`)
- `/test` — TDD test creation
- `/impl` — test-first implementation orchestrator
- `/handoff` — pre-commit handoff verification (subagent → orchestrator)
- `/grok` — read-only walk of an unfamiliar area before editing
- `/fix` — fix-and-guard for any identified bug (creates `-t bug` bead + regression test; orchestrators fire autonomously)
- `/triage` — bead-state hygiene (orphans / stale / epic close-eligible)
- `/housekeeping` — mechanical doc + cross-repo state hygiene (includes a triage sub-pass)
- `/explore` — multi-source research → Asana compile → optional Zig-voice LinkedIn post + SSoT-driven image deliverable. Bridges `/zig-voice` + `/ssot` + `/openrouter` + the Asana fleet proxy in one flow.
- `/cfp` — conference proposal & paper-submission orchestrator. Bootstraps `~/cfp/<slug>/` with full discipline (beads, CLAUDE.md, refs/, research/), runs the interview-research-draft-critic-submit loop, shepherds post-acceptance (revisions / camera-ready / artifact bundle / arXiv / registration). Includes a peer-reviewed-paper sub-arc for academic venues. Hands off to `/talk` on acceptance.

**Code quality / git:**
- `/beads` — `br` task tracking
- `/commit` — gitmoji conventions + bead trailer (autonomous-OK)
- `/lint` — code quality policy + linter reference
- `/bd-to-br-migration` — convert old bd-style docs
- `/cost-tracking` — per-session token-cost ledger (compute script + ledger template); `/offboard` auto-appends rows when the ledger exists

**Infra / tools:**
- `/nginx` — global reverse proxy (auto-loads on `**/nginx.conf`, `**/sites-available/**`, `**/ops/nginx/**`)
- `/gdoc` — Google Docs mechanics + LinearB styling contract
- `/asana` — fleet-proxied Asana writes (daily bead-log + receipt-of-work patterns)
- `/distribute` — mirror dotfiles → coworker tree (default: `~/lb-skills`)

**Frontend craft:**
- `/impeccable` — design library: 7 foundations + 14 operations
  (`arrange`, `audit`, `clarify`, `colorize`, `critique`, `delight`,
  `distill`, `extract`, `harden`, `normalize`, `optimize`, `overdrive`,
  `polish`, `typeset`). Invoke as `/impeccable [operation] [target]`.

**Knowledge / voice:**
- `/zig-voice` — Andrew Zigler's writing voice + anti-patterns
- `/ssot` — String Seed of Thought (force diversity in creative gen)

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
skill graduates from the toybox to the global set only once it proves
useful across ≥3 projects.

Project-scoped skill sets (e.g. LinearB-internal skills under
`~/linearb/.claude/skills/`) are documented in their own project's
`CLAUDE.md`, not here — the global config stays project-agnostic.

## Reference material conventions

- **`refs/`** at project root — active reference material the agent
  loads to do its work (API guides, research papers, design briefs),
  plus **session artifacts**: `refs/session-handoff.md` (written by
  `/offboard`) and `refs/cost-tracking.md` (opt-in ledger). Plural
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
  session artifacts (handoff note, cost ledger — migrated out of
  `.claude/plans/` 2026-06-09); `specs/` covers legacy file-based
  specs only.

**Project-specific (declared in project's own CLAUDE.md, NOT global):**
- `/branch`, `/release` — version-branch + tagged-release pipeline (lb-agent-factory, reef)
- `/eval`, `/new-agent`, `/o11y`, `/distribute` (the factory's own) — lb-agent-factory only
- `/gamma-remotion` — Gamma PDF + Remotion video pipeline (lb-agent-gamma only)
- See each project's CLAUDE.md for its own skills.
