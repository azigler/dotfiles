#!/usr/bin/env bash
# Live-deploy recipe for ss14-wrapper.
#
# **Not run unattended yet** — pico SSH is being restored as part of the
# Approach C2 cutover (spec dotfiles-9g1 §4.6). This script stages the
# canonical recipe so the operator can run it once `ssh pico` works.
#
# What it does (when SS14_DEPLOY_PICO is set + pico SSH is reachable):
#   1. Cross-compile wrapper on the local box (calls build.sh).
#   2. scp the binary + plist template to pico.
#   3. ssh pico to render the plist + (re)load the LaunchAgent.
#   4. Verify by probing the UDS HEALTH endpoint over ssh.
#
# Safety:
#   - Refuses to run unless SS14_DEPLOY_PICO is set (so a fat-fingered
#     `bash deploy.sh` during dev doesn't accidentally ship to prod).
#   - Refuses to run if `ssh pico true` doesn't succeed (so a stale
#     ssh-config / down-tailnet doesn't half-deploy).
#   - All remote commands are idempotent (`mkdir -p`, `unload || true`,
#     `cp -f`).

set -euo pipefail

cd "$(dirname "$0")"

if [[ "${SS14_DEPLOY_PICO:-}" != "1" ]]; then
    cat <<'EOF' >&2
ss14-wrapper deploy.sh: refusing to run without SS14_DEPLOY_PICO=1

This is the live-cutover script for Approach C2 (spec dotfiles-9g1).
Set SS14_DEPLOY_PICO=1 and re-run when you're ready to actually deploy:

    SS14_DEPLOY_PICO=1 bash deploy.sh

Pre-flight checklist before flipping the env var:
  [ ] pico SSH is restored and `ssh pico true` succeeds
  [ ] Robust.Server's bind has been flipped to 127.0.0.1 (or you're
      still in dev mode with the wrapper pointing at :11215)
  [ ] /etc/nginx/streams-enabled/ss14-game.conf is staged on zig-computer
  [ ] An off-hours maintenance window is open (cutover drops players)
EOF
    exit 1
fi

# Pre-flight: pico must be reachable.
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 pico true 2>/dev/null; then
    echo "ss14-wrapper deploy.sh: pico unreachable via ssh" >&2
    echo "  fix: \`ssh pico\` must succeed (check tailscale + ssh-config)" >&2
    exit 2
fi

echo "ss14-wrapper deploy.sh: pico reachable; starting deploy..."

# 1. Cross-compile.
bash build.sh

# 2. scp to pico.
ssh pico 'mkdir -p ~/ss14-wrapper'
scp ss14-wrapper-darwin-arm64 pico:~/ss14-wrapper/ss14-wrapper
scp com.zig.ss14-wrapper.plist pico:~/ss14-wrapper/com.zig.ss14-wrapper.plist.tmpl

# 3. Render + load on pico (idempotent).
ssh pico bash <<'REMOTE'
set -euo pipefail
TAILNET_IP=$(tailscale ip -4)
sed -e "s|TAILSCALE_IP_PLACEHOLDER|${TAILNET_IP}|g" \
    -e "s|USER_HOME_PLACEHOLDER|${HOME}|g" \
    ~/ss14-wrapper/com.zig.ss14-wrapper.plist.tmpl \
    > ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist
# Clear any stale UDS socket from a previous instance.
rm -f /tmp/ss14-wrapper.sock
launchctl unload ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist 2>/dev/null || true
launchctl load -w ~/Library/LaunchAgents/com.zig.ss14-wrapper.plist
sleep 1
launchctl list | grep ss14-wrapper || {
    echo "ss14-wrapper failed to start; tail /tmp/ss14-wrapper.log" >&2
    exit 3
}
REMOTE

# 4. Verify via UDS API probe.
# The curl-equivalent over ssh + nc — `nc -U` opens the Unix socket, we
# pipe in the HEALTH verb, and read the one-line response. Expected:
# "OK active_sessions=0 uptime_s=1\n" (or similar small uptime).
echo "ss14-wrapper deploy.sh: probing HEALTH..."
RESP=$(ssh pico 'echo HEALTH | nc -U /tmp/ss14-wrapper.sock')
echo "  response: ${RESP}"
case "${RESP}" in
    OK\ active_sessions=*)
        echo "ss14-wrapper deploy.sh: HEALTH OK — wrapper live on pico"
        ;;
    *)
        echo "ss14-wrapper deploy.sh: unexpected HEALTH response" >&2
        exit 4
        ;;
esac

# Optional: list any current sessions (will be empty until traffic flows
# through nginx).
echo ""
echo "ss14-wrapper deploy.sh: current sessions (should be empty pre-cutover):"
ssh pico 'echo ENUMERATE | nc -U /tmp/ss14-wrapper.sock'
