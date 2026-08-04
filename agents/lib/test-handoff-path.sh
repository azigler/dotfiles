#!/bin/bash
# Test for handoff-path.sh — per-window scoping of the offboard/onboard
# artifacts. Uses a throwaway tmux window with a known name (and a lexicon
# glyph) to exercise the key resolution. Convention: non-zero exit = failure,
# PASS/FAIL summary on the last line.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/handoff-path.sh"

PASS=0; FAIL=0; FAILED=()
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); }

TMUX_BIN=$(command -v tmux 2>/dev/null); [ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/usr/bin/tmux
DIR=$(mktemp -d)
mkdir -p "$DIR/refs" "$DIR/.claude"
trap 'rm -rf "$DIR"; [ -n "${SES:-}" ] && "$TMUX_BIN" kill-session -t "=$SES" 2>/dev/null' EXIT

# --- 1. No marker -> legacy single-file paths regardless of tmux state. ---
unset TMUX_PANE
if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff.md" ]; then ok; else bad "no-marker handoff legacy"; fi
if [ "$(offboard_pending_path "$DIR")" = "$DIR/.offboard-pending" ]; then ok; else bad "no-marker pending legacy"; fi
if [ "$(last_offboard_path "$DIR")" = "$DIR/.claude/last-offboard-session" ]; then ok; else bad "no-marker last-offboard legacy"; fi

# --- 2. Marker present but the window key is UNRESOLVABLE -> still legacy
# (safe fallback). Unsetting $TMUX_PANE is no longer sufficient to simulate that:
# since the ancestry resolver (2026-07-13) and the sticky session->window cache
# (2026-07-14), a process that merely lacks the env var still resolves its window
# via its parent-PID chain or a cached entry. Run from inside tmux this case
# resolved to the RUNNER's own window and failed; run from a systemd/CI shell it
# passed — an environment-dependent test, green by luck. Force the documented
# degrade explicitly and isolate the cache dir. ---
touch "$DIR/refs/.handoff-per-window"
unset TMUX_PANE
LEXDIR=$(mktemp -d)
if [ "$(CLAUDE_LEXICON_STATE_DIR="$LEXDIR" CLAUDE_CODE_SESSION_ID= TPR_TEST_FORKED=1 TPR_TEST_BG_COUNT=2 \
        handoff_path "$DIR")" = "$DIR/refs/session-handoff.md" ]; then ok; else bad "unresolvable key falls back to legacy"; fi
rm -rf "$LEXDIR"

# --- 3. Marker + a real tmux window named "🧠 wintest" -> scoped, glyph stripped. ---
if [ -x "$TMUX_BIN" ]; then
  SES="handoff-test-$$"
  "$TMUX_BIN" new-session -d -s "$SES" -n "wintest" -c "$DIR" 2>/dev/null
  PANE=$("$TMUX_BIN" list-panes -t "=$SES" -F '#{pane_id}' 2>/dev/null | head -1)
  "$TMUX_BIN" rename-window -t "$PANE" "🧠 wintest" 2>/dev/null
  export TMUX_PANE="$PANE"

  if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff--wintest.md" ]; then ok; else bad "scoped handoff (got $(handoff_path "$DIR"))"; fi
  if [ "$(offboard_pending_path "$DIR")" = "$DIR/.offboard-pending--wintest" ]; then ok; else bad "scoped pending"; fi
  if [ "$(last_offboard_path "$DIR")" = "$DIR/.claude/last-offboard-session--wintest" ]; then ok; else bad "scoped last-offboard"; fi

  # 4. handoff_read_path in a PER-WINDOW project with the scoped note ABSENT:
  # must NOT serve the legacy file (bd-msi5 — that silently onboarded a session
  # in the `di` window from a month-old note after work:di became work:pulse).
  # It returns the scoped path (which does not exist, so the caller's `[ -f ]`
  # guard reads nothing) and warns on STDERR.
  echo "stale legacy" > "$DIR/refs/session-handoff.md"
  echo "another window's note" > "$DIR/refs/session-handoff--pulse.md"
  if [ "$(handoff_read_path "$DIR" 2>/dev/null)" = "$DIR/refs/session-handoff--wintest.md" ]; then ok; else bad "missing scoped note must NOT resolve to legacy"; fi
  WARN=$(handoff_read_path "$DIR" 2>&1 >/dev/null)
  case "$WARN" in
    *"NO note for this window"*wintest*) ok ;;
    *) bad "missing scoped note must warn on stderr (got: $WARN)" ;;
  esac
  case "$WARN" in *session-handoff--pulse.md*) ok ;; *) bad "warning must list the scoped notes that DO exist" ;; esac
  # ...and the scoped note present -> scoped, silently.
  touch "$DIR/refs/session-handoff--wintest.md"
  if [ "$(handoff_read_path "$DIR")" = "$DIR/refs/session-handoff--wintest.md" ]; then ok; else bad "read prefers scoped when present"; fi
  if [ -z "$(handoff_read_path "$DIR" 2>&1 >/dev/null)" ]; then ok; else bad "present scoped note must not warn"; fi

  # 4b. A project NOT opted in is untouched: legacy path, no warning, whether or
  # not the file exists. This is a shared lib — single-session projects must not
  # start seeing diagnostics.
  OUT=$(mktemp -d); mkdir -p "$OUT/refs"
  if [ "$(handoff_read_path "$OUT")" = "$OUT/refs/session-handoff.md" ]; then ok; else bad "opted-out: legacy path when note absent"; fi
  if [ -z "$(handoff_read_path "$OUT" 2>&1 >/dev/null)" ]; then ok; else bad "opted-out: must stay silent"; fi
  echo "single-file note" > "$OUT/refs/session-handoff.md"
  if [ "$(handoff_read_path "$OUT")" = "$OUT/refs/session-handoff.md" ]; then ok; else bad "opted-out: legacy path when note present"; fi
  if [ -z "$(handoff_read_path "$OUT" 2>&1 >/dev/null)" ]; then ok; else bad "opted-out: must stay silent with note present"; fi
  rm -rf "$OUT"

  # 5. A different window name -> a different key (no cross-session collision).
  "$TMUX_BIN" rename-window -t "$PANE" "✅ elevate" 2>/dev/null
  if [ "$(handoff_path "$DIR")" = "$DIR/refs/session-handoff--elevate.md" ]; then ok; else bad "distinct window -> distinct key"; fi
else
  echo "PASS: $PASS/$PASS (tmux missing — scoped cases skipped)"; exit 0
fi

TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS/$TOTAL test cases"; exit 0; fi
echo "FAIL: $FAIL/$TOTAL test cases failed"; for n in "${FAILED[@]}"; do echo "  - $n"; done; exit 1
