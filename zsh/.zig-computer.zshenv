# zig-computer — per-host NON-interactive env, sourced by zsh/.zshenv.
#
# ANTHROPIC_BASE_URL used to live in the fleet-wide claude/settings.json `env`
# block. It was removed there on 2026-07-27 because marketing-vps could not reach
# pico's tailnet address at all, and every session on that box was pinging a
# gateway that would never answer. The setting isn't wrong — it's just
# machine-scoped, so it belongs in a per-host file rather than in the config
# every machine loads.
#
# .zshenv tier rather than the interactive .zig-computer.zsh on purpose: this
# has to reach non-interactive shells too, since that is what scheduled pulse
# dispatch runs in.
# ESCAPE HATCH (replaces the old cc-direct alias): the gateway parses every LLM
# request for token o11y and has a max body size, so a very large request —
# notably CONTEXT COMPACTION, the largest one Claude Code makes — can fail with a
# 503 that retries cannot clear. To bypass for one session, in that shell:
#     CC_NO_GATEWAY=1 claude
# (Was `unset ANTHROPIC_BASE_URL && claude` until 2026-07-29. That no longer works:
# the claude() wrapper now RE-DERIVES this value from this file at launch, because a
# shell-start-time export silently missed every durable tmux pane older than this
# file and blinded pico's request log. CC_NO_GATEWAY is checked before that
# re-derivation.) For a lasting bypass, comment out the export below.
export ANTHROPIC_BASE_URL="http://100.72.47.4:17017/claude"
