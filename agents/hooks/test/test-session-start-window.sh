#!/bin/bash
# Test for the SESSION_WINDOW resolution seam in session-start.sh
# (dotfiles-k50m).
#
# What it guards: session-start.sh was window-blind (zero tmux references)
# while agents/lib/handoff-path.sh already solves window resolution across
# /clear and env loss. This adds SESSION_WINDOW, resolved via handoff-path.sh's
# EXISTING `_handoff_key` helper (no parallel resolution logic in the hook
# itself) — the same helper session-end.sh already sources and calls for its
# own window-keyed markers.
#
# Hook test convention (see test-worktree-guard.sh, test-session-start-
# symlink-triple.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Fake-tmux seam, same pattern as agents/lib/test-tmux-pane-resolve.sh: a mock
# `tmux` binary is prepended to PATH so window resolution is fully controlled
# and no real tmux server (this box has one — verified live) is ever consulted.
# Combined with a temp $HOME (same discipline as the settings-symlink and
# symlink-triple suites), every case here is hermetic: the real ~/.claude
# settings symlink and the real tmux server are never read.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/session-start.sh"
PASS=0
FAIL=0
FAILED_NAMES=()
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); }

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT

# --- mock tmux, same shape as agents/lib/test-tmux-pane-resolve.sh's mock ---
# MOCK_PID unset / MOCK_DISP unset -> every subcommand prints nothing, which
# is exactly "tmux exists but nothing resolves" (the unresolvable-window case).
MOCKDIR=$(mktemp -d "$BASE/mocktmux.XXXXXX")
cat > "$MOCKDIR/tmux" <<'EOF'
#!/bin/sh
case "$*" in
  *list-panes*pane_id*)     [ -n "${MOCK_PID:-}" ] && printf '%s %%99\n' "${MOCK_PID}" ;;
  *list-panes*window_name*) [ -n "${MOCK_PID:-}" ] && printf '%s %s\n' "${MOCK_PID}" "${MOCK_WIN:-}" ;;
  *display-message*)        [ -n "${MOCK_DISP:-}" ] && printf '%s\n' "${MOCK_DISP}" ;;
esac
exit 0
EOF
chmod +x "$MOCKDIR/tmux"

# A REAL repo for the hook to run in (git-context guards want a real repo;
# same fixture shape as the symlink-triple/settings-symlink suites).
PROJ="$BASE/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email t@t; git -C "$PROJ" config user.name t
echo seed > "$PROJ/seed"; git -C "$PROJ" add seed; git -C "$PROJ" commit -qm seed

# new_home builds a fake $HOME with a REAL settings.json symlink (so the
# unrelated settings-symlink guard in session-start.sh stays quiet and never
# touches the real ~/.claude/settings.json).
new_home() {
  local fh
  fh=$(mktemp -d "$BASE/home.XXXXXX")
  mkdir -p "$fh/dotfiles/claude" "$fh/.claude"
  printf '%s\n' '{}' > "$fh/dotfiles/claude/settings.json"
  ln -s "$fh/dotfiles/claude/settings.json" "$fh/.claude/settings.json"
  printf '%s' "$fh"
}

# run_hook <fakehome> <log-file> [extra env assignments...] -> stdout+stderr,
# and leaves diagnostics in <log-file> (HARNESS_SESSION_START_LOG).
#
# Isolation gotcha found live: tmux_resolve_window's sticky session->window
# cache (tmux-pane-resolve.sh) defaults to /tmp/claude-lexicon, keyed by
# $CLAUDE_CODE_SESSION_ID — which is the REAL ambient session id of whatever
# Claude Code session runs this suite. Without scrubbing both, a resolved
# case (#1) seeds the REAL shared cache under the REAL session id, and a
# later "unresolvable" case (#2) silently reads it back — a false pass that
# has nothing to do with the hook. Each call gets its own
# CLAUDE_LEXICON_STATE_DIR and an unset (never a shared) session id.
run_hook() {
  local fh=$1 log=$2; shift 2
  local lexdir; lexdir=$(mktemp -d "$BASE/lex.XXXXXX")
  ( cd "$PROJ" && env -u TMUX_PANE -u TMUX -u HANDOFF_WINDOW -u CLAUDE_CODE_SESSION_ID \
      HOME="$fh" HARNESS_SESSION_START_LOG="$log" \
      CLAUDE_LEXICON_STATE_DIR="$lexdir" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      PATH="$MOCKDIR:$PATH" \
      "$@" \
      bash "$HOOK" <<< '{"hook_event_name":"SessionStart","cwd":"'"$PROJ"'"}' )
}

