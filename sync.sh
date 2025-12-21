#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.backup/$(date +%Y%m%d%H%M%S)"
cd $SCRIPT_DIR

# Back up and remove a file or directory.
#   $1: The file or directory to back up.
back_up_and_remove() {
    local to_back_up=$1
    local back_up_to="$BACKUP_DIR$1"
    if [ -e "$to_back_up" ]; then
        mkdir -p "$back_up_to"
        cp -r "$to_back_up" "$back_up_to"
        if [ $? -ne 0 ]; then
            echo "❌ Error: Failed to copy $to_back_up to $back_up_to"
            exit 1
        fi
        rm -rf "$to_back_up"
        echo " ↳ $to_back_up backed up to $back_up_to and deleted"
    fi
}

# Sync a source file or directory to a destination.
#   $1: The source file or directory.
#   $2: The destination to back up and replace with a symlink.
sync_source() {
    local sync_from=$1
    local sync_to=$2
    if [ ! -e "$sync_from" ]; then
        echo "❌ Error: $sync_from does not exist"
        return
    fi
    echo "🗄️ Synchronizing $sync_from to $sync_to..."
    back_up_and_remove "$sync_to"
    mkdir -p "$(dirname "$sync_to")"
    ln -s "$sync_from" "$sync_to"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to create symlink to $sync_to directory"
        exit 1
    fi

}

