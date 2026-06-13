#!/usr/bin/env bash
#
# install-zig-watchdog.sh — install (or uninstall) the zig-watchdog
# systemd-user timer + service that mechanically probes long-running jobs
# every 5 minutes.
#
# Usage:
#   bash install-zig-watchdog.sh              # install + enable + start
#   bash install-zig-watchdog.sh --uninstall  # stop + disable + remove
#   bash install-zig-watchdog.sh --status     # show timer/service status
#
# Spec: dotfiles-olh §3 (Architecture)
# Bead: dotfiles-olh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE_SRC="$SCRIPT_DIR/zig-watchdog.service"
TIMER_SRC="$SCRIPT_DIR/zig-watchdog.timer"
SERVICE_NAME="zig-watchdog.service"
TIMER_NAME="zig-watchdog.timer"

cmd="${1:---install}"

case "$cmd" in
  --install|install|"")
    mkdir -p "$UNIT_DIR"
    install -m 0644 "$SERVICE_SRC" "$UNIT_DIR/$SERVICE_NAME"
    install -m 0644 "$TIMER_SRC"   "$UNIT_DIR/$TIMER_NAME"
    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER_NAME"
    echo
    echo "zig-watchdog installed."
    echo "  units:    $UNIT_DIR/$SERVICE_NAME, $UNIT_DIR/$TIMER_NAME"
    echo "  state:    ~/.cache/zig-watchdog/{state,alerts}.json"
    echo "  follow:   journalctl --user -u $SERVICE_NAME -f"
    echo "  next:     systemctl --user list-timers $TIMER_NAME"
    ;;

  --uninstall|uninstall)
    systemctl --user disable --now "$TIMER_NAME" 2>/dev/null || true
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SERVICE_NAME" "$UNIT_DIR/$TIMER_NAME"
    systemctl --user daemon-reload
    echo "zig-watchdog uninstalled (cache dir ~/.cache/zig-watchdog preserved)."
    ;;

  --status|status)
    echo "=== $TIMER_NAME ==="
    systemctl --user status "$TIMER_NAME" --no-pager || true
    echo
    echo "=== $SERVICE_NAME ==="
    systemctl --user status "$SERVICE_NAME" --no-pager || true
    echo
    echo "=== ~/.cache/zig-watchdog/ ==="
    ls -la "$HOME/.cache/zig-watchdog/" 2>/dev/null || echo "(empty — no ticks yet)"
    ;;

  -h|--help|help)
    sed -n '2,12p' "$0"
    ;;

  *)
    echo "error: unknown command: $cmd" >&2
    sed -n '2,12p' "$0" >&2
    exit 1
    ;;
esac
