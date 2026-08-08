---
description: Adversarial review gate — a dedicated, read-only skeptic dispatched after an impl wave, before merge-to-main / bead-close, whose only job is to disprove "done." Hunts stub bodies, mock-the-unit tests, unverified acceptance criteria, unreproducible runtime claims, composition gaps. Distinct from /check (which interrogates the plan, pre-impl).
when_to_use: The orchestrator has merged an impl wave and is about to run the quality gate / merge the branch to main / close the impl bead. Fire /scrutinize first, as the gate. Skip only for atomic one-line or mechanical changes. Also fire when a subagent's "all tests pass" report reads cleaner than its surface area justifies.
---

# /scrutinize — Adversarial review gate

The orchestrator pipeline interrogates the **plan** hard — `/spec`'s
Interrogator pass, `/check`'s open-question walk. It does not
interrogate the **delivered implementation** with the same energy. The
pre-merge audit ("read the bodies, not the test output") used to exist as
advice in `/orchestrator` and `/impl`, but advice gets skipped under
time pressure — and it was performed by the orchestrator, the one party
structurally incented to declare the wave done. The audit itself now lives
here (see "The audit checklist" below); those skills point at it.

`/scrutinize` closes that gap. It is a **named gate**, run by a
**dedicated read-only skeptic** with no stake in the wave completing,
whose entire job is to **disprove "done."**

## Where it sits in the pipeline

```
/spec → /check → test wave → merge → impl wave → merge → /scrutinize → quality gate → done
                                                          ▲
                                       the gate: the branch does not advance,
                                       the impl bead does not close, without a verdict
```

Distinct from `/check`: `/check` interrogates the **plan** before impl;
`/scrutinize` interrogates the **delivered code** after impl. Same
adversarial energy, opposite end of the pipeline.

## When to fire

- After every impl wave that produced real implementation — before the
  `/impl` Step 5 quality gate, before the branch merges to main, before
  the impl bead closes.
- Always for user-facing surfaces (web page, CLI, HTTP API).
- Whenever a subagent's `/handoff` report reads cleaner than the
  surface area justifies.

**Skip** for atomic one-line fixes and mechanical changes (a typo, a
version bump, a doc edit) — same judgment as "when to use subagents."

## How to run it

Two modes — pick by wave size:

**Panel mode (default for substantial waves — multi-file impl, user-facing
surfaces, anything the user asked to treat thoroughly).** Run the saved
workflow (added 2026-06-09):

```
Workflow({
  scriptPath: "<absolute home>/.claude/skills/scrutinize/scrutinize-panel.workflow.mjs",
  args: {
    scope: "<bead ids + one-line wave summary>",
    files: ["<primary files>"],          // optional
    criteria: "<acceptance criteria>"    // optional
  }
})
```

Five read-only hunters run in parallel, one per failure dimension
(stub-bodies, mock-the-unit, acceptance-criteria, runtime-claims,
composition), and every finding is then independently adversarially
refuted before it counts — plausible-but-wrong findings die in the
Verify phase. Returns `{verdict, confirmed[], refutedCount}`; record
the verdict on the impl bead as usual. This skill instructing you to
call Workflow IS the user opt-in for orchestration.

**Single-agent mode (small waves).** Dispatch one **read-only**
subagent — `subagent_type: "general-purpose"` or `"Explore"`, NOT a
worktree subagent. The reviewer writes nothing; it reads and reports.
A fresh agent with no context from the impl wave is the point — it has
no investment in the result.

