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
# ---------------------------------------------------------------------------
# EPOCH 3 (dotfiles-kecb, 2026-08-09) — the TAP NAMES changed, nothing else did
# ---------------------------------------------------------------------------
# Zig's naming ruling, ~19:1xZ: `personal` -> `primary`, `work` -> `linearb`,
# and a NEW second Max 20x account `secondary` (~/.claude-secondary,
# zig@zigler.ai, first attributed request 19:22:04Z). `tick` is unchanged and
# still resolves to primary — it is a jailed GRANT of primary's account, not a
# tap. Header names, the newline separator and the `?` NOT-DERIVED convention
# are all untouched; only the VALUES of `group` moved.
#
# CLASSIFY BY VALUE, NEVER BY DATE. The cutover is rolling — a durable pane
# emits epoch-2 values until its days-old shell is replaced — so BOTH epochs
# are live in the table at once and both stay queryable:
#     primary   <- group IN ('primary','personal')
#     linearb   <- group IN ('linearb','work')
#     secondary <- group  = 'secondary'
# That mapping is DATA, in agents/scheduler/taps.conf's `pool.<p>.groups`, so
# the queries and the failover machinery read one copy of it. Full scheme and
# the query recipes: refs/probes/gateway-attribution-epoch3.md.
#
# agents/seats.yml still carries the EPOCH-2 tap names in `taps:` and in every
# seat's `tap:`, and several consumers read those strings (marshal.conf's tap
# filter, pulse-inject's seat pinning). The roster rename is deliberately a
# SEPARATE, sequenced change — this file is the emitter and moves first.
#
# NEVER REWRITE HISTORY. Epoch 1 rows (group=<host>, user=<session>:<window>,
# including the `work:*` split of dotfiles-fo5l) stay exactly as logged. Queries
# union the epochs by VALUE; see refs/probes/gateway-attribution-epoch2.md and
# refs/probes/gateway-attribution-epoch3.md.
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
#   <unset>            -> primary    (the vendor default config dir is ~/.claude)
#   …/.claude          -> primary    (epoch 2 called this `personal`)
#   …/.claude-work     -> linearb    (epoch 2 called this `work`; the DIRECTORY
#                                    name is unchanged, only the tap name moved,
#                                    so this is the one arm that cannot be
#                                    derived by stripping the prefix)
#   …/.claude-tick     -> primary    PROFILE, not a tap (dotfiles-iez1): the
#                                    isolated tick-jailed.sh sandbox config
#                                    dir carries an IDENTICAL account
#                                    fingerprint to ~/.claude (same Max
#                                    subscription) — billing is `primary`,
#                                    the jail is metadata, never a group value
#   …/.claude-<name>   -> <name>     (so ~/.claude-secondary -> secondary)
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
  [ -n "$d" ] || { printf 'primary'; return 0; }
  while [ "${d%/}" != "$d" ]; do d="${d%/}"; done   # strip trailing slashes
  b="${d##*/}"                                      # basename
  b="${b#.}"                                        # one leading dot
  case "$b" in
    claude)      printf 'primary' ;;
    claude-tick) printf 'primary' ;;  # jail PROFILE of primary, not a tap
    claude-work) printf 'linearb' ;;  # epoch-3 rename; the dir name did not move
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

# --- the TAP-FAILOVER consult (dotfiles-kecb, rbci's ruled spec) -------------
#
# CEILING ONLY. Nothing below spreads load, warms a reserve or balances
# anything: the home pool is used unless it is MEASURABLY at its ceiling, and
# then the first candidate behind it with measured headroom is. Every other
# outcome — unmeasurable, slow, no conf, no library — is HOME. An unmeasured
# pool is never evidence for moving Zig's billing.
#
# A ROLLOVER IS PER LAUNCH, NEVER A REBIND (OQ-3). Nothing here is written back
# to a roster or a pane; the next launch re-derives its home tap from its own
# CLAUDE_CONFIG_DIR and tries it first again.
#
# AND IT IS LOUD, ALWAYS. Zero silent cross-billing is the point of the whole
# tap system, so a rollover leaves three marks and each is independently
# sufficient to find it: the ACTUAL tap in `X-Tap` (never the home one), an
# explicit `X-Home-Tap` + `X-Tap-Rollover: 1` pair beside it, a JSONL ledger row
# carrying home_tap != used_tap, and one sentence on stderr for whoever is
# watching the pane.

