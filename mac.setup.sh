xcode-select --install

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install tmux jq gh ranger font-sauce-code-pro-nerd-font koekeishiya/formulae/yabai koekeishiya/formulae/skhd FelixKratz/formulae/borders FelixKratz/formulae/sketchybar multipass flyctl qemu direnv claude vercel-cli dicklesworthstone/tap/bv ollama tailscale colima docker docker-compose

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
curl -fsSL https://get.pnpm.io/install.sh | sh -
curl -fsSL https://bun.sh/install | bash
curl -LsSf https://astral.sh/uv/install.sh | sh
curl -fsSL https://deno.land/install.sh | sh
curl -L https://nixos.org/nix/install | sh
curl -fsS https://cursor.com/install  | bash
curl -fsSL https://claude.ai/install.sh | bash

nix profile install 'nixpkgs#nix-direnv'

uv tool install claude-monitor

gh auth login
curl -fsSL https://gh.io/copilot-install | bash

fly auth login

# https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection
# https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(from-HEAD)#configure-scripting-addition
echo "$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 $(which yabai) | cut -d " " -f 1) $(which yabai) --load-sa" | sudo tee /private/etc/sudoers.d/yabai

brew services start felixkratz/formulae/sketchybar
brew services start felixkratz/formulae/borders
yabai --start-service
skhd --start-service

npm install -g @github/copilot wrangler

curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash

# --- zig-zone (private tailnet + ollama server) bring-up ---
# Spec: bead dotfiles-phe. Runbook: ~/explore/.claude/skills/zig-zone/SKILL.md.
# Idempotent — re-running mac.setup.sh re-applies these without harm.
#
# IMPORTANT macOS Tailscale variant note (runbook gotcha #12):
# This script installs the brew FORMULA (CLI/headless tailscaled). That gives
# Tailscale SSH server BUT no MagicDNS for outbound queries from this host.
# Right for HEADLESS SERVERS (e.g., pico). On a WORKSTATION Mac (e.g., metis),
# AFTER this script finishes, swap to the cask GUI variant for MagicDNS:
#   brew uninstall tailscale && brew install --cask tailscale
#   sudo rm -f /usr/local/bin/tailscale /usr/local/bin/tailscaled  # remove stale formula symlinks
#   open -a Tailscale     # GUI auth flow
# Trade-off: GUI variants are sandboxed and CAN'T run Tailscale SSH server.
# Clients don't need to be SSH servers anyway, so this is fine for laptops.

# Headless-server safety: no sleep, auto-boot after power loss, no surprise reboots.
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0
sudo pmset -a autorestart 1
sudo softwareupdate --schedule off

# Tailscale daemon + interactive auth (opens browser for SSO).
# Tags + SSH are NOT advertised here — they come in Phase 1 AFTER the ACL
# has been pasted into the Tailscale admin console, otherwise the
# --advertise-tags call fails with "requested tags not permitted."
sudo brew services start tailscale
sudo tailscale up

# Ollama bound to the tailnet IP only (NOT 0.0.0.0, NOT 127.0.0.1).
# launchctl setenv makes OLLAMA_HOST visible to the LaunchAgent that
# `brew services start ollama` creates.
launchctl setenv OLLAMA_HOST "$(tailscale ip -4):11434"
brew services start ollama

# --- /etc/hosts MagicDNS shim (headless tailscaled doesn't install a resolver) ---
# On macOS, brew-formula tailscaled runs in userspace networking and can't
# install a DNS resolver. To let this host resolve other tailnet hostnames,
# mirror the tailnet IPs into /etc/hosts. Hand-maintained — re-sync if any
# device's tailnet IP changes (rare; happens on logout+rejoin). The runbook
# section "/etc/hosts shim" has the current canonical mapping.
echo "NOTE: see runbook for /etc/hosts shim entries (tailnet IPs for other devices)"

# --- Persistent tmux server (LaunchAgent, mirrors zig-computer's tmux.service) ---
# Creates a detached tmux session named after the hostname at user login.
# Requires the user to be logged in for LaunchAgents to fire — enable auto-login
# in System Settings → Users → Login Options for headless servers.
# The source plist has HOSTNAME_PLACEHOLDER as the session name; sed substitutes
# the actual hostname at install time so each Mac gets a uniquely-named session.
mkdir -p ~/Library/LaunchAgents
sed "s/HOSTNAME_PLACEHOLDER/$(hostname -s)/" \
    ~/dotfiles/tmux/com.zig.tmux.plist \
    > ~/Library/LaunchAgents/com.zig.tmux.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.tmux.plist
