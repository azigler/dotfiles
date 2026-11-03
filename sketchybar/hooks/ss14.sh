#!/bin/sh

source "$CONFIG_DIR/theme.sh"

SS14_ACTIVE_COLOR=0xffd04335

register_ss14() {
  local position=${1:-left}

  sketchybar --add item ss14 $position \
             --set ss14 script="$HOOK_DIR/ss14.sh" \
                            icon="󱎃" \
                            label.drawing=off \
                            icon.color=$SECONDARY_COLOR \
                            click_script="$HOOK_DIR/ss14.sh open" \
                            update_freq=5
}

if [ "$1" = "open" ]; then
    open -a "Space Station 14 Launcher"
    exit 0
fi

# Script logic that runs periodically
# Check if SS14 is running
# Try multiple process name patterns since macOS app pro  ess names can vary
if pgrep -f "Space Station 14 Launcher" > /dev/null 2>&1; then
    # App is running - set icon color to green
    sketchybar --set ss14 icon.color=$SS14_ACTIVE_COLOR
else
    # App is not running - set icon color to white (secondary color)
    sketchybar --set ss14 icon.color=$SECONDARY_COLOR
fi
