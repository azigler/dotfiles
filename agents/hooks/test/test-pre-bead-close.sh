#!/bin/bash
# Test for pre-bead-close.sh — lint gate (bd-8euh chained-cd, bd-w6sd
# dotted-ID), worktree guard, and scrutiny gate (dotfiles-m33).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# Stubbed `br`:
#   - `br lint <id>`  → exit 1 if <id> contains "bogus", else exit 0
#   - `br show <id>`  → "Type: <impl|bug|spec|epic>" if <id> contains that
#                       word (else "task"); a SHIP verdict line if it has
#                       "ship", an OVERRIDE line if it has "ovr"
#   - any other `br`  → exit 0

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-bead-close.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# --- Stub `br` ---
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/br" <<'STUB'
#!/bin/bash
# Record the cwd each invocation actually ran in, so the chained-`cd`
# target-resolution cases can assert WHICH bead store the gate evaluated.
[ -n "${BR_PWD_LOG:-}" ] && pwd -P >> "$BR_PWD_LOG"
case "${1:-}" in
  lint)
    case "${2:-}" in
      *bogus*) echo "Error: Issue not found: ${2:-}" >&2; exit 1 ;;
      *)       exit 0 ;;
    esac
    ;;
  show)
    case "${2:-}" in
      *impl*) echo "Owner: t · Type: impl" ;;
      *bug*)  echo "Owner: t · Type: bug" ;;
      *spec*) echo "Owner: t · Type: spec" ;;
      *epic*) echo "Owner: t · Type: epic" ;;
      *)      echo "Owner: t · Type: task" ;;
    esac
    case "${2:-}" in
      *reqlbl*) echo "Labels: scrutinize-required" ;;
    esac
    case "${2:-}" in
      *ship*) echo "## Scrutiny — 2026-05-21"; echo "Verdict: SHIP" ;;
      *ovr*)  echo "## Scrutiny — OVERRIDE: trivial mechanical change" ;;
      *game*) echo "We need scrutiny before we SHIP this" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_DIR/br"
trap 'rm -rf "$STUB_DIR"' EXIT
export PATH="$STUB_DIR:$PATH"

# Helper: run hook with payload, capture exit + stderr.
run_case() {
  local name=$1
  local want_exit=$2
  local payload=$3
  local want_stderr=${4:-}

  local stderr_out
  stderr_out=$(echo "$payload" | "$HOOK" 2>&1 >/dev/null)
  local got_exit=$?

  if [ "$got_exit" -ne "$want_exit" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (exit: want $want_exit, got $got_exit)")
    return
  fi

  if [ -n "$want_stderr" ]; then
    if ! echo "$stderr_out" | grep -qF "$want_stderr"; then
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$name (stderr missing: $want_stderr)")
      return
    fi
  fi

  PASS=$((PASS + 1))
}

WT='/tmp/proj/.claude/worktrees/agent-test'

# --- Lint gate (original behaviour) ---

# 1. Plain valid id → lint passes → exit 0
run_case "allow: plain valid id" 0 \
  '{"tool_input":{"command":"br close bd-iq81"},"cwd":"/tmp"}'

# 2. Plain bogus id → lint fails → exit 2 with Blocked
run_case "block: plain bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 3. Dotted valid id (bd-w6sd fix) → exit 0
run_case "allow: dotted valid id" 0 \
  '{"tool_input":{"command":"br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 4. Dotted bogus id → exit 2
run_case "block: dotted bogus id" 2 \
  '{"tool_input":{"command":"br close bd-bogus.99.99"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.99.99"

# 5. Chained cd + plain id (bd-8euh fix path) → exit 0
run_case "allow: chained cd + plain id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-iq81"},"cwd":"/tmp"}'

# 6. Chained cd + dotted id → exit 0
run_case "allow: chained cd + dotted id" 0 \
  '{"tool_input":{"command":"cd /tmp && br close bd-8wbz.11.10"},"cwd":"/tmp"}'

# 7. Chained cd + bogus dotted id → still blocks
run_case "block: chained cd + dotted bogus id" 2 \
  '{"tool_input":{"command":"cd /tmp && br close bd-bogus.1.2"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus.1.2"

# 8. Not a br close command at all → no-op (exit 0)
run_case "allow: unrelated bash command" 0 \
  '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'

# 9. br close with no id arg → no-op
run_case "allow: br close with no id" 0 \
  '{"tool_input":{"command":"br close"},"cwd":"/tmp"}'

