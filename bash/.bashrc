[ -z "$PS1" ] && return

source "$HOME/.local/share/tmux/start.sh"

[[ ! -f "$HOME/.$(hostname -s).bashrc" ]] || source "$HOME/.$(hostname -s).bashrc"

[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"

[[ ! -f "$HOME/.profile" ]] || source "$HOME/.profile"
