if [[ $TERM_PROGRAM == "WarpTerminal" ]]; then
    [[ ! -f "$HOME/.warp.zshrc" ]] || source "$HOME/.warp.zshrc"
    return
fi

source "$HOME/.local/share/tmux/start.sh"

[[ ! -f "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]] || source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"

[[ ! -f "$HOME/.$(hostname -s).zsh" ]] || source "$HOME/.$(hostname -s).zsh"

[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"

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
antigen bundle multipass
antigen bundle npm
antigen bundle nvm
antigen bundle pip
antigen bundle systemadmin
antigen bundle tmux
antigen bundle vscode
antigen bundle web-search
antigen bundle yarn

antigen bundle zsh-users/zsh-autosuggestions
antigen bundle zsh-users/zsh-completions
antigen bundle zsh-users/zsh-syntax-highlighting

antigen apply

[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

unsetopt correct_all
unsetopt correct
ENABLE_CORRECTION="false"

[[ -f "$HOME/.local/bin/env" ]] && . "$HOME/.local/bin/env"

# bun completions
[ -s "/home/ubuntu/.bun/_bun" ] && source "/home/ubuntu/.bun/_bun"

unalias br 2>/dev/null  # br installer - remove conflicting alias

# pnpm
export PNPM_HOME="/home/ubuntu/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end
