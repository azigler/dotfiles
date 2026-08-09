#!/bin/bash
# seat-history.sh — THE ONLY WRITER of refs/seats/<seat>.history.md.
#
# Spec: bead dotfiles-qnfk (LAURELS + the seat history), R1/R2/R5/R6 + T1-T8.
# Charter: ~/demesne/docs/constitution.md Article V ("Seats are persons of the
# estate: named, remembered, recognized") and Article IV (job seats retire;
# history and laurels preserved). Cited, never restated — read the articles.
# Roster: agents/seats.yml, ratified in dotfiles-seat-roster-from-windows-ojjf.
#
# WHAT A HISTORY IS. A seat's CAREER: an append-only, machine-written file of
# dated entries in three classes — APPOINTED (R1, the founding backfill),
# LAUREL (R2, recognition placed by the Remembrancer), RETIRED (R5). It is
# distinct from the per-window handoff note, which /offboard OVERWRITES every
# session: the note is a snapshot, this is the record.
#
# ---------------------------------------------------------------------------
# WHY GENERATION-ONLY-VIA-THIS-LIB IS THE MECHANISM (T6, R6 "not farmable")
# ---------------------------------------------------------------------------
# A recognition record a seat can write is a recognition record a seat can
# farm. Prose ("a seat never edits its own history") is not a mechanism; two
# things here are:
#
#   1. THE FILE IS GENERATED, NEVER HAND-EDITED. Every write goes through
#      _hist_rewrite: build the whole file in a temp, recompute the body
#      checksum, mv it into place, chmod 0444. An agent that opens a history
#      file and appends gets EACCES from the shell (`>>` on a 0444 file), and
#      if it works around that by rewriting the file, it lands in (2).
#
#      ⚠️ MEASURED LIMIT, stated rather than glossed: git records only the
#      EXEC bit, so a file committed at 0444 checks out 0644 (`create mode
#      100644` in this arc's own commit). The 0444 barrier therefore holds for
#      a file this lib wrote on THIS box and NOT for one that arrived by
#      clone or checkout until `history_init`/a placement rewrites it. That
#      makes (1) a speed bump, not a wall — which is why (2) is the load-
#      bearing mechanism and why the commit gate, not the file mode, is where
#      a forged entry is actually stopped.
#
#   2. THE BODY CARRIES ITS OWN CHECKSUM. `integrity: sha256:<hex>` in the
#      frontmatter covers every byte after the closing `---`. A hand-added
#      LAUREL entry does not update it, so `history_verify` fails and
#      `validate-seats.py --histories` BLOCKS THE COMMIT that carries it.
#      Recomputing the checksum by hand is possible — and it means running
#      this lib, which refuses uncited laurels and refuses the Remembrancer.
#
# Neither is cryptography: a determined seat with a shell can forge a file.
# The bar it sets is that forgery must be DELIBERATE and is VISIBLE in the
# diff — which is the whole of what "unfarmable" can mean inside a harness
# whose agents have a shell. Cheap detector, honest claim.
#
# ---------------------------------------------------------------------------
# API (bash AND zsh — nothing here uses arrays, [[ ]] or ${PIPESTATUS})
#
#   history_init [--date D] [--dir DIR]
#       Founding backfill. For EVERY seat currently on the roster (read at
#       RUNTIME via seat-resolve.sh — the count is never hardcoded) write a
#       history file with one APPOINTED entry dated D (default 2026-08-08,
#       the roster's own ratification date) citing ojjf. Idempotent: a seat
#       that already has a file is left untouched and reported as `kept`.
#
#   history_laurel --seat S --title T --bead B --commit C --why W
#                  [--date D] [--check-only] [--by-lord] [--dir DIR]
#       Append one LAUREL entry. REFUSES (nothing written, reason on stderr):
#         rc 3  unknown seat / no history file
#         rc 4  no citable evidence — --bead AND --commit are BOTH required
#               (R2: a laurel CITES value; R6: it never counts activity)
#         rc 5  the seat holds the Remembrancer's office (R6 exclusion) and
#               --by-lord was not passed
#         rc 6  the title is longer than 8 words (R2's shape)
#       --check-only validates everything and writes nothing (the first half
#       of the caller's all-three-or-none placement).
#
#   history_retire --seat S --reason R [--date D] [--dir DIR]
#       R5's final entry: date, reason, laurel tally. The FILE IS PRESERVED
#       FOREVER — retirement appends, it never deletes. Moving the roster row
#       into seats.yml's `retired:` section is a separate, human step; the
#       validator understands both sides (validate-seats.py --histories).
#
#   history_head [--seat S] [--laurels N] [--dir DIR]
#       R3's injection text: the office line plus the last N laurels (default
#       3). SILENT on absence — no output, no stderr, rc 1 — because an
#       unregistered window is the normal case, not an incident.
#
#   history_verify [--dir DIR] [<seat> ...]     integrity check (T6)
#   history_laurel_count <seat> [--dir DIR]     laurels in one file
#   history_seats / history_office <seat> / history_remembrancer
#   history_dir / history_path <seat>
#
# CLI (so python and hooks get it for free, and so the mutation harness can
# drive it): `bash seat-history.sh <init|laurel|retire|head|verify|count|
# seats|office|remembrancer|dir|path> [args]`.
#
# Environment seams (tests + the tick jail; never needed in production):
#   SEAT_HISTORY_DIR   where the .history.md files live
#   SEATS_YML          roster path (honored by seat-resolve.sh)
# ---------------------------------------------------------------------------

