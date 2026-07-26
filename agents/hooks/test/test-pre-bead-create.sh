#!/bin/bash
# Test for pre-bead-create.sh — the PreToolUse:Bash ENTRY gate that requires
# every `br create` / `br q` to carry a -d/--description containing the
# sections `br lint` (and therefore the close gate) will demand for that type.
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# The hook shells out to nothing — no `br` stub is needed. It reads only the
# command text.
#
# WHY THE ALLOW CASES ARE HALF THE SUITE. This hook runs on every Bash call in
# the fleet, and it gates the single most frequent bead operation. Its two
# failure modes cost about the same:
#
#   MISSED BLOCK — the reason it exists. 74% of `br create` calls carried no
#     -d, so beads were born owing a `## Acceptance Criteria` heading that got
#     collected months later from whoever tried to close them; 278 of 515 open
#     beads (54%) fail `br lint` today (2026-07-26 beads-lifecycle audit).
#   FALSE BLOCK — the reason it must be careful. Writing a bead ABOUT bead
#     creation, or a commit message naming the command, must not trip it — the
#     exact class that made pre-bash-stderr-guard.sh switch to the skeleton
#     lexer (explore-yfn4). A gate that blocks prose teaches agents to route
#     around the gate.
#
# NEGATIVE CONTROL (re-run 2026-07-26 at 42 cases): with the hook replaced by a
# bare `exit 0` — i.e. the pre-fix world, where nothing gated creation — this
# suite scores 25/42. The 17 failures are every BLOCK case (12) and every SAYS
# case (5); all 25 ALLOW cases pass, since an absent gate blocks nothing.
#
# A second, sharper control: with the gate intact but ONLY its `-d` presence
# check deleted, the suite scores 41/42 — one failure ("the second create in a
# chain is thin"). That is not slack in the suite, it is the shape of the gate:
# a bead with no -d also has no required section, so the section check catches
# nearly every no-description case on its own. The -d check earns its keep on
# the one case the section check structurally cannot see — a per-SEGMENT miss
# inside a chain, where an earlier compliant create's heading would otherwise
# satisfy the whole-command grep. Re-run both controls before trusting a change
# here.
#
# The per-type requirement table (lib/hook-helpers.sh bead_required_headings)
# was VERIFIED against br 0.2.16 by creating a bead of every type with an empty
# body in a scratch store and reading `br lint --status all`. The same probe
# showed `br lint` matches its sections as a CASE-INSENSITIVE PHRASE — `###
# Acceptance Criteria`, a trailing colon, lowercase, and a bare unhashed phrase
# all satisfy it — so this gate matches the same way. Matching stricter than
# `br` would block beads the close gate would happily accept, which is the wall
# this whole change exists to avoid.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-bead-create.sh"
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

# says <name> <command> <substring the block message MUST contain>
says() {
  local name=$1 cmd=$2 want=$3 out
  out=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" 2>&1 >/dev/null)
  # `--` is load-bearing: the strings this suite asserts on are FLAGS the gate
  # is teaching (`-d="- [ ] x"`), and without the terminator grep parses `-d=…`
  # as its own --directories option and dies with "invalid argument" — a green
  # message reported as a missing one. Exactly the class the audit is about: a
  # check that failed for a reason unrelated to the thing under test.
  if echo "$out" | grep -qF -- "$want"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("SAYS $name (message missing: $want)")
  fi
}

# --- MUST BLOCK: a bead born without its template ---------------------------

blocks "br create with no -d at all" \
  'br create -t task -p 2 "scope: thing"'

blocks "br q with no -d (quick capture is the same bypass)" \
  'br q "scope: quick thing"'

blocks "the fleet idiom: cd on line 1, br create on line 2" \
  'cd /home/ubuntu/explore
br create -t task "scope: thing"'

blocks "for-loop batch create with no -d" \
  'for s in a b c; do br create -t task "scope: $s"; done'

blocks "task with a description but no Acceptance Criteria" \
  'br create -t task "scope: thing" -d "some prose explaining the work"'

blocks "bug carrying only one of its two required sections" \
  'br create -t bug "scope: thing" -d "## Acceptance Criteria
- [ ] fixed"'

blocks "epic carrying Acceptance Criteria instead of Success Criteria" \
  'br create -t epic "scope: thing" -d "## Acceptance Criteria
- [ ] done"'

blocks "an explicitly empty -d" \
  'br create -t task "scope: thing" -d=""'

blocks "the second create in a chain is thin" \
  'br create -t task "a" -d "## Acceptance Criteria" && br create -t task "b"'

blocks "br q with prose but no Acceptance Criteria" \
  'br q -t task "scope: thing" -d "prose only"'

