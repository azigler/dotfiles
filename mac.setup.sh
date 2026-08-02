#!/usr/bin/env bash
# Provision a macOS box to fleet parity.
# Usage: bash mac.setup.sh
#
# `set -e` is ON: a failed REQUIRED installer stops the run instead of letting
# the script report success while a tool never landed (the dotfiles-cxle failure
# class). Steps that are legitimately optional — interactive auth, already-loaded
# LaunchAgents, a formula that is already present — end in `|| warn ...` so they
# can fail without aborting. If you add a step, decide which kind it is.
#
# --- Parity audit, probed 2026-08-01 (bead dotfiles-1r6k) --------------------
# Historical record of the gaps this script was changed to close. It is a
# SNAPSHOT of what three boxes had that day, not a live claim — re-probe with
# `command -v` before depending on any of it.
#
#   was MISSING on macOS, now installed here: rustup/cargo, ripgrep, fzf,
#   lazygit, gitleaks, go, biome, ruff, golangci-lint, goose, oh-my-zsh,
#   and the bun globals @google/gemini-cli + @openai/codex.
#
#   was DUAL-MANAGED (brew shadowed the newer curl-installed copy on PATH):
#   `bv` — brew 0.13.0 at /opt/homebrew/bin/bv beat ~/.local/bin/bv 0.18.0, so
#   running the curl installer on a Mac was a silent no-op. Resolved below in
#   favour of the curl installer, which is what ubuntu.upgrade.sh uses.
#   `vercel` — same shape (brew `vercel-cli` vs bun global); resolved to bun.
#   `rust` — brew's formula (pulled in by the A1111 block) vs rustup; resolved
#   to rustup, which is what ubuntu.setup.sh uses and what `.cargo/env` expects.
#
#   DELIBERATELY ABSENT on macOS:
#   - agentgateway / agctl — upstream publishes `*-linux-amd64` release assets
#     only, and the ubuntu/pico installs exist because those boxes SERVE the
#     gateway. A Mac workstation does not. Do not port the ubuntu snippet.
#   - apt-only plumbing (unzip, golang-go) — supplied by macOS or by brew.
#   - deno is Mac-only in the other direction; keep it, ubuntu does not need it.
#
#   KNOWN, not fixed here: `pnpm` is dual-managed on macOS the same way `bv`
#   was — the curl installer lands ~/Library/pnpm while a hand-installed brew
#   formula shadows it. This script only ever installed the curl copy, so the
#   brew formula is not its doing; do not `brew install pnpm`.
# ----------------------------------------------------------------------------

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

have() {
    command -v "$1" &>/dev/null
}

# --- Xcode command line tools ---
section "Xcode command line tools"
if xcode-select -p &>/dev/null; then
    echo "  already installed"
else
    xcode-select --install || warn "xcode-select --install returned non-zero (GUI installer may already be running)"
    echo "  finish the GUI installer before continuing if it opened"
fi

# --- Homebrew ---
section "Homebrew"
if have brew; then
    echo "  already installed: $(command -v brew)"
else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# Apple Silicon: brew is NOT on PATH in the shell that just installed it.
# Note the guard form: a bare `[ … ] && cmd` at top level returns 1 when the
# test is false, which under `set -e` would abort the whole run. Use `if`.
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
have brew || { fail "brew not on PATH after install — cannot continue"; exit 1; }

# Everything the curl installers below drop into these dirs is invisible to the
# rest of THIS process otherwise, which would make the final verify lie.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.deno/bin:$PATH"

# --- Brew formulae ---
# ripgrep / fzf / lazygit / gitleaks / go were the macOS parity gaps against
# ubuntu.setup.sh's apt line; `dicklesworthstone/tap/bv` and `vercel-cli` were
# removed from this line (see the dual-management note in the header).
section "Installing brew formulae"
brew install \
    tmux jq gh ranger font-sauce-code-pro-nerd-font \
    koekeishiya/formulae/yabai koekeishiya/formulae/skhd \
    FelixKratz/formulae/borders FelixKratz/formulae/sketchybar \
    multipass flyctl qemu direnv claude \
    ripgrep fzf lazygit gitleaks go \
    ollama tailscale colima docker docker-compose

# Retire the brew copy of bv if a previous run of this script installed it —
# it shadows the curl-installed binary on PATH and lags several minor versions.
if brew list --formula | grep -qx bv; then
    warn "removing brew's bv (it shadows ~/.local/bin/bv on PATH)"
    brew uninstall bv || warn "brew uninstall bv failed — remove it by hand"
fi

