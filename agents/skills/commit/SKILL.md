---
description: Create git commits following gitmoji conventions with bead integration. Claude commits autonomously at natural checkpoints (bead closure, file created, test passing) — this is expected, not an extra confirmation step.
argument-hint: "[message]"
allowed-tools: Bash(git add *) Bash(git fetch *) Bash(git merge *) Bash(git commit *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git push) Bash(git push *) Bash(br close *) Bash(br sync *)
when_to_use: Autonomous-OK at natural checkpoints (bead closure, test pass, config update); also when the user asks for a specific commit. Runs AFTER bead closure and selective staging.
---

# /commit - Git Commit Convention

## When to Commit

- **Every bead closure** triggers a commit + push. One bead = one commit.
- **Natural checkpoints** between beads: file created, test passing, config updated.
- **Never batch** multiple beads into one commit.
- **Never push blind.** After committing, push; if the push is rejected, another
  machine committed — absorb it with **`git fetch origin && git merge --no-edit origin/<branch>`**,
  then push again. (Worktree exception: if your branch starts with `worktree-agent-`,
  do not push at all.) The verb is AGENTS.md's "Two writers, one working tree" rule —
  merge, never rebase, NEVER stash — and that rule is canonical; this skill does not
  restate it.

## Commit Message Format

```
<emoji> scope: short description

optional body explaining WHY

Bead: <bead-id>
Co-Authored-By: <the trailer your harness specifies>
```

Use a scope prefix that matches the area of the codebase you changed. Get the bead
ID from your task prompt or `br list`. Close the bead BEFORE committing (see `/beads`).

**Co-Authored-By:** your harness states the exact trailer for the
model you're running as (in the git guidance of your system prompt,
e.g. `Co-Authored-By: Claude <model> <noreply@anthropic.com>`). Use
that line verbatim. Do NOT copy a model name from this file or from
old commits — skills outlive model versions, and a hardcoded name
misattributes every commit made under a newer model (this file pinned
"Opus 4.6" until 2026-06-09).

## Gitmoji Reference

| Emoji | Use for |
|-------|---------|
| :sparkles: | New feature or capability |
| :bug: | Bug fix |
| :memo: | Documentation changes |
| :recycle: | Refactoring (no behavior change) |
| :test_tube: | Tests |
| :wrench: | Configuration changes |
| :rocket: | Deployment and release |
| :fire: | Remove code or files |
| :lock: | Security fixes |
| :zap: | Performance improvements |
| :art: | Style, formatting, structure |
| :ambulance: | Critical hotfix |
| :lipstick: | UI/cosmetic changes |
| :construction: | Work in progress |
| :arrow_up: | Upgrade dependencies |
| :heavy_plus_sign: | Add dependency |
| :heavy_minus_sign: | Remove dependency |
| :truck: | Move or rename files |
| :boom: | Breaking changes |

## Workflow

### 1. Close bead, analyze, stage

```bash
br close <bead-id>
br sync --flush-only
git status && git diff
git add <specific-files>                       # NEVER git add -A, and never a DIRECTORY
git add .beads/issues.jsonl                    # ONLY on the default branch — see Bead-state exception
```

### 2. Commit with HEREDOC

```bash
git commit -m "$(cat <<'EOF'
:sparkles: auth: add JWT token refresh

Prevents session expiry during long-running operations.

Bead: bd-xxx
Co-Authored-By: <the trailer your harness specifies>
EOF
)"
```

### 3. Push — never blind — and PROVE the push against the remote

```bash
# Assert the branch. Never infer it, never trust it from earlier in the session.
BRANCH=$(git branch --show-current)
test -n "$BRANCH" || { echo "ABORT: detached HEAD — commits here are not on any branch"; exit 1; }

# Never push blind. If this is rejected, another machine committed — absorb it
# with fetch+merge (AGENTS.md's rule; NOT rebase, NEVER stash), then push again.
git push origin "$BRANCH" || {
  git fetch origin && git merge --no-edit "origin/$BRANCH" || {
    echo "ABORT: merge refused — the remote touches another writer's files. Stop and wait."; exit 1; }
  git push origin "$BRANCH"
}

# Prove it landed by comparing to the REMOTE.
test "$(git rev-parse "$BRANCH")" = "$(git ls-remote origin "$BRANCH" | cut -f1)" \
  || { echo "FAIL: remote did not receive it"; exit 1; }
```

