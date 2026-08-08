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

# Stub `br` so `br sync` is a hermetic no-op — and so `br show` replays a
# fixture bead body, which is what lets the kind:scrutinize proof cases below
# drive real verdict text through the gate (dotfiles-8aj5).
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/br" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "show" ]; then printf '%s\n' "${BR_SHOW_BODY:-}"; fi
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

# --- push gate keys on the BRANCH, not the cwd (dotfiles-5a46) ------------
#
# The gate used to `case` on the cwd alone, which was wrong in BOTH
# directions: it blocked a normal-branch push made from a worktree cwd (the
# cross-repo dispatch pattern, which agents then routed around with
# `git -C <path> push`), and it allowed a `worktree-agent-*` push made from
# a normal project root — the exact stale-remote-branch outcome it exists to
# prevent. Every case below is paired: a block and an allow in the same
# syntactic position.
#
# Fixtures: a real repo with a real worktree checked out on a real
# worktree-agent-* branch, plus a second, unrelated repo.

PUSHREPO=$(mktemp -d "${TMPDIR:-/tmp}/pcc-push.XXXXXX")
git -C "$PUSHREPO" init -q -b main
git -C "$PUSHREPO" config user.email t@t; git -C "$PUSHREPO" config user.name t
echo seed > "$PUSHREPO/f"; git -C "$PUSHREPO" add f; git -C "$PUSHREPO" commit -qm seed
PUSHWT="$PUSHREPO/.claude/worktrees/agent-test"
git -C "$PUSHREPO" worktree add -q -b worktree-agent-test "$PUSHWT" >/dev/null

OTHERREPO=$(mktemp -d "${TMPDIR:-/tmp}/pcc-other.XXXXXX")
git -C "$OTHERREPO" init -q -b main
git -C "$OTHERREPO" config user.email t@t; git -C "$OTHERREPO" config user.name t
echo seed > "$OTHERREPO/f"; git -C "$OTHERREPO" add f; git -C "$OTHERREPO" commit -qm seed

push_cleanup() {
  git -C "$PUSHREPO" worktree remove --force "$PUSHWT" >/dev/null 2>&1
  rm -rf "$PUSHREPO" "$OTHERREPO"
}

# JSON payload with an arbitrary command + cwd.
plc() { jq -cn --arg c "$1" --arg d "$2" '{tool_input:{command:$c},cwd:$d}'; }

# 5a. THE MISSED DIRECTION: a worktree-agent-* branch pushed from a normal
#     project root. The old cwd gate allowed this outright.
run_case "block: worktree-agent branch pushed from a project root" 2 \
  "$(plc 'git push origin worktree-agent-abc123' "$PUSHREPO")" \
  "worktree-agent-abc123"

# 5b. …and via the src:dst refspec form, where only the DESTINATION is the
#     worktree branch (this is what actually creates the stale remote ref).
run_case "block: HEAD:worktree-agent-* refspec from a project root" 2 \
  "$(plc 'git push origin HEAD:worktree-agent-abc123' "$PUSHREPO")" \
  "worktree-agent-abc123"

# 5c. A bare `git push` inside a real worktree resolves HEAD in that repo and
#     still blocks — now by NAMING the branch, not by pattern-matching a path.
run_case "block: bare git push inside a real worktree (HEAD resolved)" 2 \
  "$(plc 'git push' "$PUSHWT")" \
  "worktree-agent-test"

# 5d. THE FALSE BLOCK: a normal branch pushed from a worktree cwd.
run_case "allow: normal branch pushed from a worktree cwd" 0 \
  "$(plc 'git push origin main' "$PUSHWT")"

# 5e. …and the cross-repo form the bug report was filed about. This must not
#     depend on `-C` accidentally breaking the trigger regex: the gate now
#     PARSES `-C` and resolves HEAD in THAT repo.
run_case "allow: cross-repo git -C <other> push from a worktree cwd" 0 \
  "$(plc "git -C $OTHERREPO push origin main" "$PUSHWT")"

# 5f. …including the bare cross-repo form with no refspec (HEAD of the OTHER
#     repo is `main`, so it is allowed even though the cwd is a worktree).
run_case "allow: bare git -C <other> push from a worktree cwd" 0 \
  "$(plc "git -C $OTHERREPO push" "$PUSHWT")"

