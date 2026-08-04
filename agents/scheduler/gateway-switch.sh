#!/bin/bash
# gateway-switch.sh — the one-command, per-host kill switch for pico's
# agentgateway. `off` bypasses it, `on` restores it, `status` reports without
# touching anything.
#
# ---------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------
# Claude Code on this fleet routes through pico's agentgateway via
# ANTHROPIC_BASE_URL in the per-host shell tier ($HOME/.<host>.zshenv), and the
# routing is deliberately FAIL-HARD with no fallback to api.anthropic.com
# (dotfiles-ucl4 — a silent fallback is indistinguishable from being idle, which
# is the blindness bug that policy exists to prevent).
#
# The cost of that policy is that when the gateway HOST goes away, every box
# loses claude. On 2026-08-04 pico was off the internet for ~6.5h and flipping
# the fleet off the gateway took ~15 manual steps across two hosts plus a
# per-pane fix (dotfiles-9o46). This script is those steps, symmetric and
# idempotent, on whichever box you are standing on.
#
# DELIBERATELY SINGLE-HOST. There is no fleet-wide driver, because driving the
# other box needs ssh FROM here — the least reliable thing during exactly the
# outage this exists for. Run it on each host.
#
# ---------------------------------------------------------------------------
# The three things that hold the routing, and why all three must move
# ---------------------------------------------------------------------------
#   1. $HOME/.<host>.zshenv         the value every NEW shell exports
#   2. claude-gateway-tunnel.timer  (marketing-vps only) opens the ssh -L that
#                                   makes the loopback base URL resolve at all
#   3. the ENVIRONMENT OF SHELLS THAT ARE ALREADY RUNNING — the harness's
#      durable tmux panes hold zsh processes that are days old. They exported
#      the old value at start and will never re-read the file, and
#      claude-identity-wrapper.sh honours an inherited value (its rule 2). So a
#      file-only edit changes nothing for the panes that do the work. This is
#      the same shell-age trap that made pico's request log go blind on
#      2026-07-28; step 3 is not optional.
#
# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
#   gateway-switch.sh {off|on|status} [--host NAME] [--check-request]
#
#   off      bypass the gateway: comment the export, stop the tunnel timer if
#            this host has one, and `unset ANTHROPIC_BASE_URL` in every tmux
#            pane that is sitting at a shell prompt. Panes holding a running
#            claude are REPORTED, never typed into.
#   on       restore gateway routing: uncomment, start the timer if this host
#            has one, `exec <shell>` in shell panes, then verify with a probe.
#   status   report only. Changes NOTHING — no file write, no systemctl verb,
#            no send-keys.
#
#   --host NAME       override `hostname -s` when deriving the per-host file.
#   --check-request   status only. Adds a REAL end-to-end request (an LLM call,
#                     which is why it is opt-in) through the route the file
#                     declares, run under `env -u CC_NO_GATEWAY`.
#
# Exit: 0 ok · 1 an operation failed and nothing else was attempted · 3 VERIFICATION
#       FAILED (for off/on the change DID land — read the message) · 64 usage
#       · 65 no per-host zshenv · 66 that file has no ANTHROPIC_BASE_URL export
#       line to act on
# END-USAGE
#
# ---------------------------------------------------------------------------
# The four hazards this script is shaped around
# ---------------------------------------------------------------------------
# A. THE SYMLINK. $HOME/.<host>.zshenv is a symlink into ~/dotfiles. GNU
#    `sed -i` WITHOUT --follow-symlinks REPLACES it with a regular file, which
#    silently detaches the host from the repo: the edit works, `sync.sh` still
#    reports success, and the next repo change never arrives. Every write here
#    goes through `cat tmp > "$file"` (redirection follows the symlink and
#    truncates the TARGET) and is followed by an assertion that the path is
#    still a symlink to the same target. Covered by test-gateway-switch.sh,
#    which also runs `sed -i` as a control so the hazard stays demonstrable.
# B. NEVER TYPE INTO A PANE THAT IS NOT AT A PROMPT. send-keys to a live claude
#    SUBMITS A PROMPT. Gate on pane_current_command; skip anything that is not a
#    bare shell — and skip THIS pane too, since `exec zsh` into the shell that
#    is running this script would kill the script mid-flight.
# C. IDEMPOTENT. `off` on an already-bypassed host must be a no-op, not a
#    second `#` that `on` cannot reverse. The file steps are state-driven: if
#    there is nothing to comment, nothing is written at all.
# D. NO HARDCODED HOSTNAMES for the tunnel step. Key on whether the unit
#    EXISTS, so this is correct on zig-computer (no unit), on marketing-vps
#    (unit), and on a host that does not exist yet.

