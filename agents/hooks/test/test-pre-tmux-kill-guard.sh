#!/bin/bash
# Test for pre-tmux-kill-guard.sh — the PreToolUse:Bash gate that blocks
# `tmux kill-server` / `tmux kill-session` run with no explicit -S/-L socket.
#
# Hook test convention (see test-pre-bash-stderr-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# THE INCIDENT this guard exists for (2026-08-09, dotfiles-2v8h): a bare
# `tmux kill-server`, run with only TMUX_TMPDIR exported (no -S/-L), connected
# through the inherited $TMUX instead — the LIVE default server — and killed
# every pane, the orchestrator, and two sibling agents. This suite pins BOTH
# failure modes: the guard must actually block the bare form (the reason it
# exists), and it must not block ordinary read-only tmux use or prose that
# merely mentions the incident (the reason a guard like this gets routed
# around if it over-blocks — see pre-bash-stderr-guard.sh's own history).

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-tmux-kill-guard.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# fire <command> -> exit code of the hook (0 = allowed, 2 = blocked)
fire() {
  printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" >/dev/null 2>&1
  echo $?
}

blocks() {
  local name=$1 cmd=$2 rc
  rc=$(fire "$cmd")
  if [ "$rc" = "2" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("BLOCK $name (want exit 2, got $rc)")
  fi
}

allows() {
  local name=$1 cmd=$2 rc
  rc=$(fire "$cmd")
  if [ "$rc" = "0" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("ALLOW $name (want exit 0, got $rc)")
  fi
}

# --- MUST BLOCK: bare kill-server / kill-session, no socket flag -----------
# This is the guard's whole reason for existing — the exact shape of the
# 2026-08-09 incident.

blocks "bare tmux kill-server (the incident)" \
  'tmux kill-server'

blocks "bare tmux kill-session -t" \
  'tmux kill-session -t some-session'

blocks "bare kill-server via full path" \
  '/usr/bin/tmux kill-server'

blocks "bare kill-server with TMUX_TMPDIR set but no -S/-L (the incident's exact env)" \
  'TMUX_TMPDIR=/tmp/demo tmux kill-server'

blocks "bare kill-server chained after an unrelated command" \
  'cd /tmp && tmux kill-server'

blocks "bare kill-session inside a command substitution" \
  'OUT=$(tmux kill-session -t foo)'

blocks "bare kill-server with stderr suppressed" \
  'tmux kill-server 2>/dev/null'

# --- MUST ALLOW: explicit socket given -------------------------------------

allows "tmux -S <path> kill-server" \
  'tmux -S /tmp/tmux-1000/fcsuite12345 kill-server'

allows "tmux -L <name> kill-session -t" \
  'tmux -L pulseseat-12345 kill-session -t some-session'

allows "env -u TMUX -u TMUX_TMPDIR tmux -S ... kill-server (bead-recommended form)" \
  'env -u TMUX -u TMUX_TMPDIR tmux -S /tmp/tmux-1000/fcsuite12345 kill-server'

allows "explicit socket, stderr suppressed too" \
  'tmux -L pulseseatleak-999 kill-server 2>/dev/null'

allows "\"\$TMUX_BIN\" -L \"\$PRIV\" kill-server (fixture-script shape)" \
  '"$TMUX_BIN" -L "$PRIV" kill-server 2>/dev/null'

# --- MUST ALLOW: read-only tmux commands, gated or not ----------------------

allows "tmux list-sessions, no socket" \
  'tmux list-sessions'

allows "tmux -S <path> list-sessions" \
  'tmux -S /tmp/tmux-1000/default list-sessions'

allows "tmux has-session probe" \
  'tmux has-session -t work 2>/dev/null'

allows "tmux display-message" \
  'tmux display-message -p "#S"'

allows "unrelated command mentioning neither tmux nor kill" \
  'git status'

# --- MUST ALLOW: prose that MENTIONS the rule, never executes it -----------
# Mirrors pre-bash-stderr-guard.sh's yfn4 regression class: text ABOUT the
# incident must never trip the guard that exists because of it.

allows "bead body naming the incident, never invoking tmux" \
  'br create -t task -d "never run tmux kill-server without -S/-L, see dotfiles-2v8h"'

allows "commit message documenting the guard" \
  'git commit -m "add guard blocking bare tmux kill-server / kill-session"'

allows "comment mentioning the anti-pattern" \
  'echo hello   # never do: tmux kill-server'

allows "markdown table row naming both subcommands" \
  'br create -d "| tmux kill-server | tmux kill-session | both need -S/-L |"'

# --- Fail-open contract -----------------------------------------------------

allows "empty command" ''

# --- Summary ---
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS/$TOTAL test cases"
  exit 0
fi
echo "FAIL: $FAIL/$TOTAL test cases failed"
for n in "${FAILED_NAMES[@]}"; do
  echo "  - $n"
done
exit 1
