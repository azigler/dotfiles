#!/bin/bash
# handoff-path.sh — per-window scoping for the /offboard <-> /onboard bracket.
#
# Sourced by the /onboard, /offboard, /pulse skill bash snippets AND by the
# session-end.sh hook, so the path logic lives in ONE place.
#
# Why: the offboard/onboard bracket assumes ONE durable session per project.
# The pulse model breaks that — ~/explore runs >=2 long-lived sessions in
# different tmux windows (the explore-pulse window + the directed-elevate
# window). All three single-slot artifacts then collide: refs/session-handoff.md
# (last writer wins -> the other session re-onboards from the wrong doc),
# .offboard-pending, and .claude/last-offboard-session.
#
# Fix: a project that runs multiple durable sessions OPTS IN by carrying
# refs/.handoff-per-window. Then these helpers scope the three artifacts by a
# per-session KEY. Without the marker, every path is the legacy single-file
# form, so every other (single-session) project is completely untouched.
#
# The key is the tmux WINDOW NAME (glyph-stripped). It is the only identity
# stable across BOTH compaction AND /clear — the session id changes on /clear,
# which would break the pulse model's "re-onboard in the same window from the
# handoff" continuity.
#
# Resolution order (see _handoff_key):
#   1. $TMUX_PANE, TARGETED (`-t "$TMUX_PANE"`) — fast path when the pane env
#      var is present.
#   2. PROCESS-ANCESTRY fallback — Claude Code does NOT propagate $TMUX/$TMUX_PANE
#      into the Bash-tool shell, so even a legitimate FOREGROUND pane-bound
#      session sees an empty $TMUX_PANE (verified 2026-07-13, a fresh post-/clear
#      session in the explore window re-onboarded from elevate's note because of
#      exactly this). The window identity is not actually lost: the pane's shell
#      is a genuine ANCESTOR of this process, so we recover it by walking parent
#      PIDs and matching tmux pane_pids. Robust across /clear (new session, same
#      window) AND env loss.
# NEVER use a bare/untargeted `display-message` — it returns the CLIENT's
# currently-focused window (wherever Andrew happens to be looking), not THIS
# session's own window (verified 2026-06-30). No tmux, or a truly-detached
# session with no pane ancestor -> empty key -> legacy single file.

# Pane/window resolution — including the background-forked-session case where
# $TMUX_PANE is absent (Claude Code's `bg-pty-host --fork-session`) — lives in
# the shared lib tmux-pane-resolve.sh, sibling to this file. Source it robustly
# across bash AND zsh: in bash ${BASH_SOURCE[0]} is this file; in zsh (what
# Claude Code's Bash tool runs) BASH_SOURCE is empty, so we fall to $0, which a
# sourced zsh file sets to its own path.
_handoff_self="${BASH_SOURCE[0]:-$0}"
_handoff_dir="$(cd "$(dirname -- "$_handoff_self")" 2>/dev/null && pwd)"
[ -n "$_handoff_dir" ] && [ -f "$_handoff_dir/tmux-pane-resolve.sh" ] && . "$_handoff_dir/tmux-pane-resolve.sh"
unset _handoff_self _handoff_dir

# _handoff_key -> the glyph-stripped window name on stdout, or non-zero if it
# can't be resolved. Delegates to the shared resolver; if that lib somehow
# failed to load, degrades to the $TMUX_PANE-targeted path (the pre-2026-07-13
# legacy behavior — a bare/untargeted display-message would return the CLIENT's
# focused window, so we never do that).
_handoff_key() {
  if command -v tmux_resolve_window >/dev/null 2>&1; then
    tmux_resolve_window
    return
  fi
  [ -n "${TMUX_PANE:-}" ] || return 1
  local tb w
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  w=$("$tb" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null \
        | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//')
  [ -n "$w" ] || return 1
  printf '%s' "$w"
}

# _handoff_suffix <dir> -> "--<window>" when <dir> opts in AND a window key
# resolves; else "" (legacy single file).
_handoff_suffix() {
  local dir="${1:-.}" k
  [ -f "$dir/refs/.handoff-per-window" ] || { printf ''; return; }
  k=$(_handoff_key) || { printf ''; return; }
  printf -- '--%s' "$k"
}

# Writers — the canonical path for THIS session in <dir> (default cwd).
handoff_path()          { local d="${1:-.}"; printf '%s/refs/session-handoff%s.md' "$d" "$(_handoff_suffix "$d")"; }
offboard_pending_path() { local d="${1:-.}"; printf '%s/.offboard-pending%s'        "$d" "$(_handoff_suffix "$d")"; }
last_offboard_path()    { local d="${1:-.}"; printf '%s/.claude/last-offboard-session%s' "$d" "$(_handoff_suffix "$d")"; }

# Reader — prefer the window-scoped handoff, fall back to the legacy single
# file (covers the transition before this session has written its scoped file,
# and non-opted-in projects). /onboard reads THIS.
handoff_read_path() {
  local d="${1:-.}" p; p=$(handoff_path "$d")
  if [ -f "$p" ]; then printf '%s' "$p"; else printf '%s/refs/session-handoff.md' "$d"; fi
}
