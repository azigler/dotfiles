#!/bin/bash
# Test for pre-commit-checks.sh — git-add-A block, worktree-push guard,
# and the Bead-trailer block + meta-commit carve-out (dotfiles-5q1).
#
# Hook test convention (see test-worktree-guard.sh):
#   - tests live in dotfiles/agents/hooks/test/test-<hook>.sh
#   - executable bash; non-zero exit = test failed
#   - prints a PASS/FAIL summary on the last line
#
# The hook runs real `git` in its process cwd, so cases run from a
# NON-git temp dir — `git diff --cached` then fails cleanly, the staged
# lint is skipped, and each case exercises the command-parsing logic in
# isolation. `br` is stubbed to a no-op.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/pre-commit-checks.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# Stub `br` so `br sync` is a hermetic no-op.
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/br" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_DIR/br"
export PATH="$STUB_DIR:$PATH"

# A non-git working dir to run the hook from.
NONGIT=$(mktemp -d)

# A git repo WITH .beads/ — the Bead-trailer gate only applies in beads
# projects (guard added 2026-06-09), so trailer cases run from here.
BEADSREPO=$(mktemp -d)
git -C "$BEADSREPO" init -q
mkdir "$BEADSREPO/.beads"

trap 'rm -rf "$STUB_DIR" "$NONGIT" "$BEADSREPO"' EXIT

WT='/tmp/proj/.claude/worktrees/agent-test'

# Run the hook from a given dir; capture exit + stderr.
run_case_in() {
  local dir=$1 name=$2 want_exit=$3 payload=$4 want_stderr=${5:-}
  local stderr_out
  stderr_out=$( cd "$dir" && echo "$payload" | "$HOOK" 2>&1 >/dev/null )
  local got_exit=$?

  if [ "$got_exit" -ne "$want_exit" ]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (exit: want $want_exit, got $got_exit)")
    return
  fi
  if [ -n "$want_stderr" ] && ! echo "$stderr_out" | grep -qF "$want_stderr"; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name (stderr missing: $want_stderr)")
    return
  fi
  PASS=$((PASS + 1))
}

# Back-compat helper: run from the non-git dir.
run_case() {
  local name=$1 want_exit=$2 payload=$3 want_stderr=${4:-}
  run_case_in "$NONGIT" "$name" "$want_exit" "$payload" "$want_stderr"
}


# --- git add discipline ---

# 1. git add -A → BLOCK
run_case "block: git add -A" 2 \
  '{"tool_input":{"command":"git add -A"},"cwd":"/tmp"}' \
  "never 'git add ."

# 2. git add . → BLOCK
run_case "block: git add ." 2 \
  '{"tool_input":{"command":"git add ."},"cwd":"/tmp"}' \
  "never 'git add ."

# 3. git add <specific file> → ALLOW (not a commit, not broad)
run_case "allow: git add specific file" 0 \
  '{"tool_input":{"command":"git add foo.md"},"cwd":"/tmp"}'

# --- worktree push guard ---

# 4. git push from inside a worktree → BLOCK
run_case "block: git push from a worktree" 2 \
  "{\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$WT\"}" \
  "from inside a worktree"

# 5. git push from project root → ALLOW
run_case "allow: git push from project root" 0 \
  '{"tool_input":{"command":"git push"},"cwd":"/tmp"}'

# --- Bead-trailer block + meta-commit carve-out (beads repos only) ---

# 6. commit WITH a Bead: trailer → ALLOW
run_case_in "$BEADSREPO" "allow: commit with Bead trailer" 0 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\" -m \"Bead: bd-x\""},"cwd":"/tmp"}'

# 7. commit with NO trailer and a normal gitmoji, in a beads repo → BLOCK
run_case_in "$BEADSREPO" "block: commit with no Bead trailer" 2 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\""},"cwd":"/tmp"}' \
  "no 'Bead: <id>' trailer"

# 8. :card_file_box: bead-state meta-commit (no trailer) → ALLOW (exempt)
run_case_in "$BEADSREPO" "allow: card_file_box meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":card_file_box: beads: close bd-x\""},"cwd":"/tmp"}'

