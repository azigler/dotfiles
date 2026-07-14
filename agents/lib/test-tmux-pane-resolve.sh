#!/bin/sh
# test-tmux-pane-resolve.sh — regression tests for the ancestry-based pane
# resolver. Guards the 2026-07-13 bug: a background-forked Claude Code session
# (`bg-pty-host --fork-session`) has no $TMUX_PANE, and the earlier shell-word-
# split parse silently returned empty under ZSH. Run under BOTH bash and zsh:
#
#   bash agents/lib/test-tmux-pane-resolve.sh
#   zsh  agents/lib/test-tmux-pane-resolve.sh   # the shell where it broke
#
# Exits non-zero on any failure.

DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
FAILS=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s (got: [%s])\n' "$1" "$2"; FAILS=$((FAILS+1)); }

# --- a mock `tmux` on PATH; responds by the format string requested ----------
MOCKDIR=$(mktemp -d)
trap 'rm -rf "$MOCKDIR"' EXIT
cat > "$MOCKDIR/tmux" <<'EOF'
#!/bin/sh
# MOCK_PID = the pane_pid to advertise; MOCK_WIN = its (glyphed) window name.
case "$*" in
  *list-panes*pane_id*)     printf '%s %%99\n'   "${MOCK_PID}" ;;
  *list-panes*window_name*) printf '%s %s\n'     "${MOCK_PID}" "${MOCK_WIN}" ;;
  *display-message*)        printf '%s\n'        "${MOCK_DISP}" ;;
esac
EOF
chmod +x "$MOCKDIR/tmux"
PATH="$MOCKDIR:$PATH"; export PATH

. "$DIR/tmux-pane-resolve.sh"

# Hermetic sticky-window cache: a throwaway state dir so seeding never touches
# the real /tmp/claude-lexicon, and unset the ambient session id so the tests
# below control the cache key explicitly (a bare tmux_resolve_window in the
# suite's own Claude session would otherwise seed under a real session id).
CACHE_DIR=$(mktemp -d)
export CLAUDE_LEXICON_STATE_DIR="$CACHE_DIR"
unset CLAUDE_CODE_SESSION_ID
trap 'rm -rf "$MOCKDIR" "$CACHE_DIR"' EXIT

# Parent PID of THIS test process — forces the ancestry walk to take one real
# _tpr_ppid hop (exercising the /proc-or-ps parse that broke under zsh).
MY_PPID=$(_tpr_ppid "$$")

echo "test-tmux-pane-resolve ($(basename "${0}"), shell=$(readlink /proc/$$/exe 2>/dev/null || echo "$0"))"

# T1 — env fast-path: $TMUX_PANE wins outright, no tmux needed.
( TMUX_PANE='%7'; got=$(tmux_resolve_pane); [ "$got" = '%7' ] ) \
  && pass 'T1 env fast-path pane' || fail 'T1 env fast-path pane' "$(TMUX_PANE=%7 tmux_resolve_pane)"

# T2a — ancestry SELF match ($$ is advertised as a pane_pid).
unset TMUX_PANE
got=$(MOCK_PID="$$" tmux_resolve_pane)
[ "$got" = '%99' ] && pass 'T2a ancestry self-match pane' || fail 'T2a ancestry self-match pane' "$got"

# T2b — ancestry ONE-HOP match (parent PID advertised) — the /proc/ps ppid walk.
got=$(MOCK_PID="$MY_PPID" tmux_resolve_pane)
[ "$got" = '%99' ] && pass 'T2b ancestry one-hop pane' || fail 'T2b ancestry one-hop pane' "$got"

# T3 — window via ancestry, glyph stripped.
got=$(MOCK_PID="$$" MOCK_WIN='✅ explore' tmux_resolve_window)
[ "$got" = 'explore' ] && pass 'T3 ancestry window + glyph strip' || fail 'T3 ancestry window + glyph strip' "$got"

# T4 — no ancestor matches -> unresolved (non-zero, empty).
if got=$(MOCK_PID='4000000000' tmux_resolve_pane); then
  fail 'T4 unresolved returns non-zero' "rc=0 got=$got"
