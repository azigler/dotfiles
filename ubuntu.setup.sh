# curl -fsSL "https://raw.githubusercontent.com/azigler/dotfiles/main/ubuntu.setup.sh" | bash
# Ubuntu 25.10 LTS (Questing Quokka)

if [ "$(lsb_release -rs)" != "25.10" ]; then
    echo "This script is only for Ubuntu 25.10 LTS (Questing Quokka)"
    echo " 🦕 UPGRADE: sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade && sudo do-release-upgrade"
    exit 1
fi

if ! sudo grep -q "$USER ALL=(ALL) NOPASSWD:ALL" /etc/sudoers; then
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
    echo " 🤝 PASSWORDLESS SUDO GRANTED"
fi

if [ "$(hostname -s)" != "zig-computer" ]; then
    sudo hostnamectl set-hostname zig-computer

    git clone https://github.com/azigler/dotfiles /home/ubuntu/dotfiles

    sudo apt-get update
    sudo apt-get upgrade -y

    sudo apt install -y gh ranger direnv zsh ripgrep lazygit fzf golang-go unzip

    cd /home/ubuntu/dotfiles

    ./download.sh ssh
    ./download.sh vim

    ./sync.sh bash
    ./sync.sh bun
    ./sync.sh cargo
    ./sync.sh claude
    ./sync.sh codex
    ./sync.sh copilot
    ./sync.sh cursor
    ./sync.sh direnv
    ./sync.sh editorconfig
    ./sync.sh gemini
    ./sync.sh gh
    ./sync.sh nix
    ./sync.sh ranger
    ./sync.sh ripgrep
    ./sync.sh ssh
    ./sync.sh tmux
    ./sync.sh uv
    ./sync.sh vim
    ./sync.sh zsh

    ./download.sh tmux

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
fi

echo " 🧢 RUN: cd /home/ubuntu/dotfiles && ./download.sh zsh (say yes, then 'antigen reset' then 'exit' then 'tmux')"
echo " 🔑 AUTH: gh auth login -p https -h github.com -w"
echo " 🔑 AUTH: claude"
echo " 🔑 AUTH: gemini"
echo " 🔑 AUTH: cursor"
echo " 🔑 AUTH: codex"
echo " 🔑 AUTH: copilot"
echo " 🦕 UPGRADE: sudo apt-get update && sudo apt-get upgrade -y && sudo do-release-upgrade"