# 9. :broom: triage meta-commit (no trailer) → ALLOW (exempt)
run_case_in "$BEADSREPO" "allow: broom triage meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":broom: triage: 3 closed\""},"cwd":"/tmp"}'

# 10. :outbox_tray: distribute meta-commit (no trailer) → ALLOW (exempt)
run_case_in "$BEADSREPO" "allow: outbox_tray distribute meta-commit exempt" 0 \
  '{"tool_input":{"command":"git commit -m \":outbox_tray: distribute: sync from dotfiles\""},"cwd":"/tmp"}'

# 11. unrelated command → no-op
run_case "allow: unrelated command" 0 \
  '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'

# 12. trailer-less commit in a NON-beads context → ALLOW (guard added
#     2026-06-09: the gate only applies where .beads/ exists; demanding
#     trailers in clones/scratch dirs trains the agent to fabricate them)
run_case "allow: trailer-less commit outside a beads repo" 0 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\""},"cwd":"/tmp"}'

# --- command-skeleton: verbs inside quoted args are not real commands (dotfiles-anm) ---
# A 'git commit' appearing inside a quoted argument/echo payload must NOT be
# treated as a real commit (it would hit the trailer gate and false-block).
# Run from BEADSREPO so the trailer gate is live: without the skeleton this
# matches the commit-case and blocks; with it, it's not a commit → exit 0.
run_case_in "$BEADSREPO" "allow: quoted 'git commit' in an arg is not a commit" 0 \
  '{"tool_input":{"command":"echo \"remember to && git commit later\" | cat"},"cwd":"/tmp"}'

# --- pulse-ledger 'done' proof gate (dotfiles-aek) ---
# A git repo (no .beads, so the trailer gate stays out of the way) with a
# committed ledger that already holds a legacy proofless `done` line — which
# must NOT be re-validated (only NEW lines vs HEAD are checked).
PROOFREPO=$(mktemp -d)
git -C "$PROOFREPO" init -q
git -C "$PROOFREPO" config user.email t@t; git -C "$PROOFREPO" config user.name t
mkdir "$PROOFREPO/refs"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"r","outcome":"done","note":"legacy no proof"}' > "$PROOFREPO/refs/pulse-ledger.jsonl"
echo "deliverable" > "$PROOFREPO/refs/real.md"
git -C "$PROOFREPO" add refs/pulse-ledger.jsonl refs/real.md
git -C "$PROOFREPO" commit -qm seed
PROOF_CMD='{"tool_input":{"command":"git commit refs/pulse-ledger.jsonl -m \":card_file_box: tick\""},"cwd":"/tmp"}'

# helper: append a ledger line, run the hook from PROOFREPO, reset the ledger
proof_case() {
  local name=$1 want_exit=$2 line=$3 want_stderr=${4:-}
  printf '%s\n' "$line" >> "$PROOFREPO/refs/pulse-ledger.jsonl"
  run_case_in "$PROOFREPO" "$name" "$want_exit" "$PROOF_CMD" "$want_stderr"
  git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl
}

# 13. done with NO proof → BLOCK
proof_case "block: done without proof" 2 \
  '{"ts":"2026-06-28T01:00:00Z","row":"r","outcome":"done","note":"x"}' \
  "no valid proof token"
# 14. done with artifact proof → BLOCK even when the file EXISTS (file-exists is a
#     stub-passable zero-distance no-op — rejected fleet-wide, explore-len0).
proof_case "block: done with artifact proof (rejected fleet-wide)" 2 \
  '{"ts":"2026-06-28T02:00:00Z","row":"r","outcome":"done","proof":{"kind":"artifact","path":"refs/real.md"},"note":"x"}' \
  "stub-passable"
# 15. done with commit proof → BLOCK even when the sha RESOLVES (sha-resolves is a
#     no-op every real commit passes — rejected fleet-wide, explore-len0).
proof_case "block: done with commit proof (rejected fleet-wide)" 2 \
  '{"ts":"2026-06-28T03:00:00Z","row":"r","outcome":"done","proof":{"kind":"commit","sha":"HEAD"},"note":"x"}' \
  "proves PROGRESS, not done"
