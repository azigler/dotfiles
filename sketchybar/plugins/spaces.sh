#!/bin/sh

source "$CONFIG_DIR/theme.sh"

# Handle space change events (automatically triggered when space changes)
# SELECTED is "true" when this space is active, "false" otherwise
if [ -n "$SELECTED" ]; then
  if [ "$SELECTED" = "true" ]; then
    animate_space "$NAME" "active"
  else
    animate_space "$NAME" "inactive"
  fi
fi

register_spaces() {
  local position=${1:-left}

  SPACE_LABELS=("1" "2" "3" "4" "5" "6" "7" "8" "9" "10")

  for i in "${!SPACE_LABELS[@]}"
  do
    sid=$(($i+1))
    sketchybar --add space space.$sid $position                           \
              --set space.$sid space=$sid                                 \
                                label=${SPACE_LABELS[i]}                     \
                                background.height=$BAR_HEIGHT                   \
                                icon.drawing=off                          \
                                script="$CONFIG_DIR/plugins/spaces.sh"     \
                                click_script="yabai -m space --focus $sid"
  done
}

