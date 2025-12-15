#!/bin/sh

source "$CONFIG_DIR/theme.sh"

AIRPODS_NAME="Orpheus & Eurydice"

register_volume() {
  local position=${1:-right}

  sketchybar --add item volume $position                  \
             --set volume script="$PLUGIN_DIR/volume.sh" \
                                   click_script="$PLUGIN_DIR/volume.sh volume_click" \
             --subscribe volume volume_change
}

# Check if current device is AirPods
is_airpods() {
    # Get the device name
    local device=$(system_profiler SPAudioDataType 2>/dev/null | \
                   awk '/Default Output Device: Yes/ {
                       # Get the device name from 2 lines before
                       print prev2
                       exit
                   }
                   {prev2=prev1; prev1=$0}' | \
                   sed 's/^[[:space:]]*//' | \
                   sed 's/:$//')

    if echo "$device" | grep -qi "$AIRPODS_NAME"; then
        echo "true"
    else
        echo "false"
    fi
}

# Get volume icon based on level and device type
get_volume_icon() {
    local volume=$1
    local muted=$2
    local is_headphones=$3

    if [ "$is_headphones" = "true" ]; then
        # Headphones icons
        if [ "$muted" = "true" ]; then
            echo "󰟎"
        else
            echo "󰋋"
        fi
    else
        # Speaker icons
        if [ "$muted" = "true" ]; then
            echo "󰖁"
        elif [ $volume -ge 60 ]; then
            echo "󰕾"
        elif [ $volume -ge 30 ]; then
            echo "󰖀"
        elif [ $volume -gt 0 ]; then
            echo "󰕿"
        else
            echo "󰖁"
        fi
    fi
}

# Check if audio is muted
is_muted() {
    local mute_status=$(osascript -e 'output muted of (get volume settings)')
    echo "$mute_status"
}

# Get current volume from system
get_volume() {
    local volume=$(osascript -e 'output volume of (get volume settings)')
    echo "$volume"
}

if [ "$1" = "volume_click" ]; then
  # Toggle mute
  osascript -e 'set volume output muted not (output muted of (get volume settings))'
elif [ -n "$NAME" ]; then
  # Use $INFO if available (from volume_change event), otherwise fetch directly
  if [ -n "$INFO" ] && [ "$INFO" != "" ]; then
    VOLUME=$INFO
  else
    VOLUME=$(get_volume)
  fi

  MUTED=$(is_muted)
  IS_AIRPODS=$(is_airpods)
  ICON=$(get_volume_icon $VOLUME $MUTED $IS_AIRPODS)

  if [ "$MUTED" = "true" ]; then
    LABEL="mute"
  else
    LABEL="$VOLUME%"
  fi

  sketchybar --set $NAME icon="$ICON" \
                          label="$LABEL"
fi
