---
description: Fleet-wide hygiene pass -- mechanical text work + cross-repo state audit, CLAUDE.md/skill consistency, bead closure, lint fixes
when_to_use: Weekly / pre-release mechanical hygiene ritual (autonomous-OK), or one-off CLAUDE.md refresh, deprecation markers, orphan closure, lint autofix, skill-drift audit. Pairs with /triage.
---

# Housekeeping

Mechanical, non-creative changes that don't introduce new logic or behavior,
PLUS a fleet-wide state audit that keeps the factory and all agent clones
aligned with reality.

## What Housekeeping IS

**Single-repo mechanical work:**
- Deleting deprecated code (entire directories, files, dead imports)
- Adding deprecation markers to spec documents
- Updating architecture decisions in PLAN.md and CLAUDE.md
- Writing documentation (setup guides, workflow docs)
- Terminology renames (find-and-replace across files)
- Version bumps (package.json, constants)
- Stale doc/table cleanup (removing hardcoded counts, outdated tables)
- Gitignore updates
- Skill file creation or maintenance
- README/CLAUDE.md updates
- Fixing broken internal links or cross-references
- Removing dead tests for deleted code

**Fleet-wide audit work:**
- CLAUDE.md identity check across every agent clone (first line must
  read `# lb-agent-<name>`, not `# lb-agent-factory`)
- Skill consistency check between global (`~/.claude/skills/`, symlinked
  from dotfiles) and factory (`~/linearb/agent-factory/.claude/skills/`);
  LinearB-native skills are canonical in `~/linearb/.claude/skills/`
- Bead hygiene: close beads whose work is actually done (especially
  `in_progress` beads that have been finished for a while); fix
  stale JSONL status
- Lint fixes: run `biome check --write` across factory + every agent
  and commit the auto-fixes
- Distribute verification: every agent at latest factory main
- Systemd service state: workers running, dev servers healthy
- Worktree cleanup: no leftover `.claude/worktrees/` directories from
  previous subagent runs
- Memory audit: stale session memories, outdated feedback, missing
  index entries in `MEMORY.md`

All of these are deterministic. No design judgment required — the state
either matches reality or it doesn't.

## What Housekeeping is NOT

- New features or capabilities (use `/spec` then `/test` then `/impl`)
- Spec amendments (use `/spec`)
- Test writing for new features (use `/test`)
- Open question resolution (use `/review`)
- Refactoring that changes behavior or API surface (use `/impl`)

If you're uncertain whether something is housekeeping, ask: "Does this require
reading a spec or making a design decision?" If yes, it's not housekeeping.

## Workflow

### 1. Inventory

List every file and change needed. Group by type:

| Type | What to check |
|------|---------------|
| **Deletion** | Grep for imports from target paths before deleting |
| **Deprecation** | Read each spec to confirm it's fully superseded |
| **AD update** | Read the current AD text and the spec that changes it |
| **Doc creation** | Read the source material being converted to docs |

```bash
# Example: verify nothing imports from directories being deleted
rg "from.*factory/scaffold" --type ts
rg "from.*factory/setup" --type ts
rg "from.*factory/update" --type ts
rg "from.*templates/" --type ts
```

### 2. Dependency Check (Critical for Deletions)

Before deleting any directory or file:

1. **Grep for imports** -- search all `.ts` files for import paths referencing the target
2. **Grep for requires** -- search for `require()` calls
3. **Check test files** -- tests for deleted code should also be deleted
4. **Check package.json** -- remove script aliases and dependencies that only served deleted code
5. **Check CLAUDE.md** -- update directory layout if it references deleted paths

```bash
# Full dependency scan before deletion
rg "(from|require).*factory/(scaffold|setup|update|cli|registry|connectors|types|layers)" --type ts
rg "(from|require).*templates/" --type ts
```

If anything imports from a deletion target, classify:
- **Also being deleted** -- safe, proceed
- **Not being deleted** -- STOP. This needs code changes, which is `/impl` work

### 3. Apply Changes

Work in this order to avoid broken intermediate states:

1. **Delete code** -- remove deprecated directories and files
2. **Delete tests** -- remove tests for deleted code
3. **Update package.json** -- remove dead scripts and deps
4. **Add deprecation markers** -- update spec frontmatter
5. **Update architecture decisions** -- rewrite ADs in PLAN.md
6. **Update CLAUDE.md** -- reflect new directory layout and decisions
7. **Write new documentation** -- setup guides, workflow docs

### 4. Verify (Deterministic Quality Gates)