# 5g. Deleting a stale worktree branch is the orchestrator's documented
#     cleanup step (AGENTS.md) and must never be blocked.
run_case "allow: git push --delete of a worktree-agent branch" 0 \
  "$(plc 'git push origin --delete worktree-agent-abc123' "$PUSHREPO")"

run_case "allow: git push origin :worktree-agent-* (delete refspec)" 0 \
  "$(plc 'git push origin :worktree-agent-abc123' "$PUSHREPO")"

# 5h. A quoted "$BRANCH" is blanked by command_skeleton by design, so the ref
#     is UNRESOLVABLE. That falls back to the old cwd rule — conservative in
#     a worktree…
run_case "block: unresolvable quoted refspec from a worktree cwd" 2 \
  "$(plc 'git push origin "$BRANCH"' "$PUSHWT")" \
  "from inside a worktree"

# 5i. …and permissive everywhere else (the orchestrator's own scripts).
run_case "allow: unresolvable quoted refspec from a project root" 0 \
  "$(plc 'git push origin "$BRANCH"' "$PUSHREPO")"

run_case "allow: git push origin --delete \"\$BRANCH\" from a project root" 0 \
  "$(plc 'git push origin --delete "$BRANCH"' "$PUSHREPO")"

# 5j. `git push --all` publishes every local branch, worktree ones included —
#     no refspec names them, so the gate has to look at the repo's refs.
run_case "block: git push --all in a repo holding worktree-agent branches" 2 \
  "$(plc 'git push --all origin' "$PUSHREPO")" \
  "worktree-agent-test"

run_case "allow: git push --all in a repo with no worktree branches" 0 \
  "$(plc 'git push --all origin' "$OTHERREPO")"

# 5k. `cd <repo> && git push` — the repo being pushed is the one the command
#     WALKS INTO. (Found live: the fixed hook blocked this very form from a
#     worktree session, which is the false block it was fixed for.)
run_case "allow: cd <other-repo> && git push from a worktree cwd" 0 \
  "$(plc "cd $OTHERREPO && git push" "$PUSHWT")"

run_case "block: cd <worktree> && git push from a project root" 2 \
  "$(plc "cd $PUSHWT && git push" "$OTHERREPO")" \
  "worktree-agent-test"

# 5l. A MENTION of a push is still not a push (command_skeleton contract).
run_case "allow: quoted 'git push origin worktree-agent-x' is not a push" 0 \
  "$(plc 'echo "never git push origin worktree-agent-x" | cat' "$PUSHREPO")"

push_cleanup

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
#
# Both the budget and the expected message here are DERIVED rather than
# hand-picked, because BOTH used to make this case load-flaky (dotfiles-oe80),
# and since dotfiles-jm1c wired the suites to core.hooksPath a flake here
# blocks real commits.
#
#   * The BUDGET. $HARNESS_PULSE_PROOF_BUDGET bounds the whole gate, and the
#     gate's own bookkeeping (a `git diff` plus a `jq` per ledger line) spends
#     from it before any proof runs. At the old budget=1, a loaded box burned
#     the whole second on bookkeeping, so the hook took the budget-EXHAUSTED
#     branch — a different code path — and the case failed. Measured
#     2026-08-01 on 12 cores: hook overhead 0.20s quiet, 0.37–0.70s at load
#     44; case failed 4/30 at load 44, 0/10 quiet. So measure THIS box's
#     overhead and derive the budget from it; a constant is a guess that a
#     slower box or a heavier load invalidates silently.
#
#   * The MESSAGE. The hook prints "timed out after ${PROOF_LEFT}s", and
#     PROOF_LEFT is budget-minus-elapsed — so raising the budget while still
#     pinning an exact second count does NOT fix the flake, it only moves it
#     (measured: budget=5 wanting "after 5s" still failed 2/20 at load 47,
#     reporting "after 4s"). Assert the phrase, which ONLY the timeout branch
#     prints; the exhausted branch says "ran out before verifying".
#     Deliberately NOT a want_stderr alternation accepting either message:
#     that would go green on a hook that never reached the proof at all, and
#     case 23 exists precisely to test that other branch on its own.
SLOW_T0=$(date +%s)
printf '%s\n' '{"ts":"2026-06-28T08:59:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"true"},"note":"overhead probe"}' \
  >> "$PROOFREPO/refs/pulse-ledger.jsonl"
