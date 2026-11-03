#!/bin/sh

source "$CONFIG_DIR/theme.sh"

ZIG_COMPUTER_ACTIVE_COLOR=0xffa0e7e5
# The VPS address is NOT committed (public repo): it is read from ~/.secrets
# (export ZIG_COMPUTER_IP=...), the same file ~/.bash_aliases sources.
ZIG_COMPUTER_IP=${ZIG_COMPUTER_IP:-$(sed -n "s/^export ZIG_COMPUTER_IP=//p" "$HOME/.secrets" 2>/dev/null | tr -d "\"'" | head -1)}
ZIG_COMPUTER_SSH_MATCH="ssh ubuntu@$ZIG_COMPUTER_IP"

register_zig_computer() {
  local position=${1:-left}

  sketchybar --add item zig-computer $position \
             --set zig-computer script="$HOOK_DIR/zig-computer.sh" \
                            icon="" \
                            label.drawing=off \
                            icon.color=$SECONDARY_COLOR \
                            click_script="$HOOK_DIR/zig-computer.sh open" \
                            update_freq=5
}

if [ "$1" = "open" ]; then
  if pgrep -x alacritty >/dev/null 2>&1; then
    OVERRIDE_TMUX=true alacritty msg create-window -e zsh -lic zig-computer
  else
    open -a Alacritty --env OVERRIDE_TMUX=true --args -e zsh -lic zig-computer
  fi
  exit 0
fi

if pgrep -f "$ZIG_COMPUTER_SSH_MATCH" >/dev/null 2>&1; then
  sketchybar --set zig-computer icon.color=$ZIG_COMPUTER_ACTIVE_COLOR
else
  sketchybar --set zig-computer icon.color=$SECONDARY_COLOR
fi