```bash
# Confirm deletions
ls factory/scaffold/ 2>/dev/null && echo "FAIL: scaffold still exists" || echo "OK"
ls factory/setup/ 2>/dev/null && echo "FAIL: setup still exists" || echo "OK"
ls factory/update/ 2>/dev/null && echo "FAIL: update still exists" || echo "OK"
ls templates/ 2>/dev/null && echo "FAIL: templates still exists" || echo "OK"

# Confirm no dangling imports
rg "(from|require).*(factory/scaffold|factory/setup|factory/update|templates/)" --type ts

# If TypeScript code was touched:
bunx tsc --noEmit 2>&1 | tail -20
bun test 2>&1 | tail -20

# Confirm preserved directories
ls factory/feedback/ factory/sharing/ factory/o11y/ connectors/
```

Skip build/test checks if only documentation files were changed.

**Mass deletions require grep-based quality gates.** After deleting, run
deterministic grep scans for import paths referencing deleted modules. Never
trust a self-reported "done" without independent verification.

### 5. Deprecation Markers for Specs

Add a deprecation notice at the top of each deprecated spec, below the title:

```markdown
> **DEPRECATED by Spec 25 (Singleton Agent Model).** This spec describes
> systems that have been removed. It is retained as historical reference.
> See Spec 25 for the replacement.
```

Do NOT delete deprecated specs. They are historical reference.

### 6. Architecture Decision Updates

When updating ADs in PLAN.md:

- **Deprecated ADs** -- add `**DEPRECATED.**` prefix to the decision text
  and note which spec/AD replaces it
- **Replaced ADs** -- rewrite the decision text and rationale to reflect
  the new model. Preserve the AD number for cross-reference stability
- **New ADs** -- add with the next sequential number

### 7. Commit and Push

Follow `/commit` conventions. Use the gitmoji that best fits:

| Change type | Emoji |
|-------------|-------|
| Remove dead code/files | `:fire:` |
| Doc updates | `:memo:` |
| Config/tooling | `:wrench:` |
| Renames, moves | `:truck:` |
| Structure/formatting | `:art:` |

For large housekeeping passes, split into multiple atomic commits:
1. `:fire:` Deletions first (code + tests + deps)
2. `:memo:` Deprecation markers + AD updates
3. `:memo:` New documentation
4. `:memo:` CLAUDE.md + README.md refresh

Each commit should be independently valid (no broken imports, no dangling refs).

## 8. Project Documentation Refresh

Every housekeeping pass should end with a documentation and memory audit:

### CLAUDE.md
- **Directory Layout** -- does it match the actual filesystem after deletions?
- **Key Commands** -- are all listed commands still valid?
- **Architecture Decisions** -- do they match the ADs in PLAN.md?
- **Conventions** -- any new patterns or deprecated ones to update?

### README.md
- **Version** -- does it match the latest git tag?
- **Phase status** -- does the progress section match PLAN.md?
- **How It Works diagram** -- does it reflect the current architecture?
- **Getting Started** -- are the instructions still correct?
- **Commands** -- are the listed CLI commands still valid?

### Memory (`.claude/projects/.../memory/`)
- **Stale project memories** -- any that describe completed phases or old models?
- **Outdated feedback** -- any feedback that no longer applies?
- **Missing memories** -- anything learned this session worth persisting?
- **MEMORY.md index** -- does it match the actual files?

### `~/explore/INDEX.md` (explore umbrella only)
The theme-clustered concept-map of the compendium (the connective tissue
the flat `CHILDREN.md` children table lacks; audit `explore-doj`). When
housekeeping runs in `~/explore`:
- **New explorations** -- is every folder/submodule in INDEX.md, in the
  right cluster? (cross-check against the `CHILDREN.md` children table.)
- **Cross-cluster connections** -- still accurate after new additions?
- **Biggest-unconnected-opportunities** -- regenerate; these seed the
  next `/elevate` sweep. Stale-but-still-valid clusters are fine to keep.
- Regenerate by re-reading `*/FINDINGS.md` essences; verify relative links
  resolve (`grep -oE '\]\([^)]+\)' INDEX.md` then test each path).

Audit each, fix what's stale, and commit as a final `:memo:` commit in the pass.

## 9. Fleet-Wide Hygiene Pass

The factory + agent clones are a fleet. A full housekeeping run should end
in a green bill of health across all of them. Run these checks from the
factory root.

### 9.1 CLAUDE.md identity check

Every agent's `CLAUDE.md` must start with its own identity. Factory's generic
`CLAUDE.md` does NOT belong in any clone. If an agent's first line reads
`# lb-agent-factory`, `/distribute` clobbered it and we need to restore.

```bash
for agent in agents/lb-agent-*/; do
  name=$(basename "$agent")
  first=$(head -1 "$agent/CLAUDE.md")
  expected="# $name"
  [ "$first" = "$expected" ] && echo "OK $name" || echo "FAIL $name: $first"
done
```

