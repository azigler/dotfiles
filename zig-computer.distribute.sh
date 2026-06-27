#!/usr/bin/env bash
# zig-computer.distribute.sh
#
# Distribute the dotfiles paragon skill set to a shared destination.
#
# Two layouts:
#
#   plugin mode (DEFAULT) — the lb-marketing plugin marketplace.
#     Skills land directly in <plugin>/skills/, served to the team over
#     an MCP plugin in Claude apps. Only skills are distributed; the
#     plugin manifest (.claude-plugin/plugin.json), marketplace manifest,
#     README, hooks, CLAUDE.md and settings are NOT touched by this script.
#     Default destination: ~/linearb/plugins/linearb-marketing
#
#       <plugin>/
#         skills/<name>/SKILL.md (and supporting files)
#         skills/.native-manifest    <- destination-native skills, preserved
#
#   tree mode (--tree) — legacy "coworker ~/.claude/" layout. Distributes
#     skills + hooks + CLAUDE.md + settings into <dest>/.claude/. Kept for
#     tarball/coworker-laptop use. Default destination: ~/linearb/skills
#
#       <dest>/
#         CLAUDE.md          <- copy of dotfiles/agents/AGENTS.md
#         .claude/
#           skills/<name>/SKILL.md
#           hooks/*.sh
#           settings.json    <- copy of dotfiles/claude/settings.json (optional)
#
# Usage:
#   zig-computer.distribute.sh                 # plugin mode -> ~/linearb/plugins/linearb-marketing
#   zig-computer.distribute.sh --plugin DIR    # plugin mode -> DIR
#   zig-computer.distribute.sh --tree [DIR]    # legacy tree -> DIR (default ~/linearb/skills)
#   zig-computer.distribute.sh --dry-run       # show what would happen
#   zig-computer.distribute.sh --no-settings   # (tree mode) skip settings.json
#
# In both modes the destination's skills/ is wiped and replaced, EXCEPT
# destination-native skills listed in <skills>/.native-manifest (one per
# line) — those are preserved across runs. Private-reference blocks
# (machine-local pointers wrapped in <!-- private-start -->/<!-- private-end -->)
# are stripped from the distributed copies.

set -euo pipefail

# ---- Parse args -------------------------------------------------------

DRY_RUN=0
COPY_SETTINGS="if-missing"   # one of: always | if-missing | never  (tree mode only)
MODE="plugin"                # plugin | tree
DEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --no-settings) COPY_SETTINGS="never"; shift ;;
    --settings)    COPY_SETTINGS="always"; shift ;;
    --plugin)      MODE="plugin"; shift ;;
    --tree)        MODE="tree"; shift ;;
    -h|--help)
      sed -n '2,46p' "$0" | sed 's/^# \?//'
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

SRC="$(cd "$(dirname "$0")" && pwd)"

# ---- Verify source layout --------------------------------------------

for required in "$SRC/agents/AGENTS.md" "$SRC/agents/skills" "$SRC/agents/hooks"; do
  if [ ! -e "$required" ]; then
    echo "Source layout broken: missing $required" >&2
    exit 1
  fi
done

# ---- Resolve dest layout (mode-dependent) ----------------------------

if [ "$MODE" = "plugin" ]; then
  DEST="${DEST:-$HOME/linearb/plugins/linearb-marketing}"
else
  DEST="${DEST:-$HOME/linearb/skills}"
fi

if [ ! -d "$DEST" ]; then
  echo "Destination doesn't exist: $DEST" >&2
  echo "Create it first (e.g., 'mkdir -p $DEST') or pass a path that does." >&2
  exit 1
fi

if [ "$MODE" = "plugin" ]; then
  DEST_SKILLS_DIR="$DEST/skills"
else
  DEST_CLAUDE_DIR="$DEST/.claude"
  DEST_SKILLS_DIR="$DEST_CLAUDE_DIR/skills"
  DEST_HOOKS_DIR="$DEST_CLAUDE_DIR/hooks"
  DEST_CLAUDE_MD="$DEST/CLAUDE.md"
  DEST_SETTINGS="$DEST_CLAUDE_DIR/settings.json"
