export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$HOME/.cargo/bin:$PATH"

export EDITOR="vim"
export VISUAL=$EDITOR

export HISTFILESIZE=10000
export HISTSIZE=500
export HISTCONTROL="ignoreboth:erasedups"
export HISTTIMEFORMAT="%Y-%m-%d %H:%M  "
shopt -s histappend

shopt -s checkwinsize

export GPG_TTY=$(tty)

[ -x "/usr/bin/lesspipe" ] && eval "$(lesspipe)"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)"
fi

__conda_setup="$('/home/ubuntu/miniconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/home/ubuntu/miniconda3/etc/profile.d/conda.sh" ]; then
        . "/home/ubuntu/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="/home/ubuntu/miniconda3/bin:$PATH"
    fi
fi

[ -s "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if command -v dircolors >/dev/null 2>&1; then
        if [ -e "$HOME/.dircolors" ]; then
            eval "$(dircolors -b $HOME/.dircolors)"
        else
            eval "$(dircolors -b)"	
        fi
    fi
fi