If any agent fails, the fix is in `/distribute` (auto-resolve CLAUDE.md
with `--ours`). Don't paper over by hand-editing each clone.

### 9.2 Skill consistency check

Paragon skills are canonical in dotfiles and surface as `~/.claude/skills/`
(a symlink to `~/dotfiles/agents/skills/`). The old dotfiles→team distribute
flow is retired — the team now consumes skills via the hand-maintained
`lb-marketing` plugin, and LinearB-native skills (apex, imc, linearb-*, the
builders) are canonical in `~/linearb/.claude/skills/`. There is no longer an
auto-synced mirror to diff against.

The one place a paragon skill still exists in a second copy is the factory
(`~/linearb/agent-factory/.claude/skills/<name>/SKILL.md`), which propagates
into agent clones via upstream merges. Those copies MUST stay byte-identical
to the dotfiles source (or carry a known intentional divergence).

```bash
for skill in ~/.claude/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$skill")")
  factory="$HOME/linearb/agent-factory/.claude/skills/$name/SKILL.md"
  [ -f "$factory" ] || continue
  diff -q "$skill" "$factory" > /dev/null && echo "OK $name" || echo "DRIFT $name"
done
```

When drift is found, sync the factory copy from the dotfiles-backed global
source (`cp`), not the other way around.

### 9.3 Bead hygiene

The open-beads list drifts out of truth as work ships. **Run `/triage`
as the deeper sub-pass** for full bead-state cleanup. The minimum
quick-pass below is what /housekeeping always runs:

```bash
br stats                    # high-level counts
br orphans                  # referenced in commits but still open (handoff failures)
br stale --days 14          # no activity in 14+ days
br epic close-eligible      # epics whose children are all closed
br list --status in_progress # zombies (claimed but no recent activity)
```

For each surfaced item:

- **Orphan** → close (work is done) or reopen with `--notes` describing partial state
- **Stale + relevant** → declare the dep so it shows in `br blocked` instead, OR `br defer` it
- **Stale + irrelevant** → close with `--notes` reason
- **Close-eligible epic** → close it
- **Zombie in_progress** → if work continues, add a `--notes` indicator;
  otherwise demote to `open`

```bash
br close <id>
git add .beads/issues.jsonl
git commit -m ":card_file_box: beads: close <ids>"
```

If `br show <id>` shows wrong data (DB/JSONL drift), run `br doctor`
for diagnosis + repair, then `br sync --import-only --force` to rebuild
the DB from JSONL. Edit JSONL directly only as last resort.

For the deeper walk (zombie reasoning, dep-cycle detection, defer
decisions), invoke `/triage` — it's the dedicated skill.

### 9.3a ARCHITECTURE.md regeneration from active decision beads

When a project has a `docs/ARCHITECTURE.md` (or `ARCHITECTURE.md` at
repo root), it should be a **derived view** of active `-t decision`
beads — never hand-edited. The pattern:

```bash
# Project-specific — adjust path + transform per project's CLAUDE.md
if [ -f docs/ARCHITECTURE.md ] || [ -f ARCHITECTURE.md ]; then
  ARCH_FILE=$(ls docs/ARCHITECTURE.md ARCHITECTURE.md 2>/dev/null | head -1)
  {
    echo "# Architecture"
    echo
    echo "_Derived from active \`-t decision\` beads — do not hand-edit._"
    echo "_Regenerated by \`/housekeeping\` on $(date -u +%Y-%m-%d)._"
    echo
    br list --type decision --status open --json 2>/dev/null \
      | jq -r '.[] | "## \(.title)\n\n**Bead:** \(.id) · **Date:** \(.created_at[0:10])\n\n\(.description)\n\n---\n"'
  } > "$ARCH_FILE"
fi
```

The discipline:

- **ARCHITECTURE.md is never hand-edited**. It's a generated artifact.
- **Only active decision beads contribute** — superseded ones stay in
  the bead archive but don't pollute the canonical view.
- **Regeneration happens on every `/housekeeping` pass** so the doc
  can't drift from the underlying decisions.
- Some projects may want `docs/architecture/` as a directory with
  per-decision pages instead of one monolithic file — adapt the
  transform accordingly.

If a project doesn't have any `-t decision` beads, skip the substep.
The pattern is opt-in per project.

Beads live in the factory-level `.beads/` only; agent clones symlink
`.beads/` → `../../.beads/` (relative) so there is one source of truth.
If an agent's `.beads` is a real directory instead of a symlink, that's a
drift — fix it by removing the dir and recreating the symlink.

```bash
for agent in agents/lb-agent-*/; do
  if [ -L "$agent.beads" ]; then continue; fi
  echo "FAIL $(basename "$agent") has a real .beads dir"
done
```

