export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"

export EDITOR="vim"
export VISUAL=$EDITOR
export PAGER="less"
export SHELL="/bin/zsh"

export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

eval "$(direnv hook zsh)"
source <(fzf --zsh)
