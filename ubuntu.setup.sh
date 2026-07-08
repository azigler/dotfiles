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
    ./sync.sh biome
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
    ./sync.sh git
    ./sync.sh nix
    ./sync.sh ranger
    ./sync.sh ripgrep
    ./sync.sh ruff
    ./sync.sh ssh
    ./sync.sh tmux
    ./sync.sh uv
    ./sync.sh vim

    ./download.sh tmux

    curl -fsSL https://bun.sh/install | bash
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    curl -LsSf https://astral.sh/uv/install.sh | sh

    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install --lts

    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

    curl -fsSL https://claude.ai/install.sh | bash
    curl https://cursor.com/install -fsS | bash

    curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash
    curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | bash

    # --- zig-zone (private tailnet) ---
    # Spec: bead dotfiles-phe. Runbook: /zig-zone skill.
    # Tags + SSH are NOT advertised here — Phase 1 of the migration runbook
    # adds them AFTER the ACL has been pasted into Tailscale admin.
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up   # interactive — browser SSO

    # --- Linters ---
    bun install -g @biomejs/biome
    uv tool install ruff
    curl -sSfL https://golangci-lint.run/install.sh | sh -s -- -b "$HOME/.local/bin"

    # --- agentgateway (AI-native gateway) + agctl CLI ---
    curl -fsSL -o "$HOME/.local/bin/agentgateway" https://github.com/agentgateway/agentgateway/releases/latest/download/agentgateway-linux-amd64
    curl -fsSL -o "$HOME/.local/bin/agctl" https://github.com/agentgateway/agentgateway/releases/latest/download/agctl-linux-amd64
    chmod +x "$HOME/.local/bin/agentgateway" "$HOME/.local/bin/agctl"

    # --- goose (Block's open-source AI agent, an AAIF project) ---
    curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash

    # --- gitleaks (secret scanner — foundational to the secret-hygiene system, explore-r2iq) ---
    GL_TAG=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/${GL_TAG}/gitleaks_${GL_TAG#v}_linux_x64.tar.gz" | tar xz -C "$HOME/.local/bin" gitleaks
    chmod +x "$HOME/.local/bin/gitleaks"

    exec sudo --login --user $USER

    nix --extra-experimental-features nix-command --extra-experimental-features flakes profile add 'nixpkgs#nix-direnv'

    bun install -g @google/gemini-cli
    bun install -g @openai/codex
    bun install -g @github/copilot
    bun install -g vercel
fi

echo " 🧢 RUN: cd /home/ubuntu/dotfiles && ./sync.sh zsh &&./download.sh zsh (say yes, then 'antigen reset' then 'exit' then 'tmux')"
echo " 🔑 AUTH: gh auth login -p https -h github.com -w"
echo " 🔑 AUTH: claude"
echo " 🔑 AUTH: gemini"
echo " 🔑 AUTH: cursor"
echo " 🔑 AUTH: codex"
echo " 🔑 AUTH: copilot"
echo " 🦕 UPGRADE: sudo apt-get update && sudo apt-get upgrade -y && sudo do-release-upgrade"
