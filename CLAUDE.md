# dotfiles — the repo that owns the harness

This repo IS the global instruction tier. Editing it changes how **every**
Claude Code session on this machine behaves, in every project.

## ⚠️ Read this before editing anything under `agents/`

**Running sessions will NOT see your edits.** The always-loaded tier
(`agents/AGENTS.md` → symlinked as `~/.claude/CLAUDE.md`, plus the skill
frontmatter) is injected by the harness at **process start** and is a
**snapshot with no invalidation** (bug `explore-6wwu`, P1).

Consequences that bite:
- `/offboard` + `/onboard` do **not** refresh it. Only a `/clear` (or a new
  process) does.
- Four pulse windows (`explore`, `digest`, `elevate`, `recall-distill`) hold
  sessions for **days**. They act on rules that may no longer exist on disk.
  Stale-snapshot is the *normal* operating state, not an edge case.
- So: after changing a rule that a live loop depends on, either `/clear` the
  affected window or accept a lag of up to that window's lifetime.

## What lives here

| Path | What it is |
|---|---|
| `agents/AGENTS.md` | the global tier — symlinked to `~/.claude/CLAUDE.md`, loaded in EVERY session |
| `agents/skills/` | the global paragon skill set — symlinked as `~/.claude/skills` (one dir symlink, not per-skill) |
| `agents/skills/TOOLKIT.md` | the per-skill digest `/onboard` reads instead of all bodies |
| `agents/hooks/` | every hook — these run on **every tool call fleet-wide** |
| `agents/lib/` | shared shell libs the hooks source |
| `agents/scheduler/` | `pulse-inject.sh`, unit templates, `pulse-ledger-lint.py` |
| `agents/infra.md` | machine + mesh baseline; **re-verify before depending on a fact** |
| `ubuntu.upgrade.sh` / `pico.upgrade.sh` / `mac.setup.sh` | machine provisioning |

## Rules specific to this repo

1. **A hook bug breaks every session on the machine, including yours.** Run the
   hook test suite before AND after any hook change, and demonstrate each fix's
   failure-before / absence-after with real output. A fix you cannot demonstrate
   is a fix you should not claim.

2. **A documented EXAMPLE is executable in a prompt-driven harness.** Agents copy
   examples verbatim, so a wrong example is a defect that replicates itself —
   invisible to code review, invisible to tests, and it *scales with adoption*.
   Four confirmed instances as of 2026-07-25 (bead `dotfiles-mlti`): a `"row":null`
   ledger example that produced 23 bad rows across 3 projects; an `AGENTS.md`
   cleanup snippet that violates this repo's own rule and is blocked by its own
   hook; a mandated markdown link form that doesn't resolve; a commit template
   hardcoding a stale model name. **Before committing an example, run it.**

3. **Don't blanket-suppress stderr** (`2>/dev/null`) on anything state-changing
   or output-bearing — `pre-bash-stderr-guard.sh` enforces it, and the hooks
   themselves have violated it. Pure existence checks may append `# allow-suppress`.

4. **`git add <specific-files>` only** — `git add -A`/`.` is hook-blocked.

5. **Effort stays `high`.** It is the Opus-5 vendor default. Escalate a single
   dispatch via a Workflow `agent(…, {effort})`, never the session. Note that
   `effortLevel` is currently **absent** from every settings file — the `high` you
   get is the default, not a pin, and nothing warns if that changes.

## Beads

Prefix `dotfiles`. Orchestrator owns the lifecycle. Live epic for the Opus-5
harness refactor: `dotfiles-b9ii`.
