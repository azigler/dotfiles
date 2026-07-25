#!/bin/bash
# Shared context emission for the two hooks that (re-)orient an agent:
#   session-start.sh  (SessionStart / SubagentStart)
#   pre-compact.sh    (PreCompact)
#
# Source via:
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/context-emit.sh"
#
# Why this file exists (dotfiles-b9ii):
# Both hooks emitted branch + dirty-files + open-beads, but only
# session-start.sh had the bead CAP. pre-compact.sh ran an unbounded
# `br list` and injected 31,484 bytes (~7.9k tokens, 173 lines) into
# ~/explore — 12x session-start's payload, at the exact moment context is
# scarcest. Duplicated emission meant the cap fix had to be made twice and
# was made once. One implementation, two callers: the cap can't drift again.
#
# Everything here writes to STDOUT, which for these two hook events is
# injected verbatim into the agent's context. Treat every line as a charge
# against the context budget.

# emit_git_context
#   Branch + up-to-10 dirty files. No-op outside a git work tree.
emit_git_context() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local branch dirty
  branch=$(git branch --show-current 2>/dev/null)
  echo "Branch: ${branch:-detached}"
  dirty=$(git status --short 2>/dev/null | head -10)
  if [ -n "$dirty" ]; then
    echo "Dirty files:"
    echo "$dirty"
  fi
  return 0
}

# emit_bead_context [cap]
#   The capped open-bead banner. Cap precedence: $1 > $HARNESS_ONBOARD_BEAD_CAP
#   > 12. No-op when `br` is absent or the project has no bead store.
#
# The cap: an unbounded `br list` put 100+ open beads into EVERY session-start
# AND every compaction. We show the top N by priority plus a count of the rest.
# It is a GLOBAL cap (these hooks run for every project) that self-adjusts — it
# only truncates when the backlog exceeds the cap — and is overridable
# per-project via $HARNESS_ONBOARD_BEAD_CAP (e.g. in a project's .envrc).
# Display-only: never triages or closes anything.
#
# The truncation notice is load-bearing: aggressive truncation is safe ONLY
# because the agent has recourse — so it says the view is PARTIAL and to scan
# the full list JUST-IN-TIME, right before committing to meaningful work, NOT
# now. Pulling all 100+ up front is the exact bloat the cap prevents.
#
# Status filter: `open` + `in_progress` — everything not closed and not
# DEFERRED. A bare `br list` includes deferred beads, which are by definition
# "not now", so counting them made the banner overstate the live backlog
# (~/explore: 168 listed vs 144 actually live). in_progress is kept because a
# bead you are mid-way through is the single most relevant line on the banner.
emit_bead_context() {
  command -v br >/dev/null 2>&1 || return 0

  local cap list rc total
  cap=${1:-${HARNESS_ONBOARD_BEAD_CAP:-12}}

  # ONE `br` call: count and top-N are both derived from it in-shell. (Both
  # hooks used to invoke `br list` twice — once to count, once to display.)
  # Capturing to a variable also avoids the SIGPIPE panic `br | head` raises.
  list=$(br list --status open --status in_progress --limit 0 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # "Beads not initialized" = this project has no bead store. Expected,
    # extremely common, and correctly silent. ANY OTHER failure is real: a
    # blanket 2>/dev/null here would make a broken `br` read as "no beads"
    # (the silent-failure class this refactor exists to kill), so surface one
    # line and move on. Never fatal — a hook must not wedge a session.
    case "$list" in
      *"not initialized"*) return 0 ;;
      *)
        printf '\nOpen beads: UNAVAILABLE — `br list` exited %s: %s\n' \
          "$rc" "$(printf '%s' "$list" | head -1)"
        return 0
        ;;
    esac
  fi

  total=$(printf '%s\n' "$list" | grep -c .)
  [ "${total:-0}" -gt 0 ] || return 0

  echo ""
  if [ "$total" -gt "$cap" ]; then
    echo "Open beads — top $cap of $total by priority (truncated to protect context; NOT the full backlog):"
    printf '%s\n' "$list" | head -n "$cap"
    echo "  + $((total - cap)) more not shown — this is a PARTIAL view. Before you start anything"
    echo "    meaningful, scan the full backlog THEN (\`br list\` / \`bv --robot-triage\`) to catch a"
    echo "    higher-priority or duplicate item — do it at that point, not now."
  else
    echo "Open beads:"
    printf '%s\n' "$list"
  fi
  return 0
}

# context_emit_lib_loaded
#   Presence probe for callers that want to degrade loudly if this file is
#   missing rather than emit nothing at all.
context_emit_lib_loaded() { return 0; }
