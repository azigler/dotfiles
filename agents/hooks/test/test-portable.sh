#!/bin/bash
# Test for lib/portable.sh — the coreutils-flavour shim (dotfiles-5vz2).
#
# Hook test convention: executable bash, non-zero exit = failure, PASS/FAIL
# summary on the last line. ⚠️ RUN UNDER BASH, NOT ZSH.
#
# THE INVARIANT THIS SUITE EXISTS TO PIN. Four hooks independently wrote
#
#     <GNU-only invocation> 2>/dev/null || <plausible-looking fallback>
#
# and every one of them turned a hard macOS failure into a confident wrong
# answer. So the last section here is not about any single function: it asserts
# that EVERY function in this lib prints NOTHING and returns NON-ZERO when it
# cannot answer. The moment one of them grows an `|| echo 0`, the callers'
# fail-closed branches become unreachable and the class is back — silently,
# because a wrong number passes every other test in this file.
#
# It also runs the shell realpath walk against GNU `realpath -m` side by side
# wherever GNU is present, so the two implementations cannot drift apart.

set -u

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/portable.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }
eq()  { # <name> <want> <got>
  if [ "$2" = "$3" ]; then ok; else bad "$1 (want '$2', got '$3')"; fi
}

# shellcheck source=/dev/null
. "$LIB"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/portable-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)     # physical: /var -> /private/var on macOS
trap 'rm -rf "$TMP"' EXIT

# --- the probes resolved to something usable -------------------------------
case "$_P_STAT"     in gnu|bsd) ok ;; *) bad "no usable stat flavour ($_P_STAT)" ;; esac
case "$_P_DATE"     in gnu|bsd) ok ;; *) bad "no usable date flavour ($_P_DATE)" ;; esac
case "$_P_REALPATH" in gnu|shell) ok ;; *) bad "no realpath strategy ($_P_REALPATH)" ;; esac
case "$(_p_flavours)" in *stat=*date=*realpath=*) ok ;; *) bad "_p_flavours is unreadable" ;; esac

# --- _p_mtime / _p_size ----------------------------------------------------
echo -n abc > "$TMP/f"
NOW=$(date +%s)
M=$(_p_mtime "$TMP/f")
if [ -n "$M" ] && [ "$M" -ge "$((NOW - 60))" ] && [ "$M" -le "$((NOW + 60))" ]; then ok
else bad "_p_mtime returns a plausible NOW for a just-written file (got '$M')"; fi
eq "_p_size counts bytes" 3 "$(_p_size "$TMP/f")"

# Symlinks are DEREFERENCED — the link's own mtime is never the fact wanted.
ln -s "$TMP/f" "$TMP/link"
_p_touch_at "$((NOW - 100000))" "$TMP/link"   # touch follows the link -> ages the TARGET
eq "_p_mtime dereferences a symlink" "$(_p_mtime "$TMP/f")" "$(_p_mtime "$TMP/link")"

# --- _p_touch_at / _p_iso_utc / _p_date_since ------------------------------
_p_touch_at "$((NOW - 7200))" "$TMP/f"
AGE=$(( NOW - $(_p_mtime "$TMP/f") ))
if [ "$AGE" -ge 7195 ] && [ "$AGE" -le 7205 ]; then ok
else bad "_p_touch_at ages a file by the right amount (got ${AGE}s, want 7200)"; fi

eq "_p_iso_utc renders an epoch as ISO-8601 Z" "2026-08-01T14:00:21Z" "$(_p_iso_utc 1785592821)"
eq "_p_iso_utc / _p_epoch round-trip" "1785592821" "$(_p_epoch "$(_p_iso_utc 1785592821)")"

SINCE=$(_p_date_since "@$((NOW - 3600))")
if [ "$SINCE" -ge 3595 ] && [ "$SINCE" -le 3605 ]; then ok
else bad "_p_date_since returns elapsed seconds (got $SINCE)"; fi

# --- _p_epoch: every shape this fleet actually produces --------------------
eq "_p_epoch: ISO-8601 Z (ledger + bounce rows)" 1785592821 "$(_p_epoch 2026-08-01T14:00:21Z)"
eq "_p_epoch: ISO-8601 Z with fractional seconds" 1785592821 "$(_p_epoch 2026-08-01T14:00:21.482731Z)"
eq "_p_epoch: a bare epoch passes through" 1785592821 "$(_p_epoch 1785592821)"
eq "_p_epoch: an @epoch passes through" 1785592821 "$(_p_epoch @1785592821)"
# systemd's LastTriggerUSec — the shape pre-shared-tree-guard.sh reads, and the
# one whose parse failure made that hook conclude "no writer" on every Mac.
SYSD=$(date '+%a %Y-%m-%d %H:%M:%S %Z')
SYSD_E=$(_p_epoch "$SYSD")
if [ -n "$SYSD_E" ] && [ "$SYSD_E" -ge "$((NOW - 60))" ] && [ "$SYSD_E" -le "$((NOW + 60))" ]; then ok
else bad "_p_epoch parses systemd LastTriggerUSec '$SYSD' (got '$SYSD_E')"; fi