( cd "$PROOFREPO" && echo "$PROOF_CMD" | env HARNESS_PULSE_PROOF_BUDGET=90 "$HOOK" ) >/dev/null 2>&1
git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl
# Whole seconds, the same unit the hook's own `date +%s` arithmetic uses.
# x2 for a load spike between this probe and the case; +3 to clear both the
# sub-second truncation and a legitimate 0s measurement on a quiet box.
SLOW_BUDGET=$(( ($(date +%s) - SLOW_T0) * 2 + 3 ))
printf '%s\n' '{"ts":"2026-06-28T09:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"sleep 30"},"note":"x"}' \
  >> "$PROOFREPO/refs/pulse-ledger.jsonl"
run_case_env "$PROOFREPO" "block: slow proof times out inside the budget" 2 \
  "$PROOF_CMD" "timed out after " "HARNESS_PULSE_PROOF_BUDGET=$SLOW_BUDGET"
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

# --- kind:scrutinize verdict matching (dotfiles-8aj5) ---------------------
# This branch was `br show "$B" | grep -q 'SHIP'` — the four letters SHIP
# ANYWHERE in the bead body — from the day the proof gate shipped until
# 2026-08-01, with ZERO cases here covering it. Mutating that grep to `true`
# left this suite green at 58/58; that is how a live false-accept survived
# next to a sibling hook that had already solved the same problem and hoisted
# a shared matcher for it. The gate now calls scrutiny_verdict_ok() from
# agents/hooks/lib/scrutiny-verdict.sh, and these are its cases here.
#
# ⚠️ RUN THESE UNDER BASH. scrutiny_verdict_ok ends in `grep -qv` over
# possibly-empty input, which exits 0 under zsh and 1 under bash — a zsh-run
# harness reports the FAIL cases as ALLOW and hides exactly this bug.
scrutinize_case() {
  local name=$1 want_exit=$2 body=$3 want_stderr=${4:-}
  printf '%s\n' '{"ts":"2026-08-01T00:00:00Z","row":"r","outcome":"done","proof":{"kind":"scrutinize","bead":"explore-test"},"note":"x"}' \
    >> "$PROOFREPO/refs/pulse-ledger.jsonl"
  run_case_env "$PROOFREPO" "$name" "$want_exit" "$PROOF_CMD" "$want_stderr" "BR_SHOW_BODY=$body"
  git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl
}

# 24. a real verdict line → ALLOW
scrutinize_case "allow: scrutinize proof with 'Verdict: SHIP'" 0 \
  '## Scrutiny — 2026-08-01: Verdict: SHIP'

# 25. the negated verdict → BLOCK. Passed before the fix.
scrutinize_case "block: scrutinize proof with 'do NOT SHIP'" 2 \
  '## Scrutiny — 2026-08-01: Verdict: do NOT SHIP' \
  "verdict not SHIP"

# 26. prose that merely mentions the word → BLOCK. Passed before the fix.
scrutinize_case "block: scrutinize proof with prose 'before we SHIP'" 2 \
  'needs scrutiny before we SHIP this' \
  "verdict not SHIP"

# 27. the shape found live: an OPEN bead with no verdict of its own, whose
#     body merely QUOTES another bead's SHIP. Passed before the fix.
scrutinize_case "block: scrutinize proof on a bead quoting another's verdict" 2 \
  'Title: some open bead
Status: OPEN
It quotes another bead: "Verdict: SHIP" was recorded over there.' \
  "verdict not SHIP"

# 28. the documented bypass is still a verdict → ALLOW
scrutinize_case "allow: scrutinize proof with an OVERRIDE marker" 0 \
  '## Scrutiny — OVERRIDE: no reviewer available'

# 29. an unresolved FIX-FIRST is not a SHIP → BLOCK
scrutinize_case "block: scrutinize proof with unresolved FIX-FIRST" 2 \
  'Verdict: FIX-FIRST' "verdict not SHIP"

# 30. empty bead body (br show found nothing) → BLOCK. This is the case the
#     zsh/bash `grep -qv` split flips, so it is worth its own line.
scrutinize_case "block: scrutinize proof whose bead body is empty" 2 \
  '' "verdict not SHIP"

# 31. no .proof.bead at all → BLOCK
printf '%s\n' '{"ts":"2026-08-01T01:00:00Z","row":"r","outcome":"done","proof":{"kind":"scrutinize"},"note":"x"}' \
  >> "$PROOFREPO/refs/pulse-ledger.jsonl"
