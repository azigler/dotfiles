# zig-computer — per-host NON-interactive env, sourced by zsh/.zshenv.
#
# ANTHROPIC_BASE_URL used to live in the fleet-wide claude/settings.json `env`
# block. It was removed there on 2026-07-27 because vps-8a9eb245 cannot reach
# pico's tailnet address at all, and every session on that box was pinging a
# gateway that would never answer. The setting isn't wrong — it's just
# machine-scoped, so it belongs in a per-host file rather than in the config
# every machine loads.
#
# .zshenv tier rather than the interactive .zig-computer.zsh on purpose: this
# has to reach non-interactive shells too, since that is what scheduled pulse
# dispatch runs in.
export ANTHROPIC_BASE_URL="http://100.72.47.4:17017/claude"
