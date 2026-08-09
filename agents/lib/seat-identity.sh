#!/bin/bash
# seat-identity.sh — the WAKE-TIME identity header (bead dotfiles-z10i).
#
# A fresh context knows what it DOES (the always-loaded tier) and what was last
# worked on (the handoff note). This is the one cheap read that tells it WHO IT
# IS: the office it holds, the charter line that office answers for, the
# recognition it has accumulated, and where the law it works under lives.
# Constitution Art. V ("seats are named, remembered, recognized"); the office +
# laurels half is `dotfiles-qnfk` R3, whose text this composes rather than
# re-derives — history_head in seat-history.sh stays the ONLY formatter of a
# laurel line, exactly as /onboard Step 1.5 already calls it.
#
# WHY A SEPARATE LIB AND NOT INLINE IN THE HOOK. session-start.sh runs at every
# session start on the whole fleet, and sourcing the seat stack into ITS shell
# would put a roster parser, a tmux resolver and ~40 functions in the
# environment of the one script that must never break. The hook instead runs
# this file as a SUBPROCESS: nothing leaks into the hook's shell, a crash is
# contained to a subshell whose empty output the hook silently skips, and the
# composition stays testable on its own through the seams below.
#
# ---------------------------------------------------------------------------
# API (bash AND zsh — no arrays, no [[ ]], no ${PIPESTATUS})
#
#   seat_identity_header [--laurels N] [--seat S] [--window W] [--dir DIR]
#       3-5 lines on stdout, rc 0. SILENT with rc 1 whenever there is nothing
#       to say: no window, an UNREGISTERED window, no roster, no python3, no
#       history file. Silence is the NORMAL case for a scratch window — an
#       unregistered window must cost nothing and print nothing, so nothing
#       here is loud and nothing here refuses out loud (seat_resolve is loud by
#       design; this calls it --quiet).
#
#   seat_constitution_path
#       Absolute path of the constitution, or rc 1 with no output.
#
# CLI: `bash seat-identity.sh [--laurels N] [--seat S] [--window W]
#       [--cache-header PATH --cache-deps PATH]`.
#
# THE CACHE, and why the CALLER names its paths. Composing this header costs
# ~150ms (a bash start, a python3 roster parse, two tmux asks) and it runs at
# every session start on the fleet, for an answer that changes maybe weekly.
# So a caller may hand over two paths: the composed bytes go to <cache-header>
# and the list of files that answer DEPENDED ON goes to <cache-deps>, one per
# line. A caller can then re-serve the header with no shell and no parser at
# all — `cat` it while no dep is newer than it — which is exactly what
# session-start.sh does. The paths are the caller's because a default here and
# a default there is the two-copies defect; this library owns the CONTENT of
# the cache and nothing about its location.
#
# Only a RESOLVED header is ever cached. A refusal is not cached on purpose:
# "this window is not a seat" is cheap to re-derive and a transient failure
# (no python3 for a moment, a half-written roster) would otherwise pin an
# empty header in place until something unrelated changed.
#
# Shape:
#   🧰 dotfiles — The Master of Works (seated 2026-08-08)
#      charter: harness orchestrator — owns the always-loaded instruction tier
#      🏅 2026-08-09 · <laurel title> — <why>
#      constitution: <path> — Art. V: seats are named, remembered, recognized
#
# Environment seams (tests + the tick jail; never needed in production):
#   SEATS_YML           roster path            SEAT_WINDOW   window override
#   SEAT_HISTORY_DIR    history dir            SEAT_CONSTITUTION  constitution path
# ---------------------------------------------------------------------------

# --- source the libs we compose (idempotent, bash + zsh) --------------------
# seat-history.sh sources seat-resolve.sh, which sources tmux-pane-resolve.sh
# and agents-root.sh. ONE parser for the roster, never two.
_ident_self="${BASH_SOURCE[0]:-$0}"
_IDENT_LIB_DIR="$(cd "$(dirname -- "$_ident_self")" 2>/dev/null && pwd)"
if ! command -v history_head >/dev/null 2>&1; then
  [ -n "$_IDENT_LIB_DIR" ] && [ -f "$_IDENT_LIB_DIR/seat-history.sh" ] \
    && . "$_IDENT_LIB_DIR/seat-history.sh"
fi
unset _ident_self

# The one line of the constitution worth carrying at wake. The pointer is the
# deliverable — a seat that can NAME the file can read it; a header that
# reprints Article V is a copy that rots (AGENTS.md's derive-or-drop ladder).
SEAT_CONSTITUTION_LINE="Art. V: seats are named, remembered, recognized"

# seat_constitution_path -> where the constitution lives, on stdout.
# Resolution order mirrors agents-root.sh's: the explicit seam, then the tier's
# own repo (~/.agents/agents -> ~/demesne/agents, so docs/ is its sibling),
# then the pre-cutover location. A path that resolves NOWHERE returns 1 and the
# header simply omits the pointer — a dangling path would be worse than none.
seat_constitution_path() {
  local root cand
  if [ -n "${SEAT_CONSTITUTION:-}" ]; then
    [ -f "$SEAT_CONSTITUTION" ] || return 1
    printf '%s' "$SEAT_CONSTITUTION"
    return 0
  fi
  if command -v agents_root >/dev/null 2>&1; then
    root=$(agents_root agents) || root=""
    if [ -n "$root" ]; then
      cand="$(dirname "$root")/docs/constitution.md"
      if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
    fi
  fi
  cand="$HOME/demesne/docs/constitution.md"
  if [ -f "$cand" ]; then printf '%s' "$cand"; return 0; fi
  return 1
}

