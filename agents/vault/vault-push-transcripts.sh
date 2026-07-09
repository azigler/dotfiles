#!/usr/bin/env bash
# vault-push-transcripts.sh — the deterministic daily entrypoint for the
# claude-transcripts vault (explore-76oc §4.3, OQ-C4). Run by the headless
# claude-transcripts-push.timer (NOT a pulse LLM tick — this is a pure git push;
# refines OQ-C4's "pulse row" to a dedicated daily timer). Inert until bootstrap.
#
# Logs to ~/.claude/vault-transcripts.log (the systemd service redirects here).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/transcripts-lib.sh"

echo "== transcripts push $(date -u +%FT%TZ) =="
vault_push_transcripts
echo "== done =="
