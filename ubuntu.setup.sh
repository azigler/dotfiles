# curl -fsSL "https://raw.githubusercontent.com/azigler/dotfiles/main/ubuntu.setup.sh" | bash

echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudo
sudo hostnamectl set-hostname zig-computer

git clone https://github.com/azigler/dotfiles ~/dotfiles

sudo do-release-upgrade
sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y

sudo apt install -y tmux gh ranger direnv zsh ripgrep fzf lazygit golang-go unzip

/bin/zsh /home/ubuntu/dotfiles/sync.sh bash
/bin/zsh /home/ubuntu/dotfiles/sync.sh bun
/bin/zsh /home/ubuntu/dotfiles/sync.sh cargo
/bin/zsh /home/ubuntu/dotfiles/sync.sh claude
/bin/zsh /home/ubuntu/dotfiles/sync.sh direnv
/bin/zsh /home/ubuntu/dotfiles/sync.sh editorconfig
/bin/zsh /home/ubuntu/dotfiles/sync.sh gh
/bin/zsh /home/ubuntu/dotfiles/sync.sh nix
/bin/zsh /home/ubuntu/dotfiles/sync.sh ranger
/bin/zsh /home/ubuntu/dotfiles/sync.sh ripgrep
/bin/zsh /home/ubuntu/dotfiles/sync.sh ssh
/bin/zsh /home/ubuntu/dotfiles/sync.sh tmux
/bin/zsh /home/ubuntu/dotfiles/sync.sh uv
/bin/zsh /home/ubuntu/dotfiles/sync.sh vim
/bin/zsh /home/ubuntu/dotfiles/sync.sh zsh

/bin/zsh /home/ubuntu/dotfiles/download.sh ssh
/bin/zsh /home/ubuntu/dotfiles/download.sh tmux
/bin/zsh /home/ubuntu/dotfiles/download.sh vim
/bin/zsh /home/ubuntu/dotfiles/download.sh zsh

sudo chsh -s $(which zsh)

curl -fsSL https://bun.sh/install | bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
curl -LsSf https://astral.sh/uv/install.sh | sh

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
nix profile install 'nixpkgs#nix-direnv'

curl -fsSL https://claude.ai/install.sh | bash
curl https://cursor.com/install -fsS | bash
bun install -g @google/gemini-cli
bun install -g @openai/codex
bun install -g @github/copilot

curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | sudo zsh
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | sudo zsh

#gh auth login
