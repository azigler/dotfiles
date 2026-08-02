#!/bin/bash
# lib/portable.sh — the coreutils-flavour shim for hooks and scripts that must
# run on BOTH GNU/Linux (marketing-vps, pico, docker) and BSD/macOS (this box).
#
# ── THE DEFECT CLASS THIS EXISTS FOR (dotfiles-5vz2) ────────────────────────
#
# Four independent sites shared one shape:
#
#     <GNU-only coreutils invocation> 2>/dev/null || <plausible-looking fallback>
#
# Each ingredient is individually defensible. Together they convert a HARD
# failure on macOS into a CONFIDENT WRONG ANSWER, with no error anywhere:
#
#   realpath -m … || echo "$FILE_PATH"   -> the worktree guard prefix-checked an
#                                           UNNORMALIZED path on every Mac call
#   stat -c %Y  … || echo 0              -> "56 years old" for every file
#   date -d "$x" +%s                     -> empty; the caller `continue`s past
#
# The fallback is precisely what makes it undetectable: it returns something
# that reads as real. So this lib does two things, and the second matters more
# than the first:
#
#   1. PROBE THE FLAVOUR ONCE at source time and bind the right implementation
#      (the shape d063a13 established for _al_mtime). Never stack two suppressed
#      calls — that hides the same failure all over again.
#
#   2. FAIL LOUDLY, NOT PLAUSIBLY. Every function here returns NON-ZERO and
#      prints NOTHING when it cannot answer. There is no `|| echo 0`, no
#      `|| echo "$input"`. A caller that wants a default must write it, at the
#      call site, where a reader can see the policy.
#
# ── THE RULE FOR GUARDS ────────────────────────────────────────────────────
#
# A normalization or parse failure inside a GUARD must FAIL CLOSED or ANNOUNCE
# ITSELF. It must never silently substitute un-normalized input and keep going:
# that is a guard reporting success while checking nothing. Callers here:
#
#   pre-tool-use-worktree-guard.sh  FAILS CLOSED — cannot normalize => block,
#                                   with a message saying why.
#   stop-context-guard.sh           FAILS CLOSED — cannot read the mtime => do
#                                   not grant the release; warn on stderr.
#   pre-shared-tree-guard.sh        ANNOUNCES — the hook's documented posture is
#                                   fail-OPEN (see its header), so a parse
#                                   failure warns on stderr instead of silently
#                                   dropping the writer.
#
# Usage:
#     . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/portable.sh"
#
# Sourcing is idempotent. Everything is bash 3.2 clean (macOS /bin/bash) — no
# associative arrays, no `${var^^}`, no `mapfile`.

[ -n "${_P_PORTABLE_LOADED:-}" ] && return 0
_P_PORTABLE_LOADED=1

# --------------------------------------------------------------------------- #
# FLAVOUR PROBES — run ONCE, here, with the only `2>/dev/null` in the file.
# These are genuine capability tests: exit code is the whole answer, the output
# is discarded on purpose, and nothing downstream re-probes.
# --------------------------------------------------------------------------- #
if stat -c %Y . >/dev/null 2>&1; then _P_STAT=gnu           # allow-suppress
elif stat -f %m . >/dev/null 2>&1; then _P_STAT=bsd         # allow-suppress
else _P_STAT=none
fi

if date -d @0 +%s >/dev/null 2>&1; then _P_DATE=gnu         # allow-suppress
elif date -j -f %s 0 +%s >/dev/null 2>&1; then _P_DATE=bsd  # allow-suppress
else _P_DATE=none
fi

if realpath -m / >/dev/null 2>&1; then _P_REALPATH=gnu      # allow-suppress
else _P_REALPATH=shell
fi

# One line a caller can print / a test can assert on.
_p_flavours() { printf 'stat=%s date=%s realpath=%s\n' "$_P_STAT" "$_P_DATE" "$_P_REALPATH"; }

# --------------------------------------------------------------------------- #
# _p_mtime <path>  -> epoch seconds on stdout, rc 0
#                  -> NOTHING on stdout, rc 1, if the mtime cannot be read
# Symlinks are DEREFERENCED (-L): the link's own mtime is almost never the fact
# a caller wants, and reading it silently is trap 1 of lib/always-loaded.sh.
# --------------------------------------------------------------------------- #
case "$_P_STAT" in
  gnu)  _p_mtime() { [ -e "$1" ] || return 1; stat -Lc %Y -- "$1"; } ;;
  bsd)  _p_mtime() { [ -e "$1" ] || return 1; stat -Lf %m -- "$1"; } ;;
  none) _p_mtime() { return 1; } ;;
