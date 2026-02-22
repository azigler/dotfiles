# Agent Guidelines

You are an orchestrator. Delegate implementation to subagents; coordinate via beads.

## Delegation

For any task that writes code, use `subagent_type: "subagent"` with
`isolation: "worktree"`. This gives each agent its own repo copy with linting hooks,
commit conventions, and bead tracking. Built-in types (`Explore`, `Plan`, etc.) are
for read-only research only — they lack hooks.

After a worktree subagent finishes, merge, close the bead, commit bead state, and clean up:

```bash
# Merge
git merge worktree-agent-XXXX --no-edit
git merge-base --is-ancestor worktree-agent-XXXX HEAD  # safety: abort if not merged

# Close bead (orchestrator owns lifecycle)
br close <bead-id>

# Commit bead state — list all closed bead IDs in the message
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <bead-id>"

# Clean up
git worktree remove --force .claude/worktrees/agent-XXXX
git branch -d worktree-agent-XXXX
```

When closing multiple beads at once (e.g. after parallel agents), batch them:

```bash
br close <id-1> && br close <id-2> && br close <id-3>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <id-1>, <id-2>, <id-3>"
```

## Worktree Beads

The `session-start.sh` hook (runs at SubagentStart) automatically symlinks
`.beads/` in worktrees back to the main worktree's copy. This gives one source
of truth for bead state — the subagent can read bead descriptions and the
orchestrator sees state changes in real time. No manual setup needed.

## Beads

Orchestrator owns the full bead lifecycle — create, claim, close:

```bash
br create -p 2 "scope: title"
br update <id> --status=in_progress
```

In the subagent prompt, include the bead ID:

> Your bead is `<id>`. Include `Bead: <id>` in your commit trailer (see `/commit`).

After merge, close and commit bead state:

```bash
br close <id>
git add .beads/issues.jsonl && git commit -m ":card_file_box: beads: close <id>"
```

Subagents never run `br update` or `br close` — they only reference the ID in
commit messages.

## Skills

- `/lint` — Linter reference and known gaps
- `/commit` — Commit conventions (gitmoji, bead trailer)
- `/beads` — Task tracking with `br`