# --- source the roster reader we reuse (idempotent, bash + zsh) -------------
# ONE parser for the roster, never two — the rule seat-resolve.sh already
# states about validate-seats.py. `_seat_dump` is its flattened TSV; the hall
# (agents/bin/hall) reuses it the same way.
_hist_self="${BASH_SOURCE[0]:-$0}"
_HIST_LIB_DIR="$(cd "$(dirname -- "$_hist_self")" 2>/dev/null && pwd)"
if ! command -v _seat_dump >/dev/null 2>&1; then
  [ -n "$_HIST_LIB_DIR" ] && [ -f "$_HIST_LIB_DIR/seat-resolve.sh" ] \
    && . "$_HIST_LIB_DIR/seat-resolve.sh"
fi
unset _hist_self

# The founding constants. The date is the roster's own ratification day and the
# citation is the bead that ratified it; both are HISTORY, so they are fixed.
HIST_FOUNDING_DATE="2026-08-08"
HIST_FOUNDING_CITE="dotfiles-seat-roster-from-windows-ojjf"

# The excluded office, by OFFICE not by seat name (R6). A seat rename must not
# be able to lift the exclusion; the office is what cannot award itself.
HIST_REMEMBRANCER_OFFICE="The Remembrancer"

# 🏅 U+1F3C5, Emoji_Presentation=Yes — passes the sigil rule the roster
# validator enforces (no VS16, nothing in U+2000-U+2BFF).
HIST_LAUREL_GLYPH="🏅"
HIST_MAX_TITLE_WORDS=8

_hist_err() { printf '%s\n' "$*" >&2; }

# --- paths -----------------------------------------------------------------

# history_dir -> the directory holding <seat>.history.md, on stdout.
history_dir() {
  if [ -n "${SEAT_HISTORY_DIR:-}" ]; then printf '%s' "$SEAT_HISTORY_DIR"; return 0; fi
  local roster
  roster=$(seat_roster_path 2>/dev/null) || roster=""
  if [ -n "$roster" ]; then
    printf '%s' "$(cd "$(dirname "$roster")/.." && pwd)/refs/seats"
    return 0
  fi
  [ -n "${_HIST_LIB_DIR:-}" ] || return 1
  printf '%s' "$(cd "$_HIST_LIB_DIR/../.." && pwd)/refs/seats"
}

history_path() {
  local d
  d=$(history_dir) || return 1
  printf '%s/%s.history.md' "$d" "$1"
}

# --- roster reads (RUNTIME, never a hardcoded roster) ----------------------

history_seats() { _seat_dump | awk -F'\t' '$1=="seat"{print $2}'; }