fi

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
note "  mode:   $MODE"
note "  dest:   $DEST"
note "  apply:  $([ "$DRY_RUN" = "1" ] && echo dry-run || echo apply)"
note ""

# --- skills/ (both modes): clean + copy paragon set, preserving natives ---
# Destination-native skills: a destination may maintain skills of its own
# that do NOT come from dotfiles (e.g. linearb-positioning / campaign-builder
# in the plugin). List them one-per-line in <skills>/.native-manifest and
# the clean step preserves them across distributes.
note "[skills] clean + copy paragon set"
NATIVE_MANIFEST="$DEST_SKILLS_DIR/.native-manifest"
NATIVE_TMP=""
if [ -f "$NATIVE_MANIFEST" ]; then
  NATIVE_TMP="$(mktemp -d)"
  note "      preserving destination-native skills (.native-manifest):"
  while IFS= read -r native; do
    case "$native" in ''|'#'*) continue;; esac
    if [ -d "$DEST_SKILLS_DIR/$native" ]; then
      note "        - $native"
      run "cp -R '$DEST_SKILLS_DIR/$native' '$NATIVE_TMP/$native'"
    fi
  done < "$NATIVE_MANIFEST"
  run "cp '$NATIVE_MANIFEST' '$NATIVE_TMP/.native-manifest'"
fi
run "rm -rf '$DEST_SKILLS_DIR'"
run "mkdir -p '$DEST_SKILLS_DIR'"
run "cp -R '$SRC/agents/skills/.' '$DEST_SKILLS_DIR/'"
if [ -n "$NATIVE_TMP" ]; then
  run "cp -R '$NATIVE_TMP/.' '$DEST_SKILLS_DIR/'"
  run "rm -rf '$NATIVE_TMP'"
fi
# Strip private-reference blocks from the DISTRIBUTED copies only —
# pointers to machine-local files (~/linearb/refs/..., personal paths)
# that a teammate's clone can't resolve. Convention: everything between
# <!-- private-start --> and <!-- private-end --> (inclusive) is removed.
# The dotfiles originals keep the blocks.
run "find '$DEST_SKILLS_DIR' -name '*.md' -exec sed -i '/<!-- private-start -->/,/<!-- private-end -->/d' {} +"

# --- tree mode only: hooks + CLAUDE.md + settings -----------------------
if [ "$MODE" = "tree" ]; then
  note "[CLAUDE.md] from agents/AGENTS.md"
  run "cp '$SRC/agents/AGENTS.md' '$DEST_CLAUDE_MD'"

  note "[hooks] clean + copy"
  run "rm -rf '$DEST_HOOKS_DIR'"
  run "mkdir -p '$DEST_HOOKS_DIR'"
  run "cp -R '$SRC/agents/hooks/.' '$DEST_HOOKS_DIR/'"

  note "[settings.json]"
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
fi

note ""
note "=== summary ==="
if [ "$DRY_RUN" = "1" ]; then
  note "  dry-run only — no changes made"
else
  SKILL_COUNT=$(/usr/bin/find "$DEST_SKILLS_DIR" -name SKILL.md 2>/dev/null | wc -l)
  if [ "$MODE" = "plugin" ]; then
    note "  $SKILL_COUNT skills distributed to $DEST_SKILLS_DIR"
    note ""
    note "  Next steps for the plugin repo:"
    note "    cd '$(cd "$DEST/.." && pwd)'   # marketplace root"
    note "    # bump linearb-marketing/.claude-plugin/plugin.json version if behavior changed"
    note "    python3 .github/workflows/validate_manifests.py   # confirm manifests still valid"
    note "    git add -A && git commit -m ':outbox_tray: distribute: sync skills from dotfiles'"
    note "    git push"
  else
    HOOK_COUNT=$(/usr/bin/find "$DEST_HOOKS_DIR" -type f 2>/dev/null | wc -l)
    note "  $SKILL_COUNT skills, $HOOK_COUNT hooks distributed to $DEST"
    note ""
    note "  Next steps for the destination repo:"
    note "    cd '$DEST'"
    note "    git add -A && git commit -m ':outbox_tray: distribute: sync from dotfiles'"
    note "    git push"
  fi
fi