# --- Language runtimes + package managers ---
section "Installing language runtimes"
# nvm is a shell FUNCTION, never a binary — `command -v nvm` is always false in
# a script, so probe the install dir instead or this reinstalls on every run.
[ -d "$HOME/.nvm" ] || curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
have pnpm || curl -fsSL https://get.pnpm.io/install.sh | sh -
have bun  || curl -fsSL https://bun.sh/install | bash
have uv   || curl -LsSf https://astral.sh/uv/install.sh | sh
have deno || curl -fsSL https://deno.land/install.sh | sh
have nix  || curl -L https://nixos.org/nix/install | sh

# Rust toolchain. `bash/.profile` sources $HOME/.cargo/env unconditionally and
# sync.sh symlinks cargo/config.toml, so the repo has always ASSUMED a Rust
# toolchain here — but nothing installed one on macOS until 2026-08-01.
# Also supplies the rustfmt + clippy the /lint skill drives.
section "Installing Rust toolchain (rustup)"
if have rustup; then
    rustup update || warn "rustup update failed"
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi

section "Installing nix-direnv"
nix profile install 'nixpkgs#nix-direnv' || warn "nix profile install nix-direnv failed"

section "Installing uv tools"
uv tool install claude-monitor || warn "uv tool install claude-monitor failed"

# --- Oh My Zsh (zsh/.zshrc sources $HOME/.oh-my-zsh/oh-my-zsh.sh) ---
section "Installing Oh My Zsh"
if [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]; then
    echo "  already installed"
else
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# --- Lint toolchain (the /lint skill assumes all three are present) ---
section "Installing lint toolchain"
bun install -g @biomejs/biome || warn "biome install failed"
uv tool install ruff || warn "ruff install failed"
mkdir -p "$HOME/.local/bin"
curl -sSfL https://golangci-lint.run/install.sh | sh -s -- -b "$HOME/.local/bin" \
    || warn "golangci-lint install failed"

# --- goose (Block's open agent, AAIF project) ---
# bash/.bash_aliases carries a goose-jail alias that assumes this binary exists.
section "Installing goose"
curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash \
    || warn "goose install failed"

# --- beads_rust (br) + beads_viewer (bv) ---
# Both via the curl installers, matching ubuntu.upgrade.sh. Do NOT reintroduce
# the brew tap for bv — see the header note.
section "Installing beads_rust + beads_viewer"
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | bash

# --- GitHub + Fly auth (interactive) ---
section "Authenticating gh + fly"
gh auth login || warn "gh auth login skipped/failed"
fly auth login || warn "fly auth login skipped/failed"

# --- yabai scripting addition (needs SIP partially disabled) ---
# https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection
# https://github.com/koekeishiya/yabai/wiki/Installing-yabai-(from-HEAD)#configure-scripting-addition
section "Configuring yabai scripting addition + services"
if have yabai; then
    echo "$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 "$(command -v yabai)" | cut -d " " -f 1) $(command -v yabai) --load-sa" \
        | sudo tee /private/etc/sudoers.d/yabai \
        || warn "could not write /private/etc/sudoers.d/yabai — --load-sa will prompt"
else
    warn "yabai not installed — skipping scripting-addition sudoers entry"
fi

brew services start felixkratz/formulae/sketchybar || warn "sketchybar service start failed"
brew services start felixkratz/formulae/borders || warn "borders service start failed"
if have yabai; then yabai --start-service || warn "yabai service start failed"; fi
if have skhd;  then skhd  --start-service || warn "skhd service start failed";  fi

# --- Global CLI agents (bun, matching ubuntu.setup.sh) ---
# gemini-cli and codex were the macOS gap; wrangler stays on npm because it is
# not part of the ubuntu set and has no bun-global counterpart there.
section "Installing global CLI agents"
bun install -g @google/gemini-cli || warn "gemini-cli install failed"
bun install -g @openai/codex || warn "codex install failed"
bun install -g @github/copilot || warn "copilot install failed"
bun install -g vercel || warn "vercel install failed"
npm install -g wrangler || warn "wrangler install failed"
curl -fsSL https://gh.io/copilot-install | bash || warn "gh copilot extension install failed"

# --- Cursor + Claude Code ---
section "Installing Cursor + Claude Code"
curl -fsS https://cursor.com/install | bash || warn "cursor install failed"
curl -fsSL https://claude.ai/install.sh | bash || warn "claude install failed"

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
section "Applying headless-server power settings"
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 || warn "pmset sleep settings failed"
sudo pmset -a autorestart 1 || warn "pmset autorestart failed"
sudo softwareupdate --schedule off || warn "softwareupdate --schedule off failed"

