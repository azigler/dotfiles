#!/usr/bin/env bash
# claude-identity-wrapper.sh — P1 of the durable-session-identity arc (explore-qmsy).
#
# Replaces  alias claude='claude --dangerously-skip-permissions'  with a function that
# stamps per-launch ATTRIBUTION headers so the agentgateway can attribute each LLM
# call to a SEAT and a TAP. Nothing else changes.
#
# ---------------------------------------------------------------------------
# EPOCH 2 (dotfiles-jbnp, 2026-08-09) — user = SEAT ADDRESS, group = TAP
# ---------------------------------------------------------------------------
# FOUR headers, newline-separated in ANTHROPIC_CUSTOM_HEADERS:
#   X-Session-Identity: <host>:<seat>   -> pico maps to standardAttributes.user
#   X-Machine-Origin:   <tap>           -> pico maps to standardAttributes.group
#   X-Seat-Address:     <host>:<seat>   -> the HONEST name for the same bytes
#   X-Tap:              <tap>           -> the HONEST name for the same bytes
#
# The two legacy names are what pico's `config.standardAttributes` CEL reads today,
# so they MUST stay to keep attribution working with NO gateway config change (this
# file cannot flip pico, and pico cannot flip the fleet's days-old shells). The two
# canonical names carry the same bytes so the eventual gateway-side rename is a
# CONFIG-ONLY change: flip the CEL to x-seat-address / x-tap, let the fleet's shells
# cycle, then drop the legacy pair. A same-value overlap is the only way to move a
# header name across a fleet whose panes are days old.
#
# WHAT CHANGED FROM EPOCH 1, and why:
#   * `user` was `<tmux session>:<window>`. Zig abolished the second session on
#     2026-08-09 — ONE tmux session per server, named after the host — so
#     session:window now EQUALS host:seat for every registered seat. That equality
#     is a COINCIDENCE of the naming ruling, and a coincidence is not an identity:
#     the value came from raw tmux, so a window that was never given a seat, or was
#     renamed, produced something seat-SHAPED and wrong. Epoch 2 DERIVES the address
#     through seat_resolve (agents/lib/seat-resolve.sh, uikg R5/R13) and makes every
#     failure explicit with a `?`:
#         <host>:<seat>    the window resolved to a registered seat (or its alias)
#         <host>:?<window> the window is NOT a registered seat, or the resolver is
#                          unavailable — never silently seat-shaped
#         <host>:?         no window could be resolved at all
#         ?:<...>          `hostname -s` failed
#     `?` cannot occur in a seat name, a hostname or a tap name (the sanitizers drop
#     it), so `agentgateway_user LIKE '%?%'` IS the unattributed bucket.
#   * `group` was `hostname -s`. The host now lives in `user`, so `group` carries the
#     TAP (personal|work|tick|…) — the billing source. Per-tap spend and headroom
#     (harnessd aj08/b1v6/4icj) become a plain GROUP BY instead of a text parse.
#
# THE TAP IS DERIVED FROM WHAT ACTUALLY RUNS, never asserted from the roster: it is
# read out of CLAUDE_CONFIG_DIR in THIS launch's own environment — the same variable
# pulse-inject exports into the pane and tick-jailed.sh sets through bwrap, and the
# same one assert_seat reads back out of /proc. Unset means the vendor default
# ~/.claude, i.e. `personal`. The roster supplies only the naming CONVENTION
# (`~/.claude-<tap>`), and test-claude-identity-wrapper.sh T19 asserts this
# derivation still agrees with every `taps:` row in agents/seats.yml.
#
# NEVER REWRITE HISTORY. Epoch 1 rows (group=<host>, user=<session>:<window>,
# including the `work:*` split of dotfiles-fo5l) stay exactly as logged. Queries
# union the epochs by date boundary; see refs/probes/gateway-attribution-epoch2.md.
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
#   - identity = <host>:<seat>, DERIVED through seat_resolve — see the epoch-2 note
#     above. Resolution runs in a SUBSHELL so seat-resolve.sh's ~30 function
#     definitions never leak into the durable pane's days-old shell.
#
# GATEWAY ROUTING (added 2026-07-29) — the same launch-time treatment, for the same
# reason. ANTHROPIC_BASE_URL used to live in the fleet-wide claude/settings.json `env`
# block, which EVERY claude process read at launch. On 2026-07-27 it moved to the
# per-host shell tier (~/.<host>.zshenv, commits 2b8d22a + 5c9ff80). The scoping is
# right — one box (marketing-vps, since decommissioned) had no route to the gateway
# then — but it turned a LAUNCH-time
# setting into a SHELL-START-time one, and the harness's durable tmux panes hold zsh
# processes that are days old. Those shells never sourced the new file, so every claude
# launched from them (i.e. every pulse tick in every long-lived window) silently
# bypassed the gateway: pico's request log — the fleet's API-layer instrument — went
# blind after 2026-07-28T21:56Z and NOTHING alarmed, because bypassing an o11y proxy
# looks exactly like being idle. Resolving the value HERE, per invocation, makes it
# shell-age-independent the way the identity header already is.
#
# Precedence (first match wins):
#   1. CC_NO_GATEWAY (any non-empty value) — the escape hatch, for when the gateway's
#      o11y body-size limit 503s a huge request (context compaction is the usual
#      victim, i.e. exactly when a session is long, expensive and least able to absorb
#      a failure). Clears the base URL UNCONDITIONALLY, including over an inherited
#      one. It supersedes the old `unset ANTHROPIC_BASE_URL && claude` hatch, which
#      step 3 defeats by re-deriving the value.
#   2. ANTHROPIC_BASE_URL already in the environment — an explicit per-call override,
#      and what a freshly-started shell supplies anyway. Honored as-is.
#   3. the per-host ~/.<host>.zshenv, read in a SUBSHELL (its exports never leak into
#      the caller). A host without that file gets nothing, unchanged.
#
# WHY THE HATCH IS FIRST AND NOT SECOND (dotfiles-20rx, fixed 2026-08-03). It was
# written second, on the reasoning that an inherited value is a deliberate per-call
# override and should never be second-guessed. That reasoning does not survive zsh:
# zsh sources ~/.zshenv on EVERY invocation, ~/.zshenv sources ~/.<host>.zshenv, and
# that file EXPORTS ANTHROPIC_BASE_URL — so in every fresh zsh on the fleet rule 1 had
# already matched and rule 2 was unreachable:
#
#   env -u ANTHROPIC_BASE_URL CC_NO_GATEWAY=1 zsh  -c 'echo ${ANTHROPIC_BASE_URL:-unset}'
#     -> http://100.72.47.4:17017/claude   (hatch defeated)
#   env -u ANTHROPIC_BASE_URL CC_NO_GATEWAY=1 bash -c 'echo ${ANTHROPIC_BASE_URL:-unset}'
#     -> unset                             (hatch works)
#
# The hatch fired only where the variable happened to be unset — bash — which is the
# opposite of where it is needed: the interactive fleet is zsh. Worse, since
# dotfiles-ucl4 gateway routing is FAIL-HARD fleet-wide, so a box whose
# tunnel is down had neither a working `claude` nor a hatch that could fire in its own
# login shell.
#
# An ambient inherited value is not evidence of intent — it is the default state of
# every shell. `CC_NO_GATEWAY=1` typed at a prompt is. The more specific intent wins.
# Rule 2 still beats rule 3, so a deliberate override with the hatch unarmed behaves
# exactly as before. Guarded by T9–T12 in test-claude-identity-wrapper.sh.