history_office() {
  _seat_dump | awk -F'\t' -v n="$1" '$1=="seat" && $2==n {print $7; exit}'
}

_hist_sigil() {
  _seat_dump | awk -F'\t' -v n="$1" '$1=="seat" && $2==n {print $8; exit}'
}

# history_remembrancer -> the seat holding the excluded office, or empty.
history_remembrancer() {
  _seat_dump | awk -F'\t' -v o="$HIST_REMEMBRANCER_OFFICE" \
    '$1=="seat" && $7==o {print $2; exit}'
}

_hist_is_seat() {
  history_seats | grep -qx -- "$1"
}

# --- the file format -------------------------------------------------------
# ---
# seat: dive
# office: The Ranger
# appointed: 2026-08-08
# generator: agents/lib/seat-history.sh
# integrity: sha256:<hex of every byte after this frontmatter>
# ---
# <!-- APPEND-ONLY … -->
#
# ## 2026-08-08 · APPOINTED · The Ranger
# …

_hist_sha_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1   # macOS has no sha256sum (repo rule 6)
  fi
}

# _hist_body <file> — every byte after the closing frontmatter delimiter.
_hist_body() {
  awk 'NR==1 && $0=="---" {fm=1; next}
       fm==1 && $0=="---" {fm=2; next}
       fm==2 {print}' "$1"
}

_hist_front() {
  awk -F': ' -v k="$2" 'NR==1 && $0=="---" {fm=1; next}
       fm==1 && $0=="---" {exit}
       fm==1 && index($0, k ": ")==1 { print substr($0, length(k)+3); exit }' "$1"
}

# _hist_rewrite <seat> <path> <bodyfile> — THE ONLY WRITE PATH IN THE HARNESS.
# Recomputes the integrity line over <bodyfile>, writes atomically, 0444.
_hist_rewrite() {
  local seat="$1" path="$2" bodyfile="$3" office appointed sum tmp
  office=$(history_office "$seat"); [ -n "$office" ] || office="(unrecorded)"
  if [ -f "$path" ]; then
    appointed=$(_hist_front "$path" appointed)
  fi
  [ -n "${appointed:-}" ] || appointed="$HIST_FOUNDING_DATE"
  sum=$(_hist_sha_stdin < "$bodyfile")
  tmp="${path}.tmp.$$"
  {
    printf -- '---\n'
    printf 'seat: %s\n' "$seat"
    printf 'office: %s\n' "$office"
    printf 'appointed: %s\n' "$appointed"
    printf 'generator: agents/lib/seat-history.sh\n'
    printf 'integrity: sha256:%s\n' "$sum"
    printf -- '---\n'
    cat "$bodyfile"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0444 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# --- history_init ----------------------------------------------------------

history_init() {
  local date="$HIST_FOUNDING_DATE" dir="" seat office path body
  while [ $# -gt 0 ]; do
    case "$1" in
      --date)  shift; date="$1" ;;
      --date=*) date="${1#--date=}" ;;
      --dir)   shift; dir="$1" ;;
      --dir=*) dir="${1#--dir=}" ;;
      *) _hist_err "history_init: unknown argument: $1"; return 2 ;;
    esac
    shift
  done
  [ -n "$dir" ] && SEAT_HISTORY_DIR="$dir"
  dir=$(history_dir) || { _hist_err "history_init: cannot resolve a history dir"; return 2; }
  mkdir -p "$dir" || return 2

  local seats
  seats=$(history_seats)
  [ -n "$seats" ] || { _hist_err "history_init: roster read returned NO seats — refusing to backfill nothing"; return 3; }

  printf '%s\n' "$seats" | while IFS= read -r seat; do
    [ -n "$seat" ] || continue
    path="$dir/$seat.history.md"
    if [ -f "$path" ]; then
      printf 'kept %s\n' "$seat"
      continue
    fi
    office=$(history_office "$seat"); [ -n "$office" ] || office="(unrecorded)"
    body="$path.body.$$"
    {
      printf '<!-- APPEND-ONLY. Machine-written by agents/lib/seat-history.sh and by\n'
      printf '     NOTHING else: a seat never edits its own history (dotfiles-qnfk R1/R6,\n'
      printf '     T6). `integrity:` above is sha256 over every byte below the frontmatter,\n'
      printf '     so a hand-added entry fails validate-seats.py --histories and blocks the\n'
      printf '     commit that carries it. Constitution Art. V. -->\n'
      printf '\n'
      printf '## %s · APPOINTED · %s\n' "$date" "$office"
      printf 'Seated in the founding roster (%s).\n' "$HIST_FOUNDING_CITE"
      printf '\n'
    } > "$body" || continue
    if _hist_rewrite "$seat" "$path" "$body"; then
      printf 'made %s\n' "$seat"
    else
      _hist_err "history_init: could not write $path"
    fi
    rm -f "$body"
  done
  return 0
}