# Tailscale daemon + interactive auth (opens browser for SSO).
# Tags + SSH are NOT advertised here — they come in Phase 1 AFTER the ACL
# has been pasted into the Tailscale admin console, otherwise the
# --advertise-tags call fails with "requested tags not permitted."
section "Starting Tailscale"
sudo brew services start tailscale || warn "tailscale service start failed"
sudo tailscale up || warn "tailscale up skipped/failed (interactive SSO)"

# Ollama bound to the tailnet IP only (NOT 0.0.0.0, NOT 127.0.0.1).
# We install a CUSTOM LaunchAgent (com.zig.ollama) instead of using
# `brew services start ollama`. Reason: brew regenerates its plist on
# every `services restart`, wiping any manual `OLLAMA_HOST` edit. Our
# plist owns the env vars (host, flash-attention, KV cache, keep-alive)
# and brew just provides the binary. See ollama/README.md for the why.
section "Installing Ollama LaunchAgent"
mkdir -p ~/Library/LaunchAgents
if have tailscale && TS_IP=$(tailscale ip -4) && [ -n "$TS_IP" ]; then
    sed "s/TAILSCALE_IP_PLACEHOLDER/$TS_IP/" \
        ~/dotfiles/ollama/com.zig.ollama.plist \
        > ~/Library/LaunchAgents/com.zig.ollama.plist
    launchctl load -w ~/Library/LaunchAgents/com.zig.ollama.plist || warn "ollama LaunchAgent already loaded"
else
    fail "no tailscale IP — skipping Ollama/Phoenix/MLX LaunchAgents (they bind the tailnet IP)"
    TS_IP=""
fi

# --- Phoenix (Arize LLM observability) on tailnet ---
# Phoenix 13+ needs Python ≥ 3.10; pico's system Python is 3.9, so we install
# 3.13 via uv first. Same custom-LaunchAgent pattern as Ollama — own the env
# vars so PHOENIX_HOST is pinned to the tailnet IP.
section "Installing Phoenix"
uv python install 3.13 || warn "uv python install 3.13 failed — Phoenix/MLX will not start"
uv tool install --python 3.13 arize-phoenix || warn "arize-phoenix install failed"
mkdir -p ~/phoenix-data
if [ -n "$TS_IP" ]; then
    sed -e "s|TAILSCALE_IP_PLACEHOLDER|$TS_IP|g" \
        -e "s|USER_HOME_PLACEHOLDER|$HOME|g" \
        ~/dotfiles/phoenix/com.zig.phoenix.plist \
        > ~/Library/LaunchAgents/com.zig.phoenix.plist
    launchctl load -w ~/Library/LaunchAgents/com.zig.phoenix.plist || warn "phoenix LaunchAgent already loaded"
fi

# --- MLX-LM server on tailnet (A/B'd against Ollama for coding-agent work) ---
# Apple MLX inference server, OpenAI-compatible API. Lives alongside Ollama
# (port 8081 vs Ollama's 11434) for empirical A/B benchmarks on the
# recommended coding models (Qwen3-Coder-30B, Devstral, GLM-4.5-Air) per the
# local-coding-models exploration in ~/explore/. See mlx/README.md for the
# full operations + model-pull workflow.
# Same custom-LaunchAgent pattern as Ollama/Phoenix — we own the bind + flags
# so they survive across reinstalls. Idempotent re-runs reuse existing model
# cache in ~/.cache/huggingface/.
section "Installing MLX-LM"
uv tool install --python 3.13 mlx-lm || warn "mlx-lm install failed"
if [ -n "$TS_IP" ]; then
    sed -e "s|TAILSCALE_IP_PLACEHOLDER|$TS_IP|g" \
        -e "s|USER_HOME_PLACEHOLDER|$HOME|g" \
        ~/dotfiles/mlx/com.zig.mlx.plist \
        > ~/Library/LaunchAgents/com.zig.mlx.plist
    launchctl load -w ~/Library/LaunchAgents/com.zig.mlx.plist || warn "mlx LaunchAgent already loaded"
