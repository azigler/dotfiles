# curl -fsSL "https://raw.githubusercontent.com/azigler/dotfiles/main/ubuntu.setup.sh" | bash

echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudo
sudo hostnamectl set-hostname zig-computer

git clone https://github.com/azigler/dotfiles ~/dotfiles

sudo do-release-upgrade
sudo apt-get update
sudo apt-get upgrade

sudo apt install -y tmux gh ranger direnv zsh ripgrep fzf lazygit golang-go astral-uv

zsh ~/dotfiles/sync.sh bash
zsh ~/dotfiles/sync.sh bun
zsh ~/dotfiles/sync.sh cargo
zsh ~/dotfiles/sync.sh claude
zsh ~/dotfiles/sync.sh direnv
zsh ~/dotfiles/sync.sh editorconfig
zsh ~/dotfiles/sync.sh gh
zsh ~/dotfiles/sync.sh nix
zsh ~/dotfiles/sync.sh ranger
zsh ~/dotfiles/sync.sh ripgrep
zsh ~/dotfiles/sync.sh ssh
zsh ~/dotfiles/sync.sh tmux
zsh ~/dotfiles/sync.sh uv
zsh ~/dotfiles/sync.sh vim
zsh ~/dotfiles/sync.sh zsh

zsh ~/dotfiles/download.sh ssh
zsh ~/dotfiles/download.sh tmux
zsh ~/dotfiles/download.sh vim
zsh ~/dotfiles/download.sh zsh

sudo chsh -s $(which zsh)

curl -fsSL https://bun.sh/install | sudo zsh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sudo zsh

curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sudo zsh

curl -L https://nixos.org/nix/install | sudo zsh
nix profile install 'nixpkgs#nix-direnv'

curl -fsSL https://claude.ai/install.sh | sudo zsh
curl -fsSL https://cursor.com/install  | sudo zsh
curl -fsSL https://gh.io/copilot-install | sudo zsh
bun install -g @google/gemini-cli
bun install -g @openai/codex

curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | sudo zsh
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | sudo zsh

gh extension install github/gh-copilot

#gh auth login
