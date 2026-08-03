# vps-8a9eb245 — per-host bash env.
# Sourced by bash/.bashrc via `source "$HOME/.$(hostname -s).bashrc"`.
# The bash twin of zsh/.vps-8a9eb245.zsh — keep the two in agreement; the
# login shell here is zsh, so bash is the fallback/scripting path.
#
# Guarded throughout, for the same reason the zsh file is: this is a remote
# box, and a hook that errors on every shell start is not locally fixable.

export GOPATH="${GOPATH:-$HOME/go}"

for _d in \
  "$HOME/.local/bin" \
  "$HOME/.cargo/bin" \
  "$HOME/.bun/bin" \
  "$GOPATH/bin" \
  "/usr/lib/go/bin"
do
  [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
unset _d
export PATH

export EDITOR="vim"
export VISUAL=$EDITOR
export PAGER="less"

[ -f "$HOME/.ripgreprc" ] && export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

command -v direnv >/dev/null && eval "$(direnv hook bash)"
command -v fzf >/dev/null && eval "$(fzf --bash)"

# ~/.secrets is machine-local and gitignored (template: bash/.secrets.example).
[ -f "$HOME/.secrets" ] && source "$HOME/.secrets"
