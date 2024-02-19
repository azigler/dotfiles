if [[ "$OSTYPE" == "darwin"* ]]; then
    alias abrew="/opt/homebrew/bin/brew"
    alias ibrew="arch -x86_64 /usr/local/bin/brew"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [ -x /usr/bin/dircolors ]; then
        test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
        alias ls='ls --color=auto'
        alias dir='dir --color=auto'
        alias vdir='vdir --color=auto'

        alias grep='grep --color=auto'
        alias fgrep='fgrep --color=auto'
        alias egrep='egrep --color=auto'
    fi
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