# --- history_laurel --------------------------------------------------------

history_laurel() {
  local seat="" title="" bead="" commit="" why="" date="" dir="" check=0 bylord=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --seat)   shift; seat="$1" ;;   --seat=*)   seat="${1#--seat=}" ;;
      --title)  shift; title="$1" ;;  --title=*)  title="${1#--title=}" ;;
      --bead)   shift; bead="$1" ;;   --bead=*)   bead="${1#--bead=}" ;;
      --commit) shift; commit="$1" ;; --commit=*) commit="${1#--commit=}" ;;
      --why)    shift; why="$1" ;;    --why=*)    why="${1#--why=}" ;;
      --date)   shift; date="$1" ;;   --date=*)   date="${1#--date=}" ;;
      --dir)    shift; dir="$1" ;;    --dir=*)    dir="${1#--dir=}" ;;
      --check-only) check=1 ;;
      --by-lord)    bylord=1 ;;
      *) _hist_err "history_laurel: unknown argument: $1"; return 2 ;;
    esac
    shift
  done
  [ -n "$dir" ] && SEAT_HISTORY_DIR="$dir"
  [ -n "$date" ] || date=$(date -u +%Y-%m-%d)

  # --- R2/R6: EVIDENCE OR NOTHING. A laurel cites a bead AND a commit. Both,
  # because a bead alone is a claim about work and a commit alone is a claim
  # about a diff; the pair is what a reader can actually walk back to. This is
  # the check T4 names and the `citation-removed` mutant deletes.
  if [ -z "$bead" ] || [ -z "$commit" ]; then
    _hist_err "🚫 laurel REFUSED for '${seat:-<no seat>}': no citable evidence."
    _hist_err "    A laurel needs BOTH --bead <id> and --commit <sha> (got bead='$bead' commit='$commit')."
    _hist_err "    R2: recognition CITES value. R6: it is never a count of activity."
    return 4
  fi
  if [ -z "$seat" ] || [ -z "$title" ] || [ -z "$why" ]; then
    _hist_err "🚫 laurel REFUSED: --seat, --title and --why are all required."
    return 2
  fi
  if ! _hist_is_seat "$seat"; then
    _hist_err "🚫 laurel REFUSED: '$seat' is not a seat on the roster."
    return 3
  fi

  # --- R6: the office that PLACES laurels may not receive a machine-placed
  # one. Keyed on the OFFICE, resolved at runtime, so renaming the seat does
  # not lift it. Zig may still award it by hand (--by-lord) for its non-laurel
  # work, judged in the brief — that is the escape the spec names, and it is
  # not reachable from the weekly flow.
  local remembrancer
  remembrancer=$(history_remembrancer)
  if [ -n "$remembrancer" ] && [ "$seat" = "$remembrancer" ] && [ "$bylord" -eq 0 ]; then
    _hist_err "🚫 laurel REFUSED for '$seat': it holds the office of $HIST_REMEMBRANCER_OFFICE."
    _hist_err "    R6 — the one office that places laurels cannot receive a placed one."
    _hist_err "    Only the lord may award it, by hand, for non-laurel work (--by-lord)."
    return 5
  fi

  local words
  words=$(printf '%s\n' "$title" | wc -w | tr -d ' ')
  if [ "$words" -gt "$HIST_MAX_TITLE_WORDS" ]; then
    _hist_err "🚫 laurel REFUSED for '$seat': title is $words words, max $HIST_MAX_TITLE_WORDS (R2)."
    return 6
  fi

  local path
  path=$(history_path "$seat") || return 2
  if [ ! -f "$path" ]; then
    _hist_err "🚫 laurel REFUSED for '$seat': no history file at $path."
    _hist_err "    Run: bash agents/lib/seat-history.sh init"
    return 3
  fi

  [ "$check" -eq 1 ] && return 0

  local body
  body="$path.body.$$"
  _hist_body "$path" > "$body" || { rm -f "$body"; return 1; }
  {
    printf '## %s · %s LAUREL · %s\n' "$date" "$HIST_LAUREL_GLYPH" "$title"
    printf '%s\n' "$why"
    printf 'citation: bead %s · commit %s\n' "$bead" "$commit"
    printf '\n'
  } >> "$body" || { rm -f "$body"; return 1; }
  _hist_rewrite "$seat" "$path" "$body" || { rm -f "$body"; return 1; }
  rm -f "$body"
  printf 'laurel %s %s\n' "$seat" "$date"
}

