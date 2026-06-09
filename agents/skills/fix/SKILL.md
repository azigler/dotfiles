---
description: Fix-and-guard workflow for any identified problem. Creates a typed `bug` bead, dispatches a subagent to fix it, then either repairs an existing test or adds a new regression test so the bug can't come back silently. Orchestrators invoke this autonomously when a bug surfaces; user-invocable when a user reports one.
when_to_use: User reports a bug ("X is broken", "this doesn't work"), reviewer flags a defect, an audit / observability annotation / chat thread surfaces a regression. Orchestrators should fire this proactively when they identify a fixable problem mid-session.
argument-hint: "<short problem description>"
---

# /fix — Fix-and-guard

Every bug fix lands with a regression guard. Fix without guard is
half a fix — it ships once and silently rots back into existence the
next refactor.

This skill enforces the discipline: bead → subagent fix → test.

## When to fire

- User reports a bug
- Reviewer flags a defect
- Audit / observability trace / chat thread surfaces a regression
- You (the orchestrator) notice a problem mid-session — **don't ask
  permission, fire `/fix`** and route the work

The orchestrator runs `/fix` with no ceremony. Don't gate behind
"should I fix this?" — if it's a bug, fix it.

## Step 1: Create the fix bead

Type the bead `bug` so it shows up in `br list --type bug` and the
fleet's bug-tracking queries:

```bash
BEAD_ID=$(br create -t bug -p 1 "fix: <area> — <one-line problem>" --silent)
br update "$BEAD_ID" --description "$(cat <<'EOF'
## Problem
<verbatim user / reviewer / annotation text where possible>

## Symptom
<what the user sees, with reproduction steps if known>

## Suspected cause
<your initial diagnosis — short, can be wrong; the fix-agent re-diagnoses>

## Source of report
<chat thread permalink / observability trace URL / commit hash / "user said in this session">

## Acceptance criteria
- [ ] Root cause identified and documented in --notes
- [ ] Fix lands and passes existing tests
- [ ] Regression guard exists (existing test updated OR new test added)
- [ ] If your team tracks shipped fixes externally: receipt filed for material fixes
EOF
)"
br update "$BEAD_ID" --acceptance-criteria "$(cat <<'EOF'
- [ ] Root cause documented in bead --notes
- [ ] Fix in source code
- [ ] Test for the regression (new or updated)
- [ ] Tests + lint pass on the branch
EOF
)"
br update "$BEAD_ID" --claim
```

Priority is **P1 by default** for /fix beads — bugs matter. Override
to P2 only if it's clearly cosmetic or low-impact.

## Step 2: Dispatch a fix subagent (worktree)

The fix subagent's job is two-step: **find + fix the cause**, then
**guard against regression**. Don't split these into separate beads
— it's one logical unit and the test depends on the fix.

```
Your bead is `<BEAD_ID>` (typed `bug`). Include `Bead: <BEAD_ID>` in
your commit trailer (see /commit).

## CRITICAL: No nested agents
You are a subagent. Do NOT use the Agent tool. Work directly with
Read, Write, Edit, Bash, Grep, Glob.

## Task
Fix the bug described in bead `<BEAD_ID>` (`br show <BEAD_ID>`).

Two-phase work:

### Phase A: diagnose + fix
1. Read the bead's --description for problem, symptom, suspected cause.
2. Reproduce the bug locally if possible.
3. Identify the actual root cause. Append your diagnosis to bead --notes.
4. Apply the minimum fix that resolves it. Don't refactor adjacent code.

### Phase B: regression guard
- If a TEST EXISTS that should have caught this (but didn't) — UPDATE it
  so it would catch the bug now.
- If no relevant test exists — ADD a new test that fails on the
  buggy behavior and passes after your fix.

The guard is mandatory. A fix without a guard regresses silently.

## Pre-commit verification
- All tests pass (including your new/updated guard test)
- Lint clean (see /lint)
- Acceptance criteria all checked

## Commit
One commit per fix. Use :bug: gitmoji. Include `Bead: <BEAD_ID>`.
```

## Step 3: Merge + close

After the subagent reports done:

```bash
git merge worktree-agent-XXXX --no-edit
git merge-base --is-ancestor worktree-agent-XXXX HEAD || { echo "ABORT: not merged"; exit 1; }

br close <BEAD_ID>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <BEAD_ID>"

git worktree remove --force .claude/worktrees/agent-XXXX
git branch -D worktree-agent-XXXX
git push origin --delete worktree-agent-XXXX 2>/dev/null || true
```

## Step 4: External receipt log (team-specific)

