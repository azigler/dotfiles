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
# We install a CUSTOM LaunchAgent (com.zig.ollama) instead of using
# `brew services start ollama`. Reason: brew regenerates its plist on
# every `services restart`, wiping any manual `OLLAMA_HOST` edit. Our
# plist owns the env vars (host, flash-attention, KV cache, keep-alive)
# and brew just provides the binary. See ollama/README.md for the why.
sed "s/TAILSCALE_IP_PLACEHOLDER/$(tailscale ip -4)/" \
    ~/dotfiles/ollama/com.zig.ollama.plist \
    > ~/Library/LaunchAgents/com.zig.ollama.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.ollama.plist

# --- Phoenix (Arize LLM observability) on tailnet ---
# Phoenix 13+ needs Python ≥ 3.10; pico's system Python is 3.9, so we install
# 3.13 via uv first. Same custom-LaunchAgent pattern as Ollama — own the env
# vars so PHOENIX_HOST is pinned to the tailnet IP.
uv python install 3.13
uv tool install --python 3.13 arize-phoenix
mkdir -p ~/phoenix-data
sed -e "s|TAILSCALE_IP_PLACEHOLDER|$(tailscale ip -4)|g" \
    -e "s|USER_HOME_PLACEHOLDER|$HOME|g" \
    ~/dotfiles/phoenix/com.zig.phoenix.plist \
    > ~/Library/LaunchAgents/com.zig.phoenix.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.phoenix.plist

# --- A1111 stable-diffusion-webui on tailnet + LAN (NOT public internet) ---
# Apple-Silicon SD inference, bound 0.0.0.0:7860 so tailnet AND home LAN devices
# reach it. Public-internet exposure is deliberately OMITTED — A1111 has no real
# auth; trust boundary is the network. Zig-computer's nginx does NOT proxy here.
# See a1111/README.md for posture details + access URLs + model directory layout.
#
# Apple-Silicon-specific quirks baked into webui-user.sh:
#  - Python 3.10 pinned (system 3.9 too old)
#  - MPS-friendly COMMANDLINE_ARGS (--upcast-sampling --no-half-vae etc.)
#  - STABLE_DIFFUSION_REPO override to w-e-w/stablediffusion mirror (Stability-AI
#    deleted the canonical repo; PR #17271 in upstream A1111 documents)
#
# First-run also requires setuptools<80 in the venv (newer setuptools dropped
# pkg_resources, which CLIP's setup.py imports) + CLIP pre-install with
# --no-build-isolation. See "first-boot fix" block below.
brew install cmake protobuf rust python@3.10 git wget
[ -d ~/stable-diffusion-webui ] || git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git ~/stable-diffusion-webui
cp ~/dotfiles/a1111/webui-user.sh ~/stable-diffusion-webui/webui-user.sh
# Seed config.json with upcast_attn=true (Settings-only toggle, no CLI flag in
# A1111 1.10). Required for SDXL inpainting on MPS — without it, Unet produces
# NaN tensors mid-generation and the call crashes. See a1111/config.json.
# Only seed if missing — preserves any UI-saved settings on re-runs.
[ -f ~/stable-diffusion-webui/config.json ] || cp ~/dotfiles/a1111/config.json ~/stable-diffusion-webui/config.json
# First-boot fix: create venv, downgrade setuptools, pre-install CLIP w/ no-build-isolation
# (the upstream A1111 first-launch flow hits ModuleNotFoundError: pkg_resources without this)
if [ ! -d ~/stable-diffusion-webui/venv ]; then
  /opt/homebrew/bin/python3.10 -m venv ~/stable-diffusion-webui/venv
  ~/stable-diffusion-webui/venv/bin/pip install --upgrade pip "setuptools<80" wheel
  ~/stable-diffusion-webui/venv/bin/pip install --no-build-isolation \
    "git+https://github.com/openai/CLIP.git@d50d76daa670286dd6cacf3bcd80b5e4823fc8e1"
fi
sed "s|USER_HOME_PLACEHOLDER|$HOME|g" \
    ~/dotfiles/a1111/com.zig.a1111.plist \
    > ~/Library/LaunchAgents/com.zig.a1111.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.a1111.plist

# --- ss14-wrapper PROXY-protocol-aware UDP+TCP daemon (tailnet, pico-side) ---
# Per spec dotfiles-9g1 (Approach C2: nginx + wrapper-pair + minimal
# Robust.Server patches). The wrapper accepts UDP+TCP from zig-computer's
# nginx stream block (which prepends PROXY-protocol headers carrying the
# real client IP), strips the header, and forwards the raw payload to
# Robust.Server on loopback. The wrapper also exposes a Unix-Domain-Socket
# LOOKUP API at /tmp/ss14-wrapper.sock so the patched Robust.Server can
# resolve "what's the real IP behind this loopback peer?" for moderation
# reads (bans, IPIntel, AdminAlertIfSharedConnection).
#
# Initial-dev port assignment: LISTEN=:11214, UPSTREAM=127.0.0.1:11215 — both
# in the test-port range (per /check dotfiles-9cj convention) to avoid
# colliding with live SS14 on :1212 until the full Robust.Server cutover is
# staged. At cutover, the plist's SS14_WRAPPER_LISTEN flips to
# TAILSCALE_IP:1212 and UPSTREAM flips to 127.0.0.1:1213 once Robust.Server
# moves its bind here.
#
# The binary is built natively on the Mac (Apple Silicon → darwin-arm64) —
# no cross-compile dance required. From Linux/CI, use ss14-wrapper/build.sh.
[ -d ~/ss14-wrapper ] || mkdir -p ~/ss14-wrapper
(cd ~/dotfiles/ss14-wrapper && go build -o ~/ss14-wrapper/ss14-wrapper .)
# Install + load LaunchAgent (idempotent: unload if already loaded, then load).
sed -e "s|TAILSCALE_IP_PLACEHOLDER|$(tailscale ip -4)|g" \
    -e "s|USER_HOME_PLACEHOLDER|$HOME|g" \
    ~/dotfiles/ss14-wrapper/com.zig.ss14-wrapper.plist \
    > ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist
launchctl unload ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist 2>/dev/null || true
launchctl load -w ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist

# --- sshd alt-port :2222 LaunchDaemon (system scope) ---
# macOS sshd runs via launchd socket-activation; the `Port` directive in
# /etc/ssh/sshd_config is ignored. To get a second listening port we
# install a second launchd job at /Library/LaunchDaemons/ that runs sshd
# on :2222 alongside Apple's :22. Needed for tag:server src → user-owned
# dst SSH (Tailscale SSH grammar has no syntax for that direction;
# tailscaled only intercepts :22 on the tailnet IP, so :2222 falls through
# to this sshd directly). See ssh/com.zig.sshd-alt-port.plist + bead
# dotfiles-wzh + zig-zone runbook gotcha #24 for the why.
sudo install -m 644 -o root -g wheel \
    ~/dotfiles/ssh/com.zig.sshd-alt-port.plist \
    /Library/LaunchDaemons/com.zig.sshd-alt-port.plist
sudo launchctl bootstrap system \
    /Library/LaunchDaemons/com.zig.sshd-alt-port.plist 2>/dev/null || true
# bootstrap is idempotent-ish but errors if already loaded; the `|| true`
# handles re-runs. If you need to apply a plist change later:
# sudo launchctl bootout system /Library/LaunchDaemons/com.zig.sshd-alt-port.plist
# sudo launchctl bootstrap system /Library/LaunchDaemons/com.zig.sshd-alt-port.plist

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
