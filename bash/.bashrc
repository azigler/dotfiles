[ -z "$PS1" ] && return

source "$HOME/.local/share/tmux/start.sh"

[[ ! -f "$HOME/.bash_$(hostname -s)" ]] || source "$HOME/.bash_$(hostname -s)"

[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"
