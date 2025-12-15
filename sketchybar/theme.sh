#!/bin/sh

##### Set color palette #####
SKY_GOLD=0xfffbbf24
SKY_GRAY=0xff6b7280 # secondary color
SKY_BLACK=0xff0d0f12

SKY_GOLD_50=0x80fbbf24 # primary color
SKY_GRAY_50=0x806b7280
SKY_BLACK_50=0x800d0f12 # bar color

SKY_GOLD_25=0x40fbbf24
SKY_GRAY_25=0x406b7280 # tertiary color
SKY_BLACK_25=0x400d0f12

TRANSPARENT=0x00000000

##### Set colors #####
PRIMARY_COLOR=$SKY_GOLD_50
SECONDARY_COLOR=$SKY_GRAY
TERTIARY_COLOR=$SKY_GRAY_25
BAR_COLOR=$SKY_BLACK_50

##### Set bar appearance #####
BAR_HEIGHT=32
BAR_Y_OFFSET=3
BAR_CORNER_RADIUS=15
BAR_PADDING=10

##### Set item appearance #####
ITEM_PADDING=5
FONT="SauceCodePro Nerd Font:Bold"
FONT_16="$FONT:16.0"
FONT_14="$FONT:14.0"

##### Set animation #####
ANIM_DURATION=50  # 1.5 seconds at 60fps (duration is in frames, not seconds)
ANIM_CURVE="tanh"  # options: linear, qudratic, tanh, sin, exp, circ

# Animate one or more properties
# Usage: animate_item "item_name" "property1=value1" ["property2=value2" ...]
animate_item() {
    local item=$1
    shift
    sketchybar --animate $ANIM_CURVE $ANIM_DURATION --set $item "$@"
}

# Simple background hover (background color only)
# Usage: animate_background_hover "item_name" "enter|exit"
animate_background_hover() {
    local item=$1
    local state=$2
    if [ "$state" = "enter" ]; then
        animate_item "$item" "background.color=$TERTIARY_COLOR"
    elif [ "$state" = "exit" ]; then
        animate_item "$item" "background.color=$TRANSPARENT"
    fi
}

# Button hover (background + label color)
# Usage: animate_button_hover "item_name" "enter|exit"
animate_button_hover() {
    local item=$1
    local state=$2
    # Handle background using the shared function
    animate_background_hover "$item" "$state"
    # Then animate label color
    if [ "$state" = "enter" ]; then
        animate_item "$item" "label.color=$PRIMARY_COLOR"
    elif [ "$state" = "exit" ]; then
        animate_item "$item" "label.color=$SECONDARY_COLOR"
    fi
}

# Space state (background + icon color)
# Usage: animate_space "item_name" "active|inactive"
animate_space() {
    local item=$1
    local state=$2
    if [ "$state" = "active" ]; then
        animate_item "$item" \
            "background.color=$TERTIARY_COLOR" \
            "label.color=$PRIMARY_COLOR"
    elif [ "$state" = "inactive" ]; then
        animate_item "$item" \
            "background.color=$TRANSPARENT" \
            "label.color=$SECONDARY_COLOR"
    fi
}

##### Bar Appearance & Defaults #####
# These settings only run when executed with "init" argument (i.e., from sketchybarrc)
# This prevents them from executing every time a plugin sources this file
if [ "$1" = "init" ]; then
  sketchybar --bar height=$BAR_HEIGHT          \
                   position=top       \
                   y_offset=$BAR_Y_OFFSET        \
                   padding_left=$BAR_PADDING    \
                   padding_right=$BAR_PADDING   \
                   padding_top=$BAR_PADDING     \
                   margin=$BAR_PADDING          \
                   corner_radius=$BAR_CORNER_RADIUS   \
                   color=$BAR_COLOR

  sketchybar --default icon.font="$FONT_16"  \
                       icon.color=$PRIMARY_COLOR              \
                       label.font="$FONT_14" \
                       label.color=$SECONDARY_COLOR                 \
                       padding_left=$ITEM_PADDING                        \
                       padding_right=0                       \
                       label.padding_left=$ITEM_PADDING                  \
                       label.padding_right=$ITEM_PADDING                 \
                       icon.padding_left=$ITEM_PADDING                   \
                       icon.padding_right=$ITEM_PADDING
fi
