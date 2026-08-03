# metis — per-host NON-interactive env, sourced by zsh/.zshenv.
#
# Same rationale as .zig-computer.zshenv: ANTHROPIC_BASE_URL used to live in the
# fleet-wide claude/settings.json `env` block, and was removed there on
# 2026-07-27 because marketing-vps could not reach pico's tailnet address at all
# (it now reaches it through a chained ssh -L; see zsh/.marketing-vps.zshenv).
# The setting isn't wrong, it's machine-scoped — so each host that CAN reach the
# gateway opts in here, and a host that can't simply has no file saying so.
#
# .zshenv tier rather than the interactive .metis.zsh on purpose: it has to reach
# non-interactive shells too.
#
# ⚠️ UNVERIFIED ON METIS (created 2026-07-28 from zig-computer; metis was offline).
# zsh/.zshenv dispatches on `${HOST%%.*}`, so this file loads only if metis's short
# hostname is literally `metis`. On macOS that is often `Andrews-MacBook-Pro` or a
# `.local` name instead — `.local` is fine (the %%.* strips it), a different name
# is not. Confirm on metis with:
#     echo "${HOST%%.*}"        # must print: metis
#     echo "$ANTHROPIC_BASE_URL" # in a NEW shell, must print the gateway below
# If the first prints something else, rename this file to match it.
#
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
