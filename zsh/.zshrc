if [[ $TERM_PROGRAM == "WarpTerminal" ]]; then
    [[ ! -f "$HOME/.warp.zshrc" ]] || source "$HOME/.warp.zshrc"
    return
fi

source "$HOME/.local/share/tmux/start.sh"

# Instant prompt is a tty feature: skip it when stdout is not a tty (dotfiles-oivj).
[[ ! -t 1 || ! -f "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]] || source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"

[[ ! -f "$HOME/.$(hostname -s).zsh" ]] || source "$HOME/.$(hostname -s).zsh"

[[ ! -f "$HOME/.bun/_bun" ]] || source "$HOME/.bun/_bun"
fpath+="$HOME/.bun"

zstyle ':omz:update' mode auto
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="%F{yellow}󰔟%f"
HIST_STAMPS="yyyy-mm-dd"

source $HOME/.oh-my-zsh/oh-my-zsh.sh
source $HOME/.antigen/antigen.zsh

antigen theme romkatv/powerlevel10k

antigen use oh-my-zsh

antigen bundle docker
antigen bundle docker-compose
antigen bundle gh
antigen bundle git
antigen bundle gpg-agent
antigen bundle jsontools
antigen bundle npm
antigen bundle nvm
antigen bundle pip
antigen bundle systemadmin
antigen bundle tmux
antigen bundle web-search

antigen bundle zsh-users/zsh-autosuggestions
antigen bundle zsh-users/zsh-completions
antigen bundle zsh-users/zsh-syntax-highlighting

antigen apply

# Reclaim `tmux` for the real binary. The oh-my-zsh `tmux` bundle aliases
# `tmux` -> _zsh_tmux_plugin_run, which names a session after the $PWD
# basename and auto-attaches/creates it (ZSH_TMUX_AUTOCONNECT=true). A bare
# `tmux` from the wrong directory then silently spins up a session (e.g. a
# `hermes` dispatch session the broker immediately populated with servitors
# -> runaway session/RAM leak — Hermes itself is retired, 2026-08-08,
# `dotfiles-j4ps`, but the tmux-hijack risk this guards against is generic
# to any broker that shells out bare `tmux`). Anything wanting the wrapper
# calls `tmuxa`. Still needed after the .bash_aliases move (dotfiles-bqz4):
# .bash_aliases defines no `tmux` alias, so load order alone does not clear it.
unalias tmux 2>/dev/null
alias tmuxa='_zsh_tmux_plugin_run'

# Load the user aliases LAST among the alias sources, after `antigen apply`, so an
# oh-my-zsh or antigen plugin alias (ls, ll, la, grep, mkdir, ...) cannot shadow
# them (dotfiles-bqz4). Sourced earlier, the plugins won and every ls-family alias
# in .bash_aliases was dead in zsh.
[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"

# p10k (and its gitstatus daemon) only when stdout is a tty: a script's `zsh -ic`
# otherwise prints a red gitstatus ERROR and extra lines to stderr (dotfiles-oivj).
[[ ! -t 1 || ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

unsetopt correct_all
unsetopt correct
ENABLE_CORRECTION="false"

[[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env"

# bun completions ($HOME, not a hardcoded /home/ubuntu — identical on
# zig-computer, and no longer a dead path on every other box)
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

unalias br 2>/dev/null  # br installer - remove conflicting alias

# pnpm — $HOME rather than a hardcoded /home/ubuntu (identical on zig-computer).
# Also guarded on the directory existing, so a box without pnpm stops carrying a
# dead PATH entry, and the per-host PNPM_HOME set earlier in .$(hostname -s).zsh
# survives instead of being overwritten by a path that belongs to another machine.
if [ -d "$HOME/.local/share/pnpm" ]; then
  export PNPM_HOME="$HOME/.local/share/pnpm"
  case ":$PATH:" in
    *":$PNPM_HOME:"*) ;;
    *) export PATH="$PNPM_HOME:$PATH" ;;
  esac
fi
# pnpm end

# ensure ~/.local/bin is on PATH (user tools: mlx, br, bv, claude, etc. — no
# longer the hermes CLI, retired 2026-08-08, `dotfiles-j4ps`)
export PATH="$HOME/.local/bin:$PATH"

# Machine-local additions (installer-appended PATHs, completions, tool envs) live in
# ~/.zshrc.local — never in this tracked file, so a clone stays fast-forwardable on
# every box (dotfiles-ph1m: pico carried 8 staged local mods for 3 months).
[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"

# Added by flyctl installer
export FLYCTL_INSTALL="/home/ubuntu/.fly"
export PATH="$FLYCTL_INSTALL/bin:$PATH"