set -uo pipefail

CMD=""
HOSTKEY=""
HOSTKEY_SET=0
CHECK_REQUEST=0
TIMER_UNIT="claude-gateway-tunnel.timer"

# Print the Usage block above verbatim. Range-matched on CONTENT between two
# sentinels, never on line numbers — ensure-fleet-tunnel.sh's `sed -n '43,52p'`
# silently printed the wrong ten lines the moment anything above it grew.
usage() {
  sed -n '/^# Usage$/,/^# END-USAGE$/p' "$0" \
    | grep -v -e '^# -\{3,\}' -e '^# END-USAGE$' \
    | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    off|on|status)   CMD=$1; shift ;;
    --host)          HOSTKEY=${2:-}; HOSTKEY_SET=1; shift 2 ;;
    --check-request) CHECK_REQUEST=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "gateway-switch: unknown arg '$1'" >&2; usage >&2; exit 64 ;;
  esac
done

# No default subcommand, on purpose. `ensure-fleet-tunnel.sh` can safely default
# to its idempotent verb; here the verbs CHANGE FLEET ROUTING, so a bare
# invocation (or a typo that ate the argument) must never pick one.
if [ -z "$CMD" ]; then
  echo "gateway-switch: name a subcommand — off | on | status" >&2
  usage >&2
  exit 64
fi
# An EXPLICIT empty --host is an error, never a silent fallback to `hostname -s`
# (the same rule as ensure-fleet-tunnel.sh: an unset variable in a unit file
# expands to `--host ""`, and quietly acting on the wrong host's file is worse
# than refusing).
if [ "$HOSTKEY_SET" -eq 1 ] && [ -z "$HOSTKEY" ]; then
  echo "gateway-switch: --host was given an EMPTY value. Omit the flag to derive it from \`hostname -s\`." >&2
  exit 64
fi
[ -n "$HOSTKEY" ] || HOSTKEY=$(hostname -s)
if [ -z "$HOSTKEY" ]; then
  echo "gateway-switch: could not resolve a short hostname and --host was not given" >&2
  exit 64
fi

ZSHENV="$HOME/.$HOSTKEY.zshenv"