# Source the harness window resolver once, at load, so the identity matches the rest of
# the harness (glyph-stripped window name, bg-fork-aware).
#
# dotfiles-tm0w: resolve through the shared agents-tier indirection
# (agents/lib/agents-root.sh) rather than a hardcoded $HOME/dotfiles path, so
# a demesne-split move doesn't silently disarm identity attribution. Sourced
# robustly across bash AND zsh: in bash ${BASH_SOURCE[0]} is this file; in zsh
# (what Claude Code's Bash tool runs) BASH_SOURCE is empty, so we fall to $0,
# which a sourced zsh file sets to its own path (same idiom as handoff-path.sh).
_ciw_self="${BASH_SOURCE[0]:-$0}"
_ciw_dir="$(cd "$(dirname -- "$_ciw_self")" 2>/dev/null && pwd)"
if [ -n "$_ciw_dir" ] && [ -f "$_ciw_dir/agents-root.sh" ]; then
  . "$_ciw_dir/agents-root.sh"
fi
unset _ciw_self _ciw_dir
if ! declare -F agents_root >/dev/null; then
  echo "claude-identity-wrapper: cannot load lib/agents-root.sh — agents-tier resolution degraded to the hardcoded fallback path." >&2
  agents_root() { [ -d "$HOME/dotfiles/${1:-agents}" ] && printf '%s\n' "$HOME/dotfiles/${1:-agents}"; }
