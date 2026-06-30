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
# handoff" continuity. MUST resolve via `-t "$TMUX_PANE"`: the bare
# `display-message` returns the CLIENT's currently-focused window (wherever
# Andrew happens to be looking), not THIS session's own window (verified
# 2026-06-30). No tmux / no pane -> empty key -> legacy single file.

# _handoff_key -> the glyph-stripped window name on stdout, or non-zero if it
# can't be resolved (not in tmux, no pane, tmux missing).
_handoff_key() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  local tb w
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  w=$("$tb" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null \
        | sed -E 's/^(🧠|✅|🔔|🌀) ?//')
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
