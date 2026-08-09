#!/bin/bash
# seat-resolve.sh — resolve a tmux window to its SEAT, and a seat name to its
# roster row + liveness. Implements R5 / R6 / R7 / R8 / R9 / R13 of the seat
# address spec (bead dotfiles-seat-address-spec-uikg); bead
# dotfiles-seat-resolve-lib-btti.
#
# A SEAT is a durable, named agent identity above session and sandbox. The
# roster is agents/seats.yml — the single source of truth, enumerable with NO
# tmux server running (R8).
#
# THIS FILE WRAPS tmux-pane-resolve.sh, it does NOT replace it. All pane/window
# recovery (the $TMUX_PANE fast path, the process-ancestry walk for
# background-forked sessions, the sticky session->window cache) stays there and
# stays the only implementation. What this adds on top is the roster lookup,
# the alias migration, the R7 session/socket binding, and the refusals.
#
# ---------------------------------------------------------------------------
# API (bash AND zsh — Claude Code's Bash tool runs zsh, so nothing here relies
# on bash-only syntax: no arrays, no [[ ]], no ${PIPESTATUS}).
#
#   seat_resolve [--quiet] [--window <w>] [--session <s>]
#       SELF-resolution. Resolves THIS process's window (R5): exact seat name
#       -> that seat; else an `aliases:` entry -> the canonical seat plus a
#       migration notice on stderr; else UNREGISTERED -> a loud refusal on
#       stderr and exit 3. Never guesses.
#
#   seat_resolve --seat <name> [--quiet]
#       FOREIGN lookup (R9). Roster row + liveness for ANY seat, without a
#       tmux server and without holding that seat's home repo. Exit 3 if the
#       name is not in the roster, or if the same (session, window) tuple is
#       live on more than one tmux socket (R7 registry uniqueness,
#       dotfiles-2v8h) — refusal names both sockets.
#
#   seat_self_name [--quiet]     canonical seat name for this window, or
#                                non-zero with no output.
#   seat_names                   every seat name, one per line (offline, R8).
#   seat_roster_path             absolute path of the roster file in use.
#
# STDOUT is KEY=value lines, one per line, keys matching [a-z0-9_]+. Diagnostics
# ALWAYS go to stderr, so a caller can capture stdout unconditionally.
#
#   seat=<canonical name>      match=exact|alias   matched_name=<what matched>
#   session=<tmux session>     window=<tmux window>   socket=<tmux socket path>
#   model= effort= home= history= office= sigil=
#   (--seat only) aliases=, bindings=<n>, binding_<i>_{unit,tap,session,window},
#                 live=yes|no, live_<i>_{socket,session,window}
#
# ⚠️ R13 — session AND window are SEPARATE FIELDS, on purpose. An address is
# NEVER handed to `tmux -t`: `<host>:<seat>` is byte-identical in shape to
# tmux's own session:window target, and tmux matches targets by prefix/fnmatch,
# so a near-miss silently binds the WRONG session. Every tmux call a consumer
# makes must be built from these two fields separately.
#
# ---------------------------------------------------------------------------
# Exit codes (one convention, used by every entry point):
#   0  resolved
#   2  usage error (unknown flag, missing argument)
#   3  CANNOT EVALUATE — unregistered window, unresolvable window, a
#      cross-session binding mismatch, an unknown seat, a duplicate live tuple,
#      or a missing/unparseable roster. Never a guess, never a silent fallback.
#
# Environment seams (all optional; the first three exist for jailed ticks and
# for tests, which must never touch the live tmux server):
#   SEATS_YML              explicit roster path
#   SEAT_WINDOW            window name override (HANDOFF_WINDOW is also honored,
#                          since the tick-jail launcher already exports it)
#   SEAT_SESSION           tmux session name override
#   SEAT_TMUX_SOCKET_DIR   where to enumerate live tmux sockets
#                          (default /tmp/tmux-$(id -u))

