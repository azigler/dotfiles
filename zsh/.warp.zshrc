[[ ! -f "$HOME/.$(hostname -s).zsh" ]] || source "$HOME/.$(hostname -s).zsh"

[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"

[[ ! -f "$HOME/.bun/_bun" ]] || source "$HOME/.bun/_bun"
fpath+="$HOME/.bun"

zstyle ':omz:update' mode auto
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="%F{yellow}󰔟%f"
HIST_STAMPS="yyyy-mm-dd"

unsetopt correct_all
unsetopt correct
ENABLE_CORRECTION="false"