# --- history_retire --------------------------------------------------------

history_retire() {
  local seat="" reason="" date="" dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --seat)   shift; seat="$1" ;;   --seat=*)   seat="${1#--seat=}" ;;
      --reason) shift; reason="$1" ;; --reason=*) reason="${1#--reason=}" ;;
      --date)   shift; date="$1" ;;   --date=*)   date="${1#--date=}" ;;
      --dir)    shift; dir="$1" ;;    --dir=*)    dir="${1#--dir=}" ;;
      *) _hist_err "history_retire: unknown argument: $1"; return 2 ;;
    esac
    shift
  done
  [ -n "$dir" ] && SEAT_HISTORY_DIR="$dir"
  [ -n "$date" ] || date=$(date -u +%Y-%m-%d)
  if [ -z "$seat" ] || [ -z "$reason" ]; then
    _hist_err "history_retire: --seat and --reason are required (Art. IV: a retirement is RECORDED)."
    return 2
  fi
  local path
  path=$(history_path "$seat") || return 2
  if [ ! -f "$path" ]; then
    _hist_err "🚫 retire REFUSED: no history file for '$seat' at $path."
    return 3
  fi
  local n office body
  n=$(history_laurel_count "$seat")
  office=$(history_office "$seat"); [ -n "$office" ] || office=$(_hist_front "$path" office)
  body="$path.body.$$"
  _hist_body "$path" > "$body" || { rm -f "$body"; return 1; }
  {
    printf '## %s · RETIRED · %s\n' "$date" "${office:-(unrecorded)}"
    printf '%s\n' "$reason"
    printf 'laurels: %s · the history is preserved (Art. IV — seats are careers, not fixtures).\n' "$n"
    printf '\n'
  } >> "$body" || { rm -f "$body"; return 1; }
  _hist_rewrite "$seat" "$path" "$body" || { rm -f "$body"; return 1; }
  rm -f "$body"
  printf 'retired %s %s laurels=%s\n' "$seat" "$date" "$n"
}

# --- reads -----------------------------------------------------------------

history_laurel_count() {
  local seat="$1" path
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) shift; SEAT_HISTORY_DIR="$1" ;;
      --dir=*) SEAT_HISTORY_DIR="${1#--dir=}" ;;
    esac
    shift
  done
  path=$(history_path "$seat") || { printf '0'; return 1; }
  [ -f "$path" ] || { printf '0'; return 1; }
  grep -c "$HIST_LAUREL_GLYPH LAUREL · " "$path" | tr -d ' '
}

