---
description: Session exit -- summarize state, write handoff note, commit. Paired with /onboard.
when_to_use: Session end, before context compaction, or any natural handoff point. Orchestrator-only (skip inside worktrees). Paired with /onboard, which retroactively honors .offboard-pending.
---

# /offboard

Run at session end, before context compaction, or at any natural handoff
point. Captures the session's state in a durable form so the next
session (or another person) can pick up cleanly.

Paired with `/onboard` (run at session start).

## When to run

- **Natural end-of-session** — before closing the terminal
- **Before context auto-compaction** — compaction can lose the thread;
  capture state in a handoff note before it happens
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

## Step 2: Identify the session ID

Find the live session JSONL — its id stamps the handoff note title and the
`.claude/last-offboard-session` marker (Step 4):

```bash
PROJECT_SLUG=$(pwd | sed 's|/|-|g')                 # e.g. -home-ubuntu-myproj
SESSION_JSONL=$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)
SESSION_ID=$(basename "$SESSION_JSONL" .jsonl 2>/dev/null)
echo "Session: ${SESSION_ID:-(none found)}"
```

If no JSONL is found, use the date alone in the handoff title; the marker
step just skips.

## Step 3: Write the session handoff note

Write the handoff note (overwrite, don't append — it's a snapshot, not a
log; history lives in git). Session artifacts live in `refs/` at the
project root (standardized 2026-06-09).

**Per-window scoping (multi-session projects).** A project that runs more
than one durable session — the pulse model: e.g. `~/explore` has a pulse
window AND an elevate window — opts in via `refs/.handoff-per-window`, and
the note is then `refs/session-handoff--<window>.md` so the parallel
sessions don't clobber each other's resume doc. Single-session projects
keep plain `refs/session-handoff.md`. The shared `handoff-path.sh` helper
resolves the right path (keyed by the tmux window name); always go through
it, never hardcode the filename:

```bash
mkdir -p refs
_HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type handoff_path >/dev/null 2>&1 || handoff_path() { printf '%s/refs/session-handoff.md' "${1:-.}"; }
HANDOFF=$(handoff_path .)            # refs/session-handoff.md  OR  refs/session-handoff--<window>.md
# one-time legacy migration (pre-2026-06-09 location):
[ -f .claude/plans/session-handoff.md ] && git mv .claude/plans/session-handoff.md "$HANDOFF"
echo "handoff -> $HANDOFF"
```

Write the markdown below to `$HANDOFF`:

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

## Step 4: Clear markers and commit

```bash
# Markers are window-scoped too (handoff-path.sh), so two durable sessions
# in one project don't trip each other's safety net. Falls back to legacy
# single-file when not opted in / not in tmux. (Both markers are gitignored.)
_HP="$HOME/dotfiles/agents/lib/handoff-path.sh"; [ -f "$_HP" ] && . "$_HP"
type handoff_path          >/dev/null 2>&1 || handoff_path()          { printf '%s/refs/session-handoff.md' "${1:-.}"; }
type offboard_pending_path >/dev/null 2>&1 || offboard_pending_path() { printf '%s/.offboard-pending' "${1:-.}"; }
type last_offboard_path    >/dev/null 2>&1 || last_offboard_path()    { printf '%s/.claude/last-offboard-session' "${1:-.}"; }
HANDOFF=$(handoff_path .)
rm -f "$(offboard_pending_path .)"

# Record this session as offboarded — session-end.sh compares this to
# its own session_id and skips dropping the pending marker on a match.
mkdir -p .claude
PROJECT_SLUG=$(pwd | sed 's|/|-|g')
SESSION_ID=$(basename "$(ls -t "$HOME/.claude/projects/${PROJECT_SLUG}/"*.jsonl 2>/dev/null | head -1)" .jsonl)
[ -n "$SESSION_ID" ] && echo "$SESSION_ID" > "$(last_offboard_path .)"

git add "$HANDOFF"
git commit -m "$(cat <<'EOF'
:card_file_box: offboard: handoff note (<session-id-short>)

<one-line summary of what shipped this session>

EOF
)"
git push
```

## Step 5: Brief the user

One short paragraph:

- What shipped this session (1–2 bullets)
- What `/onboard` should pick up on next time

This is the last orchestrator action before context compaction or
session close.

## Edge cases

- **Session JSONL missing** — use the date alone in the handoff title and
  skip the `.claude/last-offboard-session` marker; still write the note
  and clear markers.
- **Multiple sessions in one day** — each gets its own handoff note,
  overwriting the prior one. The git history preserves the chain.

## Don't skip

Even short sessions deserve a handoff note. A two-line "I checked X, no
action" is honest and useful — better than no note at all.

## The `.offboard-pending` marker

`session-end.sh` (the `SessionEnd` hook) drops a `.offboard-pending`
file at the repo root when a session ends **without** `/offboard`
having run — detected primarily by `.claude/last-offboard-session`
matching the ending session's id (Step 4 writes it), with
HEAD-committed-the-handoff-note as fallback. The next session's
`/onboard` Step 0 finds the marker, runs `/offboard` retroactively,
then clears it.

`pre-compact.sh` deliberately does NOT drop the marker: compaction
keeps the same session alive, and that session's own post-compaction
`/onboard` would misread its own marker as a prior session's.

If `session-end.sh` isn't wired in your project, manual `/offboard`
discipline is the only safety net.

## Pair with /onboard

`/onboard` checks for `.offboard-pending` at session start and runs
this skill retroactively if found. The two skills together bracket
every orchestrator session and keep handoffs continuous.
