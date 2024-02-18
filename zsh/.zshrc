[[ ! -f "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]] || source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"

[[ ! -f "$HOME/.$(hostname -s).zsh" ]] || source "$HOME/.$(hostname -s).zsh"

[[ ! -f "$HOME/.bash_aliases" ]] || source "$HOME/.bash_aliases"

zstyle ':omz:update' mode auto
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="%F{yellow}󰔟%f"
HIST_STAMPS="yyyy-mm-dd"

source $HOME/.oh-my-zsh/oh-my-zsh.sh
source $HOME/.antigen/antigen.zsh

antigen theme romkatv/powerlevel10k

antigen use oh-my-zsh

antigen bundle git
antigen bundle aws
antigen bundle docker
antigen bundle docker-compose
antigen bundle dotenv
antigen bundle multipass
antigen bundle yarn
antigen bundle npm
antigen bundle nvm
antigen bundle pyenv
antigen bundle vscode
antigen bundle jsontools
antigen bundle gh
antigen bundle vi-mode
antigen bundle web-search
antigen bundle pip

antigen bundle MichaelAquilina/zsh-you-should-use
antigen bundle zsh-users/zsh-autosuggestions
antigen bundle zsh-users/zsh-completions
antigen bundle zsh-users/zsh-syntax-highlighting

antigen apply

[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