esac

# _p_size <path> -> bytes on stdout, rc 0; nothing + rc 1 on failure.
case "$_P_STAT" in
  gnu)  _p_size() { [ -e "$1" ] || return 1; stat -Lc %s -- "$1"; } ;;
  bsd)  _p_size() { [ -e "$1" ] || return 1; stat -Lf %z -- "$1"; } ;;
  none) _p_size() { return 1; } ;;
esac

# --------------------------------------------------------------------------- #
# _p_epoch <date-string> -> epoch seconds on stdout, rc 0
#                        -> NOTHING, rc 1, if the string cannot be parsed
#
# Accepts the three shapes this fleet actually produces:
#   @1785630793 / 1785630793        an epoch, with or without the `@`
#   2026-08-01T14:00:21Z            ISO-8601 UTC (ledger rows, bounce records)
#   Sat 2026-08-01 14:00:21 PDT     systemd's LastTriggerUSec
# GNU date parses all of them from one call. BSD date has no `-d` at all and
# needs an EXACT input format per shape, so we try them in turn — the rc-1
# floor is what stops a miss from becoming a wrong number.
# --------------------------------------------------------------------------- #
_p_epoch_gnu() { date -d "$1" +%s; }

# BSD `date -j -f` is LENIENT: given a format shorter than the string it prints
# "Warning: Ignoring N extraneous characters" and succeeds with a wrong answer.
# So the candidate list is ordered MOST-SPECIFIC FIRST and the first success
# wins — a loose format must never get to see a string a strict one would have
# matched. Each entry is `<u|l> <format>`: `u` reads the string as UTC (the
# trailing literal Z), `l` reads it in the machine's local zone.
#
# `l` is right for systemd's LastTriggerUSec ("Sat 2026-08-01 14:00:21 PDT"):
# BSD strptime validates %Z but does not apply it, and systemd always renders
# that field in the local zone anyway. (Moot in practice — the only caller runs
# on Linux, where the GNU branch is taken; the format is here so the suite can
# exercise the parse on a Mac.)
_P_BSD_DATE_FORMATS='u %Y-%m-%dT%H:%M:%SZ
l %Y-%m-%dT%H:%M:%S%z
l %a %Y-%m-%d %H:%M:%S %Z
l %Y-%m-%d %H:%M:%S %Z
l %a %b %d %H:%M:%S %Z %Y
u %Y-%m-%dT%H:%M:%S
u %Y-%m-%d %H:%M:%S
u %Y-%m-%d'

_p_epoch_bsd() {
  local s=$1 line mode fmt out
  # Trim fractional seconds ("…:21.482731Z"), which no BSD format spec accepts.
  case "$s" in
    *.*) s=$(printf '%s' "$s" | sed -E 's/\.[0-9]+//') ;;
  esac
  while IFS= read -r line; do
    mode=${line%% *}
    fmt=${line#* }
    if [ "$mode" = u ]; then
      out=$(date -j -u -f "$fmt" "$s" +%s 2>/dev/null) || continue   # allow-suppress
    else
      out=$(date -j -f "$fmt" "$s" +%s 2>/dev/null) || continue      # allow-suppress
    fi
    case "$out" in
      ''|*[!0-9-]*) continue ;;
    esac
    printf '%s\n' "$out"
    return 0
  done <<EOF
$_P_BSD_DATE_FORMATS
EOF
  return 1
}

_p_epoch() {
  local s=$1 out
  [ -n "$s" ] || return 1
  case "$s" in
    '@'*) s=${s#@} ;;
  esac
  case "$s" in
    ''|*[!0-9-]*) ;;
    *) printf '%s\n' "$s"; return 0 ;;      # already an epoch
  esac
  case "$_P_DATE" in
    gnu) out=$(_p_epoch_gnu "$s" 2>/dev/null) ;;   # allow-suppress
    bsd) out=$(_p_epoch_bsd "$s") ;;
    *)   return 1 ;;
  esac
  case "$out" in
    ''|*[!0-9-]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# _p_date_since <date-string> -> seconds elapsed since it, rc 0
#                             -> nothing, rc 1, if unparseable.
# A negative delta (a clock skew, a future timestamp) is returned as-is; the
# caller decides whether that is an error, because "in the future" means
# different things to a freshness check and to a stall check.
_p_date_since() {
  local then
  then=$(_p_epoch "$1") || return 1
  printf '%s\n' "$(( $(date +%s) - then ))"
}