run_case_in "$PROOFREPO" "block: scrutinize proof with no bead id" 2 \
  "$PROOF_CMD" "verdict not SHIP"
git -C "$PROOFREPO" checkout -q refs/pulse-ledger.jsonl

# --- empty kind:cmd proof (the second survivor of the same sweep) ---------
# The hook has always blocked an empty `cmd`, but nothing asserted it, so
# deleting the check left this suite green. An empty cmd is the cheapest
# possible self-certification: `bash -c ""` exits 0.

# 32. cmd proof present but empty → BLOCK
proof_case "block: done with an empty cmd proof" 2 \
  '{"ts":"2026-08-01T02:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":""},"note":"x"}' \
  "proof cmd is empty"

# 33. kind:cmd with the cmd key missing entirely → BLOCK
proof_case "block: done with kind:cmd and no cmd key" 2 \
  '{"ts":"2026-08-01T03:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd"},"note":"x"}' \
  "proof cmd is empty"

# 34. cmd proof that is only whitespace → BLOCK. `bash -c "   "` exits 0 just
#     as `bash -c ""` does, so trimming to empty must be the same verdict.
proof_case "block: done with a whitespace-only cmd proof" 2 \
  '{"ts":"2026-08-01T04:00:00Z","row":"r","outcome":"done","proof":{"kind":"cmd","cmd":"   "},"note":"x"}' \
  "proof cmd is empty"

rm -rf "$PROOFREPO"

# --- SIBLING ledgers are gated too (explore-z1k6) --------------------------
# The selector was `*pulse-ledger.jsonl` from the day the gate shipped, so
# every ledger that arrived later fell outside it SILENTLY: digest (33 done
# rows, 1 proof), dream (3 done rows, 0 proofs), friction — all three declared
# loops in ~/explore/refs/pulse.md, all three read by the dashboard. Nothing
# here covered the selector, so widening or narrowing it was invisible to the
# suite. Both directions are asserted: a sibling ledger BLOCKS on an unproven
# `done`, and PASSES on a real one — a gate the digest cannot satisfy would be
# just as broken as no gate.
SIBREPO=$(mktemp -d)
git -C "$SIBREPO" init -q
git -C "$SIBREPO" config user.email t@t; git -C "$SIBREPO" config user.name t
mkdir "$SIBREPO/refs" "$SIBREPO/digests"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"digest","outcome":"done","note":"legacy, never re-validated"}' \
  > "$SIBREPO/refs/digest-ledger.jsonl"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"dream","outcome":"done","note":"legacy"}' \
  > "$SIBREPO/refs/dream-ledger.jsonl"
printf '# Daily digest — 2026-08-02\n\n## ⭐ Worth your attention\n\nreal content\n' \
  > "$SIBREPO/digests/2026-08-02.md"
git -C "$SIBREPO" add refs/digest-ledger.jsonl refs/dream-ledger.jsonl digests/2026-08-02.md
git -C "$SIBREPO" commit -qm seed

sib_case() {
  local name=$1 want=$2 file=$3 line=$4 want_stderr=${5:-}
  printf '%s\n' "$line" >> "$SIBREPO/$file"
  git -C "$SIBREPO" add "$file"
  run_case_in "$SIBREPO" "$name" "$want" \
    '{"tool_input":{"command":"git commit -m \":card_file_box: tick\""},"cwd":"/tmp"}' \
    "$want_stderr"
  git -C "$SIBREPO" reset -q
  git -C "$SIBREPO" checkout -q "$file"
}

# 35. an unproven `done` on the DIGEST ledger → BLOCK. Before the fix this
#     was exit 0: the gate never looked at the file at all.
sib_case "block: unproven done in refs/digest-ledger.jsonl" 2 \
  refs/digest-ledger.jsonl \
  '{"ts":"2026-08-02T14:00:00Z","row":"digest","outcome":"done","note":"x"}' \
  "no valid proof token"

# 36. a bogus proof is not a proof — the cmd is RE-RUN, and a digest that did
#     not land fails it.
sib_case "block: digest done whose proof cmd fails" 2 \
  refs/digest-ledger.jsonl \
  '{"ts":"2026-08-02T14:00:00Z","row":"digest","outcome":"done","proof":{"kind":"cmd","cmd":"grep -q \"^# Daily digest — 2026-08-02\" digests/2026-08-09.md"},"note":"x"}' \
  "proof cmd exited"

