#!/usr/bin/env bash
# zig-computer.distribute.sh
#
# Distribute the dotfiles harness (skills, hooks, CLAUDE.md, optional
# settings) into a destination directory shaped like a coworker's
# `~/.claude/`. The destination ends up with:
#
#   <dest>/
#     CLAUDE.md          <- copy of dotfiles/agents/AGENTS.md
#     .claude/
#       skills/<name>/SKILL.md (and supporting files)
#       hooks/*.sh
#       settings.json    <- copy of dotfiles/claude/settings.json (optional)
#
# Default destination: ~/linearb/skills (a shared LinearB-team git repo).
#
# Usage:
#   zig-computer.distribute.sh                 # distribute to ~/linearb/skills
#   zig-computer.distribute.sh /path/to/dest   # custom destination
#   zig-computer.distribute.sh --dry-run       # show what would happen
#   zig-computer.distribute.sh --no-settings   # skip settings.json
#
# The destination's existing CLAUDE.md / skills/ / hooks/ are wiped and
# replaced. settings.json is only overwritten when --settings is set
# (default: copy if missing, otherwise leave alone — settings tend to
# be coworker-specific).

set -euo pipefail

# ---- Parse args -------------------------------------------------------

DRY_RUN=0
COPY_SETTINGS="if-missing"   # one of: always | if-missing | never
DEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --no-settings) COPY_SETTINGS="never"; shift ;;
    --settings)    COPY_SETTINGS="always"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [ -n "$DEST" ]; then
        echo "Multiple destinations given: '$DEST' and '$1'" >&2
        exit 1
      fi
      DEST="$1"
      shift
      ;;
  esac
done

DEST="${DEST:-$HOME/linearb/skills}"
SRC="$(cd "$(dirname "$0")" && pwd)"

# ---- Verify source layout --------------------------------------------

for required in "$SRC/agents/AGENTS.md" "$SRC/agents/skills" "$SRC/agents/hooks"; do
  if [ ! -e "$required" ]; then
    echo "Source layout broken: missing $required" >&2
    exit 1
  fi
done

# ---- Resolve dest layout ---------------------------------------------

if [ ! -d "$DEST" ]; then
  echo "Destination doesn't exist: $DEST" >&2
  echo "Create it first (e.g., 'mkdir -p $DEST') or pass a path that does." >&2
  exit 1
fi

DEST_CLAUDE_DIR="$DEST/.claude"
DEST_SKILLS_DIR="$DEST_CLAUDE_DIR/skills"
DEST_HOOKS_DIR="$DEST_CLAUDE_DIR/hooks"
DEST_CLAUDE_MD="$DEST/CLAUDE.md"
DEST_SETTINGS="$DEST_CLAUDE_DIR/settings.json"

# ---- Helpers ---------------------------------------------------------

run() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $*"
  else
    echo "  $*"
    eval "$@"
  fi
}

note() { echo "$*"; }

# ---- Plan + execute --------------------------------------------------

note "=== zig-computer distribute ==="
note "  source: $SRC"
note "  dest:   $DEST"
note "  mode:   $([ "$DRY_RUN" = "1" ] && echo dry-run || echo apply)"
note ""

note "[1/4] CLAUDE.md (from agents/AGENTS.md)"
run "cp '$SRC/agents/AGENTS.md' '$DEST_CLAUDE_MD'"

note "[2/4] skills/ (clean + copy paragon set)"
run "rm -rf '$DEST_SKILLS_DIR'"
run "mkdir -p '$DEST_SKILLS_DIR'"
run "cp -R '$SRC/agents/skills/.' '$DEST_SKILLS_DIR/'"

note "[3/4] hooks/ (clean + copy)"
run "rm -rf '$DEST_HOOKS_DIR'"
run "mkdir -p '$DEST_HOOKS_DIR'"
run "cp -R '$SRC/agents/hooks/.' '$DEST_HOOKS_DIR/'"

note "[4/4] settings.json"
SETTINGS_SRC="$SRC/claude/settings.json"
if [ ! -f "$SETTINGS_SRC" ]; then
  note "  (no settings.json in source — skipping)"
elif [ "$COPY_SETTINGS" = "never" ]; then
  note "  (--no-settings — skipping)"
elif [ "$COPY_SETTINGS" = "always" ]; then
  run "mkdir -p '$DEST_CLAUDE_DIR'"
  run "cp '$SETTINGS_SRC' '$DEST_SETTINGS'"
elif [ -f "$DEST_SETTINGS" ]; then
  note "  (dest already has settings.json — leaving alone; pass --settings to overwrite)"
else
  run "mkdir -p '$DEST_CLAUDE_DIR'"
  run "cp '$SETTINGS_SRC' '$DEST_SETTINGS'"
fi

note ""
note "=== summary ==="
if [ "$DRY_RUN" = "1" ]; then
  note "  dry-run only — no changes made"
else
  SKILL_COUNT=$(/usr/bin/find "$DEST_SKILLS_DIR" -name SKILL.md 2>/dev/null | wc -l)
  HOOK_COUNT=$(/usr/bin/find "$DEST_HOOKS_DIR" -type f 2>/dev/null | wc -l)
  note "  $SKILL_COUNT skills, $HOOK_COUNT hooks distributed to $DEST"
  note ""
  note "  Next steps for the destination repo:"
  note "    cd '$DEST'"
  note "    git status"
  note "    git diff"
  note "    git add -A && git commit -m ':outbox_tray: distribute: sync from dotfiles'"
  note "    git push"
fi
