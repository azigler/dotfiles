# a1111 — Stable Diffusion WebUI on pico

[Automatic1111 stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui)
on pico (M1 Max + 64GB, macOS Sonoma+) reachable over **tailnet AND home
LAN** — explicitly NOT public internet.

## Posture

- **Bind**: `--listen --port 7860` → answers on 0.0.0.0:7860 (tailnet
  IP + LAN IP + localhost)
- **Auth**: none (network restriction only — trusted tailnet ACL + home
  LAN scope)
- **Public internet**: not exposed. Zig-computer's nginx does NOT proxy
  here. A1111's Gradio API has had RCE-class bugs; the network boundary
  IS the security model.

## Files

| File | Purpose |
|---|---|
| `com.zig.a1111.plist` | LaunchAgent template (USER_HOME_PLACEHOLDER substituted at install) |
| `webui-user.sh` | A1111 config: pins python3.10, sets COMMANDLINE_ARGS |
| `README.md` | This file |

## Install (handled by `~/dotfiles/mac.setup.sh`)

```bash
# Brew deps (Python 3.10 + build chain)
brew install cmake protobuf rust python@3.10 git wget

# Clone the repo
git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui \
  ~/stable-diffusion-webui

# Install the user config
cp ~/dotfiles/a1111/webui-user.sh ~/stable-diffusion-webui/webui-user.sh

# Install + load the LaunchAgent (USER_HOME_PLACEHOLDER substituted)
sed "s|USER_HOME_PLACEHOLDER|$HOME|g" ~/dotfiles/a1111/com.zig.a1111.plist \
  > ~/Library/LaunchAgents/com.zig.a1111.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.a1111.plist
```

First boot runs `webui.sh` which creates a Python venv at
`~/stable-diffusion-webui/venv/` and installs torch with MPS support.
~5-10 minutes the first time. Logs to `/tmp/a1111.log`.

## Access

After load:

- **tailnet**: `http://pico.<tailnet>.ts.net:7860`
- **LAN**: `http://<pico-LAN-IP>:7860` (find with `ifconfig en0 inet` on pico)
- **localhost on pico**: `http://127.0.0.1:7860`

Apple Silicon performance baseline (M1 Max, 64GB):
- SD 1.5: ~2-4 it/s
- SDXL: ~0.8-1.5 it/s

## Adding models

Drop `.safetensors` / `.ckpt` files into:

- `~/stable-diffusion-webui/models/Stable-diffusion/` — base models (SD 1.5,
  SDXL, Illustrious, Pony, etc.)
- `~/stable-diffusion-webui/models/Lora/` — LoRAs
- `~/stable-diffusion-webui/models/VAE/` — VAE files
- `~/stable-diffusion-webui/models/embeddings/` — textual inversions

A1111 picks them up on next page load (no restart needed).

## macOS firewall

macOS Application Firewall may prompt on first inbound LAN connection
("Do you want the application 'python3.10' to accept incoming network
connections?"). Answer **Allow** to enable LAN access. Without this,
tailnet still works (Tailscale's interface is exempt) but LAN devices
get connection-refused.

To pre-allow non-interactively:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw \
  --add /opt/homebrew/bin/python3.10
sudo /usr/libexec/ApplicationFirewall/socketfilterfw \
  --unblockapp /opt/homebrew/bin/python3.10
```

## Lifecycle

```bash
# Reload (e.g. after editing webui-user.sh)
launchctl kickstart -k gui/$UID/com.zig.a1111

# Stop (without unloading)
launchctl stop com.zig.a1111

# Unload entirely
launchctl unload ~/Library/LaunchAgents/com.zig.a1111.plist

# Tail logs
tail -f /tmp/a1111.log
```

## Related

- `~/dotfiles/ollama/` — sibling pattern (also a tailnet-bound LLM service
  on pico)
- `~/dotfiles/phoenix/` — sibling pattern (Phoenix observability on pico)
- `~/dotfiles/mac.setup.sh` — fresh-Mac bootstrap that installs all of these
