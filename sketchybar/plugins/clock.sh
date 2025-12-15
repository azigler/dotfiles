#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_clock() {
  local position=${1:-right}

  # Time item - updates every second
  sketchybar --add item clock_time $position                   \
             --set clock_time update_freq=1                     \
                               script="$PLUGIN_DIR/clock.sh"    \
                               padding_left=0                   \
                               label.padding_left=0             \
                               label.padding_right=0            \
             --subscribe clock_time

  # Static separator "󰃭"
  sketchybar --add item clock_separator $position              \
             --set clock_separator label="󰃭"                    \
                                label.drawing=on                \
                                label.color=$PRIMARY_COLOR           \
                                padding_left=0                  \
                                label.padding_left=0            \
                                label.padding_right=0

  # Date item - updates hourly
  sketchybar --add item clock_date $position                   \
             --set clock_date update_freq=3600                  \
                                script="$PLUGIN_DIR/clock.sh"   \
                                padding_left=0                  \
                                label.padding_left=0            \
                                label.padding_right=0           \
             --subscribe clock_date
}

# Update the appropriate item based on $NAME
case $NAME in
  clock_date)
    sketchybar --set $NAME label="$(date '+%a %b %d')"
    ;;
  clock_time)
    sketchybar --set $NAME label="$(date '+%I:%M:%S %p')"
    ;;
esac
