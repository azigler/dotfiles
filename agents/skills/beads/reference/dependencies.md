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

The real signature is **2 positional args + a `-t/--type` flag**, not
3 positional args — `br dep add <ISSUE> <DEPENDS_ON>` reads "ISSUE
depends on DEPENDS_ON"; `-t` defaults to `blocks` if omitted (verified
br 0.2.16 — `br dep add A blocks B` errors `unexpected argument 'B'
found`; the type is NOT a bare third positional):

```bash
# Atomic: declare dep at create
br create -p 2 "impl: auth tokens" --deps "blocks:bd-tests-auth,relates-to:bd-spec-auth"

# Add later — ISSUE, DEPENDS_ON, then -t <type>
br dep add <bead-id> <other-bead-id> -t blocks
br dep add <bead-id> <other-bead-id> -t relates-to

# Remove
br dep rm <bead-id> <other-bead-id>
```

Full dep types (the real `DependencyType` enum, per br 0.2.16's own
validation error — the doc previously listed `blocked-by` and `parent`,
neither of which exists):

| Type | Meaning | Cycle-checked? |
|---|---|---|
| `blocks` | This bead BLOCKS the other (other can't proceed until this closes) | yes |
| `parent-child` | Epic/child containment — stored as **child → parent**, but the cycle detector treats it with **reversed** direction (parent → child) when checking against `blocks`/`conditional-blocks`/`waits-for` edges on the same pair (verified: adding `blocks child→parent` on top of an existing `parent-child` edge for that same child/parent is rejected as a cycle, even though both literal edges point the same way in the DB) | yes |
| `conditional-blocks` | Soft/conditional blocking | yes |
| `waits-for` | This bead waits for the other before proceeding | yes |
| `related` | Loose relationship — soft signal, no enforcement | no |
| `relates-to` | Loose relationship — soft signal, no enforcement | no |
| `discovered-from` | This bead was discovered while working the other | no |
| `replies-to` | Threaded reply relationship | no |
| `duplicates` | This bead duplicates the other | no |
| `supersedes` | This bead supersedes the other | no |
| `caused-by` | This bead was caused by the other | no |

Only the first four (`blocks`, `parent-child`, `conditional-blocks`,
`waits-for`) participate in `br dep cycles` / add-time cycle rejection;
the rest never trigger a cycle error no matter how they're wired (verified:
adding `relates-to` in both directions between the same two beads succeeds
with no cycle error, while the equivalent `blocks` round-trip is rejected
at add-time with `Cycle detected in dependencies`).

There is no `blocked-by` type — write the dependency from the blocked
bead's side instead: `br dep add <blocked-id> <blocker-id> -t blocks`.
There is no bare `parent` type either — use `--parent <epic-id>` at
create time, which is backed by a `parent-child` dep under the hood.

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
br graph --all           # full text-art dep graph (ISSUE or --all is required)
br graph --all --json    # for tooling
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
br dep add "$IMPL_ID" "$TEST_ID" -t blocks
```

Now `br ready` won't surface IMPL_ID until TEST_ID is closed.

### Fix-bead → evaluator pairing

```bash
FIX_ID=$(br create -p 1 "fix: accounts — ack message format" --silent)
EVAL_ID=$(br create -p 2 "eval: guard ack message regression" --silent)
br dep add "$EVAL_ID" "$FIX_ID" -t blocks
```

Eval bead surfaces in `br ready` only after fix lands.

### Spec → Check → (Test, Impl) parallelization

```bash
SPEC_ID=$(br q "spec: auth subsystem")
CHECK_ID=$(br create -p 1 "check: auth open questions" --parent "$SPEC_ID" --silent)
br dep add "$CHECK_ID" "$SPEC_ID" -t blocks

# After check completes:
TEST_ID=$(br create -p 2 "tests: auth" --parent "$SPEC_ID" --silent)
IMPL_ID=$(br create -p 2 "impl: auth" --parent "$SPEC_ID" --silent)
br dep add "$TEST_ID" "$CHECK_ID" -t blocks
br dep add "$IMPL_ID" "$TEST_ID" -t blocks
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
