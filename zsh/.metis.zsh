export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/share/dotnet/x64:$HOME/.bun/bin:$HOME/.local/bin:$PATH"

export EDITOR="vim"
export VISUAL=$EDITOR

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

export PNPM_HOME="/Users/andrew/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

__conda_setup="$('/Users/andrew/anaconda3/bin/conda' 'shell.bash' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/Users/andrew/anaconda3/etc/profile.d/conda.sh" ]; then
        . "/Users/andrew/anaconda3/etc/profile.d/conda.sh"
    else
        export PATH="/Users/andrew/anaconda3/bin:$PATH"
    fi
fi

eval "$(gh copilot alias -- zsh)"

