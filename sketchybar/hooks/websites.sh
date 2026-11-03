#!/bin/sh

source "$CONFIG_DIR/theme.sh"

WEBSITES=("https://www.andrewzigler.com" "https://zig.computer")
CURRENT_INDEX=0

# Get website URL at index
get_website_url() {
  case $1 in
    0) echo "https://www.andrewzigler.com" ;;
    1) echo "https://zig.computer" ;;
    *) echo "https://www.andrewzigler.com" ;;
  esac
}

# Update the popup with a specific index
update_popup_with_index() {
  local index=$1
  local url=$(get_website_url $index)

  # Update URL label
  sketchybar --set websites.url label="$url"

  # Update navigation button states
  if [ $index -eq 0 ]; then
    sketchybar --set websites.prev label.color=$SKY_GRAY_25
  else
    sketchybar --set websites.prev label.color=$SKY_GRAY
  fi

  max_index=1
  if [ $index -eq $max_index ]; then
    sketchybar --set websites.next label.color=$SKY_GRAY_25
  else
    sketchybar --set websites.next label.color=$SKY_GRAY
  fi
}

register_websites() {
  # Store current index in a hidden item's label (as state storage)
  sketchybar --add item websites.index left \
             --set websites.index drawing=off \
                                  label="0"

  sketchybar --add item websites left                              \
             --set websites script="$HOOK_DIR/websites.sh" \
                         click_script="$HOOK_DIR/websites.sh toggle" \
                         popup.align=center                          \
                         popup.drawing=off                           \
                         popup.background.color=$BAR_COLOR           \
                         popup.background.corner_radius=8              \
                         popup.background.border_width=1               \
                         popup.background.border_color=$SKY_GRAY      \
                         popup.blur_radius=30                         \
                         popup.y_offset=5                             \
                         icon="󰛶"                                    \
                         label.drawing=off                           \
                         icon.color=0xff6b7280                        \
                                                                   \
             --add item websites.url popup.websites                  \
             --set websites.url label="${WEBSITES[0]}"                \
                                label.color=$SKY_GRAY                \
                                background.color=0x00000000          \
                                background.corner_radius=4            \
                                padding_left=12                       \
                                padding_right=12                      \
                                padding_top=8                        \
                                padding_bottom=8                     \
                                click_script="$HOOK_DIR/websites.sh open" \
                                script="$HOOK_DIR/websites.sh"       \
                                                                   \
             --add item websites.prev popup.websites                 \
             --set websites.prev drawing=on                            \
                                 label="◀ Prev"                       \
                                 icon.drawing=off                    \
                                 label.color=$SKY_GRAY               \
                                 background.color=0x00000000          \
                                 background.corner_radius=4           \
                                 padding_left=16                      \
                                 padding_right=16                     \
                                 padding_top=10                       \
                                 padding_bottom=10                    \
                                 click_script="$HOOK_DIR/websites.sh nav_prev" \
                                 script="$HOOK_DIR/websites.sh"      \
                                                                   \
             --add item websites.next popup.websites                 \
             --set websites.next drawing=on                            \
                                 label="Next ▶"                     \
                                 icon.drawing=off                    \
                                 label.color=$SKY_GRAY               \
                                 background.color=0x00000000          \
                                 background.corner_radius=4           \
                                 padding_left=16                      \
                                 padding_right=16                     \
                                 padding_top=10                       \
                                 padding_bottom=10                    \
                                 click_script="$HOOK_DIR/websites.sh nav_next" \
                                 script="$HOOK_DIR/websites.sh"      \
                                                                   \
             --subscribe websites.url mouse.entered mouse.exited      \
             --subscribe websites.prev mouse.entered mouse.exited     \
             --subscribe websites.next mouse.entered mouse.exited

  # Initialize popup state
  update_popup_with_index 0
}

# Get current index from hidden item
get_current_index() {
  index=$(sketchybar --query websites.index 2>/dev/null | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('label', {}).get('value', '0'))" 2>/dev/null)
  case "$index" in
    ''|*[!0-9]*) echo "0" ;;
    *) echo "$index" ;;
  esac
}

# Set current index in hidden item
set_current_index() {
  sketchybar --set websites.index label="$1"
}

# Handle mouse events for hover effects (only when SENDER is set to mouse events)
# Skip this if we have arguments, which means this is being called from click_script
if [ -z "$1" ] && [ -n "$SENDER" ] && { [ "$SENDER" = "mouse.entered" ] || [ "$SENDER" = "mouse.exited" ]; }; then
  case "$NAME" in
    "websites.url")
      if [ "$SENDER" = "mouse.entered" ]; then
        animate_background_hover "$NAME" "enter"
      elif [ "$SENDER" = "mouse.exited" ]; then
        animate_background_hover "$NAME" "exit"
      fi
      ;;
    "websites.prev"|"websites.next")
      if [ "$SENDER" = "mouse.entered" ]; then
        animate_button_hover "$NAME" "enter"
      elif [ "$SENDER" = "mouse.exited" ]; then
        animate_button_hover "$NAME" "exit"
      fi
      ;;
  esac
  exit 0
fi

# Handle actions (when called directly from click handlers)
ACTION=$1

# Ensure we have everything we need
if [ -n "$ACTION" ]; then
  if [ -z "$SKY_GRAY" ] && [ -n "$CONFIG_DIR" ] && [ -f "$CONFIG_DIR/theme.sh" ]; then
    source "$CONFIG_DIR/theme.sh"
  fi

fi

case "$ACTION" in
    "toggle")
        current_index=$(get_current_index)
        update_popup_with_index $current_index
        sketchybar --set websites popup.drawing=toggle
        ;;
    "open")
        current_index=$(get_current_index)
        url=$(get_website_url $current_index)
        open "$url"
        sketchybar --set websites popup.drawing=off
        ;;
    "nav_prev")
        current_index=$(get_current_index)
        if [ "$current_index" -gt 0 ]; then
          new_index=$((current_index - 1))
          set_current_index $new_index
          update_popup_with_index $new_index
        fi
        ;;
    "nav_next")
        current_index=$(get_current_index)
        max_index=1
        if [ "$current_index" -lt "$max_index" ]; then
          new_index=$((current_index + 1))
          set_current_index $new_index
          update_popup_with_index $new_index
        fi
        ;;
esac