# _ciw_fable_launch "$@" — does this launch name a Fable-family model? The
# model-scoped weekly allotment is a SEPARATE ceiling from the unified windows
# (Zig at 82% of it while the unified weekly read 76% — measured 2026-08-09),
# so a fable launch must consult a dimension an opus launch does not.
# `--model x`, `--model=x` and $ANTHROPIC_MODEL are all real pin sites in this
# fleet (pulse-inject writes the first).
_ciw_fable_launch() {
  local a want next=0
  want=$(_ciw_conf fable_models); want="${want:-fable}"
  for a in "$@"; do
    if [ "$next" -eq 1 ]; then next=0; case "$a" in *"$want"*) return 0 ;; esac; continue; fi
    case "$a" in
      --model) next=1 ;;
      --model=*) case "${a#--model=}" in *"$want"*) return 0 ;; esac ;;
    esac
  done
  case "${ANTHROPIC_MODEL:-}" in *"$want"*) return 0 ;; esac
  return 1
}

# _ciw_conf <key> — one value from taps.conf WITHOUT sourcing the headroom
# library into this shell. Cheap (one awk), and returns "" when the conf is
# absent, which is what makes every consumer below degrade to "no failover".
_ciw_conf() {
  local root conf
  conf="${TAP_HEADROOM_CONF:-}"
  if [ -z "$conf" ]; then
    root=$(agents_root) || return 1
    conf="$root/scheduler/taps.conf"
  fi
  [ -f "$conf" ] || return 1
  awk -v want="$1" '
    /^[[:space:]]*#/ { next }
    { i=index($0,"="); if (i<2) next
      k=substr($0,1,i-1); v=substr($0,i+1)
      if (k !~ /^[a-z][a-z0-9_.-]*$/) next
      if (v !~ /^[A-Za-z0-9_,.\/~:-]+$/) next
      if (k==want) { print v; found=1; exit } }
    END { if (!found) exit 1 }
  ' "$conf"
}

# _ciw_pick <home-tap> <seat> <fable:0|1> — prints `<pool> <config-dir>` and
# returns 10 when this launch must ROLL OVER, 0 otherwise (with no output).
#
# Sourced in a SUBSHELL, exactly like _ciw_seat: tap-headroom.sh defines a
# dozen functions and this wrapper runs in a tmux pane whose shell lives for
# days. Bounded by `timeout` where it exists, and by curl's --max-time /
# ssh's ConnectTimeout in any case — a slow network must not be able to hang
# every `claude` on the box, and a consult that cannot finish means HOME.
_ciw_pick() {
  local root lib home_tap=$1 seat=$2 fable=$3 out rc pool cfg
  [ "${CIW_TAP_FAILOVER:-on}" = "off" ] && return 0
  root=$(agents_root) || return 0
  lib="$root/lib/tap-headroom.sh"
  [ -f "$lib" ] || return 0
  # THE CONSULT SCRIPT, as one string, run through bash. `timeout` is applied by
  # naming it as the COMMAND in its own branch rather than by interpolating a
  # `$tmo` prefix variable: an unquoted "$tmo" splits into words under bash and
  # does NOT under zsh (zsh performs no field splitting on parameter
  # expansions), so the prefix idiom becomes the single command
  # `timeout 12` — "command not found", every launch, on exactly half the
  # fleet's shells. Caught by T20 on the first run of this suite.
  _CIW_CONSULT='
      . "$1" || exit 0
      home=$(th_pool_of_tap "$2") || exit 0
      if [ "$4" = "1" ]; then f=--fable; else f=; fi
      p=$(th_pick_pool "$home" "$3" "$f"); rc=$?
      [ "$rc" -eq 10 ] || exit 0
      printf "%s %s\n" "$p" "$(th_pool_config_dir "$p")"
      exit 10
    '
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout "${CIW_TAP_CONSULT_TIMEOUT:-12}" bash -c "$_CIW_CONSULT" _ "$lib" "$home_tap" "$seat" "$fable")
  else
    out=$(bash -c "$_CIW_CONSULT" _ "$lib" "$home_tap" "$seat" "$fable")
  fi
  rc=$?
  unset _CIW_CONSULT
  [ "$rc" -eq 10 ] || return 0
  pool=${out%% *}; cfg=${out#* }
  [ -n "$pool" ] && [ -n "$cfg" ] && [ -d "$cfg" ] || return 0
  printf '%s %s' "$pool" "$cfg"
  return 10
}

