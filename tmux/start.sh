#!/bin/bash

if [[ "$__CFBundleIdentifier" = *"VSCode"* ]]; then
  return
fi

# Force the PTY's IUTF8 line-discipline flag ON so multi-byte UTF-8 sequences
# (nerdfonts, powerline glyphs, etc.) pass through unmangled. Tailscale SSH
# (Go reimplementation) does NOT set IUTF8 on the PTY it allocates — unlike
# OpenBSD sshd which sets it by default. Without this, glyphs render as
# missing-character boxes inside tmux when connected via the tailnet path.
# Tailscale GitHub issue #4146; bead dotfiles-st2.
# `2>/dev/null` swallows the error in non-tty contexts (cron, scripts).
stty iutf8 2>/dev/null

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