else
  [ -z "$got" ] && pass 'T4 unresolved returns non-zero+empty' || fail 'T4 unresolved empty' "$got"
fi

# T5 — every lexicon glyph strips (via the $TMUX_PANE display-message path).
for g in 🧠 ✅ 🔔 🌀 📬; do
  got=$(TMUX_PANE='%1' MOCK_DISP="$g win" tmux_resolve_window)
  [ "$got" = 'win' ] && pass "T5 strip [$g]" || fail "T5 strip [$g]" "$got"
done

# T6 — multi-fork ambiguity: forked session + >1 bg session -> DEGRADE (fail).
if got=$(TPR_TEST_FORKED=1 TPR_TEST_BG_COUNT=2 MOCK_PID="$$" tmux_resolve_pane); then
  fail 'T6 multi-fork degrades' "rc=0 got=$got"
else
  [ -z "$got" ] && pass 'T6 multi-fork degrades (non-zero+empty)' || fail 'T6 multi-fork empty' "$got"
fi

# T7 — forked but SINGLE bg session -> still resolves (the common /clear case).
got=$(TPR_TEST_FORKED=1 TPR_TEST_BG_COUNT=1 MOCK_PID="$$" tmux_resolve_pane)
[ "$got" = '%99' ] && pass 'T7 single-fork resolves' || fail 'T7 single-fork resolves' "$got"

# --- Sticky session->window cache: the childed-pid / bg-fork recovery ---------

# T8 — a successful LIVE resolution SEEDS the cache under the session id.
CSID='cache-sess-1'
got=$(TMUX_PANE='%1' MOCK_DISP='✅ explore' tmux_resolve_window "$CSID")
[ "$got" = 'explore' ] && [ "$(cat "$CACHE_DIR/$CSID.window" 2>/dev/null)" = 'explore' ] \
  && pass 'T8 live resolve seeds the cache' \
  || fail 'T8 live resolve seeds the cache' "$got / $(cat "$CACHE_DIR/$CSID.window" 2>/dev/null)"

# T9 — the childed-pid case: NO $TMUX_PANE and ancestry can't match (bogus
# MOCK_PID), but the seeded cache recovers the window (rc=0).
unset TMUX_PANE
got=$(MOCK_PID='4000000000' tmux_resolve_window "$CSID")
[ "$got" = 'explore' ] && pass 'T9 childed-pid recovers window from cache' \
  || fail 'T9 childed-pid recovers window from cache' "$got"

# T10 — live resolution fails AND no cache entry -> non-zero, empty.
if got=$(MOCK_PID='4000000000' tmux_resolve_window 'never-seen-sess'); then
  fail 'T10 uncached unresolved returns non-zero' "rc=0 got=$got"
else
  [ -z "$got" ] && pass 'T10 uncached unresolved non-zero+empty' || fail 'T10 uncached unresolved empty' "$got"
fi

# T11 — session_id defaults to $CLAUDE_CODE_SESSION_ID (env-only callers like
# handoff-path.sh): recover with NO arg via the env id.
got=$(CLAUDE_CODE_SESSION_ID="$CSID" MOCK_PID='4000000000' tmux_resolve_window)
[ "$got" = 'explore' ] && pass 'T11 env session-id default recovers' || fail 'T11 env session-id default' "$got"

# T12 — cache put/get round-trip directly; empty args are a non-zero no-op.
tmux_win_cache_put 'rt-sess' 'roundtrip-win'
got=$(tmux_win_cache_get 'rt-sess')
[ "$got" = 'roundtrip-win' ] && pass 'T12 cache put/get round-trip' || fail 'T12 cache put/get round-trip' "$got"
if tmux_win_cache_get '' >/dev/null 2>&1; then fail 'T12b empty-key get is non-zero' 'rc=0'; else pass 'T12b empty-key get is non-zero'; fi

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; fi
[ "$FAILS" -eq 0 ]
