#!/usr/bin/env bash
# sync-tick-settings.sh — keep ~/.claude-tick/settings.json's `model` + `env`
# keys in sync with the shared dotfiles/claude/settings.json (dotfiles-qby3).
#
# WHY THIS FILE CANNOT BE A SYMLINK (jail-bind evidence)
# --------------------------------------------------------
# Every other seat (~/.claude, ~/.claude-work) has settings.json as a symlink
# straight to dotfiles/claude/settings.json (claude-seat-link.sh). ~/.claude-tick
# is different: it is the ISOLATED config dir tick-jailed.sh
# (~/explore/tools/tick-jail/tick-jailed.sh) points the `dive`/`digest` pulse
# ticks at whenever ~/.claude-tick/.credentials.json is non-empty
# (TICK_JAIL_ISOLATED=1). In that mode the launcher does:
#
#   --ro-bind "$HOME/.claude/settings.json" "$TICK_CONFIG_DIR/settings.json"
#
# — a bwrap ro-bind mount of the HOST's real settings.json (which resolves
# through ~/.claude/settings.json's own symlink to dotfiles/claude/settings.json)
# ONTO the tick seat's settings.json path. bwrap's --ro-bind REFUSES to bind
# onto a symlink destination. Measured 2026-08-08, replacing the live file
# with a symlink and launching the jail (TICK_JAIL_EXEC test seam):
#
#   bwrap: Can't create file at /home/ubuntu/.claude-tick/settings.json:
#   No such file or directory
#
# That failure is a hard launch abort — every dive/digest tick would die at
# the bwrap step. So ~/.claude-tick/settings.json MUST stay a real,
# non-symlink file; this script is how it stays a CURRENT one instead of a
# stale one, and is also what any UNJAILED invocation on that config dir
# (`CLAUDE_CONFIG_DIR=~/.claude-tick claude …`, no bwrap in the path) actually
# reads directly.
#
# Usage:
#   sync-tick-settings.sh              regenerate the managed file (idempotent)
#   sync-tick-settings.sh --check      read-only: exit 1 + loud diff on drift,
#                                       exit 0 (silent-ish) if in sync or absent
#
# TICK_SETTINGS / SHARED_SETTINGS are overridable for tests.
set -euo pipefail

TICK_SETTINGS="${TICK_SETTINGS:-$HOME/.claude-tick/settings.json}"
SHARED_SETTINGS="${SHARED_SETTINGS:-$HOME/dotfiles/claude/settings.json}"
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) echo "sync-tick-settings: unknown arg $arg" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "sync-tick-settings: jq not found" >&2; exit 1; }
[ -f "$SHARED_SETTINGS" ] || { echo "sync-tick-settings: missing shared settings $SHARED_SETTINGS" >&2; exit 1; }

# A box with no tick seat at all is not drift — nothing to check or sync.
if [ ! -e "$TICK_SETTINGS" ]; then
  if [ "$CHECK" -eq 1 ]; then
    echo "sync-tick-settings: $TICK_SETTINGS absent — no tick seat on this box, nothing to check"
    exit 0
  fi
  echo "sync-tick-settings: $TICK_SETTINGS absent — refusing to create a seat that was never set up" >&2
  echo "  (a tick seat needs its own .credentials.json login first; see tick-jailed.sh)" >&2
  exit 1
fi

# The tick file must never be a symlink (see the header) — refuse loudly
# rather than silently overwrite whatever it points at.
if [ -L "$TICK_SETTINGS" ]; then
  echo "sync-tick-settings: $TICK_SETTINGS is a SYMLINK — this breaks the tick-jail bwrap bind (see header). Refusing." >&2
  exit 1
fi

if [ ! -s "$TICK_SETTINGS" ] || ! jq -e . "$TICK_SETTINGS" >/dev/null 2>&1; then
  echo "sync-tick-settings: $TICK_SETTINGS is empty or not valid JSON" >&2
  exit 1
fi
jq -e . "$SHARED_SETTINGS" >/dev/null 2>&1 || { echo "sync-tick-settings: $SHARED_SETTINGS is not valid JSON" >&2; exit 1; }

# Diff ONLY the two keys that matter for model/env correctness — everything
# else in the tick file (skipDangerousModePermissionPrompt, theme, tui, …) is
# seat-local and deliberately not touched by this script.
DIVERGED=$(jq -rs '
  (.[0] // {}) as $tick | (.[1] // {}) as $shared
  | ["model", "env"]
  | map(select(($tick[.] // null) != ($shared[.] // null)))
  | join(", ")
' "$TICK_SETTINGS" "$SHARED_SETTINGS")

if [ -z "$DIVERGED" ]; then
  [ "$CHECK" -eq 1 ] && echo "sync-tick-settings: $TICK_SETTINGS model/env are in sync with $SHARED_SETTINGS"
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "⚠ sync-tick-settings: $TICK_SETTINGS has DIVERGED from $SHARED_SETTINGS on: $DIVERGED" >&2
  echo "  live tick:   $(jq -c '{model, env}' "$TICK_SETTINGS")" >&2
  echo "  shared:      $(jq -c '{model, env}' "$SHARED_SETTINGS")" >&2
  echo "  Fix: bash ~/dotfiles/agents/bin/sync-tick-settings.sh" >&2
  exit 1
fi

# --- regenerate: overlay model+env from shared onto the tick file's other keys
TMP=$(mktemp "${TICK_SETTINGS}.XXXXXX")
jq -s '
  (.[0]) as $tick | (.[1]) as $shared
  | $tick
  | (if ($shared | has("model")) then .model = $shared.model else del(.model) end)
  | (if ($shared | has("env")) then .env = $shared.env else del(.env) end)
' "$TICK_SETTINGS" "$SHARED_SETTINGS" > "$TMP"

chmod u+w "$TICK_SETTINGS" 2>/dev/null || true
mv -f "$TMP" "$TICK_SETTINGS"
chmod 444 "$TICK_SETTINGS"
echo "sync-tick-settings: regenerated $TICK_SETTINGS (model/env now match $SHARED_SETTINGS)"
