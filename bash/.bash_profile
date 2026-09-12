if [ "$SHELL" = "/bin/bash" ]; then
    [[ ! -f "$HOME/.bashrc" ]] || source $HOME/.bashrc
fi

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"  # guarded: absent on boxes without rust (pico)

. "$HOME/.local/bin/env"