# --- 1. tmux resolves (TMUX_PANE fast path) -> SESSION_WINDOW is logged, -----
#     glyph-prefixed name stripped -------------------------------------------
FH=$(new_home)
LOG="$BASE/log1"
run_hook "$FH" "$LOG" TMUX_PANE='%1' MOCK_DISP='🧠 seat-alpha' >/dev/null 2>&1
if grep -qF 'session window: seat-alpha' "$LOG" 2>/dev/null; then
  ok
else
  bad "resolved: SESSION_WINDOW should read 'seat-alpha' (glyph-stripped) in the log; got: $(grep 'session window' "$LOG" 2>/dev/null)"
fi

# --- 2. tmux exists but resolves nothing (no TMUX_PANE, no ancestry match, ---
#     mock replies empty) -> SESSION_WINDOW stays empty, hook still completes -
FH=$(new_home)
LOG="$BASE/log2"
OUT=$(run_hook "$FH" "$LOG" 2>&1)
RC=$?
if grep -qF 'session window: <unresolved>' "$LOG" 2>/dev/null; then
  ok
else
  bad "unresolvable: SESSION_WINDOW should be empty in the log; got: $(grep 'session window' "$LOG" 2>/dev/null)"
fi
if [ "$RC" -eq 0 ]; then
  ok
else
  bad "unresolvable: hook must still exit 0 (never blocks session start), got rc=$RC"
fi
if echo "$OUT" | grep -qF '=== Session Context ==='; then
  ok
else
  bad "unresolvable: hook must still print the normal session-start banner"
fi

# --- 3. no handoff-path.sh at all (simulate a broken/missing lib install) ---
#     -> SESSION_WINDOW stays empty, hook still completes cleanly -----------
FH=$(new_home)
LOG="$BASE/log3"
LIBDIR="$(cd "$(dirname "$HOOK")/../lib" && pwd)"
if [ -f "$LIBDIR/handoff-path.sh" ]; then
  TMPLIB=$(mktemp -d "$BASE/nolib.XXXXXX")
  # Copy the whole hooks+lib tree so relative sourcing (context-emit.sh etc.)
  # still works, minus handoff-path.sh itself.
  cp -r "$(dirname "$HOOK")/.." "$TMPLIB/agents"
  rm -f "$TMPLIB/agents/lib/handoff-path.sh"
  ALT_HOOK="$TMPLIB/agents/hooks/session-start.sh"
  ( cd "$PROJ" && env -u TMUX_PANE -u TMUX -u HANDOFF_WINDOW -u CLAUDE_CODE_SESSION_ID \
      HOME="$FH" HARNESS_SESSION_START_LOG="$LOG" \
      CLAUDE_LEXICON_STATE_DIR="$(mktemp -d "$BASE/lex.XXXXXX")" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      PATH="$MOCKDIR:$PATH" \
      bash "$ALT_HOOK" <<< '{"hook_event_name":"SessionStart","cwd":"'"$PROJ"'"}' >/dev/null 2>&1 )
  RC3=$?
  if grep -qF 'session window: <unresolved>' "$LOG" 2>/dev/null; then
    ok
  else
    bad "missing-lib: SESSION_WINDOW should degrade to empty; got: $(grep 'session window' "$LOG" 2>/dev/null)"
  fi
  if [ "$RC3" -eq 0 ]; then
    ok
  else
    bad "missing-lib: hook must still exit 0 when handoff-path.sh is absent, got rc=$RC3"
  fi
else
  bad "missing-lib: could not locate agents/lib/handoff-path.sh to build the fixture"
fi

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
exit 1
