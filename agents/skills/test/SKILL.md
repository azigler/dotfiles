---
description: Test-writing — converts a spec bead's Section 5 cases into executable tests, plus adds ≥5 edge / error tests beyond the spec. Pairs with /spec (input) and /impl (downstream consumer). Test agents NEVER touch implementation source files. Test files live at conventional paths per language (TS __tests__/, Python tests/, Rust tests/+#[cfg(test)], Go *_test.go).
argument-hint: "<spec-bead-id>"
---

# /test — Test Creation

You are a test-writing agent. Your input is a **spec bead** typed
`spec` (or legacy `specs/NN.md` file). Your output is **only test
files** — no implementation, no stubs.

## Inputs

1. **Spec bead ID** (or spec file path) — the spec under test
2. **Your bead ID** (typed `test`) — your tracking bead
3. **Project test path convention** — read from CLAUDE.md or default below

## Critical: test agents write ONLY test files

You must NEVER create or modify implementation source files. Your output
is exclusively test files.

### Import from real module paths, not stubs

```typescript
// CORRECT
import { loadAgentConfig } from "../loader.js";
import type { AgentConfig } from "../types.js";

// WRONG
const loadAgentConfig = () => { throw new Error("not implemented"); };
```

If the imported module doesn't exist yet, the test won't parse. Three
strategies, in order of preference:

1. **Import only from modules you're confident exist.** Most spec test
   cases test the public API; if the impl agent will create
   `loader.ts` exporting `loadAgentConfig`, the test imports that path
   and fails at runtime (correct TDD), not at parse time.
2. **Use dynamic imports** for tests that need optional / runtime
   modules: `const mod = await import("../loader.js")`.
3. **Skip with a reason** for tests blocked by infrastructure that
   won't exist even after impl (running server, external service):
   - Rust: `#[ignore = "needs running database"]`
   - TypeScript: `test.skip("needs Next.js runtime", () => { ... })`
   - Python: `@pytest.mark.skip(reason="needs running Redis")`
   - Go: `t.Skip("needs running database")`

Skipping for "the imported module doesn't exist yet" is **not allowed**
— write the test as active. The impl agent makes it pass.

## Step 1: Load context

```bash
br show <spec-bead-id>           # spec content (Section 5 = test cases)
br show <spec-bead-id> | grep -A1 "Decisions"   # decisions in --notes
```

If the spec is a legacy file: read `specs/NN-name.md` and any
`DECISIONS.md` the project uses.

Also read `CLAUDE.md` for the project's test path convention.

## Step 2: Test output path

Read `CLAUDE.md` first — the project may declare its convention. If
not, use the language defaults:

| Language | Convention | Example |
|---|---|---|
| TypeScript / JavaScript | `src/<feature>/__tests__/<name>.test.ts` (Bun, Vitest, Jest) | `src/auth/__tests__/loader.test.ts` |
| Python | `tests/test_<module>.py` (pytest) | `tests/test_loader.py` |
| Rust | `src/<module>.rs` `#[cfg(test)] mod tests {}` for unit; `tests/<name>.rs` for integration | `tests/auth_integration.rs` |
| Go | `<file>_test.go` next to the source | `loader_test.go` |

Monorepo: tests live next to the package they test, not at root.
Workspace: same.

If the spec covers multiple modules, use ONE test file per module
(don't dump all tests into one file).

## Step 3: Convert spec cases to executable tests

For each `TEST: ...` block in spec Section 5:

1. Set up necessary state
2. Execute the operation in INPUT
3. Assert EXPECTED
4. Include RATIONALE as a doc comment

## Step 3.5: When the unit delegates, test the delegation

If the function under test calls into other modules (a "delegating" or
"adapter" pattern), at least one test must **spy on the dependency
and assert it was called** — not just mock-replace the unit and assert
its return value.

The failure mode this prevents: an impl agent ships a stub body that
returns the right SHAPE but does no actual work. If the test mocks the
unit entirely (`mock.module("./my-step.js", () => ({ myStep: () => ... }))`),
it tests the mock, not the real body. Tests pass; production silently
no-ops.

**Bad** (mocks the unit being tested — only validates the mock):

```typescript
mock.module("../app/workflows/steps.js", () => ({
  gatherEvidence: async () => ({ events: ["mock"] }),
}));
test("workflow uses gathered evidence", async () => {
  const result = await analyzeWorkflow({...});
  expect(result.events).toEqual(["mock"]);  // tests the mock return
});
```

**Good** (spies on the real dependency the unit delegates to):

```typescript
import * as collector from "../lib/accounts/collector.js";
import { spyOn } from "bun:test";

test("gatherEvidence delegates to collector.collectAccountEvidence", async () => {
  const spy = spyOn(collector, "collectAccountEvidence")
    .mockResolvedValue({ events: [] });
  const { gatherEvidence } = await import("../app/workflows/steps.js");
  await gatherEvidence({ account: "Eptura" });
  expect(spy).toHaveBeenCalledWith(expect.objectContaining({ account: "Eptura" }));
  spy.mockRestore();
});
```

The delegation test runs the REAL body and verifies it actually calls
the dependency. A stub body would never invoke the spy, and the test
fails immediately.

**When to add delegation tests:**

- Workflow step / handler / wrapper functions that call into business-logic modules
- Integration adapters (Slack/Stripe/Anthropic/etc. SDK callers) — assert the SDK method was called with expected args
- Anything where a stub body of the right type signature would type-check but produce no side effect

For each delegating function, add ONE delegation-assertion test in
addition to whatever happy-path tests exist. ≥1 per function is the
minimum bar.

## Step 4: Add edge + error tests (≥5)

For every spec test case, also consider:

- **Boundary**: empty collections, zero, MAX_INT, nil/null/undefined
- **Error path**: invalid input — throw or return error?
- **Concurrency**: simultaneous operations
- **Persistence**: survives save / restore
- **Auth / permission**: unauthorized access path

≥5 additional tests beyond spec Section 5.

## Step 5: Test naming + structure

Test names in `snake_case` or `camelCase` per language convention.
Doc comment prefix to distinguish:

```typescript
// TEST: basic-create (spec bd-XXXX, case 01)
test("creates entity with expected fields", () => { ... });

// EDGE: empty-input
test("returns empty array on empty input", () => { ... });

// ERROR: invalid-id
test("throws on invalid id", () => { ... });
```

## Step 6: Commit

Your bead should be typed `test` so it's discoverable via
`br list --type test`:

```bash
br update <your-test-bead-id> --type test

br sync --flush-only
git add .beads/issues.jsonl <test-files>
git commit -m ":white_check_mark: tests: spec <scope-name>

Bead: <your-test-bead-id>"
```

## Self-review (5 items)

- [ ] Every spec Section 5 case has a corresponding test
- [ ] ≥5 additional edge / error tests
- [ ] Tests import from real module paths (no inline stubs)
- [ ] Test files at conventional path (per CLAUDE.md or language default)
- [ ] **For delegating units (steps / wrappers / adapters): at least one delegation-assertion test per function** — spy on the dependency, assert it was called. Tests that mock the unit entirely can't catch stubbed bodies.
- [ ] **NO implementation source files were created or modified**

## See also

- [/spec](../spec/SKILL.md) — produces the spec bead this skill tests
- [/check](../check/SKILL.md) — provides decisions context
- [/impl](../impl/SKILL.md) — runs after this; reads tests as the contract
- [/orchestrator](../orchestrator/SKILL.md) — wave ordering: tests merge before impl dispatches