⚠️ **`git rev-parse HEAD` is NOT proof of a push.** Echoing it after pushing
prints your LOCAL head — including a detached one — not what the remote
received, so it reports success on exactly the failure it should catch.

This is not hypothetical. On 2026-07-31 a managed checkout on `marketing-vps` (a
box since decommissioned — the lesson is not) re-detached HEAD mid-session,
repeatedly, including between two commits in the
same turn. Four commits landed on the detached HEAD while the `main` branch
never moved; `git push origin main` dutifully pushed the unmoved branch, exited
`0`, and the session reported "pushed" four times against a remote that had
received nothing. Recovered from the reflog. **A managed, synced, or
multi-machine checkout can detach without warning** — assert the branch before
every commit, and compare to `ls-remote` after every push.

Recovery when it has already happened: `git reflog` still holds the stranded
commits. Find the last one, `git checkout <branch>`, `git merge --ff-only <sha>`
if it descends from the branch, and `git cherry-pick` any siblings.

⚠️ **A push guard behind a pipe can NEVER fire.** Measured 2026-08-03
(`dotfiles-xugk`) — a session used this idiom for every push across a long run:

```bash
if ! git push origin main 2>&1 | tail -1; then     # BROKEN: absorb path unreachable
  git fetch origin && git merge --no-edit origin/main && git push origin main
fi
```

`if !` tests the exit status of the **pipeline**, which is its LAST command's —
`tail`, which always succeeds. The fetch+merge therefore cannot run, ever. The
idiom was written specifically to satisfy AGENTS.md's "two writers" rule and
satisfied nothing; the pipe was never load-bearing, it only trimmed output.

This is the `rev-parse` trap one level down — **a guard whose signal is swallowed
before anything reads it** — and it shares the tell that let it survive a whole
session: *the failure mode is silence.* Nothing errors, nothing logs, and while
pushes succeed it is indistinguishable from a working guard. It surfaced only on
the first real rejection (another writer had landed four commits): the push
failed, the fallback silently did not run, and the divergence was caught **only**
by the `ls-remote` comparison above. So that check is not redundant with the
`||` fallback — it is what catches the fallback itself being broken. Keep it
mandatory. Real output, throwaway repo, local 1 ahead / 4 behind:

```
local=97a5859  remote=d44ad65
hint: See the 'Note about fast-forwards' in 'git push --help' for details.
(the fallback's echo never printed)
local=97a5859  remote=d44ad65
ls-remote proof: FAIL -- remote did not receive it
```

**The fix is to drop the pipe and read `$?`.** The `git push … || { … }` block
above is already correct; when you want the status explicitly:

```bash
git push origin "$BRANCH"; rc=$?
if [ "$rc" -ne 0 ]; then
  git fetch origin && git merge --no-edit "origin/$BRANCH" || {
    echo "ABORT: merge refused — the remote touches another writer's files. Stop and wait."; exit 1; }
  git push origin "$BRANCH"
fi
```

🚫 **Do NOT "fix" it with `${PIPESTATUS[0]}` — that is bash-only, and this
fleet's shell is zsh** (Bash-tool commands run `/bin/zsh` 5.9). In zsh the
uppercase array does not exist, so it expands to the **empty string** and the
guard fails open in exactly the way it was added to prevent. zsh's own array is
lowercase AND 1-indexed (`${pipestatus[1]}` is the first command), and either
array is clobbered by the very next command, so nothing may intervene. Measured
after `false | true`:

```
zsh    ${PIPESTATUS[0]} = []      ${pipestatus[1]} = [1]
bash   ${PIPESTATUS[0]} = [1]
zsh, one echo later:               ${pipestatus[1]} = [0]   <- clobbered
```

Two silent-failure traps stacked is one too many. **Keep the pipe out of the
guard** — pipe afterwards if you want quiet output.

⚠️ **Assume another writer has already committed.** This has not been a
single-writer fleet since 2026-07-28. The second writer is no longer another
*machine* — `marketing-vps` ran dispatched pulse ticks against its own checkouts
until it was decommissioned 2026-08-07 — but the hazard did not leave with it:
**a `/pulse` tick is a real session in the project root**, and a parallel
interactive session commits constantly. A second writer arrives on a timer,
with nothing in `git status` marking whose files are whose. A bare `git push` against a moved
remote either fails outright (`! [rejected] … fetch first`) or, worse, tempts a
`--force` that silently discards the other machine's work.