# history_head — R3's startup injection. SILENT when there is nothing to say.
history_head() {
  local seat="" n=3 dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --seat)    shift; seat="$1" ;;    --seat=*)    seat="${1#--seat=}" ;;
      --laurels) shift; n="$1" ;;       --laurels=*) n="${1#--laurels=}" ;;
      --dir)     shift; dir="$1" ;;     --dir=*)     dir="${1#--dir=}" ;;
      *) return 2 ;;
    esac
    shift
  done
  [ -n "$dir" ] && SEAT_HISTORY_DIR="$dir"
  # An unregistered window is the NORMAL case for an interactive session, so
  # self-resolution failure is silent here (seat_resolve is loud by design).
  if [ -z "$seat" ]; then
    seat=$(seat_self_name --quiet 2>/dev/null) || return 1
  fi
  [ -n "$seat" ] || return 1
  local path
  path=$(history_path "$seat") || return 1
  [ -f "$path" ] || return 1

  local office appointed sigil
  office=$(_hist_front "$path" office)
  appointed=$(_hist_front "$path" appointed)
  sigil=$(_hist_sigil "$seat")
  printf '%s %s — %s (seated %s)\n' "${sigil:-·}" "$seat" "${office:-(unrecorded)}" "${appointed:-?}"
  awk -v glyph="$HIST_LAUREL_GLYPH" '
    index($0, "## ") == 1 && index($0, glyph " LAUREL · ") > 0 {
      d = substr($0, 4, 10)
      i = index($0, glyph " LAUREL · ")
      t = substr($0, i + length(glyph " LAUREL · "))
      if ((getline w) > 0) printf "%s %s · %s — %s\n", glyph, d, t, w
    }' "$path" | tail -n "$n"
  return 0
}

# history_verify [<seat>...] — recompute each body checksum and compare (T6).
# No seats named = every file in the history dir. Prints one line per file.
history_verify() {
  local dir="" list="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) shift; SEAT_HISTORY_DIR="$1" ;;
      --dir=*) SEAT_HISTORY_DIR="${1#--dir=}" ;;
      # Newline-separated, never a space-joined string looped with word
      # splitting: zsh does NOT word-split unquoted expansions, so `for s in
      # $args` silently verifies ONE seat named "a b c" there. Same class as
      # the ${PIPESTATUS} trap /commit documents.
      *) list="$list$1
" ;;
    esac
    shift
  done
  dir=$(history_dir) || return 2
  if [ -z "$list" ]; then
    list=$(ls "$dir" 2>/dev/null | sed -n 's/\.history\.md$//p')   # allow-suppress: existence probe
  fi
  out=$(printf '%s\n' "$list" | while IFS= read -r seat; do
    [ -n "$seat" ] || continue
    path="$dir/$seat.history.md"
    if [ ! -f "$path" ]; then
      printf 'MISSING %s\n' "$seat"; continue
    fi
    want=$(_hist_front "$path" integrity)
    want=${want#sha256:}
    got=$(_hist_body "$path" | _hist_sha_stdin)
    if [ "$want" = "$got" ]; then
      printf 'OK %s\n' "$seat"
    else
      printf 'TAMPERED %s (want %s got %s)\n' "$seat" "${want:-<none>}" "$got"
    fi
  done)
  [ -n "$out" ] && printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -qE '^(TAMPERED|MISSING) ' && return 1
  return 0
}

# --- CLI -------------------------------------------------------------------
_hist_main_guard() {
  case "${BASH_SOURCE[0]:-}" in
    "") return 1 ;;
    "$0") return 0 ;;
    *) return 1 ;;
  esac
}
if _hist_main_guard; then
  _hist_cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$_hist_cmd" in
    init)         history_init "$@" ;;
    laurel)       history_laurel "$@" ;;
    retire)       history_retire "$@" ;;
    head)         history_head "$@" ;;
    verify)       history_verify "$@" ;;
    count)        history_laurel_count "$@" ;;
    seats)        history_seats ;;
    office)       history_office "$@" ;;
    remembrancer) history_remembrancer ;;
    dir)          history_dir; printf '\n' ;;
    path)         history_path "$@"; printf '\n' ;;
    *)
      _hist_err "usage: seat-history.sh <init|laurel|retire|head|verify|count|seats|office|remembrancer|dir|path> [args]"
      exit 2 ;;
  esac
  exit $?
fi