If your team tracks shipped fixes in an external system (Asana, Linear,
Jira, a stakeholder board), file a receipt for **material** fixes —
stakeholder visibility, novel root cause, multi-bead fix arc. The
generic shape: a closed `bug` bead with `--external-ref` pointing at
the receipt ticket.

For routine fixes (typos, small logic bugs caught in review), the bead
itself is the record — don't clutter the external tracker with
one-line fixes.

<!-- private-start -->
**LinearB fleet (private):** when `FLEET_URL` / `FLEET_TOKEN` / `AGENT`
/ `AGENT_PARENT_GID` are set, bead-start and bead-close auto-log on the
agent's daily bead-log subtask; the receipt-of-work template + the GTM
Engineering project GIDs live in `~/linearb/refs/asana-fleet.md` and
`~/linearb/refs/asana-integration.md`.
<!-- private-end -->

## Variants

### Stakeholder feedback → multiple fixes

When a single feedback thread surfaces N distinct bugs, create N
`/fix` beads, NOT one mega-bead. Atomic sizing wins:

```bash
# In the orchestrator session, after reading a Slack thread:
br create -t bug -p 1 "fix: accounts — ack tip lacks @mention" --silent
br create -t bug -p 1 "fix: accounts — closed-won handler strands silently" --silent
br create -t bug -p 2 "fix: listener — duplicate event from race" --silent

# Then dispatch each /fix sequentially or in parallel
```

### Production hotfix path

For genuinely production-blocking bugs:

- Use `-p 0` (all-hands stop) on the bead
- Skip worktree isolation if the fix is trivial; just fix on main
- Add the regression test in the same commit as the fix
- File a receipt in your team's external tracker the same day
- Notify stakeholders in the team's chat with the ticket permalink

### Dotfile-resident files (orchestrator inline, no worktree)

Worktree subagents can't fix files that live outside any project
worktree. The `pre-tool-use-worktree-guard.sh` hook blocks Write/Edit
on absolute paths outside the worktree by design. Affected file
classes:

- `~/dotfiles/agents/skills/<name>/SKILL.md` (global skills)
- `~/dotfiles/agents/hooks/*.sh` (global hooks)
- `~/dotfiles/agents/AGENTS.md`
- `~/.claude/settings.json`
- `~/.config/systemd/user/*.service` (user services)
- `/etc/systemd/system/*.service` (system services)

For fixes to these files, the orchestrator does the work inline.
Same `/fix` discipline (typed `bug` bead, regression guard
mandatory) — just no worktree dispatch:

1. Create the bead per Step 1 (full `## Problem` / `## Steps to
   Reproduce` / `## Fix` / `## Acceptance criteria` sections)
2. Read + Edit the file directly as the orchestrator
3. Add a regression test to the file's own test directory if one
   exists. For dotfiles hooks specifically, the convention lives at
   `~/dotfiles/agents/hooks/test/` — one `test-<hook>.sh` per hook,
   executable bash, JSON payload + assertions via a `run_case`
   helper, prints `PASS: N/N test cases` on success. See
   `test-worktree-guard.sh` and `test-pre-bead-close.sh` as worked
   examples.
4. Run the test and confirm it passes before commit
5. Commit in the host repo (`~/dotfiles`, the agent-factory clone,
   etc.) with the `Bead: <id>` trailer per `/commit`
6. Close the bead and commit the JSONL per Step 3 of this skill

Worked examples (recent):

- `bd-iq81` — `~/.config/systemd/user/lb-fleet.service` Restart=always
- `bd-8euh` — `pre-bead-close.sh` chained-cd parsing
- `bd-w6sd` — `pre-bead-close.sh` dotted child-bead regex

Don't reach for a non-worktree subagent variant here. The inline
path is cleaner, the regression test lives alongside the fix, and
the orchestrator already has the context loaded.

## Anti-patterns

- ❌ **Fix without test** — the bug regresses on the next refactor.
  The guard is non-negotiable.
- ❌ **Refactor while you're in there** — keep the fix focused.
  Refactor in a separate `-t feature` or `-t task` bead.
- ❌ **Bundle multiple bugs into one bead** — each bug = one bead.
  The fix log + asana ticket gets clearer per-bug.
- ❌ **Fix on main when worktree isolation would have been safe** —
  unless it's a true production hotfix, use the worktree.
- ❌ **Skip the external receipt on a material fix** when your team
  tracks shipped work — silent fixes don't surface in receipts of work
  and stakeholders don't know they shipped.

## See also

- [/beads](../beads/SKILL.md) — bead lifecycle, types, anti-patterns
- [/commit](../commit/SKILL.md) — gitmoji + bead trailer
- [/asana](../asana/SKILL.md) — fleet daily bead-log + receipt-of-work
- [/test](../test/SKILL.md) — test-writing patterns (regression guard often re-uses these)
