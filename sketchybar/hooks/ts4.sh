#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_ts4() {
  local position=${1:-left}

  sketchybar --add item ts4 $position                         \
             --set ts4 script="$HOOK_DIR/ts4.sh" \
                            icon="󱀝" \
                            label.drawing=off \
                            icon.color=$SECONDARY_COLOR \
                            click_script="$HOME/azigler/dotfiles/sync.sh ts4 --logs --play" \
                            update_freq=5
}

# Script logic that runs periodically
# Check if The Sims 4 is running
# Try multiple process name patterns since macOS app process names can vary
if pgrep -f "The Sims 4" > /dev/null 2>&1 || \
   pgrep -f "TheSims4" > /dev/null 2>&1 || \
   pgrep -f "Sims 4" > /dev/null 2>&1; then
    # App is running - set icon color to green
    sketchybar --set ts4 icon.color=0xffa6e329
else
    # App is not running - set icon color to white (secondary color)
    sketchybar --set ts4 icon.color=$SECONDARY_COLOR
fi
