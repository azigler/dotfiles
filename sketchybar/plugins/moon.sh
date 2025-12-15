#!/bin/sh

source "$CONFIG_DIR/theme.sh"

# Moon Phase Plugin
# Displays current moon phase using simple circle symbols

# Calculate moon phase
# Based on astronomical new moon (January 6, 2000)
calculate_moon_phase() {
    local current_date=$(date +%s)
    local known_new_moon=947116800  # Jan 6, 2000 18:00:00 UTC
    local lunar_cycle=2551443  # 29.53 days in seconds

    local phase=$(( ($current_date - $known_new_moon) % $lunar_cycle ))
    local phase_percentage=$(( $phase * 100 / $lunar_cycle ))

    echo $phase_percentage
}

# Get moon phase icon based on percentage
get_moon_icon() {
    local phase=$1

    # Map percentage to 8 moon phases using NerdFont symbols
    if [ $phase -lt 6 ]; then
        echo "󰽤"  # New Moon (nf-md-moon_new)
    elif [ $phase -lt 19 ]; then
        echo "󰽧"  # Waxing Crescent (nf-md-moon_waxing_crescent)
    elif [ $phase -lt 31 ]; then
        echo "󰽡"  # First Quarter (nf-md-moon_first_quarter)
    elif [ $phase -lt 44 ]; then
        echo "󰽨"  # Waxing Gibbous (nf-md-moon_waxing_gibbous)
    elif [ $phase -lt 56 ]; then
        echo "󰽢"  # Full Moon (nf-md-moon_full)
    elif [ $phase -lt 69 ]; then
        echo "󰽦"  # Waning Gibbous (nf-md-moon_waning_gibbous)
    elif [ $phase -lt 81 ]; then
        echo "󰽣"  # Last Quarter (nf-md-moon_last_quarter)
    elif [ $phase -lt 94 ]; then
        echo "󰽥"  # Waning Crescent (nf-md-moon_waning_crescent)
    else
        echo "󰽤"  # New Moon (nf-md-moon_new)
    fi
}

get_moon_phase_name() {
    local phase=$1

    if [ $phase -lt 6 ]; then
        echo "New Moon"
    elif [ $phase -lt 19 ]; then
        echo "Waxing Crescent"
    elif [ $phase -lt 31 ]; then
        echo "First Quarter"
    elif [ $phase -lt 44 ]; then
        echo "Waxing Gibbous"
    elif [ $phase -lt 56 ]; then
        echo "Full Moon"
    elif [ $phase -lt 69 ]; then
        echo "Waning Gibbous"
    elif [ $phase -lt 81 ]; then
        echo "Last Quarter"
    elif [ $phase -lt 94 ]; then
        echo "Waning Crescent"
    else
        echo "New Moon"
    fi
}

register_moon() {
  local position=${1:-right}

  sketchybar --add item moon $position                          \
             --set moon update_freq=3600                        \
                        script="$PLUGIN_DIR/moon.sh"      \
             --subscribe moon
}

# Main execution
PHASE_PERCENTAGE=$(calculate_moon_phase)
MOON_ICON=$(get_moon_icon $PHASE_PERCENTAGE)
PHASE_NAME=$(get_moon_phase_name $PHASE_PERCENTAGE)

# Update the item
sketchybar --set $NAME icon="$MOON_ICON" \
                      label.drawing=off
