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
# is durable exhaust — touched in ONE case (the resolve-on-close below): a session
# that ends while BLOCKED gets a final resolving transition so the log's newest
# event for its window isn't frozen at "blocked" forever.
if [ -n "$SESSION_ID" ]; then
  LEX_DIR="${CLAUDE_LEXICON_STATE_DIR:-/tmp/claude-lexicon}"

  # Resolve-on-close (harnessd-l9v root fix): a session that ENDS while its lexicon
  # state is "blocked" would otherwise leave the transition log's newest event for
  # its window frozen at "blocked" (no resolving event ever follows) — which
  # harnessd's lexicon_dwell counts as a STUCK window until the window itself
  # closes, and whose 🔔 push never clears. Emit a final blocked->ready transition
  # for the window (recovered from the sticky session->window cache, since the pane
  # may already be gone at teardown) BEFORE clearing the token. Best-effort: the
  # guards + 2>/dev/null keep it from ever failing the hook. This ALSO lets the
  # harnessd notifier fire its SILENT down-edge "all clear", clearing the stale 🔔.
  if [ "$(cat "$LEX_DIR/$SESSION_ID" 2>/dev/null)" = "blocked" ]; then
    _RLIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/tmux-pane-resolve.sh"
    [ -f "$_RLIB" ] && . "$_RLIB"
    _WIN=""
    command -v tmux_win_cache_get >/dev/null 2>&1 && _WIN=$(tmux_win_cache_get "$SESSION_ID" 2>/dev/null || true)
    if [ -n "$_WIN" ] && command -v jq >/dev/null 2>&1; then
      _LOGDIR="${CLAUDE_LEXICON_LOG_DIR:-$HOME/.claude/lexicon-log}"
      mkdir -p "$_LOGDIR" 2>/dev/null
      jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$SESSION_ID" \
        --arg window "$_WIN" --arg from "blocked" --arg to "ready" \
        '{ts:$ts,session:$session,window:$window,from_state:$from,to_state:$to}' \
        >> "$_LOGDIR/$(date -u +%F).jsonl" 2>/dev/null
    fi
  fi

  rm -f "$LEX_DIR/$SESSION_ID" "$LEX_DIR/$SESSION_ID.reason" "$LEX_DIR/$SESSION_ID.window" 2>/dev/null
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
    # scrub.py exits 0=clean, 1=found, 2=usage/scan-error. Distinguish them
    # explicitly (explore-ytms): an ERROR is NOT a finding — conflating them
    # (the old `if …; then clean; else raise; fi`) raised a persistent false
    # SECRET ALERT on any transient hiccup, which trains the operator to
    # dismiss the real one. Treat marker + log as a unit on every branch.
    _OUT=$(python3 "$_SCRUB" scan "${_MEM[@]}" 2>&1); _RC=$?
    if [ "$_RC" -eq 0 ]; then
      # clean → clear BOTH the marker and any stale log (never leave a dangling log)
      rm -f "$HOME/.claude/.secret-alert" "$HOME/.claude/secret-scan.log" 2>/dev/null
    elif [ "$_RC" -eq 1 ]; then
      # real finding → write the log and raise the marker together
      { date -u +%FT%TZ; printf '%s\n' "$_OUT"; } > "$HOME/.claude/secret-scan.log" 2>/dev/null
      touch "$HOME/.claude/.secret-alert" 2>/dev/null
    else
      # scan error (exit 2, or any non-0/1) → log to a diagnostics file, do NOT
      # raise the persistent .secret-alert. A false alarm here is worse than a
      # missed one: it erodes trust in the real alert.
      { date -u +%FT%TZ; printf 'scan error (rc=%s):\n%s\n' "$_RC" "$_OUT"; } \
        > "$HOME/.claude/secret-scan-error.log" 2>/dev/null
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
      # PEER (marketing-vps): also push transcripts at session-end so a worker
      # session's results sync immediately (spec lin-i2d.1 P5). The primary uses
      # the hourly timer instead (avoids parallel-session push contention).
      if [ -f "$HOME/.claude/vaults/.peer" ]; then
        _TR_LIB="$(dirname "$_VAULT_LIB")/transcripts-lib.sh"
        [ -f "$_TR_LIB" ] && { . "$_TR_LIB"; vault_push_transcripts >>"$HOME/.claude/vault-session-end.log" 2>&1 || true; }
      fi
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
