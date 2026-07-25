#!/usr/bin/env bash
# Upgrade all binaries installed on pico (the macOS gateway + local-inference host).
# The macOS counterpart of ubuntu.upgrade.sh — run it ON pico:
#   ssh pico 'bash -s' < ~/dotfiles/pico.upgrade.sh
#   # or, on pico:  bash ~/dotfiles/pico.upgrade.sh
#
# Scope: OFF-THE-SHELF tooling only. Bespoke deployments (vacation-station/vs14,
# ss14-*, gojamming, reef-router, pico-serve, ha-portal-proxy, a1111) are NOT
# touched — they have their own build/deploy paths.
#
# The two SERVICES the fleet depends on (agentgateway, ollama) are deliberately
# NOT upgraded by a blind curl here. They go through the staged/validated/
# auto-rollback updaters in ~/aaif/ops/gateway-host/, which this script calls if
# they're installed. See "Services" below for why that matters.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
section() { echo ""; echo -e "${GREEN}==> $1${NC}"; }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }
fail()    { echo -e "${RED}  ✗ $1${NC}"; }
ok()      { echo -e "  ✓ $1"; }

# brew and ~/.local/bin are NOT in a non-interactive SSH PATH on this box.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$PATH"
export HOMEBREW_NO_ENV_HINTS=1
UPDATER_DIR="$HOME/.local/libexec/host-update"

# --- Homebrew -----------------------------------------------------------------
# Auto-upgrade everything, same spirit as ubuntu.upgrade.sh's `apt-get upgrade -y`.
section "Upgrading Homebrew formulas + casks"
if command -v brew &>/dev/null; then
    # A formula rename left unmigrated makes EVERY later brew command error out,
    # which aborts the whole upgrade over an unrelated package. Clear those first.
    for f in $(brew outdated 2>&1 | sed -n 's/^Error: \(.*\) was renamed to .*/\1/p'); do
        warn "migrating renamed formula: $f"
        brew migrate "$f" || warn "migrate failed for $f"
    done
    brew update
    brew upgrade
    brew cleanup -s
    ok "brew upgraded + cleaned"

    # brew upgrade restarts services. Report any that came back broken.
    BROKEN=$(brew services list 2>/dev/null | awk 'NR>1 && $2=="error" {print $1}')
    if [ -n "$BROKEN" ]; then
        fail "brew services in error after upgrade: $(echo "$BROKEN" | tr '\n' ' ')"
        warn "check with: brew services list"
    else
        ok "no brew services in error"
    fi
else
    fail "brew not found at /opt/homebrew/bin/brew"
fi

# --- uv itself ----------------------------------------------------------------
section "Upgrading uv"
if command -v uv &>/dev/null; then
    uv self update && ok "uv updated"
else
    warn "uv not found, reinstalling"
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# --- uv tools -----------------------------------------------------------------
# arize-phoenix runs as a launchd service here, so verify it survives its upgrade.
section "Upgrading uv tools"
if command -v uv &>/dev/null; then
    uv tool upgrade --all && ok "uv tools upgraded"
    if launchctl print "gui/$(id -u)/com.zig.phoenix" 2>/dev/null | grep -q "state = running"; then
        ok "phoenix service still running"
    else
        fail "phoenix service is NOT running after the uv tool upgrade"
        warn "restart with: launchctl kickstart -k gui/\$(id -u)/com.zig.phoenix"
    fi
else
    fail "uv not found, cannot upgrade uv tools"
fi

# --- Claude Code --------------------------------------------------------------
section "Upgrading Claude Code"
if command -v claude &>/dev/null; then
    claude update || {
        warn "claude update failed, reinstalling via installer"
        curl -fsSL https://claude.ai/install.sh | bash
    }
else
    warn "claude not found, reinstalling"
    curl -fsSL https://claude.ai/install.sh | bash
fi

# --- Cursor agent -------------------------------------------------------------
section "Upgrading cursor-agent"
curl https://cursor.com/install -fsS | bash || warn "cursor install script failed"

# --- beads --------------------------------------------------------------------
section "Upgrading beads_rust + beads_viewer"
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash \
    || warn "beads_rust install failed"
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh?$(date +%s)" | bash \
    || warn "beads_viewer install failed"

# --- Services: agentgateway + ollama -----------------------------------------
# NOT a blind curl. Both are live services with real failure modes:
#   * agentgateway's config schema drifts between versions (it ships a `migrate`
#     subcommand), so a new binary can reject a working config.
#   * ollama is supervised by a system LaunchDaemon and the gateway's llm provider
#     targets it by tailnet address; a bad swap strands goose with no model.
#   * GitHub's /releases/latest for agentgateway returns a BETA flagged
#     prerelease=false, so "install latest" installs a prerelease.
# The updaters handle all three, verify health, and auto-roll-back. Use them.
section "Upgrading agentgateway + ollama (via the safe updaters)"
if [ -x "$UPDATER_DIR/agentgateway-upgrade" ]; then
    "$UPDATER_DIR/agentgateway-upgrade" apply
    case $? in
        0)  ok "agentgateway current/upgraded" ;;
        20) fail "agentgateway upgrade failed its health check and was ROLLED BACK" ;;
        *)  fail "agentgateway updater errored — see its ledger" ;;
    esac
else
    warn "agentgateway-upgrade not installed at $UPDATER_DIR"
    warn "deploy it: ~/aaif/ops/gateway-host/deploy.sh <this-host>"
fi

if [ -x "$UPDATER_DIR/ollama-upgrade" ]; then
    "$UPDATER_DIR/ollama-upgrade" apply
    case $? in
        0)  ok "ollama current/upgraded" ;;
        20) fail "ollama upgrade failed its health check and was ROLLED BACK" ;;
        *)  fail "ollama updater errored — see its ledger" ;;
    esac
else
    warn "ollama-upgrade not installed at $UPDATER_DIR"
fi

# --- Log hygiene --------------------------------------------------------------
# ~/ollama.log reached 1.4 GB unrotated before anyone noticed (2026-07-25). macOS
# has no logrotate; cap it here so the same thing can't creep back.
section "Capping oversized service logs"
for LOGF in "$HOME/ollama.log" "$HOME/Library/Logs/agentgateway.log"; do
    [ -f "$LOGF" ] || continue
    SIZE=$(stat -f%z "$LOGF" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 104857600 ]; then   # 100 MB
        tail -n 5000 "$LOGF" > "${LOGF}.trim" && mv "${LOGF}.trim" "${LOGF}.prev" && : > "$LOGF"
        ok "$(basename "$LOGF"): was $((SIZE / 1048576)) MB, truncated (tail kept as .prev)"
    else
        ok "$(basename "$LOGF"): $((SIZE / 1048576)) MB, fine"
    fi
done

section "Done"
echo "All upgrades complete."
echo ""
echo "NOT touched (bespoke, own deploy paths): vacation-station/vs14, ss14-*,"
echo "gojamming, reef-router, pico-serve, ha-portal-proxy, a1111."
