# vps-8a9eb245 — per-host interactive zsh env.
# Sourced by zsh/.zshrc via `source "$HOME/.$(hostname -s).zsh"`.
# Non-interactive shells (ssh host "cmd") get their PATH from
# .vps-8a9eb245.zshenv instead — keep the two in agreement.
#
# Every toolchain hook here is GUARDED. This is a remote box whose login
# shell is /usr/bin/zsh: an unguarded `eval "$(foo hook zsh)"` for a tool
# that isn't installed emits an error on every single shell start, and a
# hard failure here is an SSH lockout with no local console to fix it from.
# (The older per-host files — .zig-computer.zsh, .zig.zsh, .metis.zsh — run
# these unguarded. Those are laptops with a physical keyboard; this isn't.)

export GOPATH="${GOPATH:-$HOME/go}"

# Ordered most- to least-specific. Only real directories get prepended, so a
# not-yet-installed toolchain leaves no dead entry behind.
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
export SHELL="/usr/bin/zsh"

[ -f "$HOME/.ripgreprc" ] && export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

command -v direnv >/dev/null && eval "$(direnv hook zsh)"
command -v fzf >/dev/null && source <(fzf --zsh)

# ~/.secrets is machine-local and gitignored (template: bash/.secrets.example).
# Not present on this box yet — the guard keeps that from being a shell error.
[ -f "$HOME/.secrets" ] && source "$HOME/.secrets"
