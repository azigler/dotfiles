#!/bin/bash
# lib/always-loaded.sh — resolve + fingerprint the ALWAYS-LOADED context tier.
#
# THE DEFECT THIS EXISTS FOR (explore-6wwu, decision explore-0z6r).
# CLAUDE.md / MEMORY.md / skill descriptions are read from disk ONCE, when a
# session starts, and the in-memory copy is what every later request carries. A
# durable session (a pulse window, an elevate window, a long interactive
# session) then runs for hours or days on that snapshot. An edit Zig makes is
# invisible to it, and NOTHING announces the divergence.
#
# The live instance: a session held BOTH generations of the effort policy at
# once — one saying xhigh is the session default, one saying xhigh is never a
# session setting — because ~/dotfiles/agents/AGENTS.md changed after that
# session's snapshot. One of those two rules tells the agent to run at xhigh,
# which on Opus 5 silently kills WebSearch.
#
# This lib is the shared half of the detector: session-start.sh captures a
# manifest, stop-always-loaded-check.sh re-computes it and diffs. Neither
# repairs anything and neither blocks — per the decision, the harm is the
# SILENCE, so the fix is an observable.
#
# ── TWO TRAPS, both load-bearing ────────────────────────────────────────────
#
# 1. mtime alone would NEVER have caught the live instance. ~/.claude/CLAUDE.md
#    is a SYMLINK to ~/dotfiles/agents/AGENTS.md, and `stat -c %Y` on a symlink
#    reports the LINK's mtime, not the target's. On this machine the link says
#    Jun 10 while the target says Jul 26 — a naive detector would have sat
#    silent through exactly the event it was built for. So: hash the CONTENT
#    (md5sum follows symlinks) and read mtime DEREFERENCED — `stat -Lc %Y` on
#    GNU, `stat -Lf %m` on BSD/macOS (see trap 3 at _al_mtime).
#
# 2. Hashing a whole SKILL.md would fire on every skill-body edit, which is
#    NOT always-loaded context — only the frontmatter (name/description/
#    when_to_use) is injected up front. Bodies get edited constantly, so
#    whole-file hashing would be a nag generator and would train everyone to
#    ignore the warning. Skills are therefore fingerprinted on their YAML
#    frontmatter ONLY.
#
# Manifest record (TAB-separated, one per file):
#     <kind>\t<hash>\t<mtime-epoch>\t<path>
# kind ∈ global-claude | project-claude | memory | skill
#
# Usage:
#     . lib/always-loaded.sh
#     always_loaded_manifest [cwd]     # prints the manifest to stdout
#
# Everything resolves under $HOME, so a test can point HOME at a temp dir.

# Hash a file's full content. Follows symlinks (that is the point — see trap 1).
_al_hash_file() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" 2>/dev/null | awk '{print $1}'
  else
    cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'
  fi
}

# Hash ONLY the YAML frontmatter block of a SKILL.md — the part that is
# actually always-loaded (see trap 2). A file with no leading `---` hashes to
# the empty string's hash, which is stable, so it still diffs correctly.
_al_hash_frontmatter() {
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    { print }
  ' "$1" 2>/dev/null | _al_hash_stdin
}

_al_hash_stdin() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | awk '{print $1}'
  else
    cksum | awk '{print $1"-"$2}'
  fi
}

# DEREFERENCED mtime (trap 1). Missing file / broken link -> 0.
#
# TRAP 3: `stat -Lc %Y` is GNU-ONLY. BSD/macOS stat has no -c at all, so on a
# Mac EVERY call failed, the old blanket `2>/dev/null` hid the usage error, and
# `|| echo 0` handed back 0 as the mtime of every file — staleness detection
# silently degraded fleet-wide (dotfiles-yr2h). Detect the flavour ONCE at
# source time and define the function accordingly; never stack two suppressed
# stat calls, which would make the same failure invisible all over again.
# The `2>/dev/null` below is on the PROBE only — a genuine capability test.
if stat -Lc %Y . >/dev/null 2>&1; then
  _AL_STAT_FLAVOUR=gnu
  _al_mtime() { stat -Lc %Y "$1" || echo 0; }   # GNU coreutils
elif stat -Lf %m . >/dev/null 2>&1; then
  _AL_STAT_FLAVOUR=bsd
  _al_mtime() { stat -Lf %m "$1" || echo 0; }   # BSD / macOS
else
  _AL_STAT_FLAVOUR=none
  _al_mtime() { echo 0; }                       # no usable stat — last resort
fi

# _al_emit <kind> <path> <full|frontmatter>
_al_emit() {
  local kind=$1 path=$2 mode=$3 hash mtime
  [ -f "$path" ] || return 0   # -f follows symlinks; a broken link is skipped
  case "$mode" in
    frontmatter) hash=$(_al_hash_frontmatter "$path") ;;
    *)           hash=$(_al_hash_file "$path") ;;
  esac
  [ -n "$hash" ] || return 0
  mtime=$(_al_mtime "$path")
  printf '%s\t%s\t%s\t%s\n' "$kind" "$hash" "$mtime" "$path"
}

# always_loaded_manifest [cwd]
always_loaded_manifest() {
  local cwd=${1:-$PWD}
  local d s slug
  local -a chain=()

  # 1. The global tier (a symlink into dotfiles on this machine).
  _al_emit global-claude "$HOME/.claude/CLAUDE.md" full

  # 2. The project CLAUDE.md chain — cwd and every ancestor up to $HOME,
  #    outermost first (the order Claude Code layers them).
  d=$cwd
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    chain=("$d" "${chain[@]}")
    [ "$d" = "$HOME" ] && break
    d=$(dirname "$d")
  done
  for d in "${chain[@]}"; do
    _al_emit project-claude "$d/CLAUDE.md" full
    _al_emit project-claude "$d/CLAUDE.local.md" full
  done

  # 3. The auto-memory tier for this project slug (cwd with / -> -).
  slug=${cwd//\//-}
  _al_emit memory "$HOME/.claude/projects/$slug/memory/MEMORY.md" full

  # 4. Skill DESCRIPTIONS — global paragon set + this project's own skills.
  #    Frontmatter only (trap 2). Unmatched globs fail the -f test and vanish.
  for s in "$HOME"/.claude/skills/*/SKILL.md "$cwd"/.claude/skills/*/SKILL.md; do
    _al_emit skill "$s" frontmatter
  done
}

# Render a path for humans: $HOME -> ~, and name the real file behind a symlink
# (the AGENTS.md case, where the link's own name hides where the edit landed).
always_loaded_pretty_path() {
  local p=$1 real display
  display=${p/#$HOME/\~}
  if [ -L "$p" ]; then
    real=$(readlink -f "$p" 2>/dev/null)
    if [ -n "$real" ] && [ "$real" != "$p" ]; then
      printf '%s (real file: %s)' "$display" "${real/#$HOME/\~}"
      return 0
    fi
  fi
  printf '%s' "$display"
}

# "3 minutes ago" / "2 hours ago" / "4 days ago" from an epoch mtime.
always_loaded_age() {
  local mtime=$1 now delta
  now=$(date +%s)
  delta=$(( now - mtime ))
  [ "$delta" -lt 0 ] && delta=0
  if   [ "$delta" -lt 60 ];    then printf '%s seconds ago' "$delta"
  elif [ "$delta" -lt 3600 ];  then printf '%s minutes ago' "$(( delta / 60 ))"
  elif [ "$delta" -lt 86400 ]; then printf '%s hours ago'   "$(( delta / 3600 ))"
  else                              printf '%s days ago'    "$(( delta / 86400 ))"
  fi
}
