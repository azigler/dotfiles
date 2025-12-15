#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_active() {
  local position=${1:-left}

  sketchybar --add item active $position                         \
             --set active script="$PLUGIN_DIR/active.sh" \
                            icon.drawing=off                  \
             --subscribe active front_app_switched
}

if [ "$SENDER" = "front_app_switched" ]; then
  sketchybar --set $NAME label="$INFO"
fi