# 10. Multiple ids, one bogus → blocks the whole
run_case "block: multi-id with one bogus" 2 \
  '{"tool_input":{"command":"br close bd-iq81 bd-bogus bd-w6sd"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# --- Reason-string scraping (dotfiles-c7j) ---

# 10a. Hyphenated words in the -r reason are NOT bead IDs → exit 0
run_case "allow: hyphenated words in close reason" 0 \
  '{"tool_input":{"command":"br close bd-iq81 -r \"Fixed fleet-wide via merge-jsonl.sh and session-start.sh wiring\""},"cwd":"/tmp"}'

# 10b. Bogus-looking token in the reason doesn't block a valid close
run_case "allow: bogus-looking token after -r flag" 0 \
  '{"tool_input":{"command":"br close bd-iq81 -r \"supersedes bd-bogus rationale\""},"cwd":"/tmp"}'

# 10c. Real bogus id BEFORE the flag still blocks
run_case "block: bogus id before -r flag" 2 \
  '{"tool_input":{"command":"br close bd-bogus -r \"some fleet-wide reason\""},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 10d. Chained closes with reasons: every segment's ids still linted
run_case "block: bogus id in second chained close segment" 2 \
  '{"tool_input":{"command":"br close bd-iq81 -r \"first fleet-wide reason\" && br close bd-bogus -r \"second reason\""},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# --- Worktree guard (dotfiles-m33) ---

# 11. br close from inside a worktree → BLOCK
run_case "block: br close in a worktree" 2 \
  "{\"tool_input\":{\"command\":\"br close bd-iq81\"},\"cwd\":\"$WT\"}" \
  "orchestrator-only"

# 12. br update --status from inside a worktree → BLOCK
run_case "block: br update --status in a worktree" 2 \
  "{\"tool_input\":{\"command\":\"br update bd-iq81 --status open\"},\"cwd\":\"$WT\"}" \
  "orchestrator-only"

# 13. br update --notes from inside a worktree → ALLOW (notes is permitted)
run_case "allow: br update --notes in a worktree" 0 \
  "{\"tool_input\":{\"command\":\"br update bd-iq81 --notes log\"},\"cwd\":\"$WT\"}"

# 14. br update --status OUTSIDE a worktree → ALLOW (orchestrator)
run_case "allow: br update --status outside a worktree" 0 \
  '{"tool_input":{"command":"br update bd-iq81 --status open"},"cwd":"/tmp"}'

# --- Scrutiny gate (dotfiles-m33) ---

# 15. close an -t impl bead with a SHIP verdict → ALLOW
run_case "allow: impl bead with SHIP verdict" 0 \
  '{"tool_input":{"command":"br close bd-implship"},"cwd":"/tmp"}'

# 16. close an -t impl bead with no verdict → BLOCK
run_case "block: impl bead with no scrutiny verdict" 2 \
  '{"tool_input":{"command":"br close bd-implbad"},"cwd":"/tmp"}' \
  "no recorded scrutiny verdict"

# 17. close an -t impl bead with an OVERRIDE verdict → ALLOW
run_case "allow: impl bead with OVERRIDE verdict" 0 \
  '{"tool_input":{"command":"br close bd-implovr"},"cwd":"/tmp"}'

# 18. prose mentioning scrutiny + SHIP on one line, but NO recorded
#     verdict → BLOCK (regression guard for the 2026-06-09 grep fix)
run_case "block: impl bead with gamed scrutiny prose" 2 \
  '{"tool_input":{"command":"br close bd-implgame"},"cwd":"/tmp"}' \
  "no recorded scrutiny verdict"

# --- scrutinize-required label gate (explore finding-beads opt in) ---

# 19. scrutinize-required label + SHIP verdict → ALLOW
run_case "allow: scrutinize-required bead with SHIP verdict" 0 \
  '{"tool_input":{"command":"br close bd-reqlblship"},"cwd":"/tmp"}'

# 20. scrutinize-required label + NO verdict → BLOCK (the new gate)
run_case "block: scrutinize-required bead with no verdict" 2 \
  '{"tool_input":{"command":"br close bd-reqlblbad"},"cwd":"/tmp"}' \
  "no recorded scrutiny verdict"

# 21. scrutinize-required label + OVERRIDE verdict → ALLOW
run_case "allow: scrutinize-required bead with OVERRIDE verdict" 0 \
  '{"tool_input":{"command":"br close bd-reqlblovr"},"cwd":"/tmp"}'