# 37. the artifact-exists dodge stays rejected on the sibling ledgers too.
sib_case "block: digest done with an artifact proof" 2 \
  refs/digest-ledger.jsonl \
  '{"ts":"2026-08-02T14:00:00Z","row":"digest","outcome":"done","proof":{"kind":"artifact","path":"digests/2026-08-02.md"},"note":"x"}' \
  "stub-passable"

# 38. the REAL shape the digest skill now emits → ALLOW. Marker-grep on the
#     dated deliverable: a stub or a stale copy of yesterday's file fails it,
#     which is the verifier distance `test -s` does not have.
sib_case "allow: digest done with the marker-grep cmd proof" 0 \
  refs/digest-ledger.jsonl \
  '{"ts":"2026-08-02T14:00:00Z","row":"digest","outcome":"done","proof":{"kind":"cmd","cmd":"D=digests/2026-08-02.md; grep -q \"^# Daily digest — 2026-08-02\" \"$D\" && grep -q \"^## ⭐ Worth your attention\" \"$D\""},"note":"x"}'

# 39. dream is a sibling too — same selector, same verdict.
sib_case "block: unproven done in refs/dream-ledger.jsonl" 2 \
  refs/dream-ledger.jsonl \
  '{"ts":"2026-08-02T11:13:00Z","row":"dream","outcome":"done","note":"x"}' \
  "no valid proof token"

# 40. a quiet sibling row still needs no proof (it claims no work).
sib_case "allow: quiet row in a sibling ledger" 0 \
  refs/dream-ledger.jsonl \
  '{"ts":"2026-08-02T11:13:00Z","row":"dream","outcome":"quiet","note":"x"}'

# 41. history is never re-validated: the seeded proofless `done` lines are
#     already in HEAD, and a commit that adds a GOOD line beside them passes.
#     (Back-filling proofs onto historical rows would manufacture exactly the
#     false assurance the gate exists to prevent — explore-z1k6.)
sib_case "allow: legacy proofless history is not re-validated" 0 \
  refs/dream-ledger.jsonl \
  '{"ts":"2026-08-02T11:14:00Z","row":"dream","outcome":"done","proof":{"kind":"cmd","cmd":"test -d digests"},"note":"x"}'

# 42. a non-ledger .jsonl is NOT swept in by the wider glob.
printf '%s\n' '{"ts":"2026-08-02T00:00:00Z","outcome":"done"}' > "$SIBREPO/refs/notes.jsonl"
git -C "$SIBREPO" add refs/notes.jsonl
run_case_in "$SIBREPO" "allow: a non-ledger jsonl is outside the gate" 0 \
  '{"tool_input":{"command":"git commit -m \":card_file_box: x\""},"cwd":"/tmp"}'
git -C "$SIBREPO" reset -q
rm -f "$SIBREPO/refs/notes.jsonl"

rm -rf "$SIBREPO"

# --- the SCHEMA gate: pulse-ledger-lint.py has a hook caller (dotfiles-775y) -
# The linter's only invoker was the remote dispatcher (since retired,
# dotfiles-y3u8), so a row appended by
# any OTHER path was unlinted — which is exactly how explore-qdo5 happened (23
# `"row":null` rows across 3 projects, copied from /pulse's own example, none
# of them written by the dispatcher). These cases assert the gate in both
# directions AND its two deliberate limits: history is never re-validated, and
# a repo with no routing table is skipped VISIBLY rather than silently.
SCHEMAREPO=$(mktemp -d)
git -C "$SCHEMAREPO" init -q
git -C "$SCHEMAREPO" config user.email t@t; git -C "$SCHEMAREPO" config user.name t
mkdir "$SCHEMAREPO/refs"
cat > "$SCHEMAREPO/refs/pulse.md" <<'ROUTING'
# Pulse routing

| name | cadence | what |
|---|---|---|
| `dive` | daily | dive one lead |
| `desk` | Fri | the allocator |
ROUTING
# Seeded history that the linter WOULD reject (no `outcome` key — the exact
# shape refs/friction-ledger.jsonl carries on line 1 today).
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"dive","note":"legacy, no outcome"}' \
  > "$SCHEMAREPO/refs/pulse-ledger.jsonl"
