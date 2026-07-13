#!/bin/bash
# tmux-pane-resolve.sh — resolve THIS process's own tmux pane / window even when
# $TMUX_PANE is not present in the environment.
#
# Why this exists (root-caused 2026-07-13, Claude Code 2.1.207):
#   Claude Code's background-session feature runs the session under
#   `claude bg-pty-host --fork-session`, which forks it onto a DETACHED daemon
#   PTY (/tmp/cc-daemon-*/pty/<job>.sock) instead of the tmux pane's PTY. The
#   forked session is still DISPLAYED in a tmux pane and its process tree still
#   descends from that pane's shell, but it does NOT inherit $TMUX/$TMUX_PANE.
#   Every $TMUX_PANE-dependent surface then breaks silently:
#     - the lexicon glyph hook (tmux-status.sh) can't find the window to rename,
#       so the 🧠/✅/🔔 state never updates;
#     - per-window handoff scoping (handoff-path.sh) can't key the session, so
#       /onboard reads the wrong window's handoff note.
#   A normal in-pane interactive session is unaffected ($TMUX_PANE is set).
#
# The fix: the pane's shell is a genuine ANCESTOR of this process, so we recover
# the pane by walking the parent-PID chain and matching tmux pane_pids — no
# dependency on the env var. Env fast-path first (cheap when $TMUX_PANE IS set).
#
# NEVER use a bare/untargeted `tmux display-message` to identify "my" window: it
# returns the CLIENT's currently-focused window (wherever the user is looking),
# not this session's own (verified 2026-06-30).
#
# All parsing is awk-based, NOT shell word-splitting: this file is SOURCED into
# whatever shell the caller runs, and Claude Code's Bash tool runs ZSH, where
# unquoted `set -- $x` does not word-split (SH_WORD_SPLIT off) — that silently
# returned empty (found 2026-07-13).

# _tpr_ppid <pid> -> parent PID. /proc first — the only method that works inside
# Claude Code's sandboxed Bash, where `ps` is blocked — then `ps` (macOS/BSD
# have no /proc). The comm field in /proc/<pid>/stat is parenthesized and may
# contain spaces, so awk strips through the LAST ') ' before reading ppid.
_tpr_ppid() {
  local pid="$1"
  if [ -r "/proc/$pid/stat" ]; then
    awk '{ s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[2] }' "/proc/$pid/stat" 2>/dev/null
  else
    ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
  fi
}

# _tpr_by_ancestry <tmux-format> -> for the first ancestor PID that is a tmux
# pane_pid, print that pane's <tmux-format> attribute. Non-zero if none matches
# (no tmux, or a truly detached session with no pane ancestor).
_tpr_by_ancestry() {
  local fmt="$1" tb panes pid hit i=0
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  panes=$("$tb" list-panes -a -F "#{pane_pid} $fmt" 2>/dev/null) || return 1
  [ -n "$panes" ] || return 1
  pid=$$
  while [ -n "$pid" ] && [ "$pid" != 1 ] && [ "$i" -lt 24 ]; do
    hit=$(printf '%s\n' "$panes" | awk -v t="$pid" '$1==t{$1="";sub(/^ /,"");print;exit}')
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
    pid=$(_tpr_ppid "$pid"); [ -n "$pid" ] || return 1
    i=$((i+1))
  done
  return 1
}

# tmux_resolve_pane -> the pane_id (e.g. %8) for THIS session's pane, on stdout.
# $TMUX_PANE fast-path, then ancestry. Non-zero if it can't be resolved.
tmux_resolve_pane() {
  if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; return 0; fi
  _tpr_by_ancestry '#{pane_id}'
}

# tmux_resolve_window -> the glyph-stripped window name for THIS session's pane.
# Targeted display-message on $TMUX_PANE when set, else ancestry. Non-zero if
# it can't be resolved. Strips the tmux-lexicon glyph prefix (🧠✅🔔🌀📬).
tmux_resolve_window() {
  local tb w
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  if [ -n "${TMUX_PANE:-}" ]; then
    w=$("$tb" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
  fi
  [ -n "${w:-}" ] || w=$(_tpr_by_ancestry '#{window_name}')
  w=$(printf '%s' "${w:-}" | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//')
  [ -n "$w" ] || return 1
  printf '%s' "$w"
}
