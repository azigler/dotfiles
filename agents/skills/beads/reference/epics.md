# Epics

`br` supports epics via the issue-type system + parent/child relationships.
An epic is a parent bead whose children are the units of actual work.

## When to create an epic vs splitting

Create an epic when:
- The work is genuinely **multi-bead** (not just one bead with 4
  acceptance criteria)
- Children can be worked on **in parallel** by different agents
- Progress visibility matters at the umbrella level (e.g., "Phase 2"
  spans 12 beads — track via epic, not by re-counting beads each time)

Don't create an epic when:
- Work fits in a single atomic bead (1–3 acceptance criteria, 1–3 files)
- Children are strictly sequential and small — a single bead with steps
  is fine

## Create an epic

```bash
# Create the parent epic
EPIC_ID=$(br create -t epic -p 2 "scope: <epic name>" --silent)

# Add the description (epics deserve more context than work beads)
br update "$EPIC_ID" --description "$(cat <<'EOF'
## Epic scope
What does "done" look like at the epic level (vs per-child)?

## Children breakdown
- bd-aaa: <child 1 title> (or "TBD — created during planning")
- bd-bbb: <child 2 title>
- bd-ccc: ...

## Out of scope
What is NOT part of this epic.

## Success criteria
- [ ] All children closed
- [ ] Integration test covering the cross-cutting flow passes
- [ ] Receipt-of-work bead filed if user-facing
EOF
)"

# Create children with --parent
br create -p 2 "scope: child 1 work" --parent "$EPIC_ID"
br create -p 2 "scope: child 2 work" --parent "$EPIC_ID"
```

You can also reparent existing beads: `br update <child-id> --parent <epic-id>`.

## Inspect epic state

```bash
# Show all epics and their progress (open vs closed children)
br epic status

# Show one epic and its tree of children
br dep tree <epic-id>

# Auto-close epics whose children are all closed
br epic close-eligible
```

`br epic status` is great for "what's the macro state of in-flight
work?" — it surfaces stalled epics (no progress in N days), epics with
all children closed but still open (forgot to close), and which child
is blocking.

## Closing an epic

The orchestrator closes the epic AFTER all children are closed AND the
epic-level acceptance criteria pass. `br epic close-eligible` will
list epics ready to close, but DOES NOT close them — you still
explicitly `br close <epic-id>`. This is intentional: the epic-level
"are we actually done?" judgment stays human-driven.

## Epic vs scope tag

Sometimes "scope: title" prefix collisions look like an epic. They're
not. An epic is a single parent bead with children pointing at it.
A shared scope tag (e.g., `auth:`) just groups beads alphabetically
in `br list`.

Use the scope tag when grouping is incidental. Use an epic when you
want a tracked umbrella with progress + close-eligible automation.

## Anti-patterns

- ❌ **Epic with one child** — that's just a regular bead
- ❌ **Open epic with no children** — placeholder; create the children or
  delete the epic
- ❌ **Closing an epic with open children** — `br close <epic-id>` will
  error; close children first or use `br epic close-eligible` to verify
- ❌ **Treating every multi-step task as an epic** — if a single agent
  can do all steps in one session, it's a bead with 3 acceptance
  criteria, not an epic