### 9.4 Lint fixes

Biome's auto-fixes are safe in bulk. Run across factory + every agent; commit
whatever changes per-repo.

```bash
# Factory
biome check --write . 2>&1 | tail -3

# Each agent
for agent in agents/lb-agent-*/; do
  pushd "$agent" > /dev/null
  biome check --write . 2>&1 | tail -3
  if [ -n "$(git status --short)" ]; then
    git add -u  # tracked files only
    git commit -m ":art: lint: biome auto-fixes" && git push origin main
  fi
  popd > /dev/null
done
```

Do NOT run unsafe fixes in bulk — those require per-fix judgment.

### 9.5 Distribute verification

Every agent should be at (or ahead of) the latest factory main. If the
factory has unpushed commits or an agent is behind, run `/distribute`.

```bash
echo "factory unpushed: $(git log origin/main..HEAD --oneline | wc -l)"
for agent in agents/lb-agent-*/; do
  pushd "$agent" > /dev/null
  git fetch upstream main --quiet 2>/dev/null
  behind=$(git rev-list --count HEAD..upstream/main)
  dirty=$(git status --short | grep -v '^??' | wc -l)
  printf '%-24s behind=%s dirty=%s\n' "$(basename "$agent")" "$behind" "$dirty"
  popd > /dev/null
done
```

### 9.6 Systemd service state

Worker services must be running after a housekeeping pass (especially after
any code-level cleanup or lint-autofix commits).

```bash
for svc in lb-product lb-product-worker lb-accounts-worker lb-listener; do
  systemctl --user is-active "$svc" > /dev/null && echo "OK $svc" || echo "FAIL $svc"
done
```

Restart any failed services and tail their journalctl for a few seconds to
confirm they stabilize.

### 9.7 Worktree cleanup

Leftover `.claude/worktrees/agent-*/` directories from previous subagent
runs accumulate. Clean up any that are no longer locked / in-flight.

```bash
# Factory
ls .claude/worktrees/ 2>/dev/null
# Per-agent
for agent in agents/lb-agent-*/; do
  ls "$agent.claude/worktrees/" 2>/dev/null
done

# Remove stale ones (git worktree remove -f -f if force-needed)
git worktree list
git worktree prune
```

### 9.8 refs/INDEX.md (when refs/ exceeds ~10 files)

When a project's `refs/` directory grows past ~10 files, agents waste
tokens listing the directory each session. Maintain a one-line-per-file
index:

```bash
# refs/INDEX.md (kept current via /housekeeping)

# Format: each line `- [<filename>](<filename>) — <one-line description>`
# Reads in <100 tokens; avoids `ls refs/ | head -100` per session.
```

Generation pattern:

```bash
if [ -d refs ] && [ "$(ls refs/ | wc -l)" -gt 10 ]; then
  {
    echo "# refs/ index"
    echo ""
    echo "Quick map of reference material in this project. Add a one-line description per file."
    echo ""
    for f in refs/*.md; do
      name=$(basename "$f")
      first=$(head -1 "$f" | sed 's/^# *//')
      echo "- [$name]($name) — $first"
    done
  } > refs/INDEX.md
fi
```

After regenerating, eyeball the descriptions — first-line headers
are usually accurate but may need clarification. Commit as
`:memo: refs: refresh INDEX.md`.

Skip for `refs/` dirs under 10 files — listing is still cheap there.

### 9.9 Memory index refresh

After a multi-hour session, MEMORY.md often misses new memories or contains
stale references. Sanity check:

```bash
ls ~/.claude/projects/-home-ubuntu-linearb-agent-factory/memory/*.md | wc -l
wc -l ~/.claude/projects/-home-ubuntu-linearb-agent-factory/memory/MEMORY.md
```

Fix any drift; MEMORY.md's one-line-per-file index should reference every
memory file under the same directory.

## Exit Criteria

A housekeeping pass is done when:

- [ ] Factory: `git status` clean, `git log origin/main..HEAD` empty
- [ ] All agents: same. No dirty tracked files, no unpushed commits
- [ ] All agent `CLAUDE.md` first lines = `# lb-agent-<name>`
- [ ] All agent `.beads/` are symlinks (to `../../.beads/`)
- [ ] No drift between global / canonical / factory copies of a skill
- [ ] `br list` shows only actually-open work
- [ ] `biome check .` clean across factory + each agent (or auto-fixes
      committed)
- [ ] `systemctl --user is-active` green for every worker and dev-server
- [ ] No stale worktrees
- [ ] `MEMORY.md` index matches actual memory files

Report the tally when done. Incomplete items should be filed as follow-up
beads, not left open in the exit report.
