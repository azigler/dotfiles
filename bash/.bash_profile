# Per-host NON-interactive env, the bash twin of zsh/.zshenv's per-host hook
# (dotfiles-69tnl). Before the interactive branch, so bash -lc gets it too.
[ -f "$HOME/.${HOSTNAME%%.*}.bashenv" ] && . "$HOME/.${HOSTNAME%%.*}.bashenv"

if [ "$SHELL" = "/bin/bash" ]; then
    [[ ! -f "$HOME/.bashrc" ]] || source $HOME/.bashrc
fi

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"  # guarded: absent on boxes without rust (pico)

. "$HOME/.local/bin/env"
