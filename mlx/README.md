# mlx — Apple MLX inference server on pico

Custom LaunchAgent (`com.zig.mlx`) that runs `mlx_lm.server` (Apple's
MLX-LM reference OpenAI-compat server) bound to pico's tailnet IP. Same
service-discipline pattern as `ollama/` and `phoenix/`: we own the
LaunchAgent and the env so the bind address survives across reinstalls.

## Why MLX alongside Ollama

Ollama is the daily-driver server today (see `ollama/`). MLX is being
A/B'd against Ollama on the recommended coding models (Qwen3-Coder-30B,
Devstral-Small-2, GLM-4.5-Air) per the local-coding-models exploration
arc (`~/explore/local-coding-models/`, beads `explore-4te*`). MLX is
reported ~2× Ollama on decode for MoE models on M1 Max; we don't assume
— we measure.

Both servers can co-exist on different ports without conflict; only one
should hold a given model in memory at a time during benchmarks.

## Layout

```
mlx/
├── com.zig.mlx.plist   # LaunchAgent — sed-substituted at install time by mac.setup.sh
└── README.md           # this file
```

## Endpoint

After install:
- Bind: `100.72.47.4:8081` (tailnet only)
- Health: `curl http://100.72.47.4:8081/v1/models` returns JSON
- Generate: OpenAI-compat `POST /v1/chat/completions` with a `model`
  field naming any MLX model resident in `~/.cache/huggingface/`
- Log: `/tmp/mlx.log`

## Port choice

8081 sits next to MLX's default 8080 (avoiding any default-port
collisions), and far from the other pico services:

| Service | Port |
|---|---|
| ollama | 11434 |
| ccr (planned) | 3456 |
| phoenix | 6006 |
| a1111 | 7860 |
| **mlx** | **8081** |

## Models

`mlx_lm.server` serves whatever's in `~/.cache/huggingface/` on demand.
Pull a model the first time:

```bash
# Convert from HF format (downloads + quantizes; ~10-30 min for 30B class)
mlx_lm.convert --hf-path mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit \
               --mlx-path ~/.cache/huggingface/Qwen3-Coder-30B-4bit
```

Then reference it in the API call via the `model` field:

```json
{ "model": "Qwen3-Coder-30B-4bit", "messages": [...] }
```

## Operations

```bash
# Status
launchctl list com.zig.mlx
ps -ax | grep mlx_lm.server | grep -v grep

# Restart (e.g., after a config change)
launchctl unload ~/Library/LaunchAgents/com.zig.mlx.plist
launchctl load -w ~/Library/LaunchAgents/com.zig.mlx.plist

# Tail logs
tail -f /tmp/mlx.log
```

## See also

- `~/explore/local-coding-models/` — full A/B test arc (beads `explore-4te*`)
- `ollama/` — sibling: the current default server
- `phoenix/` — sibling: another uv-tool-installed Python service following the same LaunchAgent pattern
