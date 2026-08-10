# zig-computer — per-host NON-interactive env, sourced by zsh/.zshenv.
#
# ANTHROPIC_BASE_URL used to live in the fleet-wide claude/settings.json `env`
# block. It was removed there on 2026-07-27 because one box (marketing-vps, since
# decommissioned) could not reach pico's tailnet address at all, and every session on it was pinging a
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
# HISTORY: bypassed for ~1h on 2026-08-04 while pico (the gateway HOST) was off
# the internet, then reverted the same day once `tailscale ping pico` answered and
# 17017/claude/v1/models was back to 401. See bead dotfiles-9o46. One lesson from
# that hour is worth keeping: commenting this export out does NOT de-gateway an
# ALREADY-RUNNING shell or claude — the value is read once at launch and an
# `exec zsh` INHERITS it. Per-pane recovery is an explicit `unset
# ANTHROPIC_BASE_URL`, then relaunch.
export ANTHROPIC_BASE_URL="http://pico:17017/claude"

# --- lb-claude — a Claude Code session on the LinearB WORK seat ------------------
# Zig, 2026-08-05. The seven migrated pulse rows get the work seat via
# pulse-inject's --config-dir; this is the on-demand equivalent for any window.
#
# Three implementations are wrong here, each silently:
#   * a SCRIPT in ~/bin — `claude` is a shell FUNCTION (claude-identity-wrapper.sh),
#     and functions are not inherited by scripts. A script would run the raw binary
#     and lose the gateway re-derivation, i.e. dotfiles-t6to with no error.
#   * `env CLAUDE_CONFIG_DIR=… claude` / a bare `VAR=val claude` prefix — both
#     bypass or fail to export into the function (measured 2026-08-05, zsh 5.9).
#   * a plain `export` in a non-subshell function — it LEAKS, so every later plain
#     `claude` in that pane is quietly on the work seat too.
# A subshell fixes all three: functions ARE inherited by subshells, and the export
# dies with it. Verify with `type lb-claude`, not by reading this comment.
lb-claude() {
  local seat="${LB_CLAUDE_SEAT:-$HOME/.claude-work}"
  if [ ! -s "$seat/.credentials.json" ]; then
    print -u2 "lb-claude: no credential at $seat"
    print -u2 "  mint it once:  CLAUDE_CONFIG_DIR=$seat claude   # then /login as the LinearB account"
    print -u2 "  refusing to fall back to the personal seat — that failure would be invisible."
    return 78
  fi
  ( export CLAUDE_CONFIG_DIR="$seat"; claude "$@" )
}

# --- the even trio (Zig, 2026-08-10): claude / claude-secondary / claude-linearb.
# Same subshell idiom as lb-claude above, same three wrong implementations, same
# refusal to fall back silently. `claude` alone stays the primary tap (wrapper
# default). Verify with `type claude-secondary`, not by reading this comment.
claude-secondary() {
  local seat="${CLAUDE_SECONDARY_SEAT:-$HOME/.claude-secondary}"
  if [ ! -s "$seat/.credentials.json" ]; then
    print -u2 "claude-secondary: no credential at $seat"
    print -u2 "  mint it once:  CLAUDE_CONFIG_DIR=$seat claude   # then /login as zig@zigler.ai"
    print -u2 "  refusing to fall back to the primary seat — that failure would be invisible."
    return 78
  fi
  ( export CLAUDE_CONFIG_DIR="$seat"; claude "$@" )
}
claude-linearb() { lb-claude "$@" }
