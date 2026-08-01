---
description: Orchestrator-level implementation planning for test-first development. Creates test + impl beads, dispatches subagents in the right wave order, runs the quality gate. The flow is /spec -> /check -> /test -> /impl with hand-offs via beads. This skill is the orchestrator's playbook for the dispatch + merge loop, not what implementer subagents read.
when_to_use: Orchestrator is ready to dispatch implementation agents — after /check's Implementation Readiness summary and after the test wave has merged. Never fires autonomously.
---

# /impl — Implementation Orchestrator Workflow

You are the orchestrator. Implementer subagents do the actual code
work — you create beads, dispatch them, merge results, gate quality.

Pipeline: `/spec` → `/check` → `/test` → **/impl** → release.

## Step 1: Verify Implementation Readiness

Before creating any impl beads, the spec bead must show its
"Implementation Readiness" summary in `--notes` (written by `/check`):

```bash
br show <spec-bead-id>          # look for "Implementation Readiness" section
```

If readiness is BLOCKED:
- P1 OQs not all decided → re-dispatch `/check`
- Spec updates needed → re-dispatch `/spec` to apply them
- Cross-spec dependencies unconfirmed → resolve before proceeding

**Apply spec-update notes BEFORE creating impl beads.** A spec that
has pending updates is a moving target; impl agents will branch from
a stale spec.

## Step 2: Create the branch

```bash
git checkout main
git checkout -b v0.N/<descriptive-name>
git push -u origin v0.N/<descriptive-name>
```

All test + impl agents merge into the version branch (NOT main).
See `/branch` if your project uses that workflow; otherwise skip
this step.

## Step 3: Create test + impl beads (typed)

Use the bead handoff templates — full content lives at
[/beads reference/handoff-templates.md](../beads/reference/handoff-templates.md).
Per spec, you'll typically create:

- One **test bead** per subsystem
  ```bash
  br create -t test -p 2 "tests: <module>" --parent <spec-bead-id>
  ```
- One **impl bead** per subsystem (depends on its test bead)
  ```bash
  br create -t impl -p 2 "impl: <module>" --parent <spec-bead-id> \
    --deps "blocked-by:<test-bead-id>"
  ```
- Optional **integration bead** (`-t test`) for cross-subsystem work

The type lets you query later: `br list --type impl --status open`
shows all impl-in-flight, `br ready --type test` shows test work
ready to dispatch.

`br ready` will only surface impl beads after their test bead closes,
so the dependency chain enforces wave ordering automatically.

## Step 4: Wave order — TEST agents first, MERGE, THEN impl agents

This is the critical discipline. Worktree subagents branch from the
current HEAD when they're created. If test worktrees aren't merged
first, impl agents won't see the test files and will rewrite tests to
match their implementation — defeating TDD.

### Wave 1: dispatch test agents (parallel OK)

Each test agent gets:
- Its bead ID
- The spec bead ID
- The decisions bead (if /check produced one)
- The merge target (`v0.N/<name>` or main)
- Explicit "no nested agents" rule
- Pre-commit verification hook (run project tests + lint before commit)

### Pre-impl checklist (mandatory)

Before dispatching ANY impl agent, verify:

- [ ] All test beads completed
- [ ] Test agents wrote ONLY test files (run `git diff --name-only`
      on each test branch; reject if it touches src/)
- [ ] All test worktrees merged into the version branch
- [ ] All test worktrees + branches removed (`.claude/worktrees/`
      empty, no `worktree-agent-*` branches lingering)
- [ ] Version branch pushed
- [ ] Each impl agent's prompt includes the test file path it must satisfy

If any item is unchecked, the impl agents will branch from a stale
base or miss test files. Don't dispatch.

### Wave 2: dispatch impl agents (parallel OK)

Each impl agent gets:
- Its bead ID
- The test file path it satisfies
- The spec bead ID (for design notes / acceptance criteria)
- The merge target
- "Do NOT modify tests" rule

## Step 5: Quality gate (mandatory before merging branch to main)

### Step 5.0: The /scrutinize gate (run FIRST)