# _p_iso_utc <epoch> -> that instant as 2026-08-01T14:00:21Z, rc 0.
# GNU renders an epoch with `-d @N`; BSD needs `-r N`. Neither flag exists on
# the other, so this is the same trap in output form.
case "$_P_DATE" in
  gnu)  _p_iso_utc() { date -u -d "@$1" +%FT%TZ; } ;;
  bsd)  _p_iso_utc() { date -u -r "$1" +%FT%TZ; } ;;
  none) _p_iso_utc() { return 1; } ;;
esac

# _p_touch_at <epoch> <file> — set a file's mtime. Used by the suites to age a
# fixture; `touch -d '2 hours ago'` is GNU-only and dies on BSD with "out of
# range or illegal time specification", which leaves the fixture at NOW and the
# assertion testing nothing.
case "$_P_DATE" in
  gnu)  _p_touch_at() { touch -d "@$1" -- "$2"; } ;;
  bsd)  _p_touch_at() { touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" -- "$2"; } ;;
  none) _p_touch_at() { return 1; } ;;
esac

# --------------------------------------------------------------------------- #
# _p_realpath <path> -> the normalized ABSOLUTE path on stdout, rc 0
#                    -> NOTHING, rc 1, when it cannot normalize
#
# The path need NOT exist (GNU `realpath -m` semantics) — a guard has to
# normalize the path a Write is ABOUT to create, which by definition does not
# exist yet. That is exactly why `realpath -m` was reached for, and why its
# absence on BSD was so quiet.
#
# The BSD path is a component walk in pure shell:
#   * peel components off the RIGHT until what remains is an existing directory;
#   * resolve THAT physically (`cd -P` + `pwd -P`), which is what kills symlink
#     tricks;
#   * re-attach the peeled remainder.
# `..` is counted right-to-left as a PENDING POP, because a `..` cancels the
# component to its LEFT — the one we have not read yet. Popping the already-
# collected tail instead would turn `/x/a/../b` into `/x` and drop `b`.
# --------------------------------------------------------------------------- #
_p_realpath_shell() {
  local p=$1 base dir tail='' pops=0 phys guard=0
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac

  while :; do
    guard=$((guard + 1))
    [ "$guard" -gt 4096 ] && return 1
    if [ -d "$p" ]; then
      phys=$(cd -P -- "$p" 2>/dev/null && pwd -P) || return 1   # allow-suppress
      [ -n "$phys" ] || return 1
      break
    fi
    dir=${p%/*}
    base=${p##*/}
    [ -n "$dir" ] || dir=/
    if [ "$dir" = "$p" ]; then
      # Ran off the top without finding an existing directory. `/` always
      # exists, so this is unreachable in practice; rc 1 rather than a guess.
      return 1
    fi
    case "$base" in
      ''|.) ;;
      ..)   pops=$((pops + 1)) ;;
      *)    if [ "$pops" -gt 0 ]; then pops=$((pops - 1)); else tail="/$base$tail"; fi ;;
    esac
    p=$dir
  done

  while [ "$pops" -gt 0 ]; do
    phys=${phys%/*}
    [ -n "$phys" ] || phys=/
    pops=$((pops - 1))
  done
  [ "$phys" = "/" ] && phys=''
  p="$phys$tail"
  [ -n "$p" ] || p=/
  # POSIX lets `//foo` keep its double slash and macOS's `pwd -P` DOES keep it.
  # That matters here: a `case` prefix test against "$MAIN_ROOT"/* does not
  # match `//main/root/x`, so a leading `//` is a live way to walk past a
  # prefix-checking guard. Collapse it.
  while :; do
    case "$p" in //*) p=${p#/} ;; *) break ;; esac
  done
  # A leaf that is itself a symlink still points elsewhere, and a Write follows
  # it. `readlink -f` is present and correct on both flavours (audited: 34 call
  # sites, all fine) and only ever runs here on a path that exists.
  if [ -L "$p" ]; then
    phys=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$phys" ] && p=$phys   # allow-suppress
  fi
  printf '%s\n' "$p"
}

case "$_P_REALPATH" in
  gnu) _p_realpath() { [ -n "${1:-}" ] || return 1; realpath -m -- "$1"; } ;;
  *)   _p_realpath() { _p_realpath_shell "${1:-}"; } ;;
esac