# 22. plain task, no label, no verdict → ALLOW (regression: unlabeled closes stay free)
run_case "allow: plain task without label or verdict" 0 \
  '{"tool_input":{"command":"br close bd-plainok"},"cwd":"/tmp"}'

# --- Chained `cd` target resolution (dotfiles-b9ii, bug 5) ---------------
# The hook follows a chained `cd <path>` so the lint/scrutiny gates evaluate
# the SAME bead store the command will target (bd-8euh). It normalized the
# scraped path with `tr -d ' '`, which deletes EVERY space — so
# `cd "/home/me/my project"` became "/home/me/myproject", the directory did
# not exist, the cd was skipped, and the gate silently graded the bead
# against whatever store sat at the HOOK's cwd. Observed end result: a
# well-formed bead blocked with a doubly-wrong message ("incomplete template
# sections", then "Beads not initialized").

SPACEDIR=$(mktemp -d "$HOME/.pbc target dir.XXXXXX")
PLAINDIR=$(mktemp -d "$HOME/.pbc-plain.XXXXXX")
BR_PWD_LOG=$(mktemp)
export BR_PWD_LOG
trap 'rm -rf "$STUB_DIR" "$SPACEDIR" "$PLAINDIR" "$BR_PWD_LOG"' EXIT

cd_payload() { # <cd-target-as-written> <bead-id>
  printf '{"tool_input":{"command":%s},"cwd":"/tmp"}' \
    "$(printf 'cd %s && br close %s' "$1" "$2" | jq -Rs .)"
}

assert_ran_in() { # <name> <expected-dir>
  if grep -qxF "$2" "$BR_PWD_LOG"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1 (br never ran in $2; ran in: $(tr '\n' ' ' < "$BR_PWD_LOG"))")
  fi
}

# 23. quoted target containing a space → allowed AND evaluated in that dir.
: > "$BR_PWD_LOG"
run_case "allow: chained cd into a quoted path with a space" 0 \
  "$(cd_payload "\"$SPACEDIR\"" bd-ok1)"
assert_ran_in "chained cd honors a spaced path" "$SPACEDIR"

# 24. single-quoted target containing a space → same.
: > "$BR_PWD_LOG"
run_case "allow: chained cd into a single-quoted spaced path" 0 \
  "$(cd_payload "'$SPACEDIR'" bd-ok2)"
assert_ran_in "chained cd honors a single-quoted spaced path" "$SPACEDIR"

# 25. an ordinary unquoted path still resolves (the trim must not over-trim).
: > "$BR_PWD_LOG"
run_case "allow: chained cd into a plain path" 0 \
  "$(cd_payload "$PLAINDIR" bd-ok3)"
assert_ran_in "chained cd honors a plain path" "$PLAINDIR"

# 26. the gate still BLOCKS a bad bead when it follows the cd — the fix must
#     not have turned the spaced-path case into a free pass.
: > "$BR_PWD_LOG"
run_case "block: bogus id still blocks after a spaced cd" 2 \
  "$(cd_payload "\"$SPACEDIR\"" bd-bogus1)" \
  "incomplete template sections"

# (BR_PWD_LOG stays exported — the EXIT trap still needs it, and no further
# cases run. The stub ignores it when unset.)

# --- command_skeleton lexing: a MENTION of `br close` is not a `br close` ---
#
# dotfiles-aj83 was found here: an odd number of `"` in a commit message left
# the blanking span misaligned, so `br close` inside the MESSAGE was seen as a
# real invocation and the worktree guard blocked the commit. The agent's
# workaround was to write commit messages containing no quote characters at
# all — the exact "trained to route around the gate" failure this fixes.

skel_payload() { jq -cn --arg c "$1" --arg d "$WT" '{tool_input:{command:$c},cwd:$d}'; }

# 27. aj83, the original symptom: an escaped `"` makes the quote count odd.
run_case "allow: escaped quotes in a commit message do not expose br close" 0 \
  "$(skel_payload 'git commit -m "he said \" then asked me to br close bd-x1"')"

# 28. aj83, the shape seen live: an odd `"` inside a HEREDOC commit body.
run_case "allow: odd quote in a heredoc commit body does not expose br close" 0 \
  "$(skel_payload 'git commit -m "$(cat <<'"'"'EOF'"'"'
:bug: hooks: the 5" rule, and br close gating stays untouched

Bead: dotfiles-vo3t
EOF
)"')"

# 29. …and the guard is NOT weakened: a real `br close` from a worktree still
#     blocks, including from inside a command substitution.
run_case "block: a real br close from a worktree still blocks" 2 \
  "$(skel_payload 'br close bd-x1')" \
  "from inside a worktree"