A linear history is *preferred* — but not at the price of the verb. **Do not
reach for `git pull --rebase` to get it**: the measured 2026-08-01 comparison in
`agents/hooks/pre-shared-tree-guard.sh` (header, and again in its block message)
is why. Rebase refuses on ANY unrelated dirty file (rc 128), and a
`/pulse` tick or a sibling session can be a second writer in this very tree at
any moment; the refusal is exactly what tempts an agent toward `git stash`,
which "succeeds" by silently taking the other writer's work. `git fetch origin
&& git merge --no-edit origin/<branch>` fails safely instead, and costs only a
merge commit. `.beads/issues.jsonl` is fine either way — the `jsonl-union`
driver below resolves it by bead ID + `updated_at`, not by replay order.

**Bead state survives concurrent writes — but only because of the driver.**
`.beads/*.jsonl merge=jsonl-union` is committed in all 48 bead repos, and the
driver is registered globally in `dotfiles/git/.gitconfig` (so it resolves on
BOTH machines, submodules included). It unions, dedupes by bead ID, and keeps
the newer `updated_at`. Verified 2026-07-28 with the same 3-way merge on both
boxes: two machines editing the SAME bead converge to one line with the newer
state, and a bead closed on one side does **not** resurrect.

🚫 **Never `merge=union`** (git's built-in). It keeps BOTH sides' lines, so a
stale `open` line survives beside `closed` and `br`'s auto-import flips the bead
back open — the resurrection bug, `lin-eqh`, hit 3× on 2026-06-09. A stray union
line also *overrides* `jsonl-union` when it sorts later, since the last matching
`.gitattributes` rule wins.

🚫 **Never `git push --force` / `--force-with-lease` to shared `main`** to escape
a rejected push. A rejection means someone else committed; fetch, merge, push again.

**Worktree exception:** If you are working in a git worktree (your branch name
starts with `worktree-agent-`), do NOT push. The orchestrator handles merging
and pushing after your work is complete. Pushing from a worktree creates stale
remote branches.

⚠️ **`git add <directory>` stages DELETIONS too, and that is how you commit a
deletion you never chose.** `git add refs/scripts/` does not mean "add my new files
under refs/scripts" — it means "make the index match the working tree there",
including removing anything that has disappeared from disk. So any process that
touches the working tree behind you (an rsync, a sync client, a cleanup script, a
sibling agent, a checkout you forgot) gets its removals silently folded into your
commit, under a message that claims you added something.

Measured instance, 2026-07-30 on the since-decommissioned `marketing-vps`: an
hourly `rsync -az --delete` from
a stale source removed 12 committed files between a `cp` and a `git add
refs/doc-scripts`. Two commits captured the deletions as if they were intentional.
Nothing was lost only because the files were recoverable from history.

**So: name the files.** `git add a.mjs b.json` rather than `git add dir/`. When a
change genuinely spans many files, list them, or verify before committing:

```bash
git add <files>
test "$(git diff --cached --diff-filter=D --name-only | wc -l)" -eq 0 \
  || { echo "ABORT: staged deletions I did not intend"; git diff --cached --diff-filter=D --name-only; }
```

A deletion you meant is fine; stage it explicitly with `git rm` and say so in the
message. The rule is that no deletion should arrive as a side effect of naming a
directory.

**Bead-state exception:** stage `.beads/issues.jsonl` ONLY when committing on
the default branch (main). On a feature branch, leave it unstaged — bead-state
commits on branches fork the ledger, and git later auto-merges the two
versions "cleanly" while silently keeping BOTH sides' line for the same bead.
A duplicate id makes the JSONL invalid to `br` (caught live 2026-06-09,
dashboard-dev-interrupted PR #9: bd-dtz duplicated as in_progress + closed).
The `post-bash-beads-merge-check` hook flags the artifact after merges;
remediation is `git checkout <default-branch> -- .beads/issues.jsonl` or
`br sync --merge`, then `br doctor`. Don't create the artifact in the first
place. (In worktrees, `.beads/` is a symlink to the main checkout — never
stage anything under it; see /handoff Step 5.)

## Safety

- Stage specific files -- never `git add -A`, `git add .`, **or a directory**
- Never commit `.env`, credentials, or secrets
- Create NEW commits -- don't amend unless explicitly asked
- If a pre-commit hook blocks, fix the errors and retry (see `/lint`)
