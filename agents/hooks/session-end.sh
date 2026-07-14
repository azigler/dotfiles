#!/bin/bash
# SessionEnd: persist bead state, then drop the .offboard-pending marker
# if this session ended WITHOUT /offboard having run.
#
# The marker is the retroactive-offboard safety net: the next session's
# /onboard Step 0 finds it and runs /offboard for the prior session.
# /offboard removes it (Step 5). "Did /offboard run this session?" is
# detected primarily by .claude/last-offboard-session matching this
# session's id (/offboard writes that file in Step 5; both it and the
# marker are in the global gitignore). Fallback: HEAD committed the
# session handoff note. The HEAD heuristic alone was fragile — any
# commit AFTER /offboard in the same session (a bead close, a quick
# fix) made HEAD no longer the handoff commit, dropping the marker
# spuriously (fixed 2026-06-09).
#
# pre-compact.sh deliberately does NOT drop the marker: compaction keeps
# the same session alive, so that session's own post-compaction /onboard
# would misread its own marker as a prior session's.

STDIN=$(cat 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$STDIN" | jq -r '.session_id // empty' 2>/dev/null)

# Clean up this session's tmux-lexicon state file — the per-session SSoT
# written by tmux-status.sh to /tmp/claude-lexicon/<session_id> (mirrors the
# per-session /tmp teardown for statusline's context-pct file). Done early so
# even servitor sessions (which return before the offboard logic below) don't
# leave a stale token behind. The transition log under ~/.claude/lexicon-log/
# is durable exhaust and is deliberately NOT touched.
if [ -n "$SESSION_ID" ]; then
  LEX_DIR="${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}"
  rm -f "$LEX_DIR/$SESSION_ID" "$LEX_DIR/$SESSION_ID.reason" 2>/dev/null
fi

# Per-window scoping of the offboard markers (handoff-path.sh): in a project
# that opts in (refs/.handoff-per-window) and runs >1 durable session, the
# .offboard-pending / last-offboard-session markers are window-scoped so two
# sessions don't trip each other's safety net. Degrades to legacy single-file
# when not opted in / not in tmux.
_HP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/handoff-path.sh"
[ -f "$_HP" ] && . "$_HP"
type last_offboard_path    >/dev/null 2>&1 || last_offboard_path()    { printf '%s/.claude/last-offboard-session' "${1:-.}"; }
type offboard_pending_path >/dev/null 2>&1 || offboard_pending_path() { printf '%s/.offboard-pending' "${1:-.}"; }

if command -v br &>/dev/null; then
  br sync --flush-only 2>/dev/null
fi

# Servitor / dispatched sessions opt OUT of the offboard safety net. They have
# no handoff contract (ephemeral workers), and in a SHARED git umbrella like
# ~/explore — where local-coding-models/, fledgling/, etc. all resolve to the
# explore git root — a servitor ending here would otherwise drop a root-scoped
# .offboard-pending that the explore PULSE orchestrator then trips over as a
# false positive. The dispatcher (dispatch-cc.sh) sets this for every servitor.
if [ -n "${CLAUDE_NO_OFFBOARD_MARKER:-}" ]; then
  exit 0
fi

# --- Layer 2 secret-hygiene (explore-r2iq): scan the MEMORY tier for a leaked
# literal secret each session end. Policy is "secrets never go in memory" — this
# is the detect backstop for auto-memory/tool writes that can't be fenced. Scan
# is READ-ONLY (never redacts). On a finding, drop a durable alert marker + log
# that the next /onboard surfaces; clear it when the tier is clean. Best-effort:
# never fail the hook. High-confidence patterns only (no --entropy) to avoid noise.
_SCRUB="$HOME/.claude/skills/scrub-secrets/scrub.py"
if [ -f "$_SCRUB" ] && command -v python3 &>/dev/null; then
  _MEM=("$HOME"/.claude/projects/*/memory)
  if [ -e "${_MEM[0]}" ]; then
    if _OUT=$(python3 "$_SCRUB" scan "${_MEM[@]}" 2>&1); then
      rm -f "$HOME/.claude/.secret-alert" 2>/dev/null   # clean → clear the marker
    else
      { date -u +%FT%TZ; printf '%s\n' "$_OUT"; } > "$HOME/.claude/secret-scan.log" 2>/dev/null
      touch "$HOME/.claude/.secret-alert" 2>/dev/null   # found → raise the marker
    fi
  fi
fi

# --- claude-memory vault push (explore-76oc Phase 1). Commit+push the memory
# tier on session end. Best-effort; NEVER fails the hook. Worktree-guarded
# (OQ-A5): only top-level sessions push — a worktree/subagent teardown's slug is
# transient. Inert until the vault is bootstrapped (vault_push_memory returns
# early if ~/.claude/vaults/memory.git is absent). Its own flock serializes
# concurrent sessions; its pre-commit hook (Layer 1) blocks a secret loudly.
# Output goes to a dedicated log; a real secret problem also trips the Layer-2
# .secret-alert above, which /onboard surfaces.
case "$PWD" in
  */.claude/worktrees/*) ;;   # subagent/worktree teardown — skip the vault push
  *)
    _VAULT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../vault/vault-lib.sh"
    if [ -f "$_VAULT_LIB" ]; then
      . "$_VAULT_LIB"
      vault_push_memory >>"$HOME/.claude/vault-session-end.log" 2>&1 || true
    fi
    ;;
esac

if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  case "$ROOT" in
    ""|*/.claude/worktrees/*) ;;  # outside git, or inside a worktree — skip
    *)
      LAST_OFFBOARD=$(last_offboard_path "$ROOT")
      OFFBOARDED=false
      if [ -n "$SESSION_ID" ] && [ -f "$LAST_OFFBOARD" ] \
         && [ "$(cat "$LAST_OFFBOARD" 2>/dev/null)" = "$SESSION_ID" ]; then
        OFFBOARDED=true   # /offboard ran this session (primary signal)
      elif git -C "$ROOT" diff-tree --no-commit-id --name-only -r --root HEAD 2>/dev/null \
           | grep -qE 'session-handoff(--[^/]*)?\.md$'; then
        OFFBOARDED=true   # fallback: HEAD is the handoff commit (legacy or window-scoped)
      fi
      # Stamp the (window-scoped) marker with the ending session's id (not a
      # bare touch), so a stale one is traceable to its source session.
      $OFFBOARDED || printf '%s\n' "${SESSION_ID:-unknown}" > "$(offboard_pending_path "$ROOT")"
      ;;
  esac
fi

exit 0
