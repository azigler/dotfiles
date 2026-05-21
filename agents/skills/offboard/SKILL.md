---
description: Session exit -- summarize state, write handoff note, optionally compute orchestrator cost from session JSONL, commit. Paired with /onboard.
---

# /offboard

Run at session end, before context compaction, or at any natural handoff
point. Captures the session's state in a durable form so the next
session (or another person) can pick up cleanly.

Paired with `/onboard` (run at session start).

## When to run

- **Natural end-of-session** — before closing the terminal
- **Before context auto-compaction** — the `PreCompact` hook leaves
  `.offboard-pending` as a marker if you forget
- **When handing off to another person** — the handoff note summarizes
  state for the new owner

## Step 1: Verify you're not inside a worktree

Offboard is for orchestrator sessions, not subagents. Check:

```bash
branch=$(git branch --show-current)
case "$branch" in
  worktree-agent-*)
    echo "You're inside a subagent worktree — offboard is orchestrator-only. Skip."
    exit 0
    ;;
esac
```

## Step 2: Identify session ID (optional)

If the project tracks per-session cost (see Step 4), find the live JSONL:

```bash
PROJECT_SLUG=$(pwd | sed 's|/|-|g')                 # e.g. -home-ubuntu-myproj
SESSION_JSONL=$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)
SESSION_ID=$(basename "$SESSION_JSONL" .jsonl 2>/dev/null)
echo "Session: ${SESSION_ID:-(none found)}"
```

If the file doesn't exist, the project doesn't track cost — skip Step 4.

## Step 3: Write the session handoff note

Write `.claude/plans/session-handoff.md` (overwrite, don't append — it's
a snapshot, not a log; history lives in git):

```markdown
# Session handoff — YYYY-MM-DD <session-id-short>

## State at offboard
- Current branch: <branch>
- Last commit: <hash> <subject>
- Open beads: <count>; in-progress: <count>
- In-flight subagents: <list or none>
- Dirty files: <list or none>
- Markers: `.offboard-pending` <cleared | still-present>

## What happened this session (bullets)
- <key accomplishments, decisions, merges>
- <anything load-bearing for next session>

## What's next
- <the next 1–3 actions the next session should take>

## Warnings / watch-outs
- <anything unusual the next session needs to know>
```

## Step 4 (optional): Compute orchestrator cost

If the project has `.claude/plans/cost-tracking.md`, log this session's
tokens via the global `/cost-tracking` skill's compute script:

```bash
if [ -f .claude/plans/cost-tracking.md ]; then
  ROW=$(python3 ~/.claude/skills/cost-tracking/compute-cost.py --format row)
  echo "$ROW"
  # Then append $ROW to the "Orchestrator consumption (per-session)" table
  # in .claude/plans/cost-tracking.md (just above the running-total line).
fi
```

The script auto-discovers the session JSONL via cwd slug, filters out
subagent sidechains (those have their own per-bead rows from
task-notification `<usage>` blocks), applies pricing, and emits a
single markdown-table row. See [`/cost-tracking`](../cost-tracking/SKILL.md)
for full options (`--model`, `--format`, etc.).

After appending the row, update the running-total row below it.

## Step 5: Clear markers and commit

```bash
rm -f .offboard-pending

git add .claude/plans/session-handoff.md
[ -f .claude/plans/cost-tracking.md ] && git add .claude/plans/cost-tracking.md

git commit -m "$(cat <<'EOF'
:dollar: cost: log orchestrator session <session-id-short>

<one-line summary of what shipped this session>

EOF
)"
git push
```

Use `:card_file_box:` instead of `:dollar:` if cost-tracking isn't part
of this project — the commit is just the handoff note.

## Step 6: Brief the user

One short paragraph:

- What shipped this session (1–2 bullets)
- Token cost (if computed) and running total
- What `/onboard` should pick up on next time

This is the last orchestrator action before context compaction or
session close.

## Edge cases

- **Session JSONL missing** — skip cost computation; still write the
  handoff note and clear markers. Cost can be reconstructed later from
  the JSONL if it appears.
- **Multiple sessions in one day** — each gets its own handoff note,
  overwriting the prior one. The git history preserves the chain.
- **Compute-cost script errors** — fall back to a `jq` token-total:

  ```bash
  jq -s '[.[] | select(.isSidechain != true) | .message.usage // empty]
         | map((.input_tokens // 0) + (.output_tokens // 0) +
               (.cache_creation_input_tokens // 0) +
               (.cache_read_input_tokens // 0)) | add' "$SESSION_JSONL"
  ```

## Don't skip

Even short sessions deserve a handoff note. A two-line "I checked X, no
action" is honest and useful — better than no note at all.

## Hooks that leave `.offboard-pending`

- `.claude/hooks/pre-compact.sh` — when the harness is about to compact
  context
- `.claude/hooks/session-end.sh` — when the session terminates

If neither hook is wired in your project, manual `/offboard` discipline
is the only safety net.

## Pair with /onboard

`/onboard` checks for `.offboard-pending` at session start and runs
this skill retroactively if found. The two skills together bracket
every orchestrator session and keep handoffs continuous.