# `br create -f` bulk import: verified against br 0.2.16, `## <title>` is the
# ISSUE DELIMITER and `###` subsections are dropped from the body, so a
# bulk-imported bead cannot carry the template and is born un-closable. Zero
# real invocations in this fleet's transcript history, so refusing it costs
# nothing and shuts the obvious bypass.
blocks "br create -f (bulk markdown import)" 'br create -f beads.md'
blocks "br create --file= (long form)"       'br create --file=beads.md'

# --- MUST BLOCK, and the message must be USABLE -----------------------------
# The audit's own warning: a gate whose message does not tell the author how to
# comply trades one papercut for another. The leading-dash trap is the specific
# one — clap parses a -d value starting with "- " as a flag
# (error: unexpected argument '- ' found), which is a real dead end for an
# author trying to write `- [ ] …` acceptance criteria.

says "message names the missing section" \
  'br create -t bug "x" -d "## Acceptance Criteria"' \
  '## Steps to Reproduce'

says "message warns about the leading-dash trap" \
  'br create -t task "x"' \
  'LEADING-DASH TRAP'

says "message gives the -d= escape from the dash trap" \
  'br create -t task "x"' \
  '-d="- [ ] x"'

says "message explains why bulk import is refused" \
  'br create -f beads.md' \
  'ISSUE DELIMITER'

says "message names the escape hatch" \
  'br create -t task "x"' \
  '# allow-thin-bead'

# --- MUST ALLOW: a properly specified bead ----------------------------------

allows "task with the Acceptance Criteria heading" \
  'br create -t task -p 2 "scope: thing" -d "## Context
why this exists

## Acceptance Criteria
- [ ] concrete deliverable"'

allows "the heredoc idiom /beads documents" \
  "$(cat <<'OUTER'
br create -t task -p 2 "scope: thing" -d "$(cat <<'EOF'
## Context
why this exists

## Acceptance Criteria
- [ ] concrete deliverable
EOF
)"
OUTER
)"

allows "bug with both required sections" \
  'br create -t bug "scope: thing" -d "## Steps to Reproduce
1. do x

## Acceptance Criteria
- [ ] fixed"'

allows "epic with Success Criteria" \
  'br create -t epic "scope: thing" -d "## Success Criteria
- [ ] shipped"'

allows "feature with Acceptance Criteria" \
  'br create -t feature "scope: thing" -d "## Acceptance Criteria
- [ ] works"'

allows "br q with a full description" \
  'br q -t task "scope: thing" -d "## Acceptance Criteria
- [ ] y"'

# `br lint` matches its sections case-insensitively and without requiring
# hashes (verified 0.2.16). The gate must be no stricter, or it blocks beads
# that would close fine.
allows "h3 heading (br accepts it, so this must too)" \
  'br create -t task "x" -d "### Acceptance Criteria
- [ ] y"'

allows "lowercase heading (br accepts it, so this must too)" \
  'br create -t task "x" -d "## acceptance criteria
- [ ] y"'

allows "the -d= form that dodges the leading-dash trap" \
  'br create -t task "x" -d="- [ ] a thing. Acceptance Criteria: it works."'

# --- MUST ALLOW: types `br` templates nothing for ---------------------------
# Symmetry with the close gate, not laxity: `br lint` demands no sections from
# spec/decision/study/note/test/impl, so demanding them here would build the
# same wall this change exists to tear down — beads that cannot be created OR
# closed without ceremony `br` never asked for.

allows "spec bead with plain prose"     'br create -t spec "x" -d "the specification body"'
allows "decision bead with plain prose" 'br create -t decision "x" -d "Context / Decision / Why"'
allows "study bead with plain prose"    'br create -t study "x" -d "what I read and learned"'

# A QUOTED type is blanked by the skeleton, so the type is unknowable. Demand
# nothing rather than assume `task` and false-block a spec.
allows "quoted -t value (type unknowable, so demand nothing)" \
  'br create -t "decision" "x" -d "prose"'

# --- MUST ALLOW: not a creation at all --------------------------------------

allows "unrelated command"        'ls -la'
allows "br list"                  'br list --status open'
allows "br show"                  'br show explore-1234'
allows "br close"                 'br close explore-1234'
allows "br create --help"         'br create --help'
allows "br create --dry-run"      'br create -t task "x" --dry-run'

# --- MUST ALLOW: prose that MENTIONS creating a bead (explore-yfn4 class) ----

allows "commit message naming the command" \
  'git commit -m "hooks: gate br create on -d"'

allows "a bead body that talks about br create -f" \
  'br create -t note "x" -d "never reach for br create -f — bulk import drops the template"'

allows "a comment naming the command" \
  'br list   # then br create -t task for whatever is missing'

allows "echoing documentation about the rule" \
  'echo "the rule is: never run br create without -d"'

# --- Escape hatch + fail-open contract --------------------------------------

allows "escape hatch: # allow-thin-bead" \
  'br create -t task "scope: genuine quick capture" # allow-thin-bead'

allows "empty command (a broken gate must never block all Bash)" ''

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
