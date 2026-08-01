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
- The durable pulse windows (`dive`, `digest`, `desk`, `dream`) hold sessions
  for **days**. They act on rules that may no longer exist on disk.
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

   Since 2026-08-01 that is a **mechanism**, not an intention: `tools/githooks/`
   holds a `pre-commit` that runs the suite matching each staged
   `agents/{hooks,scheduler,lib,doclint}` script — keyed on the **test file**
   too, since weakening a guard is often an edit to the test alone — plus
   `pre-bead-close.sh --selftest` and, for the scrutiny-verdict guards,
   `agents/hooks/test/mutate-scrutiny-guards.sh`. **Activate it per clone:**

   ```bash
   git config core.hooksPath tools/githooks
   ```

   It is a per-clone local setting, so a fresh clone (or a new machine) starts
   ungated until that line runs. Why it exists: before it, 32 suites and a
   `--selftest` had no caller, and a 13-mutant sweep found three survivors
   against green suites — one a live false-accept in the pulse `done` gate
   (`dotfiles-8aj5`, `dotfiles-jm1c`). **A green suite is not evidence that a
   guard bites**; only a mutant that dies is.

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

6. **`$0`/`$1`/`$N` in a `SKILL.md` are rewritten before the agent ever sees them.**
   Skill-argument substitution replaces `/\$(\d+)(?!\w)/` in the **rendered** body with
   the invocation's argument words — **0-indexed, so `$0` is the FIRST argument**
   (verified against `claude` 2.1.220). An awk `$0` becomes a path and dies `division by
   zero`; prose is hit too (`$0.05` → `<arg>.05`). The file on disk stays correct, so
   this is invisible to grep and to review. Only `SKILL.md` is substituted —
   `reference/*.md` is read verbatim, and a skill invoked with no argument is untouched.
   **Prefer an idiom with no field reference** (pattern-match + `next` over `($0 ~ /re/)`);
   `${1}` / `${1:-.}` are safe (braces don't match); otherwise escape as `\$0`. Live
   instance: `explore-wcmj` — `/desk`'s corpus load silently returned 0.1% of the corpus.

## Beads

Prefix `dotfiles`. Orchestrator owns the lifecycle. Live epic for the Opus-5
harness refactor: `dotfiles-b9ii`.
