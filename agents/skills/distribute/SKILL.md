---
description: Distribute the dotfiles harness (skills, hooks, CLAUDE.md, optional settings) into a destination directory shaped like a coworker's ~/.claude folder. Default destination is ~/linearb/skills (the LinearB-team shared git repo). Run after editing any paragon skill so the share-out stays current.
when_to_use: User says "distribute the skills", "push to lb-skills", "sync my dotfiles to the team repo", or has just edited a global skill / hook / CLAUDE.md and wants the changes mirrored out. Also after onboarding a new global skill so the team picks it up on next pull.
allowed-tools: Bash(/home/ubuntu/dotfiles/zig-computer.distribute.sh*) Bash(git -C *) Bash(cd /home/ubuntu/linearb/skills*)
---

# /distribute — Mirror dotfiles into a coworker-friendly tree

This skill runs `zig-computer.distribute.sh` at the dotfiles root.
The script:

1. Copies `dotfiles/agents/AGENTS.md` to `<dest>/CLAUDE.md`
2. Cleans + copies `dotfiles/agents/skills/` to `<dest>/.claude/skills/`
3. Cleans + copies `dotfiles/agents/hooks/` to `<dest>/.claude/hooks/`
4. Copies `dotfiles/claude/settings.json` to `<dest>/.claude/settings.json`
   (only if missing on the destination by default — pass `--settings`
   to overwrite)

After the script runs, the destination directory looks like a coworker's
`~/.claude/` would: ready for them to `git pull` and start working
with the same paragon set you use locally.

## Default destination: `~/linearb/skills`

`linearb/skills` is the LinearB-team shared git repo. By default the script
distributes into it. The user (or a teammate) then commits + pushes the
changes from `linearb/skills/`.

```bash
# Standard run
~/dotfiles/zig-computer.distribute.sh

# Preview without changing anything
~/dotfiles/zig-computer.distribute.sh --dry-run

# Distribute to a non-default location
~/dotfiles/zig-computer.distribute.sh /path/to/somewhere

# Force-overwrite the destination's settings.json too
~/dotfiles/zig-computer.distribute.sh --settings

# Skip settings.json entirely
~/dotfiles/zig-computer.distribute.sh --no-settings
```

## Private-reference blocks (stripped on distribute)

Skill content that only makes sense on this machine — pointers to
`~/linearb/refs/*`, personal paths, fleet GIDs — gets wrapped in
HTML-comment markers in the dotfiles original:

```markdown
<!-- private-start -->
**LinearB note:** ... `~/linearb/refs/asana-fleet.md` ...
<!-- private-end -->
```

The distribute script deletes everything between (and including) the
markers from the DISTRIBUTED copies; the originals keep them. When you
add a machine-local pointer to any paragon skill, wrap it — otherwise
a coworker's agent chases a path that doesn't exist on their machine.
(Added 2026-06-09; asana, beads, fix, gdoc carry the first blocks.)

## What this is NOT

- **Not** the lb-agent-factory `distribute` skill. That one syncs
  factory updates into agent clones (different problem, different repo
  layout). This one mirrors the dotfiles paragon set out to a single
  destination.
- **Not** for personal `~/.claude/`. The personal `~/.claude/` is
  symlinked into dotfiles directly — no copy step needed. This skill
  is for *other* destinations (linearb/skills today, possibly a coworker
  laptop tarball later).

## Workflow

```bash
# 1. Edit a paragon skill in dotfiles (e.g., bump the asana skill)
${EDITOR} ~/dotfiles/agents/skills/asana/SKILL.md

# 2. Verify locally — your ~/.claude is symlinked to dotfiles, so
#    /asana picks up the change immediately

# 3. Distribute to linearb/skills (default destination)
~/dotfiles/zig-computer.distribute.sh

# 4. Review + commit on the destination repo
cd ~/linearb/skills
git status
git diff
git add -A && git commit -m ":outbox_tray: distribute: sync from dotfiles"
git push
```

## Guardrails

- **Don't run from a subagent worktree.** This is a top-level orchestrator
  action — it touches the destination repo's working tree.
- **Don't run with --settings unless you mean it.** Coworker settings
  often diverge intentionally (different model preferences, different
  hook permissions). The default `--no-overwrite if present` is the
  right policy.
- **Always review the destination diff before committing.** Especially
  when the paragon skill set has been refactored — a destination can
  end up with hundreds of touched lines that should land in one
  reviewed commit, not a series of churn commits.
- **Don't add destination-specific overrides into dotfiles paragons.**
  If linearb/skills needs a different hook or skill variant, that variant
  belongs on a separate distribution branch, not in dotfiles.