run_case "block: br close inside a command substitution still blocks" 2 \
  "$(skel_payload 'echo $(br close bd-x1)')" \
  "from inside a worktree"

# 30. a `#` comment mentioning br close is a comment, not a command.
run_case "allow: br close named in a trailing comment" 0 \
  "$(skel_payload 'git status   # the orchestrator will br close bd-x1 later')"

# --- Lint gate: named-vs-accepted field (explore-yfn4) --------------------
#
# The block reads `Missing: ## Acceptance Criteria`, which names a field `br`
# ALSO exposes as `--acceptance-criteria`. Verified against br 0.2.16: `br lint`
# reads the --description BODY ONLY. A bead with the --acceptance-criteria field
# populated still fails the lint; a bead whose --description contains the
# literal `## Acceptance Criteria` heading passes. (--notes and --design do not
# satisfy it either — the originally-reported `--notes` claim does NOT
# reproduce.) The gate is right; its remediation text was pointing at three
# flags, two of which cannot clear it.

# 31. the block message names the field that actually clears the lint.
run_case "block message points at --description, not the AC field" 2 \
  '{"tool_input":{"command":"br close bd-bogus"},"cwd":"/tmp"}' \
  "reads the --description body ONLY"

run_case "block message says the AC field does not clear it" 2 \
  '{"tool_input":{"command":"br close bd-bogus"},"cwd":"/tmp"}' \
  "does NOT clear it"

# 32. the chained-update skip fires for --description (the flag that can
#     actually satisfy the lint) — the dotfiles-90s clunk fix, unchanged.
run_case "allow: chained --description update skips the lint gate" 0 \
  '{"tool_input":{"command":"br update bd-bogus --description \"## Acceptance Criteria\" && br close bd-bogus"},"cwd":"/tmp"}'

# 33. …and NOT for --acceptance-criteria / --design, which cannot. Chaining
#     either used to buy a free close on a bead that still fails lint.
run_case "block: chained --acceptance-criteria does not skip the gate" 2 \
  '{"tool_input":{"command":"br update bd-bogus --acceptance-criteria=\" - [ ] x\" && br close bd-bogus"},"cwd":"/tmp"}' \
  "incomplete template sections"

run_case "block: chained --design does not skip the gate" 2 \
  '{"tool_input":{"command":"br update bd-bogus --design \"sketch\" && br close bd-bogus"},"cwd":"/tmp"}' \
  "incomplete template sections"

run_case "block: chained --notes does not skip the gate" 2 \
  '{"tool_input":{"command":"br update bd-bogus --notes \"log\" && br close bd-bogus"},"cwd":"/tmp"}' \
  "incomplete template sections"

# --- 34. Fix 3: the chained-`--description` skip must RE-CHECK the value ----
#
# The skip existed so `br update X --description "…## Acceptance Criteria…" &&
# br close X` would not false-block (PreToolUse fires before the update runs,
# so `br lint` still sees the pre-update state). But it fired UNCONDITIONALLY
# on seeing the flag and never looked at the value, so an agent that hit the
# block once and re-issued with prose bought a free close — a discoverable
# bypass sitting inside the gate (2026-07-26 audit §3.4). The skip now fires
# only when the command carries the sections `br lint` will demand for that
# bead's TYPE.
#
# NEGATIVE CONTROL (run 2026-07-26): with the unconditional skip restored, this
# suite scores 58/60 — the two failures are 34a and 34b below. 34c and 34d pass
# either way (they are ALLOW cases the old skip also allowed) and are kept as
# regression pins that the narrowing did not turn the clunk-fix back into a
# false block, not as discriminators.

# 34a. prose description, no Acceptance Criteria → the skip must NOT fire.
run_case "block: chained --description with prose only (the 3.4 bypass)" 2 \
  '{"tool_input":{"command":"br update bd-bogus --description \"just some prose about the work\" && br close bd-bogus"},"cwd":"/tmp"}' \
  "incomplete template sections"

# 34b. a bug bead needs BOTH sections; only one present → still blocked.
run_case "block: chained --description missing one of a bug's two sections" 2 \
  '{"tool_input":{"command":"br update bd-bogusbug --description \"## Acceptance Criteria\" && br close bd-bogusbug"},"cwd":"/tmp"}' \
  "incomplete template sections"

# 34c. …and with both, the skip fires (the dotfiles-90s clunk fix still works).
run_case "allow: chained --description with a bug's two sections" 0 \
  '{"tool_input":{"command":"br update bd-bogusbug --description \"## Steps to Reproduce ... ## Acceptance Criteria\" && br close bd-bogusbug"},"cwd":"/tmp"}'