# --- _p_realpath -----------------------------------------------------------
mkdir -p "$TMP/main/.claude/worktrees/agent-x/sub" "$TMP/main/real"
ln -s real "$TMP/main/lnk"
ln -s "$TMP/main" "$TMP/main/.claude/worktrees/agent-x/escape"

eq "_p_realpath: .. is collapsed" \
  "$TMP/main/foo.txt" "$(_p_realpath "$TMP/main/.claude/../foo.txt")"
eq "_p_realpath: .. cancels the component to its LEFT, not the one to its right" \
  "$TMP/main/b" "$(_p_realpath "$TMP/main/real/../b")"
eq "_p_realpath: a nonexistent leaf is fine (realpath -m semantics)" \
  "$TMP/main/real/deep/new.txt" "$(_p_realpath "$TMP/main/lnk/deep/new.txt")"
eq "_p_realpath: a symlink out of a worktree resolves to its target" \
  "$TMP/main/leaked.md" "$(_p_realpath "$TMP/main/.claude/worktrees/agent-x/escape/leaked.md")"
eq "_p_realpath: . is dropped" \
  "$TMP/main/real/b" "$(_p_realpath "$TMP/main/real/./a/../b")"
eq "_p_realpath: / is /" "/" "$(_p_realpath /)"
# A leading `//` is POSIX-legal and macOS's `pwd -P` PRESERVES it — which is a
# live way past a `case $p in "$ROOT"/*)` prefix guard. It must not survive.
eq "_p_realpath: a leading // is collapsed" "$TMP/main" "$(_p_realpath "/${TMP}//main")"
eq "_p_realpath: a relative path is anchored at PWD" \
  "$(cd "$TMP/main" && pwd -P)/x" "$(cd "$TMP/main" && _p_realpath x)"
eq "_p_realpath: a wholly nonexistent path still normalizes" \
  "/nonexistent/a/c" "$(_p_realpath /nonexistent/a/b/../c)"

# --- the two implementations must not drift --------------------------------
# Only meaningful where GNU realpath exists (Linux); on a Mac this is a no-op
# and says so rather than pretending to have compared anything.
if realpath -m / >/dev/null 2>&1; then   # allow-suppress
  DRIFT=0
  for P in "$TMP/main/../foo.txt" "/nonexistent/a/b/../c" "/${TMP}//main" \
           "$TMP/main/lnk/deep/new.txt" "$TMP/main/real/./a/../b" "/" "$TMP/main"; do
    G=$(realpath -m "$P"); S=$(_p_realpath_shell "$P")
    [ "$G" = "$S" ] || { DRIFT=1; FAILED_NAMES+=("realpath drift on $P: gnu=$G shell=$S"); }
  done
  [ "$DRIFT" -eq 0 ] && ok || FAIL=$((FAIL + 1))
else
  echo "note: GNU realpath absent — the shell-vs-GNU parity check did not run here." >&2
  ok
fi

# --- THE CLASS INVARIANT: no plausible-looking fallback, ever --------------
# Each of these is a failure case. A correct answer is EMPTY stdout + rc != 0.
# A `0`, a `1970-01-01`, or an echoed-back input would pass a naive smoke test
# and re-create the exact defect this lib was written to remove.
check_fails_empty() { # <name> <function> <arg...>
  local name=$1; shift
  local out rc
  out=$("$@" 2>/dev/null); rc=$?      # allow-suppress
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then ok
  else bad "$name must fail EMPTY + non-zero (rc=$rc, stdout='$out')"; fi
}
check_fails_empty "_p_mtime on a missing file"      _p_mtime "$TMP/does-not-exist"
check_fails_empty "_p_mtime on a broken symlink"    _p_mtime "$TMP/broken"
check_fails_empty "_p_size on a missing file"       _p_size  "$TMP/does-not-exist"
check_fails_empty "_p_epoch on unparseable text"    _p_epoch "not a timestamp at all"
check_fails_empty "_p_epoch on the empty string"    _p_epoch ""
check_fails_empty "_p_date_since on unparseable"    _p_date_since "not a timestamp at all"
check_fails_empty "_p_realpath on the empty string" _p_realpath ""

# ...and the same property SOURCE-SIDE: the only stderr suppression in the lib
# is on a capability probe. A `2>/dev/null` on an output-bearing call is the
# repo-rule-#3 half of this defect, and grep is the only thing that notices it
# coming back.
STRAY=$(grep -v '^[[:space:]]*#' "$LIB" | grep '2>/dev/null' | grep -vc 'allow-suppress')
eq "every 2>/dev/null in the lib is a marked capability probe" 0 "$STRAY"

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL portable-shim cases ($(_p_flavours))"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL portable-shim cases failed ($(_p_flavours))"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