# 16. done with cmd proof that passes → ALLOW (the hook re-runs it)
proof_case "allow: done with passing cmd proof" 0 \
  '{"ts":"2026-06-28T04:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"test -e refs/real.md"},"note":"x"}'
# 17. done with cmd proof that fails → BLOCK
proof_case "block: done with failing cmd proof" 2 \
  '{"ts":"2026-06-28T05:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"test -e refs/nope.md"},"note":"x"}' \
  "proof cmd exited"
# 18. quiet line with no proof → ALLOW (exempt)
proof_case "allow: quiet line exempt from proof" 0 \
  '{"ts":"2026-06-28T06:00:00Z","row":null,"outcome":"quiet","note":"x"}'
# 19. a commit NOT touching a pulse-ledger is unaffected by the gate
run_case_in "$PROOFREPO" "allow: non-ledger commit unaffected" 0 \
  '{"tool_input":{"command":"git commit refs/real.md -m \":card_file_box: x\""},"cwd":"/tmp"}'

# --- proof-gate diagnostics + time budget (dotfiles-b9ii, bug 4c) ---------
# The proof ran as `timeout 60 bash -c "$C" &>/dev/null`, so a blocked commit
# said only "proof cmd failed" and the author had to re-run the command by
# hand to learn why. And each proof got its own 60s inside a PreToolUse hook
# whose OWN ceiling is 120s, so 2+ slow proofs blew the hook itself and the
# commit failed opaquely, with nothing pointing at the proof gate.

# 20. a failing proof now SHOWS the proof's own output.
proof_case "block: failing proof surfaces its output" 2 \
  '{"ts":"2026-06-28T07:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"echo THE-PROOF-SAID-THIS; exit 7"},"note":"x"}' \
  "THE-PROOF-SAID-THIS"

# 21. ...and names the exit code.
proof_case "block: failing proof reports the exit code" 2 \
  '{"ts":"2026-06-28T08:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"exit 7"},"note":"x"}' \
  "exited 7"

# Env-passing variant of run_case_in, for the budget cases.
run_case_env() {
  local dir=$1 name=$2 want_exit=$3 payload=$4 want_stderr=$5; shift 5
  local stderr_out got_exit
  stderr_out=$( cd "$dir" && echo "$payload" | env "$@" "$HOOK" 2>&1 >/dev/null )
  got_exit=$?
  if [ "$got_exit" -ne "$want_exit" ]; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (exit: want $want_exit, got $got_exit)"); return
  fi
  if [ -n "$want_stderr" ] && ! echo "$stderr_out" | grep -qF "$want_stderr"; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name (stderr missing: $want_stderr)"); return
  fi
  PASS=$((PASS + 1))
}

# 22. a proof that outruns the budget is reported AS a timeout, not as a
#     mystery — and the hook still returns (it does not run to the harness's
#     own 120s ceiling).
printf '%s\n' '{"ts":"2026-06-28T09:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"sleep 30"},"note":"x"}' \
  >> "$PROOFREPO/refs/pulse-ledger.jsonl"
run_case_env "$PROOFREPO" "block: slow proof times out inside the budget" 2 \
  "$PROOF_CMD" "timed out after 1s" HARNESS_PULSE_PROOF_BUDGET=1
git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl

# 23. with the budget already spent by an earlier proof, the NEXT one says so
#     instead of silently eating another 60 seconds.
printf '%s\n%s\n' \
  '{"ts":"2026-06-28T10:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"sleep 30"},"note":"first"}' \
  '{"ts":"2026-06-28T10:00:01Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"true"},"note":"second"}' \
  >> "$PROOFREPO/refs/pulse-ledger.jsonl"
run_case_env "$PROOFREPO" "block: exhausted proof budget is named" 2 \
  "$PROOF_CMD" "proof budget" HARNESS_PULSE_PROOF_BUDGET=1
git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl

