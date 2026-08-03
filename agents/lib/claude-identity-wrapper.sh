#!/usr/bin/env bash
# claude-identity-wrapper.sh — P1 of the durable-session-identity arc (explore-qmsy).
#
# Replaces  alias claude='claude --dangerously-skip-permissions'  with a function that
# stamps per-session ATTRIBUTION headers so the agentgateway can attribute each LLM
# call to the durable tmux identity (session:window). Nothing else changes.
#
# TWO headers, newline-separated in ANTHROPIC_CUSTOM_HEADERS (dotfiles-v93v):
#   X-Session-Identity: <session>:<window>   -> pico maps to standardAttributes.user
#   X-Machine-Origin:   <hostname -s>        -> pico maps to standardAttributes.group
# The session header's FIRST field is the tmux SESSION name, not the machine, and
# that namespace is shared: zig-computer, marketing-vps AND metis all have a session
# called `work`, so `user` alone cannot say which box a request came from. The two
# are INDEPENDENT — no tmux still emits the machine header (jailed and
# non-interactive ticks are exactly the ones that were unattributed before), and a
# failed hostname still emits the session header. X-Session-Identity's format is
# deliberately unchanged so `user` and its history stay intact.
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
#
# GATEWAY ROUTING (added 2026-07-29) — the same launch-time treatment, for the same
# reason. ANTHROPIC_BASE_URL used to live in the fleet-wide claude/settings.json `env`
# block, which EVERY claude process read at launch. On 2026-07-27 it moved to the
# per-host shell tier (~/.<host>.zshenv, commits 2b8d22a + 5c9ff80). The scoping is
# right — marketing-vps had no route to the gateway then — but it turned a LAUNCH-time
# setting into a SHELL-START-time one, and the harness's durable tmux panes hold zsh
# processes that are days old. Those shells never sourced the new file, so every claude
# launched from them (i.e. every pulse tick in every long-lived window) silently
# bypassed the gateway: pico's request log — the fleet's API-layer instrument — went
# blind after 2026-07-28T21:56Z and NOTHING alarmed, because bypassing an o11y proxy
# looks exactly like being idle. Resolving the value HERE, per invocation, makes it
# shell-age-independent the way the identity header already is.
#
# Precedence (first match wins):
#   1. ANTHROPIC_BASE_URL already in the environment — an explicit per-call override,
#      and what a freshly-started shell supplies anyway. Never second-guessed.
#   2. CC_NO_GATEWAY=1 — the escape hatch, for when the gateway's o11y body-size limit
#      503s a huge request (context compaction is the usual victim). This REPLACES the
#      old `unset ANTHROPIC_BASE_URL && claude` hatch, which no longer suffices now
#      that step 3 re-derives the value.
#   3. the per-host ~/.<host>.zshenv, read in a SUBSHELL (its exports never leak into
#      the caller). A host without that file — the VPS — gets nothing, unchanged.

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
  local _hdr="" _mhdr="" _hdrs="" _sess _win _base="${ANTHROPIC_BASE_URL:-}" _hostenv _host _mhost
  # MACHINE OF ORIGIN — resolved FIRST and UNCONDITIONALLY (dotfiles-v93v).
  # Two reasons it lives up here rather than inside the routing branch below:
  #   1. `_host` used to be computed only inside `if [ -z "$_base" ]`, so it was
  #      empty in exactly the case where ANTHROPIC_BASE_URL was already exported —
  #      i.e. a freshly-started shell, the common case.
  #   2. The machine header must NOT depend on tmux. A jailed or non-interactive
  #      tick has no $TMUX_PANE and therefore sent NO header at all before this
  #      change; those are precisely the requests that need attributing.
  _host=$(hostname -s 2>/dev/null)
  # Same header-safe sanitization as the session token. Kept in a SEPARATE var so
  # the per-host env path below still uses the raw `hostname -s` output verbatim.
  _mhost=$(printf '%s' "$_host" | tr -s '[:space:]' '-' | tr -cd '[:alnum:]._-')
  [ -n "$_mhost" ] && _mhdr="X-Machine-Origin: ${_mhost}"
  # Per-host gateway routing, resolved at LAUNCH (see the header note). Skipped
  # entirely when the var is already set or the escape hatch is armed.
  if [ -z "$_base" ] && [ -z "${CC_NO_GATEWAY:-}" ]; then
    _hostenv="$HOME/.${_host}.zshenv"
    if [ -n "$_host" ] && [ -f "$_hostenv" ]; then
      # Subshell: the file's exports must NOT leak into the caller — this reads one
      # value, it does not apply the host env. Suppression is the point here (a pure
      # value extraction); a file that fails to source simply yields "" -> fail open.
      # shellcheck source=/dev/null
      _base=$( . "$_hostenv" >/dev/null 2>&1; printf '%s' "${ANTHROPIC_BASE_URL:-}" )
    fi
  fi
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
  # Join the headers. ANTHROPIC_CUSTOM_HEADERS carries MULTIPLE headers as
  # `Name: Value` separated by NEWLINES (first-party env-vars docs) — never commas
  # or semicolons. `printf` builds it rather than $'\n' so the idiom is identical
  # under bash and zsh, and joining HERE keeps the launch branches below at four
  # instead of eight. Either header may be absent independently; both absent means
  # no ANTHROPIC_CUSTOM_HEADERS at all, exactly as before.
  if [ -n "$_hdr" ] && [ -n "$_mhdr" ]; then
    _hdrs=$(printf '%s\n%s' "$_hdr" "$_mhdr")
  elif [ -n "$_hdr" ]; then
    _hdrs="$_hdr"
  elif [ -n "$_mhdr" ]; then
    _hdrs="$_mhdr"
  fi
  # Build the per-invocation env prefix. Written as explicit cases rather than an
  # array: this file is sourced by BOTH bash and zsh, and empty-array expansion is
  # exactly the kind of thing that differs between them.
  if [ -n "$_hdrs" ] && [ -n "$_base" ]; then
    ANTHROPIC_CUSTOM_HEADERS="$_hdrs" ANTHROPIC_BASE_URL="$_base" \
      command claude --dangerously-skip-permissions "$@"
  elif [ -n "$_hdrs" ]; then
    ANTHROPIC_CUSTOM_HEADERS="$_hdrs" command claude --dangerously-skip-permissions "$@"
  elif [ -n "$_base" ]; then
    ANTHROPIC_BASE_URL="$_base" command claude --dangerously-skip-permissions "$@"
  else
    command claude --dangerously-skip-permissions "$@"
  fi
}
