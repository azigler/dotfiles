if [ "$SHELL" = "/bin/bash" ]; then
    [[ ! -f "$HOME/.bashrc" ]] || source $HOME/.bashrc
fi

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
. "$HOME/.cargo/env"

. "$HOME/.local/bin/env"
