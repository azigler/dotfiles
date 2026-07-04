---
description: Walk open questions / cross-spec conflicts / cross-spec dependencies on a spec bead and record decisions ON the bead — not in a separate decisions document. Generates the Implementation Readiness summary as a child bead so /test and /impl can dispatch. Distinct from the built-in /review (PR review).
when_to_use: User asks to "check the OQs", "walk the open questions on bd-XXXX", "decide on conflicts", "resolve dependencies for the auth spec". Runs after /spec, before /test and /impl.
---

# /check — Decisions Workflow

You guide the user through the **open questions, conflicts, and
dependencies** declared in a spec bead's Section 6, recording each
decision on the same bead so `/test` and `/impl` get a clean handoff.

This skill is paired with `/spec`. It reads the spec bead's
`--description` and writes resolutions to the spec bead's `--notes`
(or to a child decisions bead — see Output below).

## Inputs

1. **Mode** — one of:
   - A specific item: `check OQ-03 on bd-XXXX`
   - A batch: `check all P1 on bd-XXXX`
   - Everything: `check all on bd-XXXX`
2. **Bead ID** — the spec bead (or check-child bead) to walk
3. Your own bead trailer — `Bead: <id>` in commit messages (see /commit)

## Step 1: Load context (in main session)

```bash
br show <spec-bead-id>           # full spec content
br dep tree <spec-bead-id>       # related beads
br search <related-scope>        # adjacent specs / decisions
```

Read `CLAUDE.md` and any related specs the bead references. If the
spec bead has existing `--notes`, read those too — earlier `/check`
sessions may have already resolved some items.

## Step 2: Present each item with expert analysis

### For Open Questions (from spec Section 6)

```
### OQ-NN: <title>
**Priority:** P1/P2/P3
**Source:** spec bead bd-XXXX, Section 6
**Affects:** <subsystems / specs>

**Question:** <verbatim from the spec bead>

**Author's Recommendation:** <from the spec bead>

**Expert Analysis:**
- **Current state:** what the system does today, or what existing
  code / docs say
- **Alternatives:** concrete pros / cons of each option
- **Prior art:** how similar systems handle this, with refs

**Recommendation:** ACCEPT / MODIFY / DEFER
<2-3 sentence rationale>
```

### For Cross-spec conflicts

```
### Conflict #N: <title>
**Specs involved:** bd-XXXX vs bd-YYYY (or specs/NN.md vs specs/MM.md)
**Affects:** <subsystems>

**The inconsistency:** <description>

**Expert Analysis:**
- **Root cause:** why the specs diverged
- **Recommended resolution:** which spec changes, how
- **Impact if unresolved:** what breaks during impl

**Recommendation:** ACCEPT / MODIFY / DEFER
```

### For Cross-spec dependencies

```
### Dependency #N: <title>
**Specs involved:** bd-XXXX, bd-YYYY, ...

**The dependency:** <description>

**Expert Analysis:**
- **Interface contract:** what these specs must agree on
- **Implementation ordering:** which must finish first
- **Current state:** aligned, or needs spec updates?

**Recommendation:** CONFIRMED / NEEDS spec update / DEFER
```

Keep analysis concrete. Cite docs, code, RFCs. No hand-waving.

## Step 3: Record decisions on the bead

When the user decides, **append** the resolution to the spec bead's
`--notes`. The `--notes` field is intended as an append-only working
log — but **`br update --notes` itself is REPLACE-only** (verified
br 0.2.5 → 0.2.15). Calling it twice in succession wipes the prior
content. To "append" you must read the existing notes first and
re-submit the full body in a single update.

```bash
# Read existing --notes verbatim first:
EXISTING=$(br show <spec-bead-id> | awk '/^Notes:/{flag=1; next} flag')

# Compose the new full body = existing + your new decision block:
NEW_BLOCK=$(cat <<'EOF'

## Decision: OQ-03 — DECIDED 2026-04-26

**Question:** Should sessions support concurrent writes from multiple agents?
**Decision:** No, single-writer per session. Reads can be concurrent.
**Rationale:** Avoid SQLite WAL contention; agents serialize via fleet proxy.
**Spec impact:** spec bead bd-XXXX Section 4 — add note that the API rejects
concurrent writes with `ConcurrentSessionError`.

---
EOF
)

# Single update with full body (existing + new):
br update <spec-bead-id> --notes "$EXISTING$NEW_BLOCK"
```

