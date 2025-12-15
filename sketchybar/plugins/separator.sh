#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_separator() {
  local position=${1:-left}
  local name=${2:-separator}
  local icon=${3:-}

  sketchybar --add item $name $position   \
            --set $name icon="$icon"      \
            label.drawing=off             \
            padding_left=0
}