fi

if _ciw_ar=$(agents_root 2>/dev/null) && [ -f "$_ciw_ar/lib/tmux-pane-resolve.sh" ]; then
  . "$_ciw_ar/lib/tmux-pane-resolve.sh" 2>/dev/null
else
  echo "claude-identity-wrapper: tmux-pane-resolve.sh not found via agents_root() (root=${_ciw_ar:-<unresolved>}) — window names in X-Session-Identity fall back to raw tmux names (lexicon glyphs not stripped)." >&2
fi
unset _ciw_ar

# zsh refuses to define a function over an existing same-name alias ("defining
# function based on alias" -> parse error). Drop any pre-existing `claude` alias
# (e.g. the old alias this wrapper replaces) so the function defines cleanly,
# regardless of load order. Harmless if none exists.
unalias claude 2>/dev/null || true

# --- epoch-2 derivation helpers ---------------------------------------------
# All three are pure value producers: stdout only, no state, no leaks. Written
# without arrays or [[ ]] so bash and zsh behave identically.

# _ciw_sanitize — the one header-safe token filter, used for every field.
# Internal whitespace -> '-', then keep only alnum . _ -  (drops lexicon glyphs,
# and drops '?' too, which is what makes '?' usable as the NOT-DERIVED marker).
_ciw_sanitize() { printf '%s' "$1" | tr -s '[:space:]' '-' | tr -cd '[:alnum:]._-'; }

# _ciw_tap — the TAP (billing/quota source) this launch will actually draw
# from, from CLAUDE_CONFIG_DIR in THIS process's environment. Purely
# syntactic, by the roster's convention:
#
#   <unset>            -> personal   (the vendor default config dir is ~/.claude)
#   …/.claude          -> personal
#   …/.claude-work     -> work
#   …/.claude-tick     -> personal   PROFILE, not a tap (dotfiles-iez1): the
#                                    isolated tick-jailed.sh sandbox config
#                                    dir carries an IDENTICAL account
#                                    fingerprint to ~/.claude (same Max
#                                    subscription) — billing is `personal`,
#                                    the jail is metadata, never a group value
#   …/.claude-<name>   -> <name>
#   …/<anything else>  -> ?<anything else>   NOT a conforming tap dir; visible
#   (nothing left)     -> ""                 degenerate; caller sends no header
#
# No roster read, no python3, no YAML on the launch path: a claude launch must not
# depend on the roster being parseable, and the roster must not be able to CLAIM a
# tap this process is not actually running on. The convention is asserted against
# agents/seats.yml's `taps:` at TEST time (T19) instead — derive, then assert.
_ciw_tap() {
  local d b
  d="${CLAUDE_CONFIG_DIR:-}"
  [ -n "$d" ] || { printf 'personal'; return 0; }
  while [ "${d%/}" != "$d" ]; do d="${d%/}"; done   # strip trailing slashes
  b="${d##*/}"                                      # basename
  b="${b#.}"                                        # one leading dot
  case "$b" in
    claude)      printf 'personal' ;;
    claude-tick) printf 'personal' ;;  # jail PROFILE of personal, not a tap
    claude-*)    _ciw_sanitize "${b#claude-}" ;;
    *)           b=$(_ciw_sanitize "$b"); [ -z "$b" ] || printf '?%s' "$b" ;;
  esac
  return 0
}