**Anti-pattern**: calling `br update --notes "<just the new block>"`
in a loop. Each call wipes the prior content. If you do this, you
silently lose every earlier decision note on that bead.

If you need to walk multiple OQs in one session, compose the FULL
post-walk notes body in memory first, then write it once at the end.
Filed as `bd-otl8` (tracked there pending a `br` upstream fix).

If the decision **affects the spec content**, the orchestrator should
re-dispatch `/spec` to revise the spec bead's `--description`. Do NOT
edit the spec bead's `--description` from inside `/check` — keep
write-responsibility clear (spec agent owns the spec; check agent owns
the decisions trail).

### Discovering new OQs during the walk

If you find a gap not in Section 6:

1. Propose: "This looks like a new OQ. Want me to add it?"
2. If yes, add it via `br update <spec-bead-id> --notes "## New OQ: <title>..."` (don't edit `--description`; that's the spec agent's job)
3. Continue with the walk

## Step 4: Batch mode

When the user says "check all P1 on bd-XXXX":

1. List all P1 OQs and their status from the bead
2. Skip already-DECIDED ones
3. Present open ones one at a time
4. Ask "Continue to next?" between each
5. Summarize all decisions at the end

Same pattern for P2/P3 batches and for "check all conflicts on
bd-XXXX" / "check all deps on bd-XXXX".

When the user says "check all on bd-XXXX":
- All P1 OQs first (block impl)
- All open conflicts
- All open dependencies
- All P2 OQs
- All P3 OQs (can defer)

## Step 5: Implementation Readiness summary

When ALL P1 OQs are DECIDED and ALL conflicts are RESOLVED, write the
Readiness summary to the spec bead's `--notes`:

```bash
br update <spec-bead-id> --notes "$(cat <<'EOF'
## Implementation Readiness — 2026-04-26

**P1 OQs decided:** 5/5
**P2 OQs decided:** 3/4 (OQ-09 deferred to v0.3)
**Conflicts resolved:** 2/2
**Dependencies confirmed:** 3/3

### Subsystem readiness
- Auth: READY
- Storage: READY
- API: BLOCKED by spec bd-YYYY OQ-12

### Spec updates needed (re-dispatch /spec to apply)
- spec bead bd-XXXX Section 4: add ConcurrentSessionError clause
- spec bead bd-XXXX Section 6: mark OQ-09 as DEFERRED-TO-v0.3

### Recommended impl order
1. Auth (no deps)
2. Storage (depends on Auth)
3. API (waits for bd-YYYY OQ-12)
EOF
)"
```

This summary is the handoff artifact for `/test` and `/impl`. The
orchestrator reads it via `br show <spec-bead-id>`.

## Step 6: Commit

Your check-bead should be typed `decision` so it's discoverable via
`br list --type decision`:

```bash
# Orchestrator created your check bead — set the type if it isn't already:
br update <your-check-bead-id> --type decision

br sync --flush-only
git add .beads/issues.jsonl
git commit -m ":memo: decisions: resolve OQ-NN [, conflict N, dep N] on bd-XXXX

Bead: <your-check-bead-id>"
```

## Self-review (5 items)

- [ ] Each decision has rationale (not just a yes/no)
- [ ] Spec impact noted for decisions that change spec content
- [ ] All P1 OQs touched (decided or deferred — never silently skipped)
- [ ] New OQs discovered are written to `--notes`, not `--description`
- [ ] Implementation Readiness summary written when blockers clear

## Pre-existing spec FILES

If the project's spec lives in `specs/NN-name.md` (file-based, pre-bead
era), this skill still applies — read the file's Section 6 and write
decisions to a NEW decisions bead with `--parent` pointing at any
related implementation bead. The legacy `DECISIONS.md` pattern (file)
is also acceptable in those projects; follow the project's CLAUDE.md
for which path to use.

## See also

- [/spec](../spec/SKILL.md) — produces the spec bead this skill walks
- [/beads reference/handoff-templates.md](../beads/reference/handoff-templates.md) — bead description templates
- [/test](../test/SKILL.md) — runs after Implementation Readiness summary
- [/impl](../impl/SKILL.md) — runs after /test (per /orchestrator wave ordering)
