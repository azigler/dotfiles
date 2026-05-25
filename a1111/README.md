# a1111 — Stable Diffusion WebUI on pico

[Automatic1111 stable-diffusion-webui](https://github.com/AUTOMATIC1111/stable-diffusion-webui)
on pico (M1 Max + 64GB, macOS Sonoma+) reachable over **tailnet AND home
LAN** — explicitly NOT public internet.

## Posture

- **Lifecycle**: **on-demand only**, NOT auto-start. SD loads its
  diffusion checkpoint into RAM at launch (~17 GB resident BEFORE the
  first image request), which starves LLM inference (`mlx_lm.server`,
  Ollama) of unified memory on Apple Silicon. The LaunchAgent is
  installed but `RunAtLoad=false`; start it manually with `sd-up` and
  stop with `sd-down` when finished. See "Lifecycle" below.
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
| `com.zig.a1111.plist` | LaunchAgent template (USER_HOME_PLACEHOLDER substituted at install). `RunAtLoad=false` — on-demand only. |
| `sd-up` | Start SD on demand (`launchctl kickstart`). Add to PATH or alias. |
| `sd-down` | Stop SD + clear restart flag + kill webui.sh wrapper. |
| `webui-user.sh` | A1111 config: pins python3.10, sets COMMANDLINE_ARGS |
| `config.json` | Seeded A1111 settings — currently just `upcast_attn: true` (required for SDXL inpainting on MPS; Settings-only toggle, no CLI flag in 1.10) |
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

## Lifecycle (on-demand)

SD-WebUI is on-demand. The LaunchAgent is registered but does NOT
auto-start at boot (`RunAtLoad=false`, no `KeepAlive`). Use the
helpers:

```bash
# Start on demand (loads the diffusion checkpoint, ~30-60 sec)
sd-up

# Stop when done (frees ~17 GB of unified memory for LLM inference)
sd-down

# Tail logs
tail -f /tmp/a1111.log
```

Equivalent raw `launchctl` calls if the helpers aren't on PATH:

```bash
launchctl kickstart -p gui/$UID/com.zig.a1111           # start
launchctl stop com.zig.a1111                            # stop
launchctl unload ~/Library/LaunchAgents/com.zig.a1111.plist  # deregister
```

### Why on-demand

SD-WebUI loads its diffusion model into RAM at process launch — not
lazily on first request. On Apple Silicon's unified memory architecture
that ~17 GB resident competes directly with mlx_lm.server's model
residency (Qwen3-Coder 4-bit = ~17 GB, GLM-4.5-Air 4-bit = ~30 GB).
With both running, even small LLMs page from compressed memory + swap
on every forward pass, dropping decode rate from ~50 tps to ~0.6 tps
(empirically measured 2026-05-25).

The lifecycle rule: **run SD only while actually generating images**;
stop it before any LLM inference work. Both `sd-up` and `sd-down`
are zero-friction so this is just-do-it discipline, not a process.

## Related

- `~/dotfiles/ollama/` — sibling pattern (also a tailnet-bound LLM service
  on pico)
- `~/dotfiles/phoenix/` — sibling pattern (Phoenix observability on pico)
- `~/dotfiles/mac.setup.sh` — fresh-Mac bootstrap that installs all of these
