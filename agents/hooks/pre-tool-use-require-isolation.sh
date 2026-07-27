#!/bin/bash
# PreToolUse (Agent): require `isolation` on code-writing subagent dispatches.
#
# Background (2026-07-13, dashboard-dev-interrupted):
# The Agent tool's `subagent_type: "subagent"` selects the code-writing agent
# DEFINITION (tool set, no-nested-agents rule, lint/commit hooks) but does NOT
# by itself create an isolated worktree — that only happens when the dispatch
# also passes `isolation: "worktree"`. Omitting `isolation` runs the subagent
# in the ORCHESTRATOR'S cwd. Two such agents dispatched together then share one
# working dir + one git index and RACE (one agent's `git commit` swept the
# sibling's staged files; an interleaved orchestrator commit landed on the
# wrong branch). The failure is SILENT — no error — which is why it needs a
# mechanical guard, not just the CLAUDE.md rule.
#
# Rule enforced: if this is an Agent call with subagent_type == "subagent",
# `isolation` MUST be "worktree" (or "remote" — remote agents are isolated by
# nature). Absent/other isolation is BLOCKED.
#
# Scope: ONLY subagent_type == "subagent" is required to isolate. Built-in
# read-only types (Explore, Plan, general-purpose used for /scrutinize) run in
# the orchestrator cwd deliberately and are ALLOWED without isolation.
#
# ⚠️ WHAT THIS HOOK DOES NOT COVER — CROSS-REPO DISPATCH (dotfiles-xype,
# 2026-07-27, found live dispatching from ~/hevyd into ~/harnessd).
# The worktree is created from the ORCHESTRATOR'S repo. When the work lives in a
# DIFFERENT repo, satisfying this hook produces a worktree the agent never uses
# while it writes directly into the other repo's shared checkout — precisely the
# hazard this hook exists to prevent, now invisible to it. The dispatch reads as
# guarded and is not.
#
# Deliberately NOT fixed by scanning the prompt for foreign repo paths: a prompt
# routinely MENTIONS other repos ("read ~/explore/.claude/skills/INDEX.md"), so a
# path-scanning blocker would false-positive on ordinary dispatches — a guard that
# cries wolf gets worked around, which is worse than a documented gap. The posture
# is therefore: this hook guards SAME-REPO dispatch, and cross-repo concurrency is
# the orchestrator's responsibility (see the message below and the Delegation
# section of ~/.claude/CLAUDE.md).
#
# One cross-repo agent is safe — there is no second writer. TWO targeting the same
# foreign repo would race silently and this hook would pass both.
#
# Behavior:
#   - exit 0 = allow the tool call
#   - exit 2 = BLOCK and surface stderr to the agent
# Fail-OPEN: any parse ambiguity allows the call, so a hook bug can never wedge
# all dispatches.
#
# Test: ~/.claude/hooks/test/test-require-isolation.sh

INPUT=$(cat 2>/dev/null || echo '{}')

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Only act on Agent dispatches; everything else passes.
[ "$TOOL_NAME" = "Agent" ] || exit 0

SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)

# Only the code-writing "subagent" type must isolate. Built-in read-only types
# (Explore, Plan, general-purpose, etc.) are allowed in-cwd.
[ "$SUBAGENT_TYPE" = "subagent" ] || exit 0

ISOLATION=$(echo "$INPUT" | jq -r '.tool_input.isolation // empty' 2>/dev/null)

case "$ISOLATION" in
  worktree|remote) exit 0 ;;  # properly isolated
esac

# subagent_type == "subagent" with no (or unrecognized) isolation → BLOCK.
cat >&2 <<'EOF'
Blocked: Agent dispatch with subagent_type:"subagent" is missing isolation:"worktree".

A "subagent" writes code and MUST run in its own git worktree. Without
`isolation: "worktree"` the subagent runs in the orchestrator's OWN working
directory and shares one git index — two such agents will race and corrupt
each other's commits (silent failure; see
~/.claude/hooks/pre-tool-use-require-isolation.sh for the incident).

Fix: re-dispatch with BOTH parameters:
  subagent_type: "subagent"
  isolation: "worktree"

(If you truly need a read-only agent in the current dir, use a built-in type
like Explore or general-purpose instead of "subagent".)

SCOPE — this guard covers SAME-REPO dispatch only (dotfiles-xype). The worktree
is cut from the ORCHESTRATOR'S repo, so if the work lives in a DIFFERENT repo the
agent gets a worktree it will not use and writes into that repo's shared checkout
instead. This hook cannot see that and will pass it. One such agent is safe (no
second writer); TWO targeting the same foreign repo race silently. If you are
dispatching cross-repo, run them ONE AT A TIME and say so in the prompt.
EOF
exit 2
