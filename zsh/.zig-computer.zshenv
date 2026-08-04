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
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ KILL SWITCH ACTIVE — 2026-08-04, Zig's instruction (bead dotfiles-9o46).
# GATEWAY BYPASSED: Claude Code on this box talks to api.anthropic.com DIRECTLY.
#
# pico — which HOSTS the agentgateway — is offline (temporary home outage), so
# 100.72.47.4:17017 is unreachable and every request timed out. Routing is
# deliberate fail-hard with no fallback (dotfiles-ucl4), so claude here was
# simply dead until this switch.
#
# REVERT when Zig says pico is back: uncomment the export below and pull. A pane
# where ANTHROPIC_BASE_URL was unset by hand self-heals on its next launch,
# because the wrapper re-derives from THIS FILE every time.
#
# COST while active, accepted: no request o11y — pico's requests.db records
# nothing from this box, and that blindness looks exactly like idleness
# (dotfiles-t6to). Nothing alarms on it. Time-boxed to the outage.
# ─────────────────────────────────────────────────────────────────────────────
# export ANTHROPIC_BASE_URL="http://100.72.47.4:17017/claude"