rm -rf "$PROOFREPO"

# --- paths containing spaces (dotfiles-b9ii, bug 4a/4b) -------------------
# Two independent word-splitting bugs, both of which changed the VERDICT:
#   a) `$JS_FILES` / `$PY_FILES` were passed to the linters unquoted, so one
#      path with a space became two nonexistent files, the linter errored,
#      and a perfectly clean commit was BLOCKED.
#   b) `for L in $LEDGERS` split ledger paths the same way, so the proof gate
#      silently SKIPPED a ledger in a directory with a space — the more
#      dangerous direction: an unproven `done` sailed through.

SPACEREPO=$(mktemp -d "$HOME/.pcc-space-test.XXXXXX")
git -C "$SPACEREPO" init -q
git -C "$SPACEREPO" config user.email t@t; git -C "$SPACEREPO" config user.name t
mkdir -p "$SPACEREPO/my dir"
printf 'x = 1\nprint(x)\n' > "$SPACEREPO/my dir/ok.py"
printf 'const x = 1;\nconsole.log(x);\n' > "$SPACEREPO/my dir/ok.js"
git -C "$SPACEREPO" add "my dir/ok.py" "my dir/ok.js"

# 24. lint-clean files in a directory with a space → ALLOW.
run_case_in "$SPACEREPO" "allow: clean staged files whose path has a space" 0 \
  '{"tool_input":{"command":"git commit -m \":sparkles: x: y\""},"cwd":"/tmp"}'

# 25. a genuinely dirty py file at a spaced path must STILL block — the fix
#     must not have simply disabled the linters.
printf 'import os\n\n\ndef f():\n    return undefined_name\n' > "$SPACEREPO/my dir/bad.py"
git -C "$SPACEREPO" add "my dir/bad.py"
if command -v ruff >/dev/null 2>&1; then
  run_case_in "$SPACEREPO" "block: violating py at a spaced path still blocks" 2 \
    '{"tool_input":{"command":"git commit -m \":sparkles: x: y\""},"cwd":"/tmp"}' \
    "ruff:"
fi
rm -rf "$SPACEREPO"

# 26. a pulse-ledger in a directory with a space is still GATED (pre-fix the
#     path split and the whole ledger was skipped → unproven done allowed).
SPACELEDGER=$(mktemp -d "$HOME/.pcc-spaceledger.XXXXXX")
git -C "$SPACELEDGER" init -q
git -C "$SPACELEDGER" config user.email t@t; git -C "$SPACELEDGER" config user.name t
mkdir -p "$SPACELEDGER/my refs"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"r","outcome":"quiet"}' > "$SPACELEDGER/my refs/pulse-ledger.jsonl"
git -C "$SPACELEDGER" add "my refs/pulse-ledger.jsonl"
git -C "$SPACELEDGER" commit -qm seed
printf '%s\n' '{"ts":"2026-06-28T11:00:00Z","row":"r","outcome":"done","note":"no proof"}' \
  >> "$SPACELEDGER/my refs/pulse-ledger.jsonl"
# Staged, so the gate finds it via `git diff --cached --name-only` — the
# primary discovery path, and the one the `for L in $LEDGERS` split broke.
# (The `git ls-files` fallback cannot help here anyway: a path with a space
# must be QUOTED in the command, and command_skeleton blanks quoted args.)
git -C "$SPACELEDGER" add "my refs/pulse-ledger.jsonl"
run_case_in "$SPACELEDGER" "block: unproven done in a spaced ledger path" 2 \
  '{"tool_input":{"command":"git commit -m \":card_file_box: tick\""},"cwd":"/tmp"}' \
  "no valid proof token"
rm -rf "$SPACELEDGER"

# --- command_skeleton lexing: false blocks vs. real blocks (vo3t / aj83) ---
#
# These run against the REAL hook, not the helper, because the defect that
# matters is the hook's verdict. The unit-level contract for the lexer itself
# is in test-hook-helpers.sh.
#
# Both directions are asserted deliberately. The bug was a gate refusing
# legitimate commands (which taught three separate agents to route around it),
# and the tempting fix — strip more — silently removes real violations from
# the gate's view. Every "allow" case below is paired with a "block" case in
# the same syntactic position.

