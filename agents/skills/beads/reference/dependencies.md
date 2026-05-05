# Bead dependencies

`br dep` declares relationships between beads so the ready-list, blocked
queries, and graph visualizations reflect actual ordering. Use this
instead of carrying ordering rules in your head.

## When to declare dependencies

Declare a dep when one bead **must** complete (or partially progress)
before another can start or merge. Examples:

- impl bead **blocks-on** test bead — impl can't merge until tests are
  written and merged into the version branch
- check bead **blocks-on** spec bead — can't decide on OQs until the
  spec exists
- migration bead **relates-to** rollback bead — they're paired but
  neither blocks the other

## Add / remove deps

```bash
# Atomic: declare dep at create
br create -p 2 "impl: auth tokens" --deps "blocks:bd-tests-auth,relates-to:bd-spec-auth"

# Add later
br dep add <bead-id> blocks <other-bead-id>
br dep add <bead-id> relates-to <other-bead-id>

# Remove
br dep rm <bead-id> <other-bead-id>
```

Available dep types (commonly used):

| Type | Meaning |
|---|---|
| `blocks` | This bead BLOCKS the other (other can't proceed until this closes) |
| `blocked-by` | This bead is BLOCKED BY the other (inverse of `blocks`) |
| `relates-to` | Loose relationship — soft signal, no enforcement |
| `parent` | Parent-child epic relationship (use `--parent` flag instead, but the dep type backs it) |

## Inspect deps

```bash
# Show direct deps of one bead
br dep list <bead-id>

# Walk the full tree from a root bead
br dep tree <bead-id>

# Detect cycles (the bug-finder)
br dep cycles

# Show what's currently READY (open + not blocked + not deferred)
br ready

# Show what's currently BLOCKED
br blocked
```

`br ready` is the orchestrator's go-to for "what should I dispatch next?"
— it filters out beads that aren't actionable yet.

## Dependency graph for the whole repo

```bash
br graph                # full text-art dep graph
br graph --json         # for tooling
```

Useful when planning a complex epic: see how a proposed split decomposes
naturally vs forces unnecessary serialization.

## Common patterns

### Test → Impl wave ordering

The `/orchestrator` and `/impl` skills require test beads to merge
BEFORE impl beads dispatch. Encode this:

```bash
TEST_ID=$(br q "tests: spec-auth")
IMPL_ID=$(br q "impl: auth")
br dep add "$IMPL_ID" blocked-by "$TEST_ID"
```

Now `br ready` won't surface IMPL_ID until TEST_ID is closed.

### Fix-bead → evaluator pairing

```bash
FIX_ID=$(br create -p 1 "fix: accounts — ack message format" --silent)
EVAL_ID=$(br create -p 2 "eval: guard ack message regression" --silent)
br dep add "$EVAL_ID" blocked-by "$FIX_ID"
```

Eval bead surfaces in `br ready` only after fix lands.

### Spec → Check → (Test, Impl) parallelization

```bash
SPEC_ID=$(br q "spec: auth subsystem")
CHECK_ID=$(br create -p 1 "check: auth open questions" --parent "$SPEC_ID" --silent)
br dep add "$CHECK_ID" blocked-by "$SPEC_ID"

# After check completes:
TEST_ID=$(br create -p 2 "tests: auth" --parent "$SPEC_ID" --silent)
IMPL_ID=$(br create -p 2 "impl: auth" --parent "$SPEC_ID" --silent)
br dep add "$TEST_ID" blocked-by "$CHECK_ID"
br dep add "$IMPL_ID" blocked-by "$TEST_ID"
```

The graph captures the wave-ordering rule the SKILLs talk about —
without relying on the orchestrator to remember it.

## Anti-patterns

- ❌ **Hand-tracking ordering** in your head — use `br dep` so `br ready`
  is the source of truth
- ❌ **Cycles** — `br dep cycles` finds them. If A blocks B and B blocks
  A, neither can ready; split or refactor
- ❌ **Over-declaring `blocks`** when `relates-to` is enough — `blocks`
  is a hard gate; abuse it and `br ready` becomes empty
- ❌ **Forgetting to update deps when a bead is reframed** — if scope
  changes, re-check `br dep tree` and prune stale relationships
