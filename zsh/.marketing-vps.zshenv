# marketing-vps — per-host NON-interactive env, sourced by zsh/.zshenv.
# (Renamed from vps-8a9eb245 on 2026-08-03, dotfiles-v1uh, so agentgateway's
#  `group` column reads the name Zig actually calls the box.)
#
# This is the tier that `ssh host "cmd"` (and therefore remote pulse dispatch)
# actually runs in: no login shell, no .zshrc, no interactive hooks. Toolchain
# PATH entries have to live HERE for remote automation to resolve them without
# wrapping every call in `bash -lc`.
#
# Originally written straight to ~/.zshenv on 2026-07-27 during VPS migration
# Phase 1.2 (bead bd-d2kt). Moved into the repo as a per-host file so that
# `sync.sh zsh` — which symlinks the fleet-wide zsh/.zshenv over ~/.zshenv —
# stops silently reverting it. Additive only: never clobber $PATH.

export BUN_INSTALL="$HOME/.bun"
[ -d "$BUN_INSTALL/bin" ] && PATH="$BUN_INSTALL/bin:$PATH"

export NVM_DIR="$HOME/.nvm"
# Resolve node's bin dir directly instead of sourcing nvm.sh — nvm.sh is slow
# and noisy in non-interactive shells. Interactive zsh still loads nvm proper
# via .marketing-vps.zsh, and this entry is harmlessly redundant there.
if [ -d "$NVM_DIR/versions/node" ]; then
  _nvm_node_bin="$(command ls -1d "$NVM_DIR"/versions/node/v*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$_nvm_node_bin" ] && [ -d "$_nvm_node_bin" ] && PATH="$_nvm_node_bin:$PATH"
  unset _nvm_node_bin
fi

[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"

export PATH

# ---------------------------------------------------------------------------
# pico's agentgateway — reached through a LOCAL FORWARD, not over the tailnet
# ---------------------------------------------------------------------------
# Same setting as .zig-computer.zshenv / .metis.zshenv, for a different reason.
# Those two hosts are tailnet peers and dial pico's gateway DIRECTLY at
# http://100.72.47.4:17017. THIS BOX IS NOT ON THE TAILNET and never will be
# (agents/infra.md: plain SSH only), so 100.72.47.4 is unreachable from here —
# which is exactly why the setting was pulled out of the fleet-wide
# claude/settings.json `env` block on 2026-07-27 in the first place.
#
# What makes it work here is a chained forward the box opens for ITSELF:
#     ssh -L 127.0.0.1:17017:100.72.47.4:17017 zig-computer
# ssh resolves a `-L` destination on the FAR end, so zig-computer does the
# tailnet leg. One hop, no nested tunnel. LOCAL (`-L`) rather than a reverse
# `-R` from zig-computer on purpose: only the initiator can reopen a forward,
# and a stranded VPS whose gateway leg died would have no working claude at all.
#
# ⚠️ NOTHING ELSE OPENS THIS FORWARD. It is not a side effect of pulse dispatch
# (that is the separate 7100 fleet-proxy tunnel). It exists only while
# claude-gateway-tunnel.timer is enabled and firing:
#     systemctl --user list-timers claude-gateway-tunnel.timer
#     ~/dotfiles/agents/scheduler/ensure-fleet-tunnel.sh status \
#         --port 17017 --target 100.72.47.4:17017 \
#         --probe-path /claude/v1/models --expect 401     # 401 == healthy
# Policy is deliberate FAIL-HARD with no fallback to api.anthropic.com
# (dotfiles-ucl4): a silent fallback is indistinguishable from being idle, which
# is the dotfiles-t6to blindness bug shipped on purpose. Tunnel down == no claude.
#
# ⚠️ The `/claude` suffix is REQUIRED — the gateway route matches pathPrefix
# `/claude` and rewrites to `/`. Measured 2026-08-02 through the tunnel:
# `/claude/v1/models` -> 401 (reached Anthropic, no key attached = healthy),
# `/v1/models` -> 404. Dropping the suffix 404s every call.
#
# BYPASS, two ways, both working as of 2026-08-03:
#   - one session:  CC_NO_GATEWAY=1 claude
#   - lastingly:    comment out the export below, start a new shell
# The hatch used to be unreachable in a fresh zsh (dotfiles-20rx: this file
# re-exports on every zsh invocation, and the wrapper checked inherited-wins
# FIRST). That is FIXED — the hatch is now rule 1 and clears an inherited value
# unconditionally, guarded by T9–T12 in test-claude-identity-wrapper.sh. Note
# `command claude` still routes to the gateway: it bypasses the wrapper function
# entirely, so no hatch and no re-derivation. Use plain `claude`.
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️ KILL SWITCH ACTIVE — 2026-08-04, Zig's instruction (bead dotfiles-9o46).
# GATEWAY BYPASSED: Claude Code on this box talks to api.anthropic.com DIRECTLY.
#
# pico — which HOSTS the agentgateway — is offline (temporary home outage), so
# 127.0.0.1:17017 has no far end. The `ssh -L` listener OUTLIVES the far end
# dying, so requests were accepted and then hung (curl exit 28, NOT refused) —
# a hang is indistinguishable from a slow model. With fail-hard routing and no
# fallback (dotfiles-ucl4), every claude here was simply dead.
#
# REVERT when Zig says pico is back — uncomment the export below, then:
#     systemctl --user enable --now claude-gateway-tunnel.timer
# (this switch also stopped that timer; it was failing every 2 min into
# journal crit). A pane where ANTHROPIC_BASE_URL was unset by hand self-heals,
# because the wrapper re-derives from THIS FILE at every launch.
#
# COST while active, accepted: no request o11y — pico's requests.db records
# nothing from this box, and that blindness looks exactly like idleness
# (dotfiles-t6to). Nothing alarms on it. Time-boxed to the outage.
# ─────────────────────────────────────────────────────────────────────────────
# export ANTHROPIC_BASE_URL="http://127.0.0.1:17017/claude"