Before any automated check, run the [`/scrutinize`](../scrutinize/SKILL.md)
gate: dispatch a dedicated, read-only adversarial reviewer over the
merged impl wave. Tests verify conformance; they do not catch stub
bodies, tests that mock the unit under test, acceptance criteria
ticked without evidence, or composition gaps on a user-facing
surface. The /scrutinize reviewer hunts exactly those. Its verdict is
SHIP / FIX-FIRST / REJECT — a non-SHIP verdict routes into a fix wave,
then re-scrutinize. The gate is not cleared until SHIP. `/scrutinize`'s
"The audit checklist" (stub bodies, composition) is what that reviewer
works from.

### Step 5.1: Automated checks

After the /scrutinize gate clears, verify on the branch:

```bash
# Run project quality checks (per CLAUDE.md):
# - All tests pass
# - Lint clean (see /lint)
# - Doc comments on public API
# - Type checks pass (tsc, mypy/pyright, etc.)
```

If any check fails: create a fix bead, dispatch a cleanup agent,
re-run the gate.

### The post-impl audit (stub bodies + composition)

**Single owner: [`/scrutinize`](../scrutinize/SKILL.md) "The audit checklist."**
The stub-body audit and the UI/CLI composition audit are the checklist the
Step 5.0 reviewer works from — they are not a second thing the orchestrator
does inline. Don't re-copy them here; an orchestrator auditing its own wave is
the conflicted-judge problem the gate removes.

### Acceptance criteria shape: outcome > artifact

Bead acceptance criteria should describe the **user-facing OUTCOME**,
not just the artifacts produced. Artifact-shaped criteria ("file X
exists with Y sections", "N tests pass") are necessary but invite
"I shipped what was on the list, even though the result doesn't work."
Outcome-shaped criteria ("a visitor opens the URL, sees the picker,
pastes a token, clicks Run, watches markdown stream in") force the
agent to verify the runtime behavior matches the description.

Best practice for UI/CLI impl beads:

- Include a `## Visitor experience` (or `## CLI usage`) section in
  the bead --description with 3–5 lines walking the expected end-user
  flow
- Acceptance criteria reference that narrative explicitly:
  `- [ ] Visitor experience step 3 (clicking Run streams response) verified live`
- Pre-commit verification includes a runtime smoke (dev-server + curl
  / CLI invocation), not only `tests pass + lint clean`

This is the orchestrator's contract with the impl agent: tell them
what "done" looks like in user terms, then check it that way.

## Step 6: Merge to main + tag (only if project uses /branch)

```bash
git checkout main && git merge v0.N/<name> --no-edit
git tag -a v0.N.R -m "<title>"
git push origin main --tags
gh release create v0.N.R --notes-file CHANGELOG.md
```

See `/release` for the full release flow if your project uses it.

## Subagent prompt skeleton (for both test + impl waves)

**Single owner: [`/dispatch`](../dispatch/SKILL.md)** — render both waves'
prompts from there. Its "For test agents" / "For impl agents" type-specific
additions carry the tests-only and do-not-modify-tests rules this wave order
depends on, and its user-facing-surface block carries the runtime-verification
requirement.

Pull the full bead description templates from [handoff-templates.md](../beads/reference/handoff-templates.md).

## Self-review (5 items)

- [ ] All P1 OQs DECIDED in spec bead before impl bead creation
- [ ] Wave ordering: tests merged + cleaned up before impl dispatch
- [ ] Each impl prompt names the specific test file it satisfies
- [ ] Quality gate passed before merging branch to main
- [ ] Spec / decisions / test / impl beads all closed and committed

## See also

- [/spec](../spec/SKILL.md) — produces the spec bead
- [/check](../check/SKILL.md) — produces decisions on the spec bead
- [/test](../test/SKILL.md) — what test agents do
- `/branch`, `/release` — version-branch workflow and tagged release flow.
  **Not links on purpose**: these are PROJECT-scoped skills (lb-agent-factory,
  reef), so there is no file here to point at. Read them in the owning
  project's own `.claude/skills/`, per that project's CLAUDE.md.
- [/orchestrator](../orchestrator/SKILL.md) — worktree-subagent dispatch mechanics
- [/beads reference/handoff-templates.md](../beads/reference/handoff-templates.md) — full per-stage bead templates