# --- source the pane resolver we wrap (idempotent, bash + zsh) --------------
# In bash ${BASH_SOURCE[0]} is this file; in zsh BASH_SOURCE is empty and a
# sourced file sets $0 to its own path.
_seat_self="${BASH_SOURCE[0]:-$0}"
_SEAT_LIB_DIR="$(cd "$(dirname -- "$_seat_self")" 2>/dev/null && pwd)"
if ! command -v tmux_resolve_window >/dev/null 2>&1; then
  [ -n "$_SEAT_LIB_DIR" ] && [ -f "$_SEAT_LIB_DIR/tmux-pane-resolve.sh" ] \
    && . "$_SEAT_LIB_DIR/tmux-pane-resolve.sh"
fi
if ! command -v agents_root >/dev/null 2>&1; then
  [ -n "$_SEAT_LIB_DIR" ] && [ -f "$_SEAT_LIB_DIR/agents-root.sh" ] \
    && . "$_SEAT_LIB_DIR/agents-root.sh"
fi
unset _seat_self

_SEAT_QUIET=0
_seat_say() { [ "${_SEAT_QUIET:-0}" = 1 ] || printf '%s\n' "$*" >&2; }
_seat_strip_glyph() { printf '%s' "$1" | sed -E 's/^(🧠|✅|🔔|🌀|📬) ?//'; }

# seat_roster_path -> the roster file in use, on stdout. Non-zero if none.
seat_roster_path() {
  if [ -n "${SEATS_YML:-}" ]; then
    [ -f "$SEATS_YML" ] || return 1
    printf '%s' "$SEATS_YML"; return 0
  fi
  if [ -n "${_SEAT_LIB_DIR:-}" ] && [ -f "$_SEAT_LIB_DIR/../seats.yml" ]; then
    printf '%s' "$(cd "$_SEAT_LIB_DIR/.." && pwd)/seats.yml"; return 0
  fi
  local root
  if command -v agents_root >/dev/null 2>&1; then
    root=$(agents_root agents) && [ -f "$root/seats.yml" ] && {
      printf '%s' "$root/seats.yml"; return 0; }
  fi
  return 1
}

# _seat_validator -> path of validate-seats.py, whose YAML-subset parser this
# lib REUSES. One parser for the roster, never two: a second implementation
# would drift from the validator that gates the file at commit time.
_seat_validator() {
  [ -n "${_SEAT_LIB_DIR:-}" ] && [ -f "$_SEAT_LIB_DIR/validate-seats.py" ] || return 1
  printf '%s' "$_SEAT_LIB_DIR/validate-seats.py"
}

# _seat_dump -> the roster flattened to TSV records, on stdout:
#   seat  <name> <model> <effort> <home> <history> <office> <sigil> <charter-line>
#   alias <alias> <seat>
#   sched <seat> <unit> <tap> <session> <window>
# Non-zero (silent) when the roster or the parser is unavailable — callers
# decide whether that is fatal (seat_resolve refuses) or a degrade
# (handoff-path.sh keeps its pre-seat behavior).
_seat_dump() {
  local roster validator
  roster=$(seat_roster_path) || return 1
  validator=$(_seat_validator) || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$validator" "$roster" <<'PY'
import importlib.util
import pathlib
import sys

vs_path, roster_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("_seat_vs", vs_path)
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)

try:
    doc = vs.load_seats_yaml(pathlib.Path(roster_path).read_text())
except Exception as exc:  # parse error -> caller treats the roster as absent
    print(f"seat: roster parse error in {roster_path}: {exc}", file=sys.stderr)
    sys.exit(1)


def s(v):
    return "" if v is None else str(v)


out = []
for name, seat in (doc.get("seats") or {}).items():
    seat = seat or {}
    out.append("\t".join(["seat", s(name), s(seat.get("model")),
                          s(seat.get("effort")), s(seat.get("home")),
                          s(seat.get("history")), s(seat.get("office")),
                          s(seat.get("sigil")), s(seat.get("charter-line"))]))
    for alias in seat.get("aliases") or []:
        out.append("\t".join(["alias", s(alias), s(name)]))
    for sched in seat.get("schedules") or []:
        sched = sched or {}
        out.append("\t".join(["sched", s(name), s(sched.get("unit")),
                              s(sched.get("tap")), s(sched.get("session")),
                              s(sched.get("window"))]))