fi

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
section "Installing A1111 stable-diffusion-webui"
# NB: brew's `rust` formula is deliberately NOT in this list even though A1111's
# wheel builds need a Rust compiler. rustup (installed above) already supplies
# rustc/cargo, and brew's copy would shadow ~/.cargo/bin on PATH — the same
# dual-management trap that made `bv` stale. One manager per tool.
brew install cmake protobuf python@3.10 git wget
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
# Register the LaunchAgent but DON'T auto-start. The plist has
# RunAtLoad=false because SD-WebUI loads its diffusion checkpoint
# (~17 GB) into RAM at launch, competing with LLM inference for
# unified memory. Use `sd-up` to start on demand, `sd-down` to stop.
launchctl bootstrap gui/"$UID" ~/Library/LaunchAgents/com.zig.a1111.plist || warn "a1111 LaunchAgent already bootstrapped"

# Install the on-demand helpers
sudo install -m 755 ~/dotfiles/a1111/sd-up /usr/local/bin/sd-up
sudo install -m 755 ~/dotfiles/a1111/sd-down /usr/local/bin/sd-down

# --- sshd alt-port :2222 LaunchDaemon (system scope) ---
# macOS sshd runs via launchd socket-activation; the `Port` directive in
# /etc/ssh/sshd_config is ignored. To get a second listening port we
# install a second launchd job at /Library/LaunchDaemons/ that runs sshd
# on :2222 alongside Apple's :22. Needed for tag:server src → user-owned
# dst SSH (Tailscale SSH grammar has no syntax for that direction;
# tailscaled only intercepts :22 on the tailnet IP, so :2222 falls through
# to this sshd directly). See ssh/com.zig.sshd-alt-port.plist + bead
# dotfiles-wzh + zig-zone runbook gotcha #24 for the why.
section "Installing sshd alt-port :2222 LaunchDaemon"
sudo install -m 644 -o root -g wheel \
    ~/dotfiles/ssh/com.zig.sshd-alt-port.plist \
    /Library/LaunchDaemons/com.zig.sshd-alt-port.plist
# bootstrap errors if the job is already loaded; the `|| warn` handles re-runs.
# If you need to apply a plist change later:
# sudo launchctl bootout system /Library/LaunchDaemons/com.zig.sshd-alt-port.plist
# sudo launchctl bootstrap system /Library/LaunchDaemons/com.zig.sshd-alt-port.plist
sudo launchctl bootstrap system \
    /Library/LaunchDaemons/com.zig.sshd-alt-port.plist || warn "sshd alt-port job already bootstrapped"

# --- /etc/hosts MagicDNS shim (headless tailscaled doesn't install a resolver) ---
# On macOS, brew-formula tailscaled runs in userspace networking and can't
# install a DNS resolver. To let this host resolve other tailnet hostnames,
# mirror the tailnet IPs into /etc/hosts. Hand-maintained — re-sync if any
# device's tailnet IP changes (rare; happens on logout+rejoin). The runbook
# section "/etc/hosts shim" has the current canonical mapping.
section "/etc/hosts MagicDNS shim"
echo "NOTE: see runbook for /etc/hosts shim entries (tailnet IPs for other devices)"

# --- Persistent tmux server (LaunchAgent, mirrors zig-computer's tmux.service) ---
# Creates a detached tmux session named after the hostname at user login.
# Requires the user to be logged in for LaunchAgents to fire — enable auto-login
# in System Settings → Users → Login Options for headless servers.
# The source plist has HOSTNAME_PLACEHOLDER as the session name; sed substitutes
# the actual hostname at install time so each Mac gets a uniquely-named session.
section "Installing persistent tmux LaunchAgent"
mkdir -p ~/Library/LaunchAgents
sed "s/HOSTNAME_PLACEHOLDER/$(hostname -s)/" \
    ~/dotfiles/tmux/com.zig.tmux.plist \
    > ~/Library/LaunchAgents/com.zig.tmux.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.tmux.plist || warn "tmux LaunchAgent already loaded"

# --- Verify ---
# The point of the whole exercise: say out loud which tools did NOT land,
# instead of exiting 0 with a silent hole in the toolchain.
section "Verifying installed toolchain"
MISSING=()
for _t in brew tmux jq gh ranger direnv rg fzf lazygit gitleaks go \
          bun uv deno nix pnpm cargo rustup rustfmt \
          biome ruff golangci-lint goose br bv claude cursor-agent \
          gemini codex copilot vercel wrangler tailscale ollama; do
    have "$_t" || MISSING+=("$_t")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
    echo "  all expected tools present"
else
    fail "missing after setup: ${MISSING[*]}"
    warn "open a new shell first (PATH changes from this run are not live here),"
    warn "then re-probe; anything still missing needs a hand-run of its section."
fi

section "Done"
echo " 🧢 RUN: cd ~/dotfiles && ./sync.sh <name> for each config you want linked"
echo " 🔑 AUTH: claude / gemini / codex / copilot / cursor"
