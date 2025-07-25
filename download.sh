#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $SCRIPT_DIR

# Fetch a file via curl and save it to a specified directory. Exit with an error if the download fails.
#   $1: The URL to download.
#   $2: The directory to save the file to.
fetch_file() {
    local url=$1
    local output_dir=$2

    curl -LO --output-dir "$output_dir" "$url"
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to download $url"
        exit 1
    fi
}

download() {
    local dir=$1
    case ${dir} in
        "alacritty")
            fetch_file "https://github.com/catppuccin/alacritty/raw/main/catppuccin-macchiato.toml" "$SCRIPT_DIR/alacritty"
            ;;
        "blightmud")
            rm -rf "$SCRIPT_DIR/blightmud/plugins/blightmud_mcp"
            git clone https://github.com/lisdude/blightmud_mcp "$SCRIPT_DIR/blightmud/plugins/blightmud_mcp"
            ;;
        "cursor")
            if command -v cursor >/dev/null 2>&1; then
                echo "#!/bin/bash" > $SCRIPT_DIR/cursor/install_extensions.sh
                cursor --list-extensions | while read -r extension; do
                    echo "cursor --install-extension \"$extension\"" >> $SCRIPT_DIR/cursor/install_extensions.sh
                done
                chmod +x $SCRIPT_DIR/cursor/install_extensions.sh
            fi
            ;;
        "fonts")
            mkdir -p "$SCRIPT_DIR/fonts/SauceCodePro"
            cd $SCRIPT_DIR/fonts/SauceCodePro
            curl -LO $(curl -s https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest | jq -r '.assets[] | select(.name | contains("SourceCodePro.tar.xz")) | .browser_download_url')
            tar -xf SourceCodePro.tar.xz
            rm SourceCodePro.tar.xz
            cd $SCRIPT_DIR
            ;;
        "gnupg")
            mkdir -p "$HOME/.gnupg"
            chmod -R u=rw,u+X,go= $HOME/.gnupg
            if [ -n "$(gpg --list-secret-keys --keyid-format=long)" ]; then
                gpg --armor --export > "$SCRIPT_DIR/gnupg/$(hostname -s).asc"
            fi
            ;;
        "ssh")
            if [ -f "$HOME/.ssh/id_rsa" ]; then
                cp "$HOME/.ssh/id_rsa.pub" "$SCRIPT_DIR/ssh/$(hostname -s).pub"
            fi
            ;;
        "tmux")
            rm -rf $SCRIPT_DIR/tmux/plugins/tpm
            git clone https://github.com/tmux-plugins/tpm $SCRIPT_DIR/tmux/plugins/tpm
            source $SCRIPT_DIR/tmux/plugins/tpm/bin/install_plugins
            ;;
        "vim")
            fetch_file "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim" "$SCRIPT_DIR/vim/autoload"
            ;;
        "vscode")
            if command -v code >/dev/null 2>&1; then
                echo "#!/bin/bash" > $SCRIPT_DIR/vscode/install_extensions.sh
                code --list-extensions | while read -r extension; do
                    echo "code --install-extension \"$extension\"" >> $SCRIPT_DIR/vscode/install_extensions.sh
                done
                chmod +x $SCRIPT_DIR/vscode/install_extensions.sh
            fi
            ;;
        "zsh")
            rm -rf $SCRIPT_DIR/zsh/ohmyzsh
            rm -rf $SCRIPT_DIR/zsh/.antigen
            mkdir -p $SCRIPT_DIR/zsh/.antigen
            fetch_file "https://raw.githubusercontent.com/zsh-users/antigen/master/bin/antigen.zsh" "$SCRIPT_DIR/zsh/.antigen"
            if [[ "$SHELL" == "/bin/zsh" ]]; then
                sh -c "RUNZSH=no ZSH=$SCRIPT_DIR/zsh/ohmyzsh $(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) --keep-zshrc"
            fi
            # Use 'antigen reset' in the zsh shell if p10k does not load.
            ;;
    esac
}

if [ -n "$1" ]; then
    download "$1"
    echo "Ran download.sh for $1"
else
    # Upgrades brew formulae
    brew upgrade

    # Upgrades rust
    rustup update

    # Upgrades bun
    bun upgrade

    # Updates goose
    goose update

    for dir in */ .*/; do
        download "${dir%/}"
    done
fi
