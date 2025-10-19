xtools-select --install

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install tmux jq gh ranger font-sauce-code-pro-nerd-font koekeishiya/formulae/yabai koekeishiya/formulae/skhd FelixKratz/formulae/borders FelixKratz/formulae/sketchybar pnpm block-goose multipass flyctl qemu direnv

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
curl -fsSL https://get.pnpm.io/install.sh | sh -
curl -fsSL https://bun.sh/install | bash
curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | bash
curl -LsSf https://astral.sh/uv/install.sh | sh
curl -fsSL https://deno.land/install.sh | sh
curl -L https://nixos.org/nix/install | sh

gh auth login
gh extension install github/gh-copilot

fly auth login

# https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection
# https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(from-HEAD)#configure-scripting-addition
echo "$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 $(which yabai) | cut -d " " -f 1) $(which yabai) --load-sa" | sudo tee /private/etc/sudoers.d/yabai

brew services start felixkratz/formulae/sketchybar
brew services start felixkratz/formulae/borders
yabai --start-service
skhd --start-service

curl https://cursor.com/install -fsS | bash
npm install -g @github/copilot
