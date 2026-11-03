#!/bin/sh

source "$CONFIG_DIR/theme.sh"

PP_ACTIVE_COLOR=0xffbe1a26

register_pp() {
  local position=${1:-left}

  sketchybar --add item pp $position \
             --set pp script="$HOOK_DIR/pp.sh" \
                            icon="󰨈" \
                            label.drawing=off \
                            icon.color=$SECONDARY_COLOR \
                            click_script="$HOOK_DIR/pp.sh open" \
                            update_freq=5
}

if [ "$1" = "open" ]; then
    open -a "Puzzle Pirates"
    exit 0
fi

# Script logic that runs periodically
# Check if PP is running
# Try multiple process name patterns since macOS app process names can vary
if pgrep -f "java" > /dev/null 2>&1; then
    # App is running - set icon color to green
    sketchybar --set pp icon.color=$PP_ACTIVE_COLOR
else
    # App is not running - set icon color to white (secondary color)
    sketchybar --set pp icon.color=$SECONDARY_COLOR
fi
