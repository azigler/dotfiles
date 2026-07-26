#!/bin/bash
# Test for pre-bash-stderr-guard.sh — the PreToolUse:Bash gate that blocks
# blanket stderr suppression on state-changing / output-bearing commands.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# This hook runs on EVERY Bash call for every agent in the fleet, so it has two
# equally-expensive failure modes and both are covered here:
#
#   MISSED BLOCK — the reason the guard exists. On 2026-07-07 a sandbox test's
#     `git config --global … >/dev/null 2>&1` silently clobbered the machine git
#     identity. The BLOCK_* cases pin that class.
#   FALSE BLOCK — the reason it got fixed (explore-yfn4). The guard matched
#     suppression patterns and risky verbs inside QUOTED TEXT and split segments
#     on `|` characters inside string literals, so writing a bead *about* the
#     stderr rule tripped the stderr rule — and markdown tables in bead bodies
#     made it worse, since a table row is made of pipes. The PASS_* prose cases
#     pin that class. A gate that blocks prose teaches agents to route around
#     the gate, which costs more than the block it saved.
#
# NEGATIVE CONTROL (run 2026-07-26): with the fix reverted — matching on the raw
# command instead of `command_skeleton` — this suite scores 17/22. The five
# failures are all "prose that mentions the rule" ALLOW cases; every BLOCK case
# still passes, i.e. the fix removes false blocks without loosening the control.
# Two of the yfn4 cases pass either way (the heredoc-prose one only because of
# where the punctuation falls, the pipe-table one because splitting on `|` had
# already separated verb from suppression); they are kept as regression pins,
# not as discriminators. Re-run the control before trusting any change here — a
# test that passes with AND without the fix proves nothing.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-bash-stderr-guard.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# fire <command> -> exit code of the hook (0 = allowed, 2 = blocked)
fire() {
  printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" >/dev/null 2>&1
  echo $?
}

# blocks <name> <command>   — the guard MUST refuse this
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

# allows <name> <command>   — the guard MUST stay out of the way
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

# --- MUST BLOCK: real suppression on a state-changing verb ------------------
# These are the guard's whole reason for existing. Any change that lets one of
# these through has disabled the control, not fixed it.

blocks "git config --global (the 2026-07-07 incident)" \
  'git config --global user.email x >/dev/null 2>&1'

blocks "curl POST" \
  'curl -X POST https://example.com/api 2>/dev/null'

blocks "systemctl restart" \
  'systemctl --user restart foo.service 2>/dev/null'

blocks "git push" \
  'git push origin main 2>/dev/null'

blocks "&>/dev/null form" \
  'git commit -m msg &>/dev/null'

blocks "risky verb after && in a chain" \
  'cd /tmp && git push origin main 2>/dev/null'

blocks "risky verb inside a command substitution" \
  'OUT=$(curl -sS https://example.com 2>/dev/null)'

blocks "suppression + risky verb still caught with prose elsewhere" \
  'git commit -m "a message about nothing in particular" >/dev/null 2>&1'

# --- MUST ALLOW: legitimate exit-code-only probes ---------------------------

allows "command -v probe" 'command -v jq 2>/dev/null'
allows "tmux has-session probe" 'tmux has-session -t work 2>/dev/null'
allows "git rev-parse probe (read-only git)" 'git rev-parse --git-dir 2>/dev/null'
allows "escape hatch" 'git push origin main 2>/dev/null # allow-suppress'
allows "no suppression at all" 'git push origin main'
allows "cross-segment: suppression and risky verb in DIFFERENT segments" \
  'command -v git 2>/dev/null && git push origin main'

# --- MUST ALLOW: prose that MENTIONS the rule (explore-yfn4) ----------------
# Nothing here executes a risky verb or suppresses anything — it is text about
# doing so. Every one of these was a live false block.

allows "yfn4: bead body, markdown table row naming the rule" \
  "$(cat <<'OUTER'
br create -t note "title" -d "$(cat <<'EOF'
| rule | why |
| never use 2>/dev/null on a git commit | it hides failures |
EOF
)"
OUTER
)"

allows "yfn4: bead body, prose naming the rule" \
  "$(cat <<'OUTER'
br create -t note "title" -d "$(cat <<'EOF'
The rule is: never use 2>/dev/null on a git push, ever.
EOF
)"
OUTER
)"

allows "yfn4: double-quoted prose argument" \
  'br create -t note "do not git push with 2>/dev/null attached"'

allows "yfn4: single-quoted prose argument" \
  "br create -t note 'avoid curl https://x 2>/dev/null in tests'"

allows "yfn4: commit message documenting the anti-pattern" \
  'git commit -m "docs: warn against systemctl restart foo 2>/dev/null"'

allows "yfn4: markdown table pipes around a risky verb" \
  'br create -d "| git config --global | 2>/dev/null | bad |"'

allows "yfn4: comment mentioning the anti-pattern" \
  'git status   # never do: git push origin main 2>/dev/null'

# --- Fail-open contract ----------------------------------------------------
# A broken guard must never block all Bash. Empty/absent command = allow.

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
