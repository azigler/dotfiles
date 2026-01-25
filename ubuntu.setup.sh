# curl -fsSL "https://raw.githubusercontent.com/azigler/dotfiles/main/ubuntu.setup.sh" | bash

echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudo
sudo hostnamectl set-hostname zig-computer

git clone https://github.com/azigler/dotfiles /home/ubuntu/dotfiles

cd /home/ubuntu/dotfiles

/bin/zsh sync.sh bash
/bin/zsh sync.sh bun
/bin/zsh sync.sh cargo
/bin/zsh sync.sh claude
/bin/zsh sync.sh direnv
/bin/zsh sync.sh editorconfig
/bin/zsh sync.sh gh
/bin/zsh sync.sh nix
/bin/zsh sync.sh ranger
/bin/zsh sync.sh ripgrep
/bin/zsh sync.sh ssh
/bin/zsh sync.sh tmux
/bin/zsh sync.sh uv
/bin/zsh sync.sh vim
/bin/zsh sync.sh zsh

/bin/zsh download.sh ssh
/bin/zsh download.sh tmux
/bin/zsh download.sh vim
/bin/zsh download.sh zsh

sudo do-release-upgrade
sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get upgrade -y

sudo apt install -y tmux gh ranger direnv zsh ripgrep fzf lazygit golang-go unzip

sudo chsh -s $(which zsh)

curl -fsSL https://bun.sh/install | bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
curl -LsSf https://astral.sh/uv/install.sh | sh

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

curl -fsSL https://claude.ai/install.sh | bash
curl https://cursor.com/install -fsS | bash

curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | bash

exec sudo --login --user $USER

nix --extra-experimental-features nix-command --extra-experimental-features flakes profile add 'nixpkgs#nix-direnv'

bun install -g @google/gemini-cli
bun install -g @openai/codex
bun install -g @github/copilot

#gh auth login
#https://github.com/login/device
#claude
#gemini cli
#codex
#copilot
