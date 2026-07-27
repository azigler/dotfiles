# vps-8a9eb245 — per-host NON-interactive env, sourced by zsh/.zshenv.
#
# This is the tier that `ssh host "cmd"` (and therefore remote pulse dispatch)
# actually runs in: no login shell, no .zshrc, no interactive hooks. Toolchain
# PATH entries have to live HERE for remote automation to resolve them without
# wrapping every call in `bash -lc`.
#
# Originally written straight to ~/.zshenv on 2026-07-27 during VPS migration
# Phase 1.2 (bead bd-d2kt). Moved into the repo as a per-host file so that
# `sync.sh zsh` — which symlinks the fleet-wide zsh/.zshenv over ~/.zshenv —
# stops silently reverting it. Additive only: never clobber $PATH.

export BUN_INSTALL="$HOME/.bun"
[ -d "$BUN_INSTALL/bin" ] && PATH="$BUN_INSTALL/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
# Resolve node's bin dir directly instead of sourcing nvm.sh — nvm.sh is slow
# and noisy in non-interactive shells. Interactive zsh still loads nvm proper
# via .vps-8a9eb245.zsh, and this entry is harmlessly redundant there.
if [ -d "$NVM_DIR/versions/node" ]; then
  _nvm_node_bin="$(command ls -1d "$NVM_DIR"/versions/node/v*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$_nvm_node_bin" ] && [ -d "$_nvm_node_bin" ] && PATH="$_nvm_node_bin:$PATH"
  unset _nvm_node_bin
fi

[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"

export PATH