# 34d. a type br templates NOTHING for (spec) — the skip fires on any body,
#      because `br lint` itself demands nothing there. Symmetry, not laxity.
run_case "allow: chained --description on a type with no template (spec)" 0 \
  '{"tool_input":{"command":"br update bd-bogusspec --description \"prose is fine here\" && br close bd-bogusspec"},"cwd":"/tmp"}'

# --- 35. Fix 1: the matcher must fire in the shapes the FLEET actually uses --
#
# The gate used to be a `case` glob that fired only when the command STARTED
# with `br close`, or contained a literal `&& br close` / `; br close`. The
# fleet's dominant idiom — `cd /home/ubuntu/<proj>` on line 1, `br close <id>`
# on line 2 — matched none of them. Measured bypass: 0% (Feb) → 48% (May/Jun) →
# 81% (Jul), 1,043 of 1,044 bypasses being that newline form. The hook reported
# itself installed the entire time.
#
# NEGATIVE CONTROL (run 2026-07-26): with the `case` glob restored, this suite
# scores 53/60. The seven failures are exactly the shapes the glob could not
# see: cd+newline, leading whitespace, a multi-line preamble, the for-loop
# batch, a command substitution, an if-block, and the scrutiny gate reached
# through the newline form. Every case that existed BEFORE this block passes
# either way — which is precisely why the bug survived two months: the suite
# only ever exercised the shape the gate was written in.
#
# The pipe and subshell cases below also pass either way (`br close X | tee`
# starts with the verb, and `(cd /x && br close X)` contains `&& br close`, so
# the old glob caught both). They are kept as regression pins for the id-scrape
# terminators, not as discriminators.

# 35a. THE shape: `cd <dir>` on its own line, then the close.
run_case "block: cd + NEWLINE + br close (the 81% bypass)" 2 \
  '{"tool_input":{"command":"cd /tmp\nbr close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

run_case "allow: cd + NEWLINE + br close on a clean bead" 0 \
  '{"tool_input":{"command":"cd /tmp\nbr close bd-iq81"},"cwd":"/tmp"}'

# 35b. leading whitespace / indentation.
run_case "block: leading whitespace before br close" 2 \
  '{"tool_input":{"command":"   br close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 35c. a multi-line preamble, not just a bare cd.
run_case "block: multi-line preamble then br close" 2 \
  '{"tool_input":{"command":"set -e\ncd /tmp\nbr close bd-bogus"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 35d. for-loop batch close — the ids live in the LOOP HEADER, not after the
#      verb, so the id scrape needs the loop-header fallback to see them.
run_case "block: for-loop batch close over literal ids" 2 \
  '{"tool_input":{"command":"for b in bd-iq81 bd-bogus; do br close $b; done"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

run_case "allow: for-loop batch close over clean ids" 0 \
  '{"tool_input":{"command":"for b in bd-iq81 bd-w6sd; do br close $b; done"},"cwd":"/tmp"}'

# 35e. pipe.
run_case "block: br close piped into another command" 2 \
  '{"tool_input":{"command":"br close bd-bogus | tee /dev/null"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 35f. subshell / command substitution — the scrape must not keep the `)`.
run_case "block: br close inside a subshell" 2 \
  '{"tool_input":{"command":"(cd /tmp && br close bd-bogus)"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

run_case "block: br close inside a command substitution" 2 \
  '{"tool_input":{"command":"OUT=$(br close bd-bogus)"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 35g. an if/then block (the `; br close` glob happened to cover this one).
run_case "block: br close inside an if block" 2 \
  '{"tool_input":{"command":"if true; then br close bd-bogus; fi"},"cwd":"/tmp"}' \
  "Blocked: bead bd-bogus"

# 35h. the scrutiny gate rides the same matcher, so it leaked identically.
run_case "block: impl bead with no verdict, closed via the newline form" 2 \
  '{"tool_input":{"command":"cd /tmp\nbr close bd-implbad"},"cwd":"/tmp"}' \
  "no recorded scrutiny verdict"

# 35i. …and a MENTION of br close in a newline-separated command still does not
#      count as one (the lexer contract must survive the wider matcher).
run_case "allow: newline command whose text merely mentions br close" 0 \
  '{"tool_input":{"command":"cd /tmp\ngit commit -m \"note: the orchestrator will br close bd-bogus later\""},"cwd":"/tmp"}'

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
