# G — The hook enforcement map (orchestrator-built)

**Why this exists.** The single cleanest cut in a prompt-driven harness is *prose that
restates a rule a hook already blocks*. The hook is the real guard: it fires whether or
not the model read the paragraph, it fires in every session including stale-snapshot
ones, and it cannot be forgotten under compaction. Where both exist, the paragraph is
**belt on top of a bolted-shut door** — and it is paid for in every session forever.

This is the join key for audits A–F: any finding of the form "rule X is documented in
AGENTS.md / SKILL.md" should be checked against this table before a KEEP verdict.

28 hooks, 3,764 lines. 19 `exit 2` (hard block) sites.

## The blocking tier — these REFUSE the tool call

| hook | lines | what it mechanically enforces | prose that restates it |
|---|---|---|---|
| `pre-commit-checks.sh` | 506 | git-discipline gate: blocks broad `git add -A`/`.`; keys push checks on the branch being pushed; **the pulse `done`-proof gate** (a `done` ledger row must carry a verifying `kind:cmd` or `kind:scrutinize` proof, re-run with a time budget; `quiet`/`blocked` exempt); bead-trailer checks; file-scoped lint | AGENTS.md "git add -A is hook-blocked"; dotfiles/CLAUDE.md rule 4; `/commit`; `/pulse`'s entire proof-token anti-pattern block; `/beads` |
| `pre-bead-close.sh` | 308 | close gate: an impl bead cannot close without a recorded **SHIP** (or explicit OVERRIDE) scrutiny verdict. Shares ONE matcher definition with pre-commit-checks (dotfiles-8aj5) and fails CLOSED | AGENTS.md verification section; `/impl`; `/scrutinize`; `/beads` |
| `pre-bead-create.sh` | 181 | entry gate: refuses a bead whose description lacks the sections `br lint` will later require — i.e. refuses to create a bead that could never be closed. Emits the leading-dash trap warning inline | `/beads` "Mandatory: every bead has a description"; the `-t` type table |
| `pre-shared-tree-guard.sh` | 422 | **the merge-never-rebase-NEVER-stash rule, mechanically** — blocks `git stash` / `reset --hard` / `checkout .` / `clean -fd` used to unblock a pull, but only while another writer is provably mid-run. Explicitly designed to "refuse the blunderbuss, name the precise alternative" | AGENTS.md's entire "Two writers, one working tree" section incl. the measured 3-row table |
| `pre-bash-stderr-guard.sh` | 83 | blocks `2>/dev/null` on state-changing / output-bearing commands; `# allow-suppress` escape for pure existence checks | AGENTS.md "Don't blanket-suppress stderr"; dotfiles/CLAUDE.md rule 3 |
| `pre-tool-use-require-isolation.sh` | 93 | requires `isolation` on code-writing subagent dispatches. **Known gap, documented: cannot see cross-repo dispatch** | AGENTS.md delegation section + the cross-repo warning block |
| `pre-tool-use-worktree-guard.sh` | 120 | blocks worktree subagents writing outside their worktree | `/dispatch` (which already says this is "structurally enforced… prompts carry task-specific content only" — good, correctly deferred) |
| `pre-merge-worktree.sh` | 92 | blocks `git merge worktree-agent-*` when the worktree state makes it unsafe | AGENTS.md's ~30-line worktree-cleanup bash snippet |
| `task-completed.sh` | 73 | blocks task completion when modified files aren't lint-clean | `/lint` |
| `teammate-idle.sh` | 36 | blocks on unpushed commits; warns on uncommitted | AGENTS.md "Commit AND push as you go" |

## The advisory tier — these inject text, they do not block

| hook | what it does |
|---|---|
| `session-start.sh` (420) | injects branch/dirty/beads context at SessionStart **and SubagentStart**; symlinks `.beads/` in worktrees; runs `direnv allow` |
| `pre-compact.sh` / `pre-compact-observe.sh` | re-inject state across compaction |
| `stop-always-loaded-check.sh` (134) | **staleness detector for the always-loaded tier itself** — directly relevant to this audit; check what it considers stale |
| `stop-context-guard.sh`, `check-status.sh` | end-of-turn checks |
| `post-*` (7 hooks) | beads-merge check, submodule absorb, gen fan-out nudge, orchestrator action, **push→AskUserQuestion fallback**, SKILL.md format validation, **toybox usage tracking** |
| `lint-on-write.sh` (150) | auto-fixes formatting on write |
| `tmux-status.sh` (230) | the 🧠/🔔/✅/🌀 glyph lexicon |
| `merge-jsonl.sh` (44) | the custom `jsonl-union` driver (NOT git's `merge=union` — the resurrection bug) |
| `worktree-create.sh` (100) | overrides worktree placement |

## The three findings this map produces

**1. AGENTS.md's largest rule blocks are each backed by a blocking hook.** "Two writers /
never stash" (422-line hook), stderr (83), `git add -A` (506), delegation isolation (93),
worktree cleanup (92), push-before-idle (36). The prose in each case predates or explains
the hook. **The explanation is not worthless** — a blocked agent that doesn't know *why*
retries around the guard, and `pre-shared-tree-guard.sh`'s own comments say the refusal
"is exactly what tempts you toward stash." But the *full measured table + rationale* does
not need to live in the always-loaded tier: it needs to live in the hook's block message,
where it is delivered exactly when it is needed and costs nothing the rest of the time.
**This is the single most repeatable pattern in the whole audit: move rationale from the
always-loaded tier into the block message.**

**2. `/dispatch` already demonstrates the target state.** Its TOOLKIT entry reads:
"No-nested-agents + path discipline are *structurally enforced* (subagent definition +
hooks) — prompts carry task-specific content only." That is the correct relationship
between a hook and a skill, and it is already written down. The pattern exists; it just
hasn't been applied to the other skills.

**3. A hook is only a real guard if a mutant kills a test.** dotfiles/CLAUDE.md rule 1
records that a 13-mutant sweep against 32 green suites found **three survivors — one a
live false-accept in the pulse `done` gate** (`dotfiles-8aj5`, `dotfiles-jm1c`). So
"ALSO hook-enforced" is not automatically "safe to delete the prose." The correct test is
*hook-enforced AND the guard is mutation-tested*. Audit F is checking the done-gate's real
strength; that result gates how aggressively finding #1 can be applied.

## Caveat on this map

Built from hook headers, block-message strings, and structural greps — not a line-by-line
read of all 3,764 lines. Treat the "what it enforces" column as accurate-in-kind and
verify the exact predicate before deleting any specific paragraph on its strength.
