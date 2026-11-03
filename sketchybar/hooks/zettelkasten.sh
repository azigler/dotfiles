#!/bin/sh

source "$CONFIG_DIR/theme.sh"

ZETTELKASTEN_REPO="$HOME/Documents/Backups/zettelkasten"

# Get the last push timestamp from git
get_last_push_time() {
  if [ -z "$ZETTELKASTEN_REPO" ]; then
    echo "No repo configured"
    return
  fi

  if [ ! -d "$ZETTELKASTEN_REPO/.git" ]; then
    echo "No repo found"
    return
  fi

  (
    cd "$ZETTELKASTEN_REPO" 2>/dev/null || exit 1
    BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
    # Try remote branch first, then local HEAD
    git log -1 --format=%cd --date=format:'%a %b %d %Y 󰃭 %I:%M:%S %p' "origin/$BRANCH" 2>/dev/null || \
    git log -1 --format=%cd --date=format:'%a %b %d %Y 󰃭 %I:%M:%S %p' HEAD 2>/dev/null || \
    echo "Never"
  ) 2>/dev/null || echo "Cannot access repo"
}

register_zettelkasten() {
  sketchybar --add item zettelkasten left                                  \
             --set zettelkasten click_script="$HOOK_DIR/zettelkasten.sh toggle" \
                                popup.align=center                          \
                                popup.drawing=off                           \
                                popup.background.color=$BAR_COLOR           \
                                popup.background.corner_radius=8            \
                                popup.background.border_width=1             \
                                popup.background.border_color=$SKY_GRAY     \
                                popup.blur_radius=30                        \
                                popup.y_offset=5                            \
                                icon="󱨋"                                   \
                                label.drawing=off                           \
                                icon.color=0xff6b7280                       \
                                                                           \
             --add item zettelkasten.last_push popup.zettelkasten          \
             --set zettelkasten.last_push label="Last Push: Loading..."     \
                                          label.color=$SKY_GRAY            \
                                          background.color=0x00000000       \
                                          background.corner_radius=4        \
                                          padding_left=12                   \
                                          padding_right=12                  \
                                          click_script=""                   \
                                                                           \
             --add item zettelkasten.backup popup.zettelkasten             \
             --set zettelkasten.backup label="Backup Now"                   \
                                       label.color=$SKY_GRAY               \
                                       background.color=0x00000000          \
                                       background.corner_radius=4           \
                                       padding_left=12                      \
                                       padding_right=12                     \
                                       click_script="$HOOK_DIR/zettelkasten.sh backup" \
                                       script="$HOOK_DIR/zettelkasten.sh"   \
                                                                           \
             --subscribe zettelkasten.backup mouse.entered mouse.exited
}

# Handle mouse events for hover effects (only when SENDER is set to mouse events)
# Skip this if we have arguments, which means this is being called from click_script
if [ -z "$1" ] && [ -n "$SENDER" ] && { [ "$SENDER" = "mouse.entered" ] || [ "$SENDER" = "mouse.exited" ]; }; then
  if [ "$NAME" = "zettelkasten.backup" ]; then
    if [ "$SENDER" = "mouse.entered" ]; then
      animate_background_hover "$NAME" "enter"
    elif [ "$SENDER" = "mouse.exited" ]; then
      animate_background_hover "$NAME" "exit"
    fi
  fi
  exit 0
fi

# Handle toggle when clicked
if [ "$1" = "toggle" ]; then
  # Update the last push time before showing popup
  LAST_PUSH=$(get_last_push_time)
  sketchybar --set zettelkasten.last_push label="Last Push: $LAST_PUSH"
  # Toggle popup visibility
  sketchybar --set zettelkasten popup.drawing=toggle
fi

# Handle backup action
if [ "$1" = "backup" ]; then
  # Placeholder for future backup functionality
  sketchybar --set zettelkasten popup.drawing=off
fi