# _ciw_ledger <home-tap> <used-tap> <pool> <address> — the durable mark. One
# JSON object per rollover; the `home_tap != used_tap` pair is the whole point,
# so both are always written even though one is derivable from the other.
# A ledger that cannot be written is NOISE ON STDERR, never a silent skip.
_ciw_ledger() {
  local f d
  f="${CIW_ROLLOVER_LEDGER:-$HOME/.local/share/fleet-health/tap-rollover.jsonl}"
  d=$(dirname "$f")
  mkdir -p "$d" || { echo "claude-identity-wrapper: cannot create $d — the rollover ledger row for $1 -> $2 is NOT recorded." >&2; return 1; }
  printf '{"ts":"%s","event":"tap_rollover","home_tap":"%s","used_tap":"%s","pool":"%s","seat_address":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >> "$f" \
    || { echo "claude-identity-wrapper: cannot append to $f — the rollover ledger row for $1 -> $2 is NOT recorded." >&2; return 1; }
  return 0
}

claude() {
  local _hdrs="" _addr="" _tap="" _seat="" _win _base="${ANTHROPIC_BASE_URL:-}" _hostenv _host _mhost
  local _home_tap="" _pool="" _cfg="" _pick="" _fable=0
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
  # THE FAILOVER CONSULT — after the seat is known (the per-seat home-tap
  # override is keyed on it) and before a single header is built, because a
  # rollover CHANGES the tap this launch bills to and `X-Tap` must carry the
  # tap that actually ran. `_home_tap` keeps what it would have been.
  _home_tap="$_tap"
  if _ciw_fable_launch "$@"; then _fable=1; fi
  if _pick=$(_ciw_pick "$_tap" "$_seat" "$_fable"); then
    : # rc 0 — home pool, the overwhelming case. Nothing to say and nothing to do.
  else
    _pool=${_pick%% *}; _cfg=${_pick#* }
    # RE-DERIVE the tap from the config dir we are about to launch with, rather
    # than trusting the pool name to equal it: the tap is derived from what
    # actually runs. Inside $( ) so the assignment cannot survive the subshell —
    # a leaked CLAUDE_CONFIG_DIR would silently re-tap every later claude in this
    # days-old pane (the lb-claude lesson, zsh 5.9).
    _tap=$(CLAUDE_CONFIG_DIR="$_cfg" _ciw_tap)
    # LOUD, on all three surfaces. Nothing here is conditional on a verbosity
    # knob: zero silent cross-billing is the reason the tap system exists.
    echo "claude-identity-wrapper: TAP ROLLOVER — home tap '$_home_tap' is at its ceiling; this launch runs on '$_tap' (pool $_pool, $_cfg). Billing moves with it. Recorded in ${CIW_ROLLOVER_LEDGER:-$HOME/.local/share/fleet-health/tap-rollover.jsonl}." >&2
    _ciw_ledger "$_home_tap" "$_tap" "$_pool" "${_addr:-?}"
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
  # THE ROLLOVER PAIR. `X-Tap` alone is already honest — it carries the tap that
  # ran, not the one that was meant to — but honest is not the same as VISIBLE:
  # a rolled-over row is byte-identical to a launch whose home tap was that pool
  # all along, so nothing downstream could ever count rollovers or notice one
  # becoming permanent. These two say it explicitly, and they are emitted ONLY
  # on a rollover, so their mere presence is the query.
  if [ -n "$_pool" ]; then
    _hdrs=$(_ciw_add "$_hdrs" X-Home-Tap "$_home_tap")
    _hdrs=$(_ciw_add "$_hdrs" X-Tap-Rollover "1")
  fi
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
  #
  # CASES 3s/4s/4us — THE SAME ARGUMENT, FOR ANTHROPIC_CUSTOM_HEADERS
  # (dotfiles-kecb). The header variable is inherited exactly the way the base
  # URL is, and worse: `claude` EXPORTS it to its own children, so every Bash
  # tool call inside a session starts life carrying its parent's `X-Tap`.
  # Measured 2026-08-09 19:23Z — a probe launched from inside a session BILLED
  # to `secondary` while the ambient header still claimed `personal`. Where this
  # wrapper runs it now recomputes, and where it declines to send a header at
  # all it REMOVES the ambient one instead of letting it pass through: a request
  # with no header is logged `unknown` and is visibly unattributed, which is a
  # far better outcome than one that is confidently attributed to the wrong
  # account. (The remaining path — `env … claude`, which invokes the BINARY and
  # never reaches this function — is closed one tier down, in zsh/.zshenv.)
  if [ -n "$_cfg" ]; then
    # ROLLOVER LAUNCHES. The config dir MUST be in the launched environment or
    # nothing has actually moved: the headers would announce a tap this process
    # is not running on, which is the one failure this whole mechanism exists to
    # prevent. A rollover always has headers (it always has a tap), so there are
    # three cases here rather than five.
    if [ -z "$_base" ] && [ -n "${ANTHROPIC_BASE_URL+x}" ]; then
      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" CLAUDE_CONFIG_DIR="$_cfg" \
        env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions "$@"
    elif [ -n "$_base" ]; then
      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" CLAUDE_CONFIG_DIR="$_cfg" ANTHROPIC_BASE_URL="$_base" \
        command claude --dangerously-skip-permissions "$@"
    else
      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" CLAUDE_CONFIG_DIR="$_cfg" \
        command claude --dangerously-skip-permissions "$@"
    fi
  elif [ -z "$_base" ] && [ -n "${ANTHROPIC_BASE_URL+x}" ]; then
    if [ -n "$_hdrs" ]; then
      ANTHROPIC_CUSTOM_HEADERS="$_hdrs" \
        env -u ANTHROPIC_BASE_URL claude --dangerously-skip-permissions "$@"
    else
      env -u ANTHROPIC_BASE_URL -u ANTHROPIC_CUSTOM_HEADERS claude --dangerously-skip-permissions "$@"
    fi
  elif [ -n "$_hdrs" ] && [ -n "$_base" ]; then
    ANTHROPIC_CUSTOM_HEADERS="$_hdrs" ANTHROPIC_BASE_URL="$_base" \
      command claude --dangerously-skip-permissions "$@"
  elif [ -n "$_hdrs" ]; then
    ANTHROPIC_CUSTOM_HEADERS="$_hdrs" command claude --dangerously-skip-permissions "$@"
  elif [ -n "$_base" ]; then
    ANTHROPIC_BASE_URL="$_base" env -u ANTHROPIC_CUSTOM_HEADERS claude --dangerously-skip-permissions "$@"
  else
    env -u ANTHROPIC_CUSTOM_HEADERS claude --dangerously-skip-permissions "$@"
  fi
}
