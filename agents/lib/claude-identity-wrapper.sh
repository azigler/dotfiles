#!/usr/bin/env bash
# claude-identity-wrapper.sh — P1 of the durable-session-identity arc (explore-qmsy).
#
# Replaces  alias claude='claude --dangerously-skip-permissions'  with a function that
# stamps a per-session ATTRIBUTION header so the agentgateway can attribute each LLM
# call to the durable tmux identity (session:window). Nothing else changes.
#
# SUBSCRIPTION-SAFE (the load-bearing invariant): this sets ONLY a custom request
# header (ANTHROPIC_CUSTOM_HEADERS), NEVER a gateway credential. Per Claude Code's
# gateway docs, a gateway credential (ANTHROPIC_AUTH_TOKEN / apiKeyHelper) would flip
# CC off the claude.ai subscription onto per-token billing; a custom header does not.
# The header is OBSERVABILITY, not a security boundary (asserted, not verified —
# cryptographic identity is a deferred phase).
#
# Contract (hardened per spec-scrutiny 2026-07-14):
#   - preserves --dangerously-skip-permissions (dropping it prompts fleet-wide + hangs pulses)
#   - passes "$@" through (so --resume / -p / etc. keep working)
#   - uses `command` to run the real binary (no recursion into this function)
#   - FAILS OPEN: any resolution failure -> launch normally, no header
#   - NOT exec: runs claude as a child so the durable pane's shell survives claude exit
#   - identity = <session>:<glyph-stripped window>, matching handoff-path.sh's key

# Source the harness window resolver once, at load, so the identity matches the rest of
# the harness (glyph-stripped window name, bg-fork-aware). Harmless if absent.
[ -f "$HOME/dotfiles/agents/lib/tmux-pane-resolve.sh" ] && \
  . "$HOME/dotfiles/agents/lib/tmux-pane-resolve.sh" 2>/dev/null

# zsh refuses to define a function over an existing same-name alias ("defining
# function based on alias" -> parse error). Drop any pre-existing `claude` alias
# (e.g. the old alias this wrapper replaces) so the function defines cleanly,
# regardless of load order. Harmless if none exists.
unalias claude 2>/dev/null || true

claude() {
  local _hdr="" _sess _win
  if [ -n "$TMUX_PANE" ] && command -v tmux >/dev/null 2>&1; then
    _sess=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    if type tmux_resolve_window >/dev/null 2>&1; then
      _win=$(tmux_resolve_window 2>/dev/null)
    else
      _win=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
    fi
    # Sanitize to a clean, header-safe token: internal whitespace -> '-', keep only
    # alnum . _ - (drops any lexicon glyph the resolver didn't and any odd chars).
    _win=$(printf '%s' "$_win" | tr -s '[:space:]' '-' | tr -cd '[:alnum:]._-')
    _sess=$(printf '%s' "$_sess" | tr -s '[:space:]' '-' | tr -cd '[:alnum:]._-')
    [ -n "$_sess" ] && [ -n "$_win" ] && _hdr="X-Session-Identity: ${_sess}:${_win}"
  fi
  if [ -n "$_hdr" ]; then
    ANTHROPIC_CUSTOM_HEADERS="$_hdr" command claude --dangerously-skip-permissions "$@"
  else
    command claude --dangerously-skip-permissions "$@"
  fi
}