# _ident_cache_write <header-path> <deps-path> <body> <dep>...
# Deps first, header LAST, each via temp+mv, so a reader that finds the header
# can never find a deps file older than the answer it describes.
_ident_cache_write() {
  local hdr="$1" deps="$2" body="$3" d
  shift 3
  mkdir -p "$(dirname "$hdr")" "$(dirname "$deps")" || return 1
  chmod 0700 "$(dirname "$hdr")" || return 1
  : > "$deps.tmp.$$" || return 1
  for d in "$@"; do
    [ -n "$d" ] && printf '%s\n' "$d" >> "$deps.tmp.$$"
  done
  mv -f "$deps.tmp.$$" "$deps" || { rm -f "$deps.tmp.$$"; return 1; }
  printf '%s' "$body" > "$hdr.tmp.$$" || { rm -f "$hdr.tmp.$$"; return 1; }
  mv -f "$hdr.tmp.$$" "$hdr" || { rm -f "$hdr.tmp.$$"; return 1; }
}

seat_identity_header() {
  local n=3 seat="" window="" charter office sigil head_out first rest con
  local cache_hdr="" cache_deps="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --laurels) shift; n="$1" ;;   --laurels=*) n="${1#--laurels=}" ;;
      --seat)    shift; seat="$1" ;; --seat=*)   seat="${1#--seat=}" ;;
      --window)  shift; window="$1" ;; --window=*) window="${1#--window=}" ;;
      --dir)     shift; SEAT_HISTORY_DIR="$1" ;; --dir=*) SEAT_HISTORY_DIR="${1#--dir=}" ;;
      --cache-header) shift; cache_hdr="$1" ;; --cache-header=*) cache_hdr="${1#--cache-header=}" ;;
      --cache-deps)   shift; cache_deps="$1" ;; --cache-deps=*)  cache_deps="${1#--cache-deps=}" ;;
      *) return 2 ;;
    esac
    shift
  done
  [ -n "$window" ] && SEAT_WINDOW="$window"

  # ONE roster read for the whole header. Without this memo the composition
  # below costs three python3 roster parses (seat_self_name, history_office,
  # _hist_sigil) — 0.30s vs 0.10s, measured; see _seat_dump's header.
  command -v _seat_dump >/dev/null 2>&1 || return 1
  local _SEAT_DUMP_CACHE
  _SEAT_DUMP_CACHE=$(_seat_dump) || return 1
  [ -n "$_SEAT_DUMP_CACHE" ] || return 1

  # --quiet: an unregistered window is the normal case for a scratch session,
  # not an incident. seat_resolve's loud refusal is right for an operator
  # command and wrong for every session start on the fleet.
  if [ -z "$seat" ]; then
    seat=$(seat_self_name --quiet) || return 1
  fi
  [ -n "$seat" ] || return 1

  charter=$(printf '%s\n' "$_SEAT_DUMP_CACHE" \
    | awk -F'\t' -v s="$seat" '$1=="seat" && $2==s {print $9; exit}')

  # The office line + laurels come from qnfk's lib WHEN PRESENT: a seat whose
  # history file has not been written yet still gets its identity, composed
  # from the roster, rather than nothing.
  head_out=$(history_head --seat "$seat" --laurels "$n") || head_out=""
  if [ -n "$head_out" ]; then
    first=$(printf '%s\n' "$head_out" | sed -n '1p')
    rest=$(printf '%s\n' "$head_out" | sed -n '2,$p')
  else
    office=$(printf '%s\n' "$_SEAT_DUMP_CACHE" \
      | awk -F'\t' -v s="$seat" '$1=="seat" && $2==s {print $7; exit}')
    sigil=$(printf '%s\n' "$_SEAT_DUMP_CACHE" \
      | awk -F'\t' -v s="$seat" '$1=="seat" && $2==s {print $8; exit}')
    first=$(printf '%s %s — %s' "${sigil:-·}" "$seat" "${office:-(unrecorded)}")
    rest=""
  fi

  # The office line leads; everything under it is indented into one block.
  # Indenting is not reformatting: the laurel LINE is still history_head's,
  # byte for byte, which keeps one formatter for it (R3).
  out="$first"$'\n'
  [ -n "$charter" ] && out="$out   charter: $charter"$'\n'
  [ -n "$rest" ] && out="$out$(printf '%s\n' "$rest" | sed 's/^/   /')"$'\n'
  con=$(seat_constitution_path) || con=""
  [ -n "$con" ] && out="$out   constitution: $con — $SEAT_CONSTITUTION_LINE"$'\n'

  printf '%s' "$out"

  # Cache only a RESOLVED header, and declare what it depended on so a caller
  # can invalidate without knowing any of this file's internals. The libs are
  # deps too: an edit to the composer or to history_head's format must expire
  # every cached header on the machine, and nothing else would notice.
  if [ -n "$cache_hdr" ] && [ -n "$cache_deps" ]; then
    _ident_cache_write "$cache_hdr" "$cache_deps" "$out" \
      "$(seat_roster_path)" "$(history_dir)" "$(history_path "$seat")" "$con" \
      "$_IDENT_LIB_DIR/seat-identity.sh" "$_IDENT_LIB_DIR/seat-history.sh" \
      "$_IDENT_LIB_DIR/seat-resolve.sh" || return 0
  fi
  return 0
}

# --- CLI (so the hook gets it as a subprocess, and the mutation harness can
# drive it) — guarded so sourcing never executes anything.
_ident_main_guard() {
  case "${BASH_SOURCE[0]:-}" in
    "") return 1 ;;
    "$0") return 0 ;;
    *) return 1 ;;
  esac
}
if _ident_main_guard; then
  seat_identity_header "$@"
  exit $?
fi
