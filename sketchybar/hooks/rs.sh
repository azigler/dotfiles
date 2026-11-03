#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_rs() {
  local position=${1:-left}

  sketchybar --add item rs $position                         \
             --set rs script="$HOOK_DIR/rs.sh" \
                            icon="󰓥" \
                            label.drawing=off \
                            icon.color=$SECONDARY_COLOR \
                            click_script="$HOOK_DIR/rs.sh open" \
                            update_freq=5
}

if [ "$1" = "open" ]; then
    open -a "Jagex Launcher"
    exit 0
fi

# Script logic that runs periodically
# Check if Jagex Launcher is running
# Try multiple process name patterns since macOS app process names can vary
if pgrep -f "Jagex Launcher" > /dev/null 2>&1; then
    # App is running - set icon color to red
    sketchybar --set rs icon.color=0xff780609
else
    # App is not running - set icon color to white (secondary color)
    sketchybar --set rs icon.color=$SECONDARY_COLOR
fi
