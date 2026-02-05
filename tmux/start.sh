#!/bin/bash

if [[ "$__CFBundleIdentifier" = *"VSCode"* ]]; then
  return
fi

TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/"

if [[ "$OSTYPE" == "darwin"* ]]; then
    tmux_command="/opt/homebrew/opt/tmux/bin/tmux"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    tmux_command="/usr/bin/tmux"
fi

session_name="$(hostname -s)"

$tmux_command has-session -t=$session_name 2> /dev/null

if [[ $? -ne 0 ]]; then
    TMUX='' $tmux_command new-session -d -s "$session_name"
fi

if [[ -z "$TMUX" ]]; then
    $tmux_command attach -t "$session_name"
fi