# Build a payload from an arbitrary (possibly multi-line, quote-laden) command.
pl() { jq -cn --arg c "$1" '{tool_input:{command:$c},cwd:"/tmp"}'; }

# 27. dotfiles-vo3t, THE headline case: /commit SKILL.md:71 documents this
#     line, and the hook refused it — matching the flag inside the very
#     comment that warns agents not to use the flag.
run_case "allow: the documented /commit line with its NEVER-git-add-A comment" 0 \
  "$(pl 'git add <specific-files>                       # NEVER git add -A')"

# 28-32. A GENUINE all-staging command stays blocked from every position.
run_case "block: git add -A after &&" 2 \
  "$(pl 'git status && git add -A')" "never 'git add ."

run_case "block: git add --all after ;" 2 \
  "$(pl 'git status ; git add --all')" "never 'git add ."

# `$( … )` and backticks were a REAL HOLE before this fix: the old skeleton
# left `$(` glued to the verb, so no hook's word-boundary ever matched and the
# command was silently allowed. Verified against the pre-fix hook.
run_case "block: git add -A inside a command substitution" 2 \
  "$(pl 'echo $(git add -A)')" "never 'git add ."

run_case "block: git add -A inside a backtick substitution" 2 \
  "$(pl 'echo `git add -A`')" "never 'git add ."

run_case "block: git add -A as the second command in a pipeline" 2 \
  "$(pl 'printf x | git add -A')" "never 'git add ."

# 33-35. A MENTION of the flag is not a command.
run_case "allow: the flag inside a double-quoted string" 0 \
  "$(pl 'echo "do not run git add -A here" && git status')"

run_case "allow: the flag inside a single-quoted string" 0 \
  "$(pl "echo 'do not run git add -A here' && git status")"

run_case "allow: the flag after a # that opens a real comment" 0 \
  "$(pl 'git status   # do not git add -A ever')"

# 36. A `#` INSIDE a quoted string is not a comment — so the rest of the
#     string stays blanked and a later real command is still seen.
run_case "block: quoted # does not turn the rest of the line into a comment" 2 \
  "$(pl 'echo "a # b" && git add -A')" "never 'git add ."

# 37-38. dotfiles-vo3t, confirmed live: heredoc BODIES are data. The hook
#     blocked the very command that filed the bug report, because the report's
#     prose named the flag inside a quoted heredoc.
run_case "allow: heredoc body naming the flag (the bug report that got blocked)" 0 \
  "$(pl 'br create -p 1 "hooks: skeleton bug" -d "$(cat <<'"'"'EOF'"'"'
The 5" rule aside: the hook matches git add -A inside the warning comment.
EOF
)"')"

run_case "allow: plain heredoc body naming the flag" 0 \
  "$(pl 'cat > refs/rules.md <<EOF
Stage by name; never git add -A in this repo.
EOF')"

# 39. …but code AFTER the heredoc terminator is still code.
run_case "block: git add -A after a heredoc terminator" 2 \
  "$(pl 'cat > refs/rules.md <<EOF
body
EOF
git add -A')" "never 'git add ."

# 40. dotfiles-aj83: an ODD number of `"` characters in a commit message used
#     to misalign the blanking span and expose the text after it. Here the
#     third quote is an ESCAPED one, so the message is a single well-formed
#     argument — the old pairing read it as two and left the tail bare.
run_case "allow: odd-quote commit message does not expose the flag" 0 \
  "$(pl 'git commit -m "he said \" then claimed git add -A is fine"')"

# 41. The other half of that: a quote that genuinely CLOSES the string leaves
#     what follows as real code, and the gate must still see it. (This is what
#     bash does too — an unterminated tail is a syntax error, not a hiding place.)
run_case "block: text after a genuinely closed quote is still code" 2 \
  "$(pl 'git commit -m "note" && git add -A')" "never 'git add ."

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
