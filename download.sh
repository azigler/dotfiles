#!/bin/bash
#
# download.sh — vendor the supporting resources (plugins, fonts, keys, extension
# lists) that the dotfiles in this repo depend on.
#
#   ./download.sh              # every case
#   ./download.sh cursor       # one case
#   ./download.sh cursor --prune   # see "Extension lists" below
#
# This script does NOT upgrade binaries. It used to: the no-argument branch ran
# brew/rustup/bun/deno/pnpm/claude/uv upgrades AND THEN every destructive vendor
# case, so there was no way to get the upgrades without also regenerating repo
# content, and no way to regenerate one thing without skipping the upgrades
# entirely (bead dotfiles-7bij). Binary upgrades now live in the per-machine
# upgrade scripts: mac.upgrade.sh, ubuntu.upgrade.sh, pico.upgrade.sh.
#
# Extension lists: the `cursor` and `vscode` cases write TRACKED files from
# whatever is installed on the current box. That is additive by default — a
# machine with a subset of the extensions can only ever ADD to the canonical
# list, never silently shrink it. Pass --prune to make the tracked list match
# this machine exactly (deliberate removal); review that diff before committing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $SCRIPT_DIR

PRUNE_EXTENSIONS=${PRUNE_EXTENSIONS:-0}
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --prune) PRUNE_EXTENSIONS=1 ;;
        *)       ARGS+=("$arg") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

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

# Regenerate a tracked install_extensions.sh from the editor's installed set.
#   $1: the editor CLI (`cursor` / `code`)
#   $2: the tracked script to write
#
# ADDITIVE by default. The old version piped `--list-extensions` straight over
# the tracked file, so running it on a machine with fewer extensions deleted
# entries from the canonical list — a silent, lossy, machine-dependent overwrite
# of shared state, and the worst of the download.sh cases (bead dotfiles-7bij).
# The union means a subset machine is now a no-op instead of a regression.
sync_extensions() {
    local cli=$1
    local out=$2

    if ! command -v "$cli" >/dev/null 2>&1; then
        echo "⏭  $cli not installed; leaving $(basename "$out") untouched"
        return
    fi

    local installed
    installed=$("$cli" --list-extensions)
    if [ -z "$installed" ]; then
        # A CLI that lists nothing is far more likely to be broken than to be a
        # genuinely empty install. Never let that outcome reach a tracked file.
        echo "⏭  $cli reported ZERO extensions; refusing to rewrite $(basename "$out")"
        return
    fi

    local tracked=""
    [ -f "$out" ] && tracked=$(sed -n "s/^$cli --install-extension \"\(.*\)\"\$/\1/p" "$out")

    local merged
    if [ "$PRUNE_EXTENSIONS" = "1" ]; then
        merged=$installed
    else
        merged=$(printf '%s\n%s\n' "$tracked" "$installed")
    fi
    # -f so a case-only duplicate collapses; extension ids are case-insensitive.
    merged=$(printf '%s\n' "$merged" | grep -v '^[[:space:]]*$' | sort -fu)

    {
        echo "#!/bin/bash"
        printf '%s\n' "$merged" | while IFS= read -r ext; do
            printf '%s --install-extension "%s"\n' "$cli" "$ext"
        done
    } > "$out"
    chmod +x "$out"

    local before after
    before=$(printf '%s\n' "$tracked" | grep -c '[^[:space:]]')
    after=$(printf '%s\n' "$merged" | grep -c '[^[:space:]]')
    if [ "$PRUNE_EXTENSIONS" = "1" ]; then
        echo "✅ $(basename "$out"): pruned to this machine — $before → $after entries"
    else
        echo "✅ $(basename "$out"): merged (additive) — $before → $after entries"
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
            sync_extensions cursor "$SCRIPT_DIR/cursor/install_extensions.sh"
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
            if command -v gpg >/dev/null 2>&1; then
              mkdir -p "$HOME/.gnupg"
              chmod -R u=rw,u+X,go= $HOME/.gnupg
              if [ -n "$(gpg --list-secret-keys --keyid-format=long)" ]; then
                gpg --armor --export > "$SCRIPT_DIR/gnupg/$(hostname -s).asc"
              fi
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
            sync_extensions code "$SCRIPT_DIR/vscode/install_extensions.sh"
            ;;
        "zsh")
            rm -rf $SCRIPT_DIR/zsh/ohmyzsh
            rm -rf $SCRIPT_DIR/zsh/.antigen
            mkdir -p $SCRIPT_DIR/zsh/.antigen
            fetch_file "https://raw.githubusercontent.com/zsh-users/antigen/master/bin/antigen.zsh" "$SCRIPT_DIR/zsh/.antigen"
            sh -c "ZSH=$SCRIPT_DIR/zsh/ohmyzsh $(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) --keep-zshrc"
            # Use 'antigen reset' in the zsh shell if p10k does not load.
            ;;
    esac
}

if [ -n "${1:-}" ]; then
    download "$1"
    echo "Ran download.sh for $1"
else
    # No binary upgrades here — see the header. Use the machine's upgrade script:
    #   macOS workstation : bash mac.upgrade.sh
    #   Linux             : bash ubuntu.upgrade.sh
    #   pico (mac server) : bash pico.upgrade.sh
    for dir in */ .*/; do
        download "${dir%/}"
    done
fi
