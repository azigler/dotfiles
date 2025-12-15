#!/bin/sh

source "$CONFIG_DIR/theme.sh"

register_power() {
  local position=${1:-right}

  sketchybar --add item power $position                        \
           --set power script="$PLUGIN_DIR/power.sh"      \
                         update_freq=120                      \
           --subscribe power system_woke power_source_change
}

# Handle power_source_change, system_woke events, and regular updates (from update_freq)
if [ -n "$NAME" ]; then
  echo "$(date): power.sh called - SENDER=$SENDER NAME=$NAME INFO=$INFO" >> /tmp/sketchybar-power.log
  PERCENTAGE=$(pmset -g batt | grep -Eo "\d+%" | cut -d% -f1)
  CHARGING=$(pmset -g batt | grep 'AC Power')

  if [ -z "$PERCENTAGE" ]; then
    exit 0
  fi

  # Determine battery icon based on level
  case ${PERCENTAGE} in
    9[0-9]|100) ICON=""
    ;;
    [6-8][0-9]) ICON=""
    ;;
    [3-5][0-9]) ICON=""
    ;;
    [1-2][0-9]) ICON=""
    ;;
    *) ICON=""
  esac

  if [[ $CHARGING != "" ]]; then
    ICON=""
  fi

  # The item invoking this script (name $NAME) will get its icon and label
  # updated with the current battery status
  sketchybar --set $NAME icon="$ICON" \
                        label="${PERCENTAGE}%"
fi