sync() {
    local dir=$1
    case ${dir} in
        "alacritty")
            sync_source "$SCRIPT_DIR/alacritty" "$HOME/.config/alacritty"
            ;;
        "bash")
            [[ ! -f "$SCRIPT_DIR/bash/.$(hostname -s).bashrc" ]] || sync_source "$SCRIPT_DIR/bash/.$(hostname -s).bashrc" "$HOME/.$(hostname -s).bashrc"
            sync_source "$SCRIPT_DIR/bash/.bash_aliases" "$HOME/.bash_aliases"
            sync_source "$SCRIPT_DIR/bash/.bash_login" "$HOME/.bash_login"
            sync_source "$SCRIPT_DIR/bash/.bash_logout" "$HOME/.bash_logout"
            sync_source "$SCRIPT_DIR/bash/.bash_profile" "$HOME/.bash_profile"
            sync_source "$SCRIPT_DIR/bash/.bashrc" "$HOME/.bashrc"
            sync_source "$SCRIPT_DIR/bash/.inputrc" "$HOME/.inputrc"
            sync_source "$SCRIPT_DIR/bash/.profile" "$HOME/.profile"
            ;;
        "blightmud")
            sync_source "$SCRIPT_DIR/blightmud/autoload_plugins.ron" "$HOME/.local/share/blightmud/autoload_plugins.ron"
            sync_source "$SCRIPT_DIR/blightmud/plugins" "$HOME/.local/share/blightmud/plugins"
            ;;
        "borders")
            sync_source "$SCRIPT_DIR/borders/bordersrc" "$HOME/.config/borders/bordersrc"
            ;;
        "cursor")
            if command -v cursor >/dev/null 2>&1; then
                [[ ! -f "$SCRIPT_DIR/cursor/install_extensions.sh" ]] || sh "$SCRIPT_DIR/cursor/install_extensions.sh"
            fi
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sync_source "$SCRIPT_DIR/cursor/settings.json" "/Users/$USER/Library/Application Support/Cursor/User/settings.json"
            fi
            ;;
        "direnv")
            sync_source "$SCRIPT_DIR/direnv" "$HOME/.config/direnv"
            ;;
        "editorconfig")
            sync_source "$SCRIPT_DIR/editorconfig/.editorconfig" "$HOME/.editorconfig"
            ;;
        "gh")
            sync_source "$SCRIPT_DIR/gh" "$HOME/.config/gh"
            git config --global gpg.program $(which gpg)
            ;;
        "git")
            sync_source "$SCRIPT_DIR/git/.gitconfig" "$HOME/.gitconfig"
            ;;
        "gnupg")
            sync_source "$SCRIPT_DIR/gnupg/common.conf" "$HOME/.gnupg/common.conf"
            sync_source "$SCRIPT_DIR/gnupg/gpg.conf" "$HOME/.gnupg/gpg.conf"
            echo "pinentry-program $(brew --prefix)/bin/pinentry-mac" > "$HOME/.gnupg/gpg-agent.conf"
            ;;
        "nix")
            sync_source "$SCRIPT_DIR/nix/nix.conf" "$HOME/.config/nix/nix.conf"
            ;;
        "npm")
            sync_source "$SCRIPT_DIR/npm/.npmrc" "$HOME/.npmrc"
            ;;
        "ranger")
            sync_source "$SCRIPT_DIR/ranger" "$HOME/.config/ranger"
            ;;
        "sketchybar")
            sync_source "$SCRIPT_DIR/sketchybar" "$HOME/.config/sketchybar"
            ;;
        "skhd")
            sync_source "$SCRIPT_DIR/skhd" "$HOME/.config/skhd"
            sync_source "$SCRIPT_DIR/skhd/skhdrc" "$HOME/.skhdrc"
            ;;
        "ssh")
            if [[ ! -f "$HOME/.ssh/local" && -f "$HOME/.ssh/config" && ! -L "$HOME/.ssh/config" ]]; then
                mv "$HOME/.ssh/config" "$HOME/.ssh/local"
            fi
            sync_source "$SCRIPT_DIR/ssh/config" "$HOME/.ssh/config"
            if [[ -L "$HOME/.ssh/config" && ! -f "$HOME/.ssh/local" ]]; then
                touch "$HOME/.ssh/local"
            fi
            ;;
        "tmux")
            sync_source "$SCRIPT_DIR/tmux/tmux.conf" "$HOME/.tmux.conf"
            sync_source "$SCRIPT_DIR/tmux/start.sh" "$HOME/.local/share/tmux/start.sh"
            sync_source "$SCRIPT_DIR/tmux/plugins" "$HOME/.tmux/plugins"
            ;;
        "ts4")
            source "$SCRIPT_DIR/ts4/sync.sh" "${@:2}"
            ;;
        "vim")
            sync_source "$SCRIPT_DIR/vim" "$HOME/.vim"
            sync_source "$SCRIPT_DIR/vim/vimrc" "$HOME/.vimrc"
            ;;
        "vscode")
            if command -v code >/dev/null 2>&1; then
                [[ ! -f "$SCRIPT_DIR/vscode/install_extensions.sh" ]] || sh "$SCRIPT_DIR/vscode/install_extensions.sh"
            fi
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sync_source "$SCRIPT_DIR/vscode/settings.json" "$HOME/Library/Application Support/Code/User/settings.json"
            elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
                sync_source "$SCRIPT_DIR/vscode/settings.json" "$HOME/.config/Code/User/settings.json"
            fi
            ;;
        "yabai")
            sync_source "$SCRIPT_DIR/yabai/yabairc" "$HOME/.config/yabai/yabairc"
            sync_source "$SCRIPT_DIR/yabai/yabairc" "$HOME/.yabairc"
            ;;
        "yarn")
            sync_source "$SCRIPT_DIR/yarn/.yarnrc" "$HOME/.yarnrc"
            ;;
        "zsh")
            if [[ "$SHELL" == "/bin/zsh" ]]; then
                sync_source "$SCRIPT_DIR/zsh/ohmyzsh" "$HOME/.oh-my-zsh"
                [[ ! -f "$SCRIPT_DIR/zsh/.$(hostname -s).zsh" ]] || sync_source "$SCRIPT_DIR/zsh/.$(hostname -s).zsh" "$HOME/.$(hostname -s).zsh"
            fi
            sync_source "$SCRIPT_DIR/zsh/.zlogin" "$HOME/.zlogin"
            sync_source "$SCRIPT_DIR/zsh/.zlogout" "$HOME/.zlogout"
            sync_source "$SCRIPT_DIR/zsh/.zprofile" "$HOME/.zprofile"
            sync_source "$SCRIPT_DIR/zsh/.zshenv" "$HOME/.zshenv"
            sync_source "$SCRIPT_DIR/zsh/.zshrc" "$HOME/.zshrc"
            sync_source "$SCRIPT_DIR/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
            sync_source "$SCRIPT_DIR/zsh/.antigen" "$HOME/.antigen"
            ;;
    esac
}

if [ -n "$1" ]; then
    sync "$@"
    echo "Ran sync.sh for $1"
else
    for dir in */ .*/; do
        sync "${dir%/}"
    done
fi
