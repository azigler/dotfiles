#!/usr/bin/env bash
# vault-sync.sh — bidirectional sync for BOTH claude vaults (the hourly timer's
# entrypoint on both machines). PULLS latest for each vault FIRST — even when the
# machine is idle with no local changes — so a quiet box still receives the other
# machine's updates (the gap the daily push-only timer left). Then pushes local
# changes via the tested, guarded push functions (which also pull-before-push).
# Best-effort; bounded by timeouts; never clobbers (merge=union on MEMORY.md,
# delete-guard on the peer). spec lin-i2d.1 (P5).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
VDIR="${VAULT_DIR:-$HOME/.claude/vaults}"
WT="$HOME/.claude/projects"
echo "== vault-sync $(date -u +%FT%TZ) on $(hostname -s) =="

# 0. Peer only: materialize any slugs newly registered by the dynamic-slug hook.
if [ -f "$VDIR/.peer" ]; then
  for v in memory transcripts; do
    [ -d "$VDIR/$v.git" ] || continue
    timeout 60 git --git-dir="$VDIR/$v.git" --work-tree="$WT" sparse-checkout reapply >/dev/null 2>&1 || true
  done
fi

# 1. Unconditional PULL per vault — an idle machine still syncs DOWN the latest.
#    merge=union (info/attributes) resolves MEMORY.md; a genuine conflict defers
#    (loud) rather than clobbering.
for v in memory transcripts; do
  gd="$VDIR/$v.git"; [ -d "$gd" ] || continue
  if timeout 120 git --git-dir="$gd" --work-tree="$WT" pull --rebase --autostash -q origin main >/dev/null 2>&1; then
    echo "  $v: pulled latest"
  else
    echo "  $v: pull deferred (offline / conflict — NOT clobbered, resolve manually)"
  fi
done

# 2. PUSH local changes via the tested guarded functions (each pulls-before-push).
if [ -f "$HERE/vault-lib.sh" ];        then . "$HERE/vault-lib.sh";        vault_push_memory       || true; fi
if [ -f "$HERE/transcripts-lib.sh" ];  then . "$HERE/transcripts-lib.sh";  vault_push_transcripts  || true; fi
echo "== vault-sync done =="
