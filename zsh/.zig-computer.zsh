export PATH="/:$PATH"

export EDITOR="vim"
export VISUAL=$EDITOR
export PAGER="less"

export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

eval "$(direnv hook zsh)"
source <(fzf --zsh)