git -C "$SCHEMAREPO" add refs/pulse.md refs/pulse-ledger.jsonl
git -C "$SCHEMAREPO" commit -qm seed

schema_case() {
  local name=$1 want=$2 line=$3 want_stderr=${4:-}
  printf '%s\n' "$line" >> "$SCHEMAREPO/refs/pulse-ledger.jsonl"
  git -C "$SCHEMAREPO" add refs/pulse-ledger.jsonl
  run_case_in "$SCHEMAREPO" "$name" "$want" \
    '{"tool_input":{"command":"git commit -m \":card_file_box: tick\""},"cwd":"/tmp"}' \
    "$want_stderr"
  git -C "$SCHEMAREPO" reset -q
  git -C "$SCHEMAREPO" checkout -q refs/pulse-ledger.jsonl
}

# 43. THE incident row: `"row":null`. outcome:"quiet" on purpose — quiet is
#     exempt from the 2.5 proof gate, so a BLOCK here can only come from 2.6.
schema_case "block: \"row\":null in a new ledger row" 2 \
  '{"ts":"2026-08-02T09:00:00Z","row":null,"outcome":"quiet"}' \
  "pulse-ledger-lint rejected a NEW row"

# 44. an invented row name is not in refs/pulse.md — the canonical-ledger-row
#     rule, the same failure class Zig caught by eye on 2026-07-14.
schema_case "block: a row name not declared in refs/pulse.md" 2 \
  '{"ts":"2026-08-02T09:00:00Z","row":"made-up-loop","outcome":"quiet"}' \
  "pulse-ledger-lint rejected a NEW row"

# 45. outcome outside done/quiet/blocked.
schema_case "block: an out-of-contract outcome" 2 \
  '{"ts":"2026-08-02T09:00:00Z","row":"dive","outcome":"finished"}' \
  "pulse-ledger-lint rejected a NEW row"

# 46. a non-UTC ts — the whole cap/day-boundary argument rests on UTC.
schema_case "block: a non-UTC timestamp" 2 \
  '{"ts":"2026-08-02T09:00:00-07:00","row":"dive","outcome":"quiet"}' \
  "pulse-ledger-lint rejected a NEW row"

# 47. the honest marker for an unrecoverable attribution is ALLOWED — a
#     visible gap beats a confabulated row name.
schema_case "allow: row 'unattributed'" 0 \
  '{"ts":"2026-08-02T09:00:00Z","row":"unattributed","outcome":"quiet"}'

# 48. a well-formed declared row passes. A gate the loops cannot satisfy would
#     be as broken as no gate.
schema_case "allow: a valid declared row" 0 \
  '{"ts":"2026-08-02T09:00:00Z","row":"dive","outcome":"quiet"}'

# 49. HISTORY IS NEVER RE-VALIDATED. The seeded line has no `outcome` and is
#     already in HEAD; a commit adding a GOOD line beside it must pass. Without
#     the new-lines-only slice this whole repo would be permanently unable to
#     commit — refs/friction-ledger.jsonl is the live instance.
schema_case "allow: legacy invalid history is not re-validated" 0 \
  '{"ts":"2026-08-02T09:01:00Z","row":"desk","outcome":"quiet"}'

# 50. no routing table -> SKIPPED, but the skip says so. An implicit exempt is
#     indistinguishable from an oversight (explore-z1k6's lesson).
NOROUTE=$(mktemp -d)
git -C "$NOROUTE" init -q
git -C "$NOROUTE" config user.email t@t; git -C "$NOROUTE" config user.name t
mkdir "$NOROUTE/refs"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","row":"x","outcome":"quiet"}' \
  > "$NOROUTE/refs/pulse-ledger.jsonl"
git -C "$NOROUTE" add refs/pulse-ledger.jsonl
git -C "$NOROUTE" commit -qm seed
printf '%s\n' '{"ts":"2026-08-02T09:00:00Z","row":null,"outcome":"quiet"}' \
  >> "$NOROUTE/refs/pulse-ledger.jsonl"
git -C "$NOROUTE" add refs/pulse-ledger.jsonl
run_case_in "$NOROUTE" "note: no routing table -> visible skip, not a block" 0 \
  '{"tool_input":{"command":"git commit -m \":card_file_box: tick\""},"cwd":"/tmp"}' \
  "skipping the ledger schema gate"
rm -rf "$NOROUTE"

rm -rf "$SCHEMAREPO"

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
