# Sourced by EVERY zsh — including the non-login, non-interactive shell that
# `ssh host "cmd"` gets, which is the one remote automation actually runs in.
# Keep it cheap and strictly additive; never clobber $PATH.

# Guarded: an absent ~/.cargo/env used to error on every shell on a box
# without rustup.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Per-host NON-interactive env — the .zshenv-tier twin of the
# `.$(hostname -s).zsh` hook that .zshrc uses for interactive shells.
# ${HOST%%.*} rather than $(hostname -s): this file runs on every single zsh
# invocation, and a fork per shell is a cost worth not paying. zsh sets HOST
# itself, so the two agree.
[ -f "$HOME/.${HOST%%.*}.zshenv" ] && . "$HOME/.${HOST%%.*}.zshenv"
