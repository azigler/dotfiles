# ollama LaunchAgent (pico)

Custom LaunchAgent for Ollama on pico (Mac Studio M1 Max 64GB, zig-zone GPU box). Replaces brew's `homebrew.mxcl.ollama.plist` so we can pin `OLLAMA_HOST` to pico's tailnet IP without brew clobbering it on every `brew services restart`.

## Why not just `brew services start ollama`

`brew services restart ollama` regenerates `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist` from the formula's template, wiping any manual `EnvironmentVariables.OLLAMA_HOST` edit. The pattern that survives:

1. Install ollama via brew (`brew install ollama`) — gives us the binary at `/opt/homebrew/opt/ollama/bin/ollama`.
2. Do NOT run `brew services start ollama` — that races our custom plist.
3. Install `com.zig.ollama.plist` to `~/Library/LaunchAgents/` with `OLLAMA_HOST` baked in.
4. `launchctl load -w` the custom plist.

`mac.setup.sh` does this end-to-end including a sed substitution of `TAILSCALE_IP_PLACEHOLDER` with `$(tailscale ip -4)` at install time.

## Bind target

`OLLAMA_HOST=<pico tailnet IP>:11434` — exposes Ollama only on the tailnet interface (utun5). No localhost binding, no LAN exposure. Reachable from any tailnet device via `pico:11434` (MagicDNS) or the IP directly.

## If pico's tailnet IP changes

Tailnet IPs are stable per-node, but rename / re-register / account migration can change them. Symptom: brew's old plist log + `Error: listen tcp <old-IP>:11434: bind: can't assign requested address`. Fix:

```bash
# On pico
plutil -replace EnvironmentVariables.OLLAMA_HOST -string "$(tailscale ip -4):11434" \
  ~/Library/LaunchAgents/com.zig.ollama.plist
launchctl unload ~/Library/LaunchAgents/com.zig.ollama.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.ollama.plist
```

## Tuning baked into the plist

- `OLLAMA_FLASH_ATTENTION=1` — Metal flash attention on Apple Silicon (~30% faster on M1+)
- `OLLAMA_KV_CACHE_TYPE=q8_0` — quantized KV cache, ~halves VRAM per active model
- `OLLAMA_KEEP_ALIVE=24h` — keep models loaded a full day instead of the 5m default; pico is dedicated to this

## See also

- `~/explore/.claude/skills/zig-zone/SKILL.md` — the broader runbook
- `tmux/com.zig.tmux.plist` — same template pattern, also installed by `mac.setup.sh`
