#!/bin/bash

if [[ "$__CFBundleIdentifier" = *"VSCode"* || "$OVERRIDE_TMUX" = "true" ]]; then
  return
fi

# Only autostart/attach from a REAL interactive terminal. Non-interactive,
# sandboxed, or dispatched shells (e.g. the MUD servitor loop spawning Claude
# Code sessions) must NEVER reach the new-session/attach below: without a
# controlling TTY the tmux client blocks in poll forever, orphans to systemd,
# and leaks ~5MB each. ~93 of these accumulated in one day and filled VPS RAM
# until the box locked up (2026-06-17). A login terminal is an interactive
# shell ($- contains 'i') with stdin+stdout on a tty; anything else bails.
case "$-" in *i*) ;; *) return ;; esac
{ [ -t 0 ] && [ -t 1 ]; } || return

TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/"

if [[ "$OSTYPE" == "darwin"* ]]; then
    tmux_command="/opt/homebrew/opt/tmux/bin/tmux"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    tmux_command="/usr/bin/tmux"
fi

#session_name="$(hostname -s)"
session_name="work"

$tmux_command has-session -t=$session_name 2> /dev/null

if [[ $? -ne 0 ]]; then
    TMUX='' $tmux_command new-session -d -s "$session_name"
fi

if [[ -z "$TMUX" ]]; then
    $tmux_command attach -t "$session_name"
fi
