# claude-code-router (CCR) — pico-routed local-models proxy

A's foundation. Translator between Anthropic Messages API ↔ OpenAI-compat backends. Allows Claude Code (which talks Anthropic Messages) to route specific calls to local pico models.

**Status**: 2026-05-25 — installed on zig, smoke-tested end-to-end with pico-mlx + Qwen3-Coder MLX. CCR daemon listens on `127.0.0.1:3456`.

## Install

```bash
npm install -g @musistudio/claude-code-router
```

## Config

Lives at `~/.claude-code-router/config.json` (symlinked from `config.json` in this dir).

### Providers

| name | URL | purpose |
|---|---|---|
| `anthropic` | api.anthropic.com | default route (preserves current behavior) |
| `pico-mlx` | `100.72.47.4:8081/v1/chat/completions` | MLX-served (Qwen3-Coder, Trinity, Devstral) |
| `pico-ollama` | `100.72.47.4:11434/v1/chat/completions` | Ollama-served (Qwen, Laguna, Devstral, etc.) |

### Router

| scenario | model | notes |
|---|---|---|
| `default` | `anthropic,claude-opus-4-7` | preserves main-session behavior |
| `background` | `pico-mlx,mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | when Claude Code marks a call as background |
| `longContext` | `pico-ollama,laguna-xs.2:latest` | requests >50K tokens (Laguna is only model passing 100K bench) |

Other Router keys (`think`, `webSearch`, `subagent`) deliberately omitted:
- `subagent`: **not in CCR's documented surface** (confirmed by /check OQ1 + scrutinize A1 + reading the README). Use `CLAUDE_CODE_SUBAGENT_MODEL` env var instead.
- `think`: extended-thinking detection unverified; defer.
- `webSearch`: not in scope.

## Daily use

```bash
ccr start              # spin up daemon (defaults to 127.0.0.1:3456)
ccr status             # check it's alive
ccr code <args>        # run claude command via the router (wraps env vars)
ccr restart            # reload after config edit
ccr stop               # bring down
```

`ccr code` is the user-facing entry point. It sets `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` and runs `claude`. For tasks that should hit local: use `--model pico-mlx,mlx-community/Qwen3-Coder-...` flag or rely on the Router rules.

## Smoke-test pattern

```bash
# Anthropic Messages shape (CCR's native) → pico-mlx
curl -sS -X POST http://127.0.0.1:3456/v1/messages \
  -H 'Content-Type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{
    "model": "pico-mlx,mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
    "max_tokens": 30,
    "messages": [{"role":"user","content":"Reply with PONG only."}]
  }'
# → {"content":[{"type":"text","text":"PONG"}], ...}
```

If you get `Provider 'undefined' not found`, you used `/v1/chat/completions` not `/v1/messages`. CCR routes Anthropic shape only.

## Known limits (empirical, 2026-05-25)

- **Subagent routing not via Router key** — `Router.subagent` is not in CCR's surface. Rely on `CLAUDE_CODE_SUBAGENT_MODEL` env var (verify propagation to worktree subagents via X1 probe before depending on it).
- **MLX tool-use is per-model**: Qwen3-Coder works (returns structured `tool_calls[]`, parallel calls supported); Trinity does NOT (returns `<tool_call>` jammed in `content`). See GUARDRAILS.md G1 + G9 (revised).
- **No automatic failover**: if pico is down, requests hard-fail (by design — `/check` OQ4).

## Cross-references

- `../local-models/GUARDRAILS.md` — invariants (G1, G9, etc.)
- `~/explore/refs/cross-epic-overlap-2026-05-25.md` — A's role as foundation
- Bead: `dotfiles-ukx.6` — spec + /check + scrutinize notes
