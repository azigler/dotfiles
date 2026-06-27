---
description: Distribute the dotfiles paragon skill set into the LinearB Marketing plugin marketplace (default) or a legacy coworker-shaped ~/.claude tree. Run after editing any paragon skill so the team's MCP plugin stays current.
when_to_use: User says "distribute the skills", "sync my skills to the plugin", "push the toolkit to the marketplace", or has just edited a global skill / hook / CLAUDE.md and wants it mirrored out to the team. Also after onboarding a new global skill so the team picks it up on next plugin update.
allowed-tools: Bash(/home/ubuntu/dotfiles/zig-computer.distribute.sh*) Bash(git -C *) Bash(cd /home/ubuntu/linearb/plugins*)
---

# /distribute — Mirror dotfiles skills to the team

This skill runs `zig-computer.distribute.sh` at the dotfiles root. It has
two layouts:

## Plugin mode (DEFAULT) — the lb-marketing plugin marketplace

The team consumes skills over an MCP **plugin**. The canonical home is
`lb-marketing/plugins` (the `lb-marketing` marketplace), plugin
`linearb-marketing`. Distribute copies the paragon skill set into:

```
<plugin>/skills/<name>/SKILL.md (and supporting files)
<plugin>/skills/.native-manifest   <- destination-native skills, preserved
```

Default destination: `~/linearb/plugins/linearb-marketing` (a local clone
of the marketplace repo). **Only skills are distributed** — the plugin
manifest, marketplace manifest, README, hooks, CLAUDE.md, and settings are
NOT touched by the script.

```bash
# Standard run (plugin mode -> ~/linearb/plugins/linearb-marketing)
~/dotfiles/zig-computer.distribute.sh

# Preview without changing anything
~/dotfiles/zig-computer.distribute.sh --dry-run

# Distribute to a different plugin dir
~/dotfiles/zig-computer.distribute.sh --plugin /path/to/some-plugin
```

## Tree mode (`--tree`) — legacy coworker `~/.claude/` layout

Distributes skills + hooks + CLAUDE.md + settings into `<dest>/.claude/`,
shaped like a coworker's `~/.claude/`. Kept for tarball / laptop seeding.
Default destination: `~/linearb/skills` (now archived — pass an explicit
path).

```bash
~/dotfiles/zig-computer.distribute.sh --tree /path/to/dest
~/dotfiles/zig-computer.distribute.sh --tree --settings /path/to/dest   # overwrite settings.json too
```

## Destination-native skills (preserved across runs)

A destination may maintain skills of its own that do NOT come from dotfiles
(e.g. `linearb-positioning`, `linearb-brand-docs`, `campaign-builder` in the
plugin). List them one-per-line in `<skills>/.native-manifest` and the clean
step preserves them — distribute overlays the paragon set around them
without clobbering.

## Excluding personal-only skills from team destinations

Some paragon skills are Andrew's personal harness (pulse, cfp, talk,
zig-voice, gamma, nginx, orchestrator, …) and should NOT ship to teammates.
List them one-per-line in **`agents/skills/.distribute-exclude`** (in the
dotfiles SOURCE; `#` comments allowed). After copying the paragon set, the
script removes those skills from the distributed copy — they stay in Andrew's
local `~/.claude/skills/`, the team gets the curated subset. Applies in both
plugin and tree modes. The exclude file itself is never shipped.

## Private-reference blocks (stripped on distribute)

Skill content that only makes sense on this machine — pointers to
`~/linearb/refs/*`, personal paths, fleet GIDs — gets wrapped in HTML-comment
markers in the dotfiles original:

```markdown
<!-- private-start -->
**LinearB note:** ... `~/linearb/refs/asana-fleet.md` ...
<!-- private-end -->
```

The distribute script deletes everything between (and including) the markers
from the DISTRIBUTED copies; the dotfiles originals keep them. When you add a
machine-local pointer to any paragon skill, wrap it — otherwise a teammate's
agent chases a path that doesn't exist on their machine. (asana, beads, fix,
gdoc, distribute carry blocks.)

## Workflow (plugin mode)

```bash
# 1. Edit a paragon skill in dotfiles (your ~/.claude is symlinked to
#    dotfiles, so the change is live locally immediately)
${EDITOR} ~/dotfiles/agents/skills/asana/SKILL.md

# 2. Distribute to the plugin (default destination)
~/dotfiles/zig-computer.distribute.sh

# 3. Review + ship via the marketplace repo's PR flow (CI validates manifests)
cd ~/linearb/plugins
git checkout -b sync-skills-YYYYMMDD
# bump linearb-marketing/.claude-plugin/plugin.json version if behavior changed
python3 .github/workflows/validate_manifests.py
git add linearb-marketing/skills <changed-manifests>
git commit -m "Sync skills from dotfiles"
git push -u origin HEAD
gh pr create --fill           # CONTRIBUTING.md mandates a PR; let CI pass
```

## What this is NOT

- **Not** the lb-agent-factory `distribute` skill. That one syncs factory
  updates into agent clones (different problem, different repo layout).
- **Not** for personal `~/.claude/`. The personal `~/.claude/` is symlinked
  into dotfiles directly — no copy step needed.

## Guardrails

- **Don't run from a subagent worktree.** This is a top-level orchestrator
  action — it touches the destination repo's working tree.
- **Respect the marketplace PR flow.** `lb-marketing/plugins` validates
  manifests in CI on every PR; ship skill syncs as a PR, not a direct push to
  `main`.
- **Bump the plugin `version`** in `linearb-marketing/.claude-plugin/plugin.json`
  whenever skill behavior changes (semver; added skills are at least a MINOR
  bump). The marketplace `metadata.version` bumps only when a plugin is
  added/removed.
- **Always review the destination diff before committing.** A refactored
  paragon set can touch hundreds of lines that should land in one reviewed PR.
- **Don't add destination-specific overrides into dotfiles paragons.** If the
  plugin needs a different variant, it belongs on a distribution branch, not in
  dotfiles.