print("\n".join(out))
PY
}

# seat_names -> every seat name, one per line. Works with no tmux at all (R8).
seat_names() { _seat_dump | awk -F'\t' '$1=="seat"{print $2}'; }

# Every helper below takes the DUMP as its second argument rather than calling
# _seat_dump itself: one python3 invocation per seat_resolve call, not five. (A
# variable cache cannot work here — the helpers run inside $( ), so anything
# they cache dies with the subshell.)

# _seat_lookup <window> <dump> -> "<exact|alias>\t<canonical seat>" for a window
# name. Non-zero when the name is in neither the names nor the aliases (R5's
# third branch: UNREGISTERED).
_seat_lookup() {
  local w="$1" hit
  hit=$(printf '%s\n' "$2" | awk -F'\t' -v w="$w" '
    $1=="seat"  && $2==w { print "exact\t" $2; exit }
    $1=="alias" && $2==w { print "alias\t" $3; exit }
  ') || return 1
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

# _seat_row <seat> <dump> -> that seat's `seat` TSV record. Non-zero if unknown.
_seat_row() {
  local row
  row=$(printf '%s\n' "$2" | awk -F'\t' -v n="$1" '$1=="seat" && $2==n {print; exit}')
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# _seat_names_of <dump> -> every seat name, space-joined (for diagnostics).
_seat_names_of() {
  printf '%s\n' "$1" | awk -F'\t' '$1=="seat"{printf "%s ", $2}'
}

# _seat_emit_row <seat-tsv-row> — the roster fields every caller gets.
_seat_emit_row() {
  printf '%s' "$1" | awk -F'\t' '{
    printf "model=%s\neffort=%s\nhome=%s\nhistory=%s\noffice=%s\nsigil=%s\n",
      $3, $4, $5, $6, $7, $8
  }'
}

# --- live tmux enumeration --------------------------------------------------
# READ-ONLY, and always socket-explicit. Nothing in this library ever starts,
# renames, or kills anything: a resolver that can mutate the live server is one
# bad argument away from taking down every window on the machine.

_seat_socket_dir() { printf '%s' "${SEAT_TMUX_SOCKET_DIR:-/tmp/tmux-$(id -u)}"; }

# _seat_sockets -> one live tmux socket path per line (none is not an error).
_seat_sockets() {
  local d
  d=$(_seat_socket_dir)
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type s 2>/dev/null   # allow-suppress: existence probe
}

# _seat_live_windows -> "<socket>\t<session>\t<window>" for every live window on
# every socket in the socket dir. Glyph-stripped. `env -u TMUX` so an inherited
# $TMUX can never redirect a -S-targeted call back at the caller's own server.
_seat_live_windows() {
  local tb sock
  tb=$(command -v tmux 2>/dev/null); [ -x "${tb:-}" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 0
  _seat_sockets | while IFS= read -r sock; do
    [ -n "$sock" ] || continue
    env -u TMUX "$tb" -S "$sock" list-windows -a \
        -F "$sock	#{session_name}	#{window_name}" 2>/dev/null \
      | sed -E 's/^(.*	)(🧠|✅|🔔|🌀|📬) ?/\1/'
  done
}

# --- self-resolution inputs -------------------------------------------------

# _seat_self_socket -> the socket THIS session's server listens on (R7: self
# resolution binds to $TMUX's OWN socket and never searches other sockets).
_seat_self_socket() {
  if [ -n "${TMUX:-}" ]; then printf '%s' "${TMUX%%,*}"; return 0; fi
  local tb
  tb=$(command -v tmux 2>/dev/null); [ -x "${tb:-}" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] && [ -n "${TMUX_PANE:-}" ] || return 1
  "$tb" display-message -p -t "$TMUX_PANE" '#{socket_path}' 2>/dev/null
}

# _seat_self_window -> this process's glyph-stripped window name, or non-zero.
_seat_self_window() {
  if [ -n "${SEAT_WINDOW:-}" ]; then _seat_strip_glyph "$SEAT_WINDOW"; return 0; fi
  if [ -n "${HANDOFF_WINDOW:-}" ]; then _seat_strip_glyph "$HANDOFF_WINDOW"; return 0; fi
  command -v tmux_resolve_window >/dev/null 2>&1 || return 1
  tmux_resolve_window
}

# _seat_self_session -> this process's tmux session name, or empty. Bound to
# $TMUX's own socket; it never enumerates other sockets looking for a match.
_seat_self_session() {
  if [ -n "${SEAT_SESSION:-}" ]; then printf '%s' "$SEAT_SESSION"; return 0; fi
  local tb sock s
  tb=$(command -v tmux 2>/dev/null); [ -x "${tb:-}" ] || tb=/usr/bin/tmux
  [ -x "$tb" ] || return 1
  sock=$(_seat_self_socket)
  if [ -n "${TMUX_PANE:-}" ]; then
    if [ -n "$sock" ]; then
      s=$("$tb" -S "$sock" display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    else
      s=$("$tb" display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    fi
  fi
  [ -n "${s:-}" ] || s=$(_tpr_by_ancestry '#{session_name}' 2>/dev/null)
  [ -n "${s:-}" ] || return 1
  printf '%s' "$s"
}

# --- the resolver ------------------------------------------------------------

_seat_resolve_self() {
  local want_window="$1" want_session="$2"
  local win ses sock hit match seat row bind_sessions roster dump

  roster=$(seat_roster_path) || {
    _seat_say "🚫 seat: no roster found (agents/seats.yml). Set \$SEATS_YML or install the agents tier."
    _seat_say "    Refusing to resolve a seat without the roster (R5: never a guess)."
    return 3
  }
  dump=$(_seat_dump) || {
    _seat_say "🚫 seat: roster $roster could not be read (parser or python3 missing, or a parse error above)."
    _seat_say "    Refusing to resolve a seat without the roster (R5: never a guess)."
    return 3
  }

  win="$want_window"
  [ -n "$win" ] || win=$(_seat_self_window) || win=""
  if [ -z "$win" ]; then
    _seat_say "🚫 seat: cannot resolve THIS session's tmux window (no \$TMUX_PANE, no pane ancestor, no cache)."
    _seat_say "    Set \$SEAT_WINDOW (or \$HANDOFF_WINDOW, as the tick jail does) when there is no tmux server to ask."
    return 3
  fi

  ses="$want_session"
  [ -n "$ses" ] || ses=$(_seat_self_session) || ses=""
  sock=$(_seat_self_socket) || sock=""

  hit=$(_seat_lookup "$win" "$dump") || {
    _seat_say "🚫 seat: window '$win' is NOT a registered seat."
    _seat_say "    roster: $roster"
    _seat_say "    registered seats: $(_seat_names_of "$dump")"
    _seat_say "    If this window was RENAMED, add '$win' to the seat's aliases: list — that is the"
    _seat_say "    di->pulse failure (bd-msi5) this refusal exists to stop. If it is a new durable"
    _seat_say "    window, give it a seat. Refusing to guess (R5)."
    return 3
  }
  match=${hit%%	*}
  seat=${hit#*	}

  # R7: qualify by the binding's session. A window name is per-session, and two
  # sessions are live on the default socket today (`work`, `zig-computer`), so a
  # name that matches a seat whose binding lives in ANOTHER session is not this
  # seat — refuse rather than tie-break silently.
  bind_sessions=$(printf '%s\n' "$dump" | awk -F'\t' -v s="$seat" -v w="$win" \
    '$1=="sched" && $2==s && $6==w {print $5}' | sort -u)
  if [ -n "$bind_sessions" ] && [ -n "$ses" ]; then
    if ! printf '%s\n' "$bind_sessions" | grep -qx -- "$ses"; then
      _seat_say "🚫 seat: window '$win' maps to seat '$seat', but that seat's binding for this window"
      _seat_say "    is in tmux session '$(printf '%s' "$bind_sessions" | tr '\n' ' ' | sed 's/ $//')' — this session is '$ses'."
      _seat_say "    roster: $roster"
      _seat_say "    R7: a window-name lookup MUST be qualified by the binding's session. Refusing to guess."
      return 3
    fi
  fi

  if [ "$match" = alias ]; then
    _seat_say "⚠️  seat: window '$win' is an ALIAS of seat '$seat' (roster: $roster)."
    _seat_say "    Resolving to the canonical seat '$seat'; the alias entry is what makes the rename survivable."
  fi

  row=$(_seat_row "$seat" "$dump") || return 3
  printf 'seat=%s\n' "$seat"
  printf 'match=%s\n' "$match"
  printf 'matched_name=%s\n' "$win"
  printf 'session=%s\n' "$ses"
  printf 'window=%s\n' "$win"
  printf 'socket=%s\n' "$sock"
  _seat_emit_row "$row"
  return 0
}

_seat_resolve_foreign() {
  local name="$1" row aliases scheds n live i sess win pairs dupes roster dump

  roster=$(seat_roster_path) || {
    _seat_say "🚫 seat: no roster found (agents/seats.yml). Set \$SEATS_YML or install the agents tier."
    return 3
  }
  dump=$(_seat_dump) || {
    _seat_say "🚫 seat: roster $roster could not be read (parser or python3 missing, or a parse error above)."
    return 3
  }
  row=$(_seat_row "$name" "$dump") || {
    _seat_say "🚫 seat: '$name' is not a seat in $roster."
    _seat_say "    registered seats: $(_seat_names_of "$dump")"
    return 3
  }

  scheds=$(printf '%s\n' "$dump" | awk -F'\t' -v s="$name" '$1=="sched" && $2==s {print $3 "\t" $4 "\t" $5 "\t" $6}')
  aliases=$(printf '%s\n' "$dump" | awk -F'\t' -v s="$name" '$1=="alias" && $3==s {print $2}')

  # R7 registry uniqueness: the SAME (session, window) tuple live on two tmux
  # sockets makes the tuple non-unique machine-wide (dotfiles-2v8h — leaked
  # hook-test servers did exactly this), so a foreign lookup cannot say which
  # server holds the seat. Refuse, naming both sockets.
  live=$(_seat_live_windows | awk -F'\t' -v s="$name" -v names="$(printf '%s\n%s\n' "$name" "$aliases" | tr '\n' ' ')" \
    -v wins="$(printf '%s' "$scheds" | awk -F'\t' '{print $4}' | tr '\n' ' ')" '
    BEGIN { split(names, a, " "); split(wins, b, " ");
            for (i in a) if (a[i] != "") k[a[i]] = 1
            for (i in b) if (b[i] != "") k[b[i]] = 1 }
    $3 in k { print }')

  pairs=$(printf '%s' "$live" | awk -F'\t' 'NF>=3 {print $2 "\t" $3}' | sort | uniq -c \
          | awk '$1 > 1 {print $2 "\t" $3}')
  if [ -n "$pairs" ]; then
    dupes=$(printf '%s' "$live" | awk -F'\t' '{print $1}' | sort -u | tr '\n' ' ')
    _seat_say "🚫 seat: '$name' resolves to a DUPLICATE live (session, window) tuple across tmux servers:"
    printf '%s\n' "$pairs" | while IFS='	' read -r sess win; do
      _seat_say "    session '$sess' window '$win'"
    done
    _seat_say "    sockets involved: $dupes"
    _seat_say "    R7: the tuple is not unique machine-wide, so liveness is unknowable. Refusing to guess."
    _seat_say "    (Leaked test servers do this — check for stale sockets in $(_seat_socket_dir).)"
    return 3
  fi

  printf 'seat=%s\n' "$name"
  printf 'match=exact\n'
  _seat_emit_row "$row"
  printf 'aliases=%s\n' "$(printf '%s' "$aliases" | tr '\n' ' ' | sed 's/ *$//')"

  n=$(printf '%s' "$scheds" | grep -c . )
  printf 'bindings=%s\n' "$n"
  i=0
  if [ "$n" -gt 0 ]; then
    printf '%s\n' "$scheds" | while IFS='	' read -r unit tap sess win; do
      [ -n "$unit$tap$sess$win" ] || continue
      i=$((i+1))
      printf 'binding_%s_unit=%s\nbinding_%s_tap=%s\nbinding_%s_session=%s\nbinding_%s_window=%s\n' \
        "$i" "$unit" "$i" "$tap" "$i" "$sess" "$i" "$win"
    done
  fi

  # R13: session and window as SEPARATE fields, and only when unambiguous. A
  # seat with several distinct bindings gets the indexed forms above and no
  # bare pair — the caller must choose, because nothing here may invent one.
  if [ "$n" -gt 0 ]; then
    local distinct
    distinct=$(printf '%s\n' "$scheds" | awk -F'\t' 'NF>=4 {print $3 "\t" $4}' | sort -u)
    if [ "$(printf '%s\n' "$distinct" | grep -c .)" = 1 ]; then
      printf 'session=%s\n' "$(printf '%s' "$distinct" | cut -f1)"
      printf 'window=%s\n'  "$(printf '%s' "$distinct" | cut -f2)"
    fi
  fi

  if [ -n "$live" ]; then
    printf 'live=yes\n'
    i=0
    printf '%s\n' "$live" | while IFS='	' read -r sock sess win; do
      [ -n "$sock" ] || continue
      i=$((i+1))
      printf 'live_%s_socket=%s\nlive_%s_session=%s\nlive_%s_window=%s\n' \
        "$i" "$sock" "$i" "$sess" "$i" "$win"
    done
  else
    printf 'live=no\n'
  fi
  return 0
}

seat_resolve() {
  local mode=self name="" window="" session="" prev_quiet="${_SEAT_QUIET:-0}" rc
  _SEAT_QUIET=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet|-q)  _SEAT_QUIET=1 ;;
      --seat)      shift; [ $# -gt 0 ] || { printf '%s\n' "seat_resolve: --seat needs a name" >&2; _SEAT_QUIET=$prev_quiet; return 2; }; mode=foreign; name="$1" ;;
      --seat=*)    mode=foreign; name="${1#--seat=}" ;;
      --window)    shift; [ $# -gt 0 ] || { printf '%s\n' "seat_resolve: --window needs a name" >&2; _SEAT_QUIET=$prev_quiet; return 2; }; window="$1" ;;
      --window=*)  window="${1#--window=}" ;;
      --session)   shift; [ $# -gt 0 ] || { printf '%s\n' "seat_resolve: --session needs a name" >&2; _SEAT_QUIET=$prev_quiet; return 2; }; session="$1" ;;
      --session=*) session="${1#--session=}" ;;
      *)           printf '%s\n' "seat_resolve: unknown argument: $1" >&2; _SEAT_QUIET=$prev_quiet; return 2 ;;
    esac
    shift
  done
  if [ "$mode" = foreign ]; then
    _seat_resolve_foreign "$name"; rc=$?
  else
    _seat_resolve_self "$(_seat_strip_glyph "$window")" "$session"; rc=$?
  fi
  _SEAT_QUIET=$prev_quiet
  return $rc
}

# seat_self_name [--quiet] -> just the canonical seat name for this window.
# The convenience every consumer would otherwise re-derive with its own awk.
seat_self_name() {
  local out rc
  out=$(seat_resolve "$@") ; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | awk -F= '$1=="seat"{print $2; exit}'
}

# Direct invocation (`bash seat-resolve.sh --seat desk`) as well as sourcing —
# consumers outside a shell (a hook, a python caller) get a CLI for free.
# Guarded so sourcing never executes anything.
_seat_main_guard() {
  case "${BASH_SOURCE[0]:-}" in
    "") return 1 ;;                     # zsh source, or no bash
    "$0") return 0 ;;                   # bash, executed directly
    *) return 1 ;;
  esac
}
if _seat_main_guard; then
  seat_resolve "$@"
  exit $?
fi