# _ciw_window — this launch's glyph-stripped, sanitized tmux window name, or "".
# $SEAT_WINDOW / $HANDOFF_WINDOW first, because a tick jail has no tmux server to
# ask and the jail launcher already exports HANDOFF_WINDOW (same order as
# seat-resolve.sh's _seat_self_window, deliberately).
_ciw_window() {
  local w=""
  if [ -n "${SEAT_WINDOW:-}" ]; then
    w="$SEAT_WINDOW"
  elif [ -n "${HANDOFF_WINDOW:-}" ]; then
    w="$HANDOFF_WINDOW"
  elif [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
    if type tmux_resolve_window >/dev/null 2>&1; then
      w=$(tmux_resolve_window 2>/dev/null)
    else
      w=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
    fi
  fi
  _ciw_sanitize "$w"
}

# _ciw_seat — the canonical SEAT name for this window, via seat_resolve, or
# non-zero with no output (unregistered window, no roster, no python3, …).
# Sourced in a SUBSHELL: seat-resolve.sh defines ~30 functions and this wrapper
# runs in a tmux pane whose shell lives for days. --quiet because the caller
# prints its own one-line consequence; seat_resolve's six-line refusal is right
# for an operator command and wrong for every claude launch.
#
# COST, measured 2026-08-09 on the keep: ~130 ms per launch (a python3 start plus
# the roster parse, inside seat-resolve.sh's one _seat_dump call). That is paid
# ONCE PER `claude` LAUNCH, never per request — a session or a tick pays it at
# start-up and nothing else in the wrapper got slower. Accepted deliberately over
# caching it: a cache keyed on a window name is wrong the moment the roster
# changes, and the roster changing is precisely when the address must move.
_ciw_seat() {
  local root lib s
  root=$(agents_root) || return 1
  lib="$root/lib/seat-resolve.sh"
  [ -f "$lib" ] || return 1
  # shellcheck source=/dev/null
  s=$( . "$lib"; seat_self_name --quiet ) || return 1
  [ -n "$s" ] || return 1
  _ciw_sanitize "$s"
}

# _ciw_add <accumulated> <name> <value> — append one `Name: Value` line.
# ANTHROPIC_CUSTOM_HEADERS is NEWLINE-separated (first-party env-vars docs); a
# comma join yields ONE header whose value silently carries the other's text.
_ciw_add() {
  if [ -n "$1" ]; then printf '%s\n%s: %s' "$1" "$2" "$3"; else printf '%s: %s' "$2" "$3"; fi
}

claude() {
  local _hdrs="" _addr="" _tap="" _seat="" _win _base="${ANTHROPIC_BASE_URL:-}" _hostenv _host _mhost
  # THE HOST — resolved FIRST and UNCONDITIONALLY (dotfiles-v93v).
  # Two reasons it lives up here rather than inside the routing branch below:
  #   1. `_host` used to be computed only inside `if [ -z "$_base" ]`, so it was
  #      empty in exactly the case where ANTHROPIC_BASE_URL was already exported —
  #      i.e. a freshly-started shell, the common case.
  #   2. The identity must NOT depend on tmux. A jailed or non-interactive tick has
  #      no $TMUX_PANE and therefore sent NO header at all before that change; those
  #      are precisely the requests that need attributing. In epoch 2 the host is
  #      the FIRST FIELD of the seat address rather than a header of its own.
  _host=$(hostname -s 2>/dev/null)
  # Kept in a SEPARATE var so the per-host env path below still uses the raw
  # `hostname -s` output verbatim.
  _mhost=$(_ciw_sanitize "$_host")
  # Per-host gateway routing, resolved at LAUNCH (see the header note).
  # THE HATCH IS CHECKED FIRST — the ordering is the whole fix for dotfiles-20rx
  # and it is not cosmetic; see the precedence note above for why an inherited
  # value cannot be treated as evidence of intent.
  if [ -n "${CC_NO_GATEWAY:-}" ]; then
    _base=""
  elif [ -z "$_base" ]; then
    _hostenv="$HOME/.${_host}.zshenv"
    if [ -n "$_host" ] && [ -f "$_hostenv" ]; then
      # Subshell: the file's exports must NOT leak into the caller — this reads one
      # value, it does not apply the host env. Suppression is the point here (a pure
      # value extraction); a file that fails to source simply yields "" -> fail open.
      # shellcheck source=/dev/null
      _base=$( . "$_hostenv" >/dev/null 2>&1; printf '%s' "${ANTHROPIC_BASE_URL:-}" )
    fi
  fi
  # THE TAP — what this launch actually bills to. Derived, never asserted.
  _tap=$(_ciw_tap)
  # THE SEAT ADDRESS. seat_resolve first; the window is only needed for the
  # explicit NOT-A-SEAT form, so it is resolved lazily.
  _seat=$(_ciw_seat) || _seat=""
  if [ -n "$_seat" ]; then
    _addr="${_mhost:-?}:${_seat}"
  else
    _win=$(_ciw_window)
    if [ -n "$_win" ]; then
      _addr="${_mhost:-?}:?${_win}"
      # ONE line, on stderr, naming the consequence. This is how an unregistered
      # durable window gets noticed and given a seat instead of quietly polluting
      # the attribution table with a seat-shaped value that is not a seat.
      echo "claude-identity-wrapper: window '$_win' is not a registered seat (agents/seats.yml) or the seat resolver is unavailable — attributing this session as ${_addr}." >&2
    elif [ -n "$_mhost" ]; then
      _addr="${_mhost}:?"
    fi
  fi
  # Join the headers. ANTHROPIC_CUSTOM_HEADERS carries MULTIPLE headers as
  # `Name: Value` separated by NEWLINES (first-party env-vars docs) — never commas
  # or semicolons. `_ciw_add`'s printf builds it rather than $'\n' so the idiom is
  # identical under bash and zsh, and joining HERE keeps the launch branches below
  # at four instead of eight.
  #
  # LEGACY NAME FIRST, then the canonical one, for each of the two values — pico's
  # CEL reads the legacy pair, and the canonical pair exists so the eventual
  # gateway-side rename is config-only (see the epoch-2 note in the header).
  # Either value may be absent independently; both absent means no
  # ANTHROPIC_CUSTOM_HEADERS at all, exactly as before.
  [ -z "$_addr" ] || _hdrs=$(_ciw_add "$_hdrs" X-Session-Identity "$_addr")
  [ -z "$_tap" ]  || _hdrs=$(_ciw_add "$_hdrs" X-Machine-Origin "$_tap")
  [ -z "$_addr" ] || _hdrs=$(_ciw_add "$_hdrs" X-Seat-Address "$_addr")
  [ -z "$_tap" ]  || _hdrs=$(_ciw_add "$_hdrs" X-Tap "$_tap")
  # Build the per-invocation env prefix. Written as explicit cases rather than an
  # array: this file is sourced by BOTH bash and zsh, and empty-array expansion is
  # exactly the kind of thing that differs between them.
  #
  # CASES 2u/4u — "we resolved to NO base URL, but the environment carries one."
  # Clearing `_base` is NOT enough to bypass the gateway: ANTHROPIC_BASE_URL is
  # EXPORTED in the calling shell (that export is the bug), so an unset-in-here
  # variable is still inherited by the child and the request still routes. It has
  # to be removed from the LAUNCHED environment.
  #   `env -u` and not `unset`: this function runs in the caller's shell, and that
  #   shell is a durable tmux pane that lives for days — `unset` would silently
  #   de-gateway every later claude in the pane, turning a per-call hatch into a
  #   sticky one. `env` execs the binary, so claude stays a direct child and the
  #   NOT-exec invariant (the pane's shell survives claude exiting) is unaffected.
  #   `env` cannot see shell functions, so naming `claude` here cannot recurse,
  #   exactly as `command claude` cannot.
  # Reached only via CC_NO_GATEWAY today (nothing else empties an inherited value),
  # but written as the state it actually is rather than as a second hatch check.
  if [ -z "$_base" ] && [ -n "${ANTHROPIC_BASE_URL+x}" ]; then
    if [ -n "$_hdrs" ]; then
      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" \
        env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions "$@"
    else
      env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions "$@"
    fi
  elif [ -n "$_hdrs" ] && [ -n "$_base" ]; then
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
