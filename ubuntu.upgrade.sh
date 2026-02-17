#!/usr/bin/env bash
# Upgrade all binaries installed by ubuntu.setup.sh
# Usage: bash ubuntu.upgrade.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

section() {
    echo ""
    echo -e "${GREEN}==> $1${NC}"
}

warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

fail() {
    echo -e "${RED}  ✗ $1${NC}"
}

# --- APT packages ---
# gh, ranger, direnv, zsh, ripgrep, lazygit, fzf, golang-go, unzip
section "Upgrading APT packages"
sudo apt-get update
sudo apt-get upgrade -y

# --- Bun ---
section "Upgrading Bun"
if command -v bun &>/dev/null; then
    bun upgrade
else
    warn "bun not found, reinstalling"
    curl -fsSL https://bun.sh/install | bash
fi

# --- Rust (via rustup) ---
section "Upgrading Rust toolchain"
if command -v rustup &>/dev/null; then
    rustup update
else
    warn "rustup not found, reinstalling"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

# --- uv ---
section "Upgrading uv"
if command -v uv &>/dev/null; then
    uv self update
else
    warn "uv not found, reinstalling"
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# --- Oh My Zsh ---
section "Upgrading Oh My Zsh"
OMZ="${ZSH:-$HOME/.oh-my-zsh}"
if [ -d "$OMZ" ]; then
    env ZSH="$OMZ" zsh "$OMZ/tools/upgrade.sh"
else
    warn "Oh My Zsh not found at $OMZ"
fi

# --- Nix ---
section "Upgrading Nix"
if command -v nix &>/dev/null; then
    sudo /nix/var/nix/profiles/default/bin/nix-channel --update && sudo /nix/var/nix/profiles/default/bin/nix-env -iA nixpkgs.nix nixpkgs.cacert -p /nix/var/nix/profiles/default
else
    warn "nix not found"
fi

# --- nix-direnv (nix profile) ---
section "Upgrading nix-direnv"
if command -v nix &>/dev/null; then
    nix --extra-experimental-features nix-command --extra-experimental-features flakes profile upgrade nix-direnv
else
    warn "nix not found, skipping nix profile upgrades"
fi

# --- Claude Code ---
section "Upgrading Claude Code"
if command -v claude &>/dev/null; then
    claude update || {
        warn "claude update failed, reinstalling via installer"
        curl -fsSL https://claude.ai/install.sh | bash
    }
else
    warn "claude not found, reinstalling"
    curl -fsSL https://claude.ai/install.sh | bash
fi

# --- Cursor ---
section "Upgrading Cursor"
curl https://cursor.com/install -fsS | bash

# --- beads_rust ---
section "Upgrading beads_rust"
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash

# --- beads_viewer ---
section "Upgrading beads_viewer"
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | bash

# --- Bun global packages ---
section "Upgrading Bun global packages"
if command -v bun &>/dev/null; then
    bun install -g @google/gemini-cli
    bun install -g @openai/codex
    bun install -g @github/copilot
    bun install -g vercel
else
    fail "bun not found, cannot upgrade global packages"
fi

section "Done"
echo "All upgrades complete."
