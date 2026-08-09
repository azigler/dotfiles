#!/bin/bash
# PreCompact: re-inject state so the agent doesn't lose orientation.
#
# Context budget (dotfiles-b9ii): this hook fires at the moment context is
# SCARCEST. It used to run an unbounded `br list` and inject 31,484 bytes
# (~7.9k tokens) in ~/explore — 12x what session-start.sh injects. The emit
# is now shared with session-start.sh via lib/context-emit.sh, so both go
# through the same cap ($HARNESS_ONBOARD_BEAD_CAP, default 12).
#
# RE-ARM, path (b) (dotfiles-ygf8). stop-context-guard.sh's .fired marker is
# permanent for a session_id unless something clears it, and compaction is
# the single event most likely to leave it stuck: same session_id, fresh
# context, backstop already dead. stop-context-guard.sh's OWN re-arm (any
# Stop where pct drops below threshold-20) is the general case, but it
# depends on the NEXT Stop actually finding a rendered pct file — and the
# statusline may not have painted yet immediately post-compaction, in which
# case that Stop exits at the "no pct file" check before ever reaching the
# re-arm line. Clearing HERE, at the compaction boundary itself, has no such
# dependency: it fires on every PreCompact, unconditionally, regardless of
# what the statusline has or hasn't rendered yet. Both paths are load-bearing
# for that reason — this is the belt, stop-context-guard.sh's is the general
# mechanism. The nudge marker is cleared alongside it for the same reason:
# a fresh context deserves a fresh nudge cooldown too.
SESSION_ID=$(cat 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SESSION_ID" ]; then
  _PC_STATE_DIR="${CONTEXT_GUARD_STATE_DIR:-/tmp/claude-context-pct}"
  rm -f "$_PC_STATE_DIR/$SESSION_ID.fired" "$_PC_STATE_DIR/$SESSION_ID.nudged" 2>/dev/null
fi

CTX_LIB="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/context-emit.sh"
if [ -r "$CTX_LIB" ]; then
  # shellcheck source=lib/context-emit.sh
  . "$CTX_LIB"
else
  # Degrade LOUDLY, not silently: without the lib the agent gets no state at
  # all across a compaction, and a silent omission is indistinguishable from
  # "there was nothing to say."
  echo "⚠ hook lib missing: $CTX_LIB — git/bead context omitted from this compaction."
  emit_git_context() { :; }
  emit_bead_context() { :; }
fi

echo "=== State Before Compaction ==="

# Tell the post-compaction agent to onboard before any action.
echo "IMPORTANT: Run /onboard before doing anything. It re-reads CLAUDE.md, MEMORY.md, the prior session's handoff note (refs/session-handoff.md), and the skills TOOLKIT digest in the main session — preventing blind post-compaction execution."

emit_git_context
emit_bead_context

if command -v br >/dev/null 2>&1; then
  # Flush bead state to JSONL so the post-compaction git view is current.
  # Output is captured rather than injected — a successful flush has nothing
  # the agent needs. A missing store is expected and silent; any OTHER
  # failure IS surfaced, because a silently-failed flush loses bead state.
  if ! FLUSH_ERR=$(br sync --flush-only 2>&1); then
    case "$FLUSH_ERR" in
      *"not initialized"*) ;;
      *) echo "⚠ br sync --flush-only failed: $(printf '%s' "$FLUSH_ERR" | head -1)" ;;
    esac
  fi
fi

exit 0
