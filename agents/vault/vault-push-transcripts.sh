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
rc=$?
# Propagate the tier status (dotfiles-t6sd): this entrypoint has the same exit-0
# lie vault-sync.sh had — it ended on a successful `echo` and reported
# 0/SUCCESS no matter what the push did. Codes: 0 OK | 1 FAILED | 2 BLOCKED |
# 3 DEFERRED | 4 SKIPPED | 9 INERT (see transcripts-lib.sh). 9 is remapped to 0
# so an un-bootstrapped machine is not a permanently red unit.
[ "$rc" -eq 9 ] && rc=0
echo "== done (status $rc) =="
exit "$rc"
