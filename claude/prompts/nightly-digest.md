# Nightly digest prompt

You are running headless (`claude -p`) at 03:00 local on `zig` (Ubuntu).
Your job is to produce a one-page Markdown digest of the last ~24 hours
of activity across the operator's active repos. Output goes to stdout —
the wrapper script appends it to `~/.local/share/claude-digests/YYYY-MM-DD.md`.

You are routed through CCR's `background` channel, which means a **local
pico model** (Qwen3-Coder via llama-swap on :8090) is answering, not the
Anthropic API. Keep that in mind: terse, structured, no flowery prose.

## Source data the wrapper has already gathered

The wrapper has run these and pasted the output below this prompt:

1. `git -C ~/dotfiles log --oneline --since="1 day ago"`
2. `git -C ~/explore log --oneline --since="1 day ago"`
3. `git -C ~/explore/autonovel log --oneline --since="1 day ago"`
4. `br --db ~/dotfiles/.beads/beads.db list --status open` (top 20 lines)
5. `br --db ~/explore/.beads/beads.db list --status open` (top 20 lines, if exists)
6. `br --db ~/explore/autonovel/.beads/beads.db list --status open` (top 20 lines, if exists)

## Output format (strict)

Produce exactly these sections, in this order, in GitHub-flavored Markdown:

```
## Digest YYYY-MM-DD

### Commits (last 24h)
- **dotfiles** (<N> commits): one-line theme summary
- **explore** (<N> commits): one-line theme summary
- **autonovel** (<N> commits): one-line theme summary

### In-flight beads (open, ready)
- <bead-id>: <title> — <one-line context if obvious>
- (bullet per repo; cap at 5 most-recent per repo)

### Surface — needs attention
- <0-3 bullets> if anything looks stuck, conflicting, or overdue
- "Nothing flagged." if clean
```

## Rules

- Do NOT invent commits, beads, or context not in the input.
- If a repo has zero commits in the window, write "(no commits)".
- If a bead list is empty or the file is missing, skip that line silently.
- One page max. No preamble, no closing remarks, no "Hope this helps."
- Start the response with `## Digest ` and end at the last bullet.
- Each bead appears AT MOST ONCE in the output. Do not repeat the same bead
  across "In-flight" and "Surface" sections. Do not repeat a bead within a
  single section.
- Cap "Surface — needs attention" at 3 bullets total. If you cannot find a
  genuine concern in 3, write "Nothing flagged." and stop.
