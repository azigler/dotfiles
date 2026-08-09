#!/bin/bash
# PreToolUse (Bash): block `tmux kill-server` / `tmux kill-session` when the
# command names no explicit socket (-S <path> or -L <name>).
#
# THE INCIDENT (2026-08-09, dotfiles-2v8h). A sweep agent exported
# TMUX_TMPDIR for a demo dir and ran a bare `tmux kill-server`. TMUX_TMPDIR
# only shapes the DEFAULT socket path tmux would construct with no -S/-L; an
# inherited $TMUX (set because the agent's own shell is itself a tmux client)
# takes precedence over that default and is consulted first. The client
# connected through the LIVE default socket instead of the demo one. Server
# down: every pane, the orchestrator, two sibling agents — recovered only
# because it was a `kill-server`, not something worse.
#
# THE FIX AT THE MECHANICAL LAYER: verified empirically (dotfiles-2v8h) that
# an explicit -S/-L ON THE COMMAND LINE overrides $TMUX regardless of env —
#   TMUX="/tmp/tmux-1000/default,99999,0" tmux -L probetest-verify list-sessions
#   -> "error connecting to /tmp/tmux-1000/probetest-verify (No such file or
#      directory)" — it never touched the default socket named in $TMUX.
# So the rule this hook enforces is narrow and sufficient: a kill-server or
# kill-session invocation MUST carry -S or -L. TMUX_TMPDIR and `env -u TMUX`
# are good hygiene (see /commit-adjacent scripts using them) but are not what
# this hook checks — the explicit socket flag is what actually protects the
# live server, and it is the one thing missing that caused the incident.
#
# SCOPE: this hook inspects the LITERAL command text handed to the Bash tool.
# It does not open script files an agent invokes (`bash foo.sh`) — a script's
# internal tmux calls are its own responsibility (see the fixture traps in
# agents/scheduler/test-pulse-inject.sh and test-fleet-creds.sh, both audited
# under dotfiles-2v8h to already pass an explicit -L to every kill-server /
# kill-session they run). This hook exists for the failure mode the incident
# actually was: an agent typing the dangerous command directly.
#
# NO ESCAPE HATCH. Every other guard in this file has one (# allow-suppress,
# etc.) because its failure mode is "annoying false block". This one's failure
# mode is "every pane on the machine dies", so there is deliberately no way to
# bypass it from the command line — if you genuinely need to kill a server,
# name its socket.
#
# Behavior:
#   - exit 0 = allow the tool call
#   - exit 2 = BLOCK and surface stderr to the agent
# Fail-OPEN on parse ambiguity (a hook bug must never wedge all Bash).
#
# Test: agents/hooks/test/test-pre-tmux-kill-guard.sh

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Match against the SKELETON (string-literal contents, comments, heredoc
# bodies removed) so prose that merely MENTIONS `tmux kill-server` — this
# file's own header, a bead body, a commit message — is never mistaken for a
# command that runs it. Same rationale and same helper as
# pre-bash-stderr-guard.sh.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/hook-helpers.sh" 2>/dev/null
if ! type command_skeleton >/dev/null 2>&1 || ! SKEL=$(command_skeleton "$COMMAND"); then
  SKEL="$COMMAND"   # fail toward the old over-matching behavior: never a missed block
fi

# fast bail: no kill-server / kill-session anywhere
echo "$SKEL" | grep -Eq '\btmux\b.*\bkill-(server|session)\b' || exit 0

# split into segments on && || ; | and newlines, mirroring pre-bash-stderr-guard.sh
SEGMENTS=$(printf '%s\n' "$SKEL" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g; s/\|/\n/g')

FLAGGED=""
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  # Every tmux-invocation-ending-in-kill-server/kill-session substring in this
  # segment, lazily up to the FIRST such subcommand — that span is exactly
  # tmux's main-option region, where -S/-L (if given at all) must live.
  while IFS= read -r inv; do
    [ -z "$inv" ] && continue
    if ! echo "$inv" | grep -Eq '(^|[[:space:]])-[SL]([[:space:]]|$)'; then
      FLAGGED="$inv"
      break 2
    fi
  done < <(echo "$seg" | grep -oP '\btmux\b.*?\bkill-(server|session)\b')
done <<< "$SEGMENTS"

[ -z "$FLAGGED" ] && exit 0

cat >&2 <<MSG
[tmux-kill-guard] This command runs tmux kill-server / kill-session with NO
explicit -S <socket-path> or -L <socket-name> — that means it connects
through whatever \$TMUX (or the default socket) resolves to, which on this
machine is very likely the LIVE server every pane and agent shares:

  ${FLAGGED}

This is exactly the 2026-08-09 incident (dotfiles-2v8h): a bare
\`tmux kill-server\` killed the live server, every pane, the orchestrator, and
two sibling agents, because an inherited \$TMUX took precedence over the
TMUX_TMPDIR override that was supposed to isolate it.

Fix: name the socket explicitly —
  tmux -S /tmp/tmux-1000/<your-fixture-socket> kill-server
  tmux -L <your-fixture-name> kill-session -t <name>

Read-only commands (list-sessions, has-session, display-message, …) are
untouched by this guard; only kill-server / kill-session are gated, and only
when given with no socket flag. There is no escape hatch — this failure mode
is severe enough that the fix is always "name the socket", never "skip the
check".
MSG
exit 2