say()  { printf 'gateway-switch: %s\n' "$*"; }
warn() { printf 'gateway-switch: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# The file: recognising the export line, in both states
# ---------------------------------------------------------------------------
# The comment MARKER exists so `on` reverses exactly what `off` wrote. `on` also
# accepts a hand-commented line (`# export …`, `## export …`) so a manual bypass
# — which is what the zshenv's own comments tell you to do — is still reversible
# by this script.
MARKER='#gateway-switch:off# '
ACTIVE_RE='^[[:space:]]*export[[:space:]]+ANTHROPIC_BASE_URL[[:space:]]*='
# Line starts with '#', and somewhere after it comes `export ANTHROPIC_BASE_URL=`.
# The optional `(.*[[:space:]])?` is what lets the marker prefix through.
OFF_RE='^[[:space:]]*#[[:space:]]*(.*[[:space:]])?export[[:space:]]+ANTHROPIC_BASE_URL[[:space:]]*='

count_re() { # <regex> — 0 when nothing matches, never an error
  local n
  n=$(grep -cE "$1" "$ZSHENV") || n=0
  printf '%s' "$n"
}

# The configured value, read from whichever form the line is currently in. Read
# even when BYPASSED on purpose: `status` on a bypassed host should still be able
# to probe the gateway, because "is it safe to turn back on?" is the question you
# ask while it is off.
base_url_value() {
  grep -hE "$ACTIVE_RE|$OFF_RE" "$ZSHENV" | head -1 \
    | sed -E 's/.*ANTHROPIC_BASE_URL[[:space:]]*=[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# ---------------------------------------------------------------------------
# Preflight — refuse LOUDLY. Silence is the failure mode this replaces.
# ---------------------------------------------------------------------------
if [ ! -e "$ZSHENV" ]; then
  warn "REFUSING: no per-host zshenv at $ZSHENV"
  warn "  This host's routing is not held where this script looks. Check \`hostname -s\` (got '$HOSTKEY'), or pass --host."
  exit 65
fi
N_ACTIVE=$(count_re "$ACTIVE_RE")
N_OFF=$(count_re "$OFF_RE")
if [ "$N_ACTIVE" -eq 0 ] && [ "$N_OFF" -eq 0 ]; then
  warn "REFUSING: $ZSHENV exists but has no ANTHROPIC_BASE_URL export line, commented or not."
  warn "  There is nothing here to switch. If routing moved somewhere else, this script is looking at the wrong tier."
  exit 66
fi

BASE=$(base_url_value)
# The gateway route matches pathPrefix /claude and rewrites to /, so the probe
# path must keep the prefix that is already in the base URL. 401 is HEALTH here:
# a transparent passthrough with no key attached (agents/infra.md). Do not
# "fix" it to 200.
PROBE_URL="${BASE%/}/v1/models"
EXPECT_CODE=401

probe() { # -> exactly one HTTP code; 000 means nothing answered
  local code
  # No `2>/dev/null`: curl is output-bearing, and a suppressed failure here
  # would read as "no data" (repo rule 3). `-s` already keeps it quiet on the
  # ordinary refused-connection path.
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$PROBE_URL")
  printf '%s' "${code:-000}"
}

# ---------------------------------------------------------------------------
# Hazard A: write through the symlink, then PROVE it survived
# ---------------------------------------------------------------------------
write_through_symlink() { # <new-content-file>
  local was_link=0 before="" after=""
  if [ -L "$ZSHENV" ]; then was_link=1; before=$(readlink "$ZSHENV"); fi
  if ! cat "$1" > "$ZSHENV"; then
    warn "FAILED to write $ZSHENV — nothing else was changed"
    return 1
  fi
  if [ "$was_link" -eq 1 ]; then
    if [ ! -L "$ZSHENV" ]; then
      warn "FATAL: $ZSHENV WAS a symlink to '$before' and is now a regular file."
      warn "  The host is now detached from the repo. Restore with: ln -sfn '$before' '$ZSHENV'"
      return 1
    fi
    after=$(readlink "$ZSHENV")
    if [ "$after" != "$before" ]; then
      warn "FATAL: $ZSHENV's symlink target changed ('$before' -> '$after')"
      return 1
    fi
    say "symlink intact: $ZSHENV -> $before"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Hazard D: the tunnel timer, keyed on EXISTENCE, never on a hostname
# ---------------------------------------------------------------------------
timer_exists() {
  # `list-unit-files PATTERN --no-legend` prints nothing and exits 1 when the
  # pattern matches no unit (measured, systemd on Ubuntu 26.04). stdout is
  # discarded because we want the exit code; stderr stays visible.
  systemctl --user list-unit-files "$TIMER_UNIT" --no-legend --no-pager >/dev/null
}

timer_state() { # enabled|disabled|... — never an error
  local s
  s=$(systemctl --user is-enabled "$TIMER_UNIT") || true
  printf '%s' "${s:-unknown}"
}

# ---------------------------------------------------------------------------
# Hazard B: panes. Classify, then act on shells ONLY.
# ---------------------------------------------------------------------------
PANE_FMT='#{pane_id}|#{pane_current_command}|#{session_name}:#{window_name}.#{pane_index}|#{pane_pid}'
SHELL_RE='^-?(zsh|bash|sh|dash|ksh|fish)$'

list_panes() { # pane_id|cmd|label|pid per line, empty if there is no tmux
  command -v tmux >/dev/null || return 1
  tmux list-panes -a -F "$PANE_FMT"
}

# `unset` / `exec` in every pane that is genuinely at a prompt.
#
# C-u FIRST, and that is a deliberate trade. A shell pane can be holding
# half-typed text (on 2026-08-04 two of five panes were), and appending our
# command to it and pressing Enter executes something nobody wrote. C-u
# (kill-line in both zsh's and bash's default emacs bindings) costs an unsent
# draft; not sending it risks running garbage in a shell.
apply_to_panes() { # <verb: off|on>
  local panes id cmd label pid sent=0 skipped=0
  if ! panes=$(list_panes); then
    say "panes:      none reachable — no tmux on PATH, or no server running. New shells pick the file up on their own."
    return 0
  fi
  if [ -z "$panes" ]; then
    say "panes:      none — nothing to update in place."
    return 0
  fi
  while IFS='|' read -r id cmd label pid; do
    [ -n "$id" ] || continue
    # Hazard B, second half: never `exec` the shell that is running this script.
    if [ -n "${TMUX_PANE:-}" ] && [ "$id" = "$TMUX_PANE" ]; then
      say "  SKIP  $label ($id, $cmd) — this is MY OWN pane; run it here yourself when the script exits"
      skipped=$((skipped + 1))
      continue
    fi
    if ! printf '%s' "$cmd" | grep -Eq "$SHELL_RE"; then
      # Reported, never typed into. This is the list that needs a human.
      say "  MANUAL $label ($id) is running '$cmd' — typing into it would SUBMIT A PROMPT. Restart it by hand to pick up the change."
      skipped=$((skipped + 1))
      continue
    fi
    local keys
    if [ "$1" = "off" ]; then
      keys="unset ANTHROPIC_BASE_URL"
    else
      # `exec <that pane's own shell>`, not a hardcoded zsh: re-exec is what
      # re-reads the file, and it is enough in THIS direction because there is
      # nothing stale left to inherit.
      keys="exec ${cmd#-}"
    fi
    # `< /dev/null` so tmux cannot consume the pane table this loop is reading
    # from the here-string below — the classic `ssh`-inside-`while read` bug,
    # which here would silently update only the FIRST pane.
    if tmux send-keys -t "$id" C-u "$keys" Enter < /dev/null; then
      say "  sent   $label ($id): $keys"
      sent=$((sent + 1))
    else
      warn "  FAILED to send keys to $label ($id)"
    fi
  done <<< "$panes"
  say "panes: $sent updated, $skipped left for a human"
}

# ---------------------------------------------------------------------------
# The running-claude report: routing read from the PROCESS, not from the file
# ---------------------------------------------------------------------------
# /proc/<pid>/environ is the environment the process was EXEC'd with, which is
# the only honest answer to "is this session actually going through the
# gateway?" — the file says what the next shell will do, not what a days-old
# session is doing.
ppid_of() { # <pid>
  local v
  v=$(grep -m1 '^PPid:' "/proc/$1/status") || return 1
  printf '%s' "${v##*[[:space:]]}"
}

pane_for_pid() { # <pid> <pane table> — walk up until some pane's shell pid matches
  local p=$1 panes=$2 id cmd label pane_pid hops=0
  while [ -n "$p" ] && [ "$p" != "1" ] && [ "$p" != "0" ] && [ "$hops" -lt 40 ]; do
    while IFS='|' read -r id cmd label pane_pid; do
      [ -n "$pane_pid" ] || continue
      if [ "$pane_pid" = "$p" ]; then printf '%s (%s)' "$label" "$id"; return 0; fi
    done <<< "$panes"
    p=$(ppid_of "$p") || return 1
    hops=$((hops + 1))
  done
  return 1
}

report_claude_procs() {
  local pids panes p envs base hatch pane route
  # -x matches the COMMAND NAME exactly. A `-f claude` pattern would also match
  # this very script's own shell and every grep in the pipeline.
  pids=$( { pgrep -x claude || true; pgrep -x bwrap || true; } | sort -un )
  if [ -z "$pids" ]; then
    say "processes: no running claude/bwrap"
    return 0
  fi
  panes=$(list_panes) || panes=""
  say "processes: running claude/bwrap, routing read from /proc/<pid>/environ:"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -r "/proc/$p/environ" ]; then
      say "  pid $p — environ unreadable (another user's process on this shared box)"
      continue
    fi
    envs=$(tr '\0' '\n' < "/proc/$p/environ")
    base=$(printf '%s\n' "$envs" | grep -m1 '^ANTHROPIC_BASE_URL=' | cut -d= -f2-) || true
    hatch=$(printf '%s\n' "$envs" | grep -m1 '^CC_NO_GATEWAY=' | cut -d= -f2-) || true
    pane=$(pane_for_pid "$p" "$panes") || pane="pane unknown"
    if [ -n "$base" ]; then route="via $base"; else route="DIRECT (no ANTHROPIC_BASE_URL)"; fi
    printf '  pid %-8s %-30s %s%s\n' "$p" "$pane" "$route" \
      "${hatch:+   [CC_NO_GATEWAY=$hatch]}"
  done <<< "$pids"
  say "  ^ each session's routing was fixed at LAUNCH; editing the file does not move it. Restart it to re-route."
}

# ---------------------------------------------------------------------------
# status — read-only, and cheap
# ---------------------------------------------------------------------------
if [ "$CMD" = "status" ]; then
  say "host key:   $HOSTKEY"
  if [ -L "$ZSHENV" ]; then
    say "file:       $ZSHENV -> $(readlink "$ZSHENV")  (symlink)"
  else
    say "file:       $ZSHENV  (regular file — expected a symlink into ~/dotfiles; a previous \`sed -i\` may have detached it)"
  fi
  if [ "$N_ACTIVE" -gt 0 ]; then
    say "routing:    ON  — $N_ACTIVE active export line(s): ANTHROPIC_BASE_URL=$BASE"
  else
    say "routing:    OFF — bypassed, $N_OFF commented export line(s); configured value would be $BASE"
  fi
  if timer_exists; then
    say "timer:      $TIMER_UNIT exists, is-enabled=$(timer_state), is-active=$( { systemctl --user is-active "$TIMER_UNIT" || true; } | head -1)"
  else
    say "timer:      no $TIMER_UNIT on this host — nothing to toggle (that is normal off marketing-vps)"
  fi
  CODE=$(probe)
  if [ "$CODE" = "$EXPECT_CODE" ]; then
    say "probe:      $PROBE_URL -> $CODE (HEALTHY — 401 is a keyless passthrough reaching Anthropic)"
  elif [ "$CODE" = "000" ]; then
    say "probe:      $PROBE_URL -> 000 (NOTHING ANSWERED — the gateway is unreachable from here; \`on\` would leave this box with no claude)"
  else
    say "probe:      $PROBE_URL -> $CODE (UNEXPECTED — something answered but not $EXPECT_CODE. This is a real answer, not 'no data')"
  fi
  report_claude_procs
  if [ "$CHECK_REQUEST" -eq 1 ]; then
    say "end-to-end: issuing ONE real request (this is an LLM call) through the route the file declares"
    # `env -u CC_NO_GATEWAY` is MANDATORY. The hatch is EXPORTED, so a session
    # started with CC_NO_GATEWAY=1 hands it to every child: the request then
    # goes direct while looking like a passing gateway test. That exact false
    # pass happened on 2026-08-04.
    if [ "$N_ACTIVE" -gt 0 ]; then
      env -u CC_NO_GATEWAY ANTHROPIC_BASE_URL="$BASE" \
        claude --dangerously-skip-permissions -p 'reply with the single word OK' \
        && say "end-to-end: request completed through $BASE" \
        || { warn "end-to-end: the request FAILED through $BASE"; exit 3; }
    else
      env -u CC_NO_GATEWAY -u ANTHROPIC_BASE_URL \
        claude --dangerously-skip-permissions -p 'reply with the single word OK' \
        && say "end-to-end: request completed DIRECT (gateway bypassed)" \
        || { warn "end-to-end: the direct request FAILED"; exit 3; }
    fi
  else
    say "end-to-end: skipped (no LLM call). Add --check-request to spend one."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# off / on — the state-driven file edit, then the timer, then the panes
# ---------------------------------------------------------------------------
TMP=$(mktemp) || { warn "could not create a temp file"; exit 1; }
trap 'rm -f "$TMP"' EXIT

if [ "$CMD" = "off" ]; then
  if [ "$N_ACTIVE" -eq 0 ]; then
    # Hazard C. Nothing is written, so a second `off` cannot produce `## export`.
    say "file:       already bypassed ($N_OFF commented line(s) in $ZSHENV) — no write"
  else
    awk -v mark="$MARKER" -v re="$ACTIVE_RE" '
      $0 ~ re { print mark $0; next }
      { print }
    ' "$ZSHENV" > "$TMP" || { warn "awk failed; $ZSHENV untouched"; exit 1; }
    write_through_symlink "$TMP" || exit 1
    A=$(count_re "$ACTIVE_RE"); O=$(count_re "$OFF_RE")
    if [ "$A" -ne 0 ] || [ "$O" -lt "$N_ACTIVE" ]; then
      warn "POST-WRITE CHECK FAILED: $A active / $O commented after commenting $N_ACTIVE line(s)"
      exit 1
    fi
    say "file:       commented $N_ACTIVE export line(s) in $ZSHENV"
  fi
else
  if [ "$N_OFF" -eq 0 ]; then
    say "file:       already routed through the gateway ($N_ACTIVE active line(s) in $ZSHENV) — no write"
  else
    # Strips the marker when present, and otherwise any leading run of '#' and
    # spaces — so a hand-commented (or double-commented) line comes back too,
    # and comes back exactly once.
    awk -v mark="$MARKER" -v re="$OFF_RE" '
      index($0, mark) == 1 { print substr($0, length(mark) + 1); next }
      $0 ~ re { sub(/^[[:space:]]*#+[[:space:]]*/, ""); print; next }
      { print }
    ' "$ZSHENV" > "$TMP" || { warn "awk failed; $ZSHENV untouched"; exit 1; }
    write_through_symlink "$TMP" || exit 1
    A=$(count_re "$ACTIVE_RE"); O=$(count_re "$OFF_RE")
    if [ "$O" -ne 0 ] || [ "$A" -lt "$N_OFF" ]; then
      warn "POST-WRITE CHECK FAILED: $A active / $O commented after uncommenting $N_OFF line(s)"
      exit 1
    fi
    say "file:       uncommented $N_OFF export line(s) in $ZSHENV"
  fi
fi

if timer_exists; then
  STATE=$(timer_state)
  if [ "$CMD" = "off" ]; then
    if [ "$STATE" = "enabled" ]; then
      if systemctl --user disable --now "$TIMER_UNIT"; then
        say "timer:      disabled --now $TIMER_UNIT"
      else
        warn "timer:      FAILED to disable $TIMER_UNIT (the file edit already landed)"
      fi
    else
      say "timer:      $TIMER_UNIT already $STATE — no change"
    fi
  else
    if [ "$STATE" = "enabled" ]; then
      say "timer:      $TIMER_UNIT already enabled — no change"
    else
      if systemctl --user enable --now "$TIMER_UNIT"; then
        say "timer:      enabled --now $TIMER_UNIT"
      else
        warn "timer:      FAILED to enable $TIMER_UNIT — the tunnel will not open, and routing fails HARD"
      fi
    fi
  fi
else
  # Hazard D: this is the normal answer on zig-computer, not a problem.
  say "timer:      no $TIMER_UNIT on this host — skipping the tunnel step"
fi

apply_to_panes "$CMD"

# ---------------------------------------------------------------------------
# Verify. "I did a thing" is not "it works".
# ---------------------------------------------------------------------------
FINAL_ACTIVE=$(count_re "$ACTIVE_RE")
if [ "$CMD" = "off" ]; then
  if [ "$FINAL_ACTIVE" -ne 0 ]; then
    warn "VERIFY FAILED: $ZSHENV still has $FINAL_ACTIVE active export line(s)"
    exit 3
  fi
  say "DONE — bypassed. New shells go direct to api.anthropic.com."
  say "  Running claude sessions keep their old routing until restarted (see \`status\`)."
  exit 0
fi

if [ "$FINAL_ACTIVE" -eq 0 ]; then
  warn "VERIFY FAILED: $ZSHENV has no active export line after \`on\`"
  exit 3
fi
CODE=$(probe)
if [ "$CODE" = "$EXPECT_CODE" ]; then
  say "DONE — routing restored and $PROBE_URL answers $CODE. New shells go through the gateway."
  exit 0
fi
warn "ROUTING RESTORED, BUT THE GATEWAY DOES NOT ANSWER: $PROBE_URL -> $CODE (expected $EXPECT_CODE)."
warn "  Routing is FAIL-HARD with no fallback (dotfiles-ucl4), so this box now has NO working claude."
warn "  Fix the tunnel or run \`$0 off\` again:"
warn "    ~/dotfiles/agents/scheduler/ensure-fleet-tunnel.sh ensure --port 17017 --target 100.72.47.4:17017 --probe-path /claude/v1/models --expect 401"
exit 3
