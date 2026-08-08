#!/bin/bash
# agents-root.sh — shared resolver for "where does the live agents tier live"
# (dotfiles-tm0w). Four call sites previously hardcoded a `$HOME/dotfiles/...`
# path directly and degraded SILENTLY when it went missing:
#   - pre-commit-checks.sh   (agents/scheduler/pulse-ledger-lint.py)
#   - post-write-skill.sh    (agents/AGENTS.md, for citation checks)
#   - claude-identity-wrapper.sh (agents/lib/tmux-pane-resolve.sh)
#   - session-start.sh       (claude/settings.json, the tracked template)
# The demesne split (epic dotfiles-agent-brain-split-ezeu) moves that content
# to a private `~/demesne` repo indirected through a `~/.agents` symlink, and
# a silently-missed path there would disarm all four checks with the working
# tree looking completely clean.
#
# agents_root [<subtier>]: print the live root for <subtier> on stdout and
# return 0, or print NOTHING and return 1 if no candidate resolves. Never
# prints a diagnostic itself — library code stays silent so each CALLER picks
# its own failure convention (some hooks warn-and-continue, some must never
# block; see /commit's mandate that a PreToolUse hook stays side-effect-free).
#
# <subtier> defaults to "agents" (agents/AGENTS.md, agents/lib/…,
# agents/scheduler/…) and also accepts "claude" (claude/settings.json,
# claude/statusline.sh) — the OTHER subtree the epic names as agent-brain
# content (dotfiles/claude/, 9 files). One resolver, parameterized, rather
# than a second near-identical function.
#
# Resolution order, per subtier:
#   1. $HOME/.agents/<subtier> — the shape VERIFIED on-disk 2026-08-08 against
#      the already-seeded ~/demesne (dotfiles-demesne-repo-seed-clxe):
#      ~/demesne/agents/AGENTS.md, ~/demesne/claude/settings.json. Once
#      ~/.agents -> ~/demesne lands (dotfiles-retarget-claude-symlinks-860z,
#      still blocked as of this writing), this is the real path.
#   2. $HOME/.agents itself, for subtier=agents only — tolerates a flatter
#      indirection (~/.agents pointed straight at the agents/ dir) should the
#      cutover bead land differently than currently planned. Not offered for
#      "claude", since a flat "~/.agents IS the claude tier" reading makes no
#      sense next to the AGENTS-tier default.
#   3. $HOME/dotfiles/<subtier> — the pre-split location. Always the final
#      fallback, and it is what every one of the four call sites already
#      hardcoded before this fix.
#
# EITHER ~/.agents candidate is accepted ONLY if it looks like the REAL tier
# content, never on mere directory existence: ~/.agents currently holds an
# UNRELATED aaif skill-lock (.skill-lock.json + skills/, evicted only at
# 860z's cutover — see decision dotfiles-32j4). Treating that as the tier
# would silently disarm every caller TODAY, before the split has even
# started, which is the exact failure class this resolver exists to close.
agents_root() {
  local subtier="${1:-agents}"
  local marker
  case "$subtier" in
    agents) marker="AGENTS.md" ;;
    claude) marker="settings.json" ;;
    *)      marker="" ;;
  esac

  local candidate="$HOME/.agents/$subtier"
  if [ -d "$candidate" ] && { [ -n "$marker" ] && [ -e "$candidate/$marker" ]; }; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [ "$subtier" = "agents" ] && [ -d "$HOME/.agents" ] \
     && { [ -f "$HOME/.agents/AGENTS.md" ] || [ -d "$HOME/.agents/lib" ]; }; then
    printf '%s\n' "$HOME/.agents"
    return 0
  fi

  local fallback="$HOME/dotfiles/$subtier"
  if [ -d "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  return 1
}
