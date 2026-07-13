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

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILURE(S)"; fi
[ "$FAILS" -eq 0 ]
