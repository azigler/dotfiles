export GOPATH="$HOME/.go"

export PATH="$GOPATH/bin:$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"

export EDITOR="vim"
export VISUAL=$EDITOR
export PAGER="less"
export SHELL="/bin/zsh"

export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

eval "$(direnv hook zsh)"
source <(fzf --zsh)

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
