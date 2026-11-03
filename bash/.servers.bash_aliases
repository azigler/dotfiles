# Server aliases, sourced by ~/.bash_aliases AFTER ~/.secrets (dotfiles-glhe).
# The VPS address lives in ~/.secrets as ZIG_COMPUTER_IP, never in this public file.
alias zig-computer='ssh ubuntu@"${ZIG_COMPUTER_IP:?set ZIG_COMPUTER_IP in ~/.secrets}"'
