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
        echo "Error: Failed to download $url"
        exit 1
    fi
}

for dir in */ .*/; do
    case ${dir%/} in
        "alacritty")
            fetch_file "https://github.com/catppuccin/alacritty/raw/main/catppuccin-macchiato.toml" "$SCRIPT_DIR/alacritty"
            ;;
        "blightmud")
            rm -rf "$SCRIPT_DIR/blightmud/plugins/blightmud_mcp"
            git clone https://github.com/lisdude/blightmud_mcp "$SCRIPT_DIR/blightmud/plugins/blightmud_mcp"
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
            gpg --armor --export > "$SCRIPT_DIR/gnupg/$(hostname -s).asc"
            ;;
        "ssh")
            cp "$HOME/.ssh/id_rsa.pub" "$SCRIPT_DIR/ssh/$(hostname -s).pub"
            ;;
        "vim")
            fetch_file "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim" "$SCRIPT_DIR/vim/autoload"
            ;;
        "vscode")
            if command -v my_command >/dev/null 2>&1; then
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
            sh -c "RUNZSH=no ZSH=$SCRIPT_DIR/zsh/ohmyzsh $(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) --keep-zshrc"
            fetch_file "https://raw.githubusercontent.com/zsh-users/antigen/master/bin/antigen.zsh" "$SCRIPT_DIR/zsh/.antigen"
            ;;
    esac
done
