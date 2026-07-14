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
# Scope + a known limit: this resolves a SINGLE forked session (its ancestry
# leads to the daemon's origin pane, which IS its display pane) and any normal
# in-pane session. It CANNOT distinguish TWO+ sessions forked under one shared
# daemon (they all trace to the same origin pane, and nothing in the process
# tree ties a fork to its display pane — that link is the runtime PTY socket).
# In that multi-fork case the resolver DEGRADES (returns non-zero -> callers
# fall back to legacy / skip the rename) rather than return a wrong window. A
# fully robust multi-fork mapping would need the PTY-socket/tmux-pane signal.
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

# _tpr_cmdline <pid> -> the process command line (NULs -> spaces). /proc first,
# ps fallback (macOS/BSD).
_tpr_cmdline() {
  if [ -r "/proc/$1/cmdline" ]; then tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
  else ps -o command= -p "$1" 2>/dev/null; fi
}

# _tpr_bg_session_count -> number of live daemon-hosted bg sessions (their PTY
# sockets). >1 means several forked sessions share ONE daemon rooted in a single
# pane, so process ancestry cannot tell which fork THIS is — it would confidently
# return the daemon's origin pane (possibly the wrong window).
# (TPR_TEST_BG_COUNT overrides for tests.)
_tpr_bg_session_count() {
  [ -n "${TPR_TEST_BG_COUNT:-}" ] && { printf '%s' "$TPR_TEST_BG_COUNT"; return; }
  find /tmp -maxdepth 4 -type s -path '*cc-daemon*/pty/*.sock' 2>/dev/null | wc -l | tr -d ' '
}

# _tpr_by_ancestry <tmux-format> -> for the first ancestor PID that is a tmux
# pane_pid, print that pane's <tmux-format> attribute. Non-zero when it can't be
# resolved (no tmux / no pane ancestor) OR when resolution would be AMBIGUOUS:
# a background-forked session (an ancestor is a bg-pty-host) while >1 bg session
# is live shares the daemon's origin pane with its siblings, so we REFUSE (return
# non-zero -> caller degrades to legacy) rather than confidently guess the wrong
# window. Single fork, or a normal in-pane session, resolves fine.
# (TPR_TEST_FORKED forces the forked branch for tests.)
_tpr_by_ancestry() {
  local fmt="$1" tb panes pid hit i=0 forked="${TPR_TEST_FORKED:-0}"
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  panes=$("$tb" list-panes -a -F "#{pane_pid} $fmt" 2>/dev/null) || return 1
  [ -n "$panes" ] || return 1
  pid=$$
  while [ -n "$pid" ] && [ "$pid" != 1 ] && [ "$i" -lt 24 ]; do
    case "$(_tpr_cmdline "$pid")" in *bg-pty-host*) forked=1 ;; esac
    hit=$(printf '%s\n' "$panes" | awk -v t="$pid" '$1==t{$1="";sub(/^ /,"");print;exit}')
    if [ -n "$hit" ]; then
      [ "$forked" = 1 ] && [ "$(_tpr_bg_session_count)" -gt 1 ] && return 1
      printf '%s' "$hit"; return 0
    fi
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

# --- Sticky session->window cache (childed-pid recovery, root-caused 2026-07-14)
# A background-forked session (`claude bg-pty-host --fork-session`, CC 2.x) is
# re-parented under the CC daemon (fork -> bg-pty-host -> daemon), so its process
# ancestry NEVER reaches its display pane's shell AND $TMUX_PANE is absent — both
# live-resolution paths above then come back empty. Every window-keyed surface
# breaks: the lexicon transition log records window="" (the session drops out of
# the harnessd fleet roster's window-keyed dwell join — explore's hourly pulse
# ticks read "idle 15h" while ticking), and handoff scoping can't key the window.
# This is the ancestry resolver's documented multi-fork degrade (dotfiles-5w4)
# AND, on CC 2.1.207, the SINGLE-fork case too.
#
# Recovery without the fragile PTY-socket->pane archaeology: cache
# session_id -> window whenever we DO resolve it live (every time the session
# runs normally in its pane — interactive or a --resume, both keep intact
# ancestry/$TMUX_PANE), and fall back to that last-known-good window when live
# resolution fails. Keyed by session id (stable across a durable session's pulse
# ticks) so it can never return a WRONG window the way ancestry-degrade could.
# The cache lives beside the per-session lexicon token ($CLAUDE_LEXICON_STATE_DIR,
# default /tmp/claude-lexicon) so every lexicon surface shares one convention.
_tpr_win_cache_file() { printf '%s/%s.window' "${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}" "$1"; }

# tmux_win_cache_get <session_id> -> cached window on stdout; non-zero if the
# session has no (non-empty) cache entry.
tmux_win_cache_get() {
  [ -n "${1:-}" ] || return 1
  local f w; f=$(_tpr_win_cache_file "$1")
  [ -s "$f" ] || return 1
  w=$(cat "$f" 2>/dev/null); [ -n "$w" ] || return 1
  printf '%s' "$w"
}

# tmux_win_cache_put <session_id> <window> -> atomically cache the mapping
# (temp+mv so a concurrent reader never sees a partial name). Non-zero on empty
# args or a write failure; callers ignore its return.
tmux_win_cache_put() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  local dir="${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}" f
  f=$(_tpr_win_cache_file "$1")
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s' "$2" > "$f.tmp.$$" 2>/dev/null || { rm -f "$f.tmp.$$" 2>/dev/null; return 1; }
  mv -f "$f.tmp.$$" "$f" 2>/dev/null || { rm -f "$f.tmp.$$" 2>/dev/null; return 1; }
}

# tmux_resolve_window [session_id] -> the glyph-stripped window name for THIS
# session's pane. Targeted display-message on $TMUX_PANE when set, else ancestry,
# else the sticky session->window cache (childed-pid recovery, above). Seeds the
# cache on every successful LIVE resolution. session_id defaults to
# $CLAUDE_CODE_SESSION_ID so env-only callers (handoff-path.sh) get recovery too.
# Strips the tmux-lexicon glyph prefix (🧠✅🔔🌀📬). Non-zero only when live
# resolution fails AND the cache has no entry.
tmux_resolve_window() {
  local sid="${1:-${CLAUDE_CODE_SESSION_ID:-}}" tb w
  tb=$(command -v tmux 2>/dev/null); [ -x "$tb" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  if [ -n "${TMUX_PANE:-}" ]; then
    w=$("$tb" display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
  fi
  [ -n "${w:-}" ] || w=$(_tpr_by_ancestry '#{window_name}')
  w=$(printf '%s' "${w:-}" | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//')
  if [ -n "$w" ]; then
    tmux_win_cache_put "$sid" "$w"   # seed for later fork ticks (no-op if sid empty)
    printf '%s' "$w"; return 0
  fi
  tmux_win_cache_get "$sid"          # childed-pid recovery; non-zero if no cache
}