> The PRIMARY mechanism is this **structural separation** (a fresh agent,
> no investment, skeptical-by-default) — not model choice. A **different
> model** is a *supplementary* lever worth reaching for on high-stakes or
> repeatedly-passed work (it breaks shared blind spots the same model
> keeps); run it via a Workflow `agent(…, {model:'sonnet'|…})`, or pass
> `model:` on a plain `Agent` call — AGENTS.md "Effort and model" owns the
> allocation policy and the alias seams. Don't
> treat model-swap as the headline — fresh-context adversarial separation
> is (Loop Engineering §V.B: model-swap "too helps," it isn't the core).

Prompt skeleton:

> You are an adversarial reviewer. Assume the implementation's
> self-report is optimistic and the tests are weaker than they look.
> Your job is to find where "done" is FALSE.
>
> Spec: <spec bead id / path>. Impl bead: <id>. Acceptance criteria:
> <list>. Files changed: <`git diff --name-only`>.
>
> Hunt specifically for:
> - **Stub bodies** — functions returning `{}` / `""` / `null` / an
>   input passthrough; empty bodies after a directive; bodies shorter
>   than the test that "verifies" them.
> - **Tests that mock the unit under test** — a test that replaces the
>   function it claims to verify tests the mock, not the code. Confirm
>   each key test exercises a REAL body.
> - **Acceptance criteria checked without evidence** — for every ticked
>   box, find the proof. No proof = not done.
> - **Unreproducible runtime claims** — if the handoff claims a runtime
>   verification, re-run it. If you cannot, the claim is unverified.
> - **Execute & observe (don't just read) for any user-facing surface** —
>   for a web/CLI/output-producing change, do NOT certify by reading the
>   code. RUN it: execute the command and inspect the real output, click
>   the UI via Playwright MCP and screenshot/inspect the DOM, hit the
>   endpoint. Judge "does it run right," not "does it look right." A
>   reviewer that only reads is one self-persuasion step from the nodding
>   loop (Loop Engineering §V.C). Reading-only is acceptable ONLY for
>   pure-logic changes with no observable surface.
> - **Missing error paths** — spec error cases with no handling.
> - **Composition gaps** — for a user-facing surface, confirm every
>   required component / subcommand / endpoint is actually wired into
>   the entry point, not merely defined in isolation.
>
> Output a verdict — SHIP / FIX-FIRST / REJECT — with file:line
> evidence for every finding. No finding without a location. If you
> find nothing, say so plainly; do not invent issues.

## The audit checklist — the single owner of the post-impl audit

`/impl` and `/orchestrator` used to carry their own copies of this audit as
orchestrator advice. It lives here now, once: the audit is what this gate's
reviewer works from, and an orchestrator auditing its own wave is the
conflicted-judge problem this skill exists to remove.

### 1. Stub bodies

**Tests passing is necessary but not sufficient.** When tests heavily mock the
modules being tested, an impl agent can satisfy the contract with stub bodies
that return the right shape but do no real work. The classic shape is
`function foo(args) { /* "use step"; */ return {}; }` — types check, tests pass
against mocks, production silently no-ops. An impl agent's "All tests pass ✓" is
a green flag on the test runner, not on the implementation.

**Read the primary modified files end-to-end** and audit each function body:

- Functions that should call into another module: verify the call exists — and
  that the module is even imported (a `publishToGoogleDocs` with no Google
  client import; a `searchSlack` with no Slack SDK import)
- Functions that should perform a side effect (HTTP, DB, file I/O): verify the
  relevant SDK / client / fs API is invoked
- Bodies that are empty, `return {}`, `return ""`, `return null`, or a
  passthrough of input → output: high suspicion. Open the test file — if it
  mocks the entire module, the stub passed unverified.
- Bodies SHORTER than the test that "verifies" them — usually the tell that the
  test mocks the function entirely and the body is just enough to typecheck

```bash
# Quick triage greps (TypeScript examples):
rg -n '"use (step|workflow)";\s*\n\s*}' app/          # empty bodies after a directive
rg -n 'return (\{\}|""|null|undefined);' app/ lib/ connectors/   # trivial returns
rg -L '@slack/web-api|googleapis|@anthropic-ai/sdk' app/workflows/steps.ts  # adapters not importing their SDK
```

A stub body means **do not merge**. It routes as FIX-FIRST: dispatch a follow-up
impl wave to wire it up, AND require a delegation-assertion test (see
[/test SKILL Step 3.5](../test/SKILL.md)) for the wired body, so a future
refactor cannot silently re-stub it.

### 2. Composition — for any user-facing surface

**Tests passing on isolated components is necessary but not sufficient for any
impl that produces a user-facing surface** — a web page, a CLI binary, a TUI, an
HTTP API. Unit tests cover each component in isolation against mocks. They do
not assert that the final artifact — the page a visitor opens, the binary a
customer types, the URL a curl hits — composes those parts into a working whole.

**Precedent (2026-05-18, `skills-library-8l6`)**: a sandbox impl shipped 5 React
components + 84 passing unit tests + a clean `validate.sh` + a clean type-check.
But `page.tsx` was a static HTML skeleton that imported none of the 5 components.
The product didn't work, and every artifact-shaped acceptance criterion was
green. Runtime verification would have caught it in 60 seconds. This is the one
telling of that incident in the orchestrator-side skills; `/dispatch` and
`/handoff` carry it only as the warning pasted to the agent doing the work.

Apply the same body-reading discipline to the integration surface:

- **Web page**: open the root page file (e.g. `app/page.tsx`) top-to-bottom.
  Confirm every component the bead's "Visitor experience" requires is imported
  AND used in the JSX — not merely imported and unreferenced.
- **CLI**: open the entry point (`main.py`, `cli.ts`). Confirm the subcommand map
  references every command's handler.
- **HTTP API**: open the route definitions. Confirm every endpoint the bead's
  contract names has a real handler, not a 501 placeholder.

Beyond static reading, **run the artifact**:

```bash
# Web: start dev server + curl the rendered HTML
npm run dev &
sleep 3
curl -s http://localhost:3000 > /tmp/rendered.html
# Grep for signature markers of EACH component the bead requires:
grep -q 'data-component="skill-picker"' /tmp/rendered.html || echo "FAIL: SkillPicker not in page"
grep -q 'autocomplete="off"' /tmp/rendered.html || echo "FAIL: TokenInput not in page"
# ... per-component check

# CLI: run the canonical happy-path invocation
./bin/foo --help                         # subcommands all listed?
./bin/foo do-the-thing --dry-run         # exits 0?
```

If a signature marker is missing from the runtime output, the page isn't
composed. Do not merge; route it as FIX-FIRST for a wiring wave.

## The verdict

| Verdict | Meaning | Orchestrator action |
|---|---|---|
| **SHIP** | No load-bearing defect found | Proceed to the quality gate |
| **FIX-FIRST** | Real defects, scoped and fixable | Dispatch a fix wave for the named findings; then re-scrutinize |
| **REJECT** | The wave did not deliver what the bead claims | Re-open the impl bead with the findings in `--notes`; re-dispatch impl |

Record the verdict + findings on the impl bead's `--notes`. The gate
is not cleared until the verdict is SHIP — or the orchestrator
explicitly overrides with a documented, honest reason. Overrides
should be rare.

## Beads — /scrutinize is a gate, not a type

`scrutinize` is **not a bead type**, and the reviewer gets **no bead
of its own**. A scrutiny produces a verdict on existing work, not a
new artifact — see [/beads](../beads/SKILL.md) "Stages vs. gates."

- The reviewer is dispatched read-only (`general-purpose` / `Explore`):
  no worktree, no bead, no `Bead:` trailer — it commits nothing. It
  returns the verdict + findings **in its final message**, the way
  `/spec`'s Interrogator returns questions.
- The orchestrator appends a `## Scrutiny — <date>` block (verdict +
  findings with file:line) to the **`impl` bead's `--notes`**, using
  the read-then-rewrite append pattern from [/check](../check/SKILL.md)
  Step 3 (`br update --notes` is replace-only).
- The `impl` bead stays open across the gate and closes **only on a
  SHIP verdict**. FIX-FIRST / REJECT routes into existing types —
  `bug` beads via `/fix`, or the `impl` bead reopened — never a new
  type.

The verdict lives on the bead it gates; the scrutiny never needs a
type of its own.

## What it is NOT

- ❌ Not a second test run. Tests verify conformance; `/scrutinize`
  verifies that the tests and the bodies are not lying.
- ❌ Not the orchestrator doing it inline. The whole point is a
  separate agent with no stake in the wave. An orchestrator that
  "scrutinizes" its own wave is the conflicted-judge problem this
  skill exists to remove.
- ❌ Not `/check`. `/check` walks plan-stage open questions;
  `/scrutinize` reviews delivered code.
- ❌ Not a worktree subagent. Read-only. It writes nothing.

## Anti-patterns

- ❌ **Skipping the gate because the report looked good.** A clean
  report is exactly when the gate earns its keep — precedent:
  `skills-library-8l6`, told in full under "The audit checklist" §2.
- ❌ **Findings without file:line evidence.** A verdict the
  orchestrator cannot act on is noise.
- ❌ **Inventing issues to look thorough.** "Found nothing" is a valid,
  honest verdict. The skeptic's integrity is the asset.
- ❌ **Running it on trivial changes.** A typo fix does not need an
  adversarial gate. Scope it.

## See also

- [/orchestrator](../orchestrator/SKILL.md) — wave ordering, worktree
  hygiene; points here for the pre-merge audit
- [/impl](../impl/SKILL.md) — the quality gate this gate precedes
- [/check](../check/SKILL.md) — the plan-stage counterpart
  (interrogates the spec, not the delivered code)
- [/dispatch](../dispatch/SKILL.md) — see the scrutinize-agent block
- [/fix](../fix/SKILL.md) — where a FIX-FIRST verdict routes
