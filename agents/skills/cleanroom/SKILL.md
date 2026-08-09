---
description: Oracle-driven clean-room reimplementation — rebuild an existing artifact (binary, CLI, library, service, ROM, file format) as fresh source, verified continuously against the original rather than against your own belief about it. Covers target selection, oracle construction, the observer/implementer split, and the agent loop. Also known as the "reverse Ralph loop"; the loop is the trivial part, the oracle is the whole job.
when_to_use: You want to reimplement something you can observe but do not have source for (or whose source you must not use) — port a binary to a new language, rebuild a legacy system from behaviour, recover a spec from a running service, write a reader for an undocumented format. Also fire when someone proposes an autonomous rebuild loop and you need to establish whether they have an oracle, because usually they do not.
argument-hint: "<target to reimplement>"
---

# /cleanroom — Rebuild it from behaviour, not from belief

You are reimplementing something whose source you do not have, or must
not use. The artifact exists. It runs. It is the only specification
there is.

Everything here rests on one claim, and the claim is load-bearing:

> **The hard part is not generating code. It is knowing, continuously
> and mechanically, whether the code you generated is right.**

An agent in a loop will write an implementation, write a test that
agrees with the implementation, watch it pass, and commit. Both halves
wrong, in agreement, at speed, for about \$10/hour. The thing that
prevents that is an **oracle** — something outside your implementation
that can answer "is this output correct?" without sharing your
misunderstanding.

**If you cannot name your oracle in one sentence, you do not have a
project yet. You have an expensive way to generate plausible code.**

---

## 0. What the literature actually shows (read this before believing anyone)

The technique circulates under the name "reverse Ralph loop," descended
from Geoffrey Huntley's "Ralph Wiggum" loop. The loop is real, public,
and trivial. The verification discipline is mostly absent. Researched
and verified 2026-08-07:

| Source | What it actually did | Oracle? |
|---|---|---|
| ghuntley/how-to-ralph-wiggum | `while :; do cat PROMPT.md \| claude -p …; done`. Context resets each iteration; filesystem + git are the memory layer. | Type checkers, linters, tests — "backpressure." Real but generic. |
| ghuntley Z80 tax-app demo | The demo that inspired the genre. | **None.** Author ran an emulator, screenshotted it, pasted the screenshot back. His words: *"the Z/80 spectrum isn't really a good target for automating a reward loop."* Its spec silently drifted (tax brackets 10/0/25 → 5/0/10). Nobody caught it. |
| ghuntley Atlassian Rovo post | `file` + `strings` + `hexdump` found an embedded ZIP; `python3 zipfile` extracted 100+ source files. | N/A — this is `unzip`, not reimplementation. Do not cite it as clean-room anything. |
| DanielJoyce/ls-rs | `specs/` tree, ~1000 LOC in ~45 min. | **None.** No differential testing against real `ls`. Author: *"I have NOT undertaken any heavy checking of the claims made in this file."* |
| **Ryan Allen's Express.js gist** | **The only source that implements the discipline.** Two-stage split: agent A reads original `lib/`, writes tests; agent B reads *only the tests*, writes a fresh implementation. | **Yes.** Four-cell coverage matrix (two suites × two impls). 340/340 both ways; rebuilt tests hit 97.9% statement coverage on the *original*. Clean-room impl 1,493 lines vs 2,762 — *"54% code is behavior, 46% is polish."* |

The one large-scale success (Claas Busemann's TypeScript port of Snatcher
— 769 tasks, 5,127 commits, 96 days) is notable precisely because he
**built the oracle the genre lacks**: three escalating stages, described
in §4.

So: take the loop from the literature. Do not take the confidence.

---

## 1. Target selection — by oracle availability, not by desire

Ask three questions about the target. **Any "no" that you cannot
manufacture (§2) means there is no project.**

1. **Can I pin the inputs?** Same input, same run, every time.
2. **Can I re-run it?** As many times as I want, cheaply, on demand.
3. **Can I observe internal state** — not just final output?

The counter-intuitive part, and the thing most people get backwards:

> **Reversibility is a property of determinism and observability, not of
> format.** Obfuscation and minification are speed bumps. Machine code
> is not meaningfully harder than TypeScript. What is genuinely hard is
> non-determinism, unobservable state, and irreproducible inputs.

This is why a game ROM is close to the friendliest target that exists —
deterministic, self-contained, small enumerable state, decades of mature
instrumentation — and why a SaaS backend is genuinely hard: you can only
see the API surface, and the state lives on someone else's machine.

Score the target honestly before committing:

```
TARGET:        <what>
PIN INPUTS:    yes / no / manufactured via <instrument>
RE-RUN:        yes / no / manufactured via <instrument>
OBSERVE STATE: yes / no / manufactured via <instrument>
ORACLE:        <one sentence, or STOP>
STUB TEST:     if the implementation were an empty stub, this oracle
               would report: <___>.  If that answer is "pass", it is
               not an oracle.
```

Write this into the project's bead before any code is generated.

---

## 2. Oracle manufacture — when the answer is "no"

A "no" is not the end. The move is to find an **instrument pair that
manufactures the missing property.**

**The canonical pairing: Frida → Unicorn.** A packed or obfuscated
function inside a live application fails all three questions — it runs
only in situ, only once, and opaquely. Together:

- **Frida** attaches to the real process and harvests ground truth: the
  decrypted bytes as they exist in memory *after* unpacking, plus the
  exact register state and memory context at the moment of call. That is
  a pinned input, taken from reality rather than guessed.
- **Unicorn** re-executes those exact bytes from that exact state,
  off-target, unlimited times, with a hook on every instruction and every
  memory access. That is re-runnability and observability.

Neither works alone. Frida hooks, but the code still runs once, in a
process you do not control. Unicorn observes everything, but has no idea
what state the function expects — wrong registers give a plausible wrong
answer.

Other instances of the same move:

| Missing property | Instrument that manufactures it |
|---|---|
| Determinism in a live system | `rr` — record one execution, replay it identically forever |
| Re-runnability of a network service | Capture traffic (mitmproxy/tcpdump), build a replay harness |
| Isolated execution of one routine | Unicorn (bare-metal) / Qiling (needs an OS) |
| Observability inside a closed binary | Frida hooks; or Ghidra headless for structure |
| Observability inside an emulated machine | The emulator's GDB stub or Lua API |
| Determinism in an interactive system | Fixed input sequence replay (the TAS-movie trick) |

Tools, verified invocations, and which ones an agent can drive
unattended: **`reference/tool-shelf.md`**. Read it when you are choosing
instruments; do not guess command forms from memory.

---

## 3. What makes an oracle real — four properties

Judge every candidate oracle on all four. Weakness in one is survivable;
name it. Weakness in *independence* is disqualifying.

**Fidelity** — does passing actually mean correct? A type checker has low
fidelity (rules out a class of wrongness, not wrongness). A byte-exact
diff against the original's output has very high fidelity.

**Coverage** — what fraction of behaviour does it exercise? Measure it.
Ryan Allen's result means something *because* the rebuilt tests hit 97.9%
statement coverage on the original library.

**Locality** — when it fails, how precisely does it point at the defect?
The most underrated property. "Frame 40,000 differs" is nearly useless;
"routine `sub_1A2C` returned `d0=0x14`, yours returned `0x13`" is a fix.
You generally cannot get high coverage and high locality from one
instrument — which is why §4 is a ladder, not a choice.

**Independence** — does the oracle share a failure mode with the thing it
checks? This is the one that kills people:

> **When a check and the thing it checks share a failure mode, the check
> is decoration.**

A round-trip test where your own reader feeds your own writer is not an
oracle — both halves can be wrong together and agree. An LLM judging its
own output is not an oracle. A test generated from the same
misunderstanding as the code is not an oracle.

**The stub question, asked of every probe:** *what would this report if
the implementation did nothing at all?* If the answer is "pass," it is
decoration.

---

## 4. The oracle ladder — build more than one

One instrument cannot give you both coverage and locality. Build a ladder
and run all rungs. Busemann's three-stage ladder is the reference shape:

| Stage | Instrument | Granularity | Catches |
|---|---|---|---|
| 1 | Agent-drivable debug tooling in the artifact itself | whatever you ask | "what did I just produce?" |
| 2 | Unicorn executing the original, trace-matched | one routine | a wrong function |
| 3 | Reference emulator, both jumped to the same frame, memory + layers + VM stack diffed | one frame | a *right* function wired wrong |

Stage 2 catches a wrong function. Stage 3 catches a correct function
called in the wrong order. **Neither substitutes for the other**, and a
project with only stage 3 will spend weeks bisecting.

Note stage 1: **tooling the agent can drive itself.** This is the highest-
leverage early investment in the whole method and it is consistently
underbuilt. Busemann shipped ~30 `__snatcher*` debug globals and 20
inspector panels to *production* because they were never separable from
the work. Build the debugger before the thing being debugged.

### The ladder by surface

| Rebuilding | Oracle | Comparison surface | Locality |
|---|---|---|---|
| CLI tool | run both binaries | stdout, stderr, exit code, files touched, `strace` trace | medium |
| Library / module | link both, call same API | return values, thrown errors, mutated state | high |
| HTTP service | shadow traffic | response bodies, diffed modulo noisy fields | medium |
| Codec / file format | reference implementation | byte-exact output + round-trip | high |
| Parser / compiler | reference parser | the AST, or emitted IR | high |
| Query engine | another engine | result sets over a query corpus | medium |
| Bare-metal routine | **Unicorn** | registers + memory after N instructions | very high |
| Live app you cannot isolate | **Frida** | hooked function args and returns | high |
| Whole game / machine | reference emulator | frame hash, memory snapshot, fixed-input replay | low |
| GUI | accessibility tree (**not** screenshots) | node tree diff | low |

**Every-byte accountability** deserves special mention for formats and
protocols: parse a corpus of real artifacts and assert your model
**explains every byte**. Any byte you cannot account for is a hole in the
spec, and it names its own location. Cheap, brutal, high-coverage.

### Differential testing is not a novel AI technique

Feeding the same inputs to two implementations and diffing has been the
highest-yield bug-finding method in systems software for fifteen years:
Csmith (hundreds of GCC/LLVM bugs), SQLancer (400+ DBMS bugs), jsfunfuzz,
Twitter's Diffy for shadow-running production traffic. You are applying a
mature technique with an agent in the fix loop. Say so; it calibrates
expectations correctly and points at a real literature.

### When you genuinely cannot run the original

Weaker instruments. Name them as weaker:

- **Metamorphic relations** — you do not know the right answer, but you
  know relations that must hold: `decompress(compress(x)) == x`,
  `sort(shuffle(x)) == sort(x)`. Catches a surprising amount with no
  reference at all.
- **Invariants / property tests** — output must satisfy checkable structure.
- **The original's own test suite**, if it shipped one — a partial spec
  carrying the original author's assumptions along with the behaviour.
- **A human looking at it** — Huntley's screenshot loop. It works, does
  not scale, and let a tax bracket silently change from 25% to 10%.

---

## 5. The clean-room split

Two roles, and they must not be the same context:

**Observer** — may touch the original. Runs it, hooks it, disassembles it,
dumps it. Produces **specs only**: behaviour, interfaces, invariants,
worked input→output examples. Never writes implementation code.

**Implementer** — never sees the original, its source, its disassembly, or
raw dumps. Reads **only the spec** and the oracle's verdicts. Writes the
implementation.

Because the implementer sees only the spec — walled, no repo secrets — the split
maps onto a **heterogeneous fleet**: it can run on a different vendor than the
observer *precisely because* the spec is its only input, which makes it the
natural first job for a codex tap (`dotfiles-d3ky`; not wired yet).

Ryan Allen's gist is the working reference: read `lib/` → write tests;
read *only the tests* → write the implementation.

### Enforce disposal structurally, not by instruction

Every public source except that gist treats "dispose of the original" as
a *prompt*, not a mechanism. In the Z80 post the entire Chinese wall is
one line: *"Remove all ANSI C aspects of the spec and write them to SPECS
folder."* That is not a wall.

Make it structural:

- Separate agents, separate contexts — never one context that ingests,
  abstracts, and implements.
- Separate directories. The implementer's worktree does not contain the
  original. Not "should not open it" — does not contain it.
- The spec is the only channel. If the implementer needs a fact, the
  answer is to improve the spec, not to peek.

**In this harness:** a worktree subagent gets a full copy of the project
repo. If the original is a tracked file in that repo, every implementer
worktree contains it and the wall is void by default. The original must
live outside the project repo, or be untracked — untracked files do not
materialize in a fresh worktree. The observer reads it by absolute path
from outside the repo; the implementer's worktree is cut from a repo that
has never tracked the artifact. Check it mechanically, in the implementer's
worktree: `git ls-files | grep -i <artifact>` — empty output means the wall
holds.

### The leak detector

No public source has a mechanical test for whether disposal held. Use this:

> **Does the implementation contain correct facts the spec does not
> state?**

If the implementer produced a correct magic number, field offset, edge-case
branch, or ordering rule that the spec never specifies, then it came from
somewhere else — the original, or the model's prior knowledge. Either way
the boundary did not hold and your clean-room claim is void.

Run it as a real gate: diff the implementation's load-bearing constants and
branch conditions against the spec's stated facts. Unjustified correctness
is the signal. **Note this catches prior-knowledge contamination too**, which
matters when reimplementing anything well-documented — the model may simply
know the answer, and you will score a pass you did not earn.

Make it a command, not an intention — extract the impl's literals and branch
predicates, then assert the spec accounts for each:

```bash
# literals + branch predicates the impl's correctness hinges on
{ grep -rhoE '0x[0-9a-fA-F]+|[0-9]{2,}|"[^"]{2,}"' src/
  grep -rhoE 'if [^{]+|case [^ :]+' src/ ; } | sort -u > impl.facts
# each fact the spec never states is a leak candidate
while IFS= read -r fact; do
  grep -qraF -- "$fact" specs/ || echo "UNJUSTIFIED: $fact"
done < impl.facts
```

Every `UNJUSTIFIED:` line is right without the spec justifying it: either the
spec is missing a fact, or the boundary leaked. Triage each — no third option.

### On the legal framing

Genuine clean-room practice (spec-writer and implementer legally walled) is
a real doctrine with real requirements, and nothing here constitutes advice
about it. Two practical notes: **file formats and APIs are generally not
copyrightable** while implementations are; and if the target's license is a
live concern, the wall needs to be a documented process with records, not a
prompt. Say plainly in the project's bead which of the two you are doing —
exercising the method, or building a defensible wall.

---

## 6. The loop

The mechanically trivial part. One iteration = fresh context = one task =
one commit. The filesystem and git are the memory layer, not the context
window.

The literature original (§0, ghuntley/how-to-ralph-wiggum) is quoted here for
context — it is what "reverse Ralph loop" names, not a form to copy. It is
uncapped and cannot tell success from failure:

```bash
# LITERATURE QUOTATION — uncapped, verdict-blind. Do not copy this form.
while :; do cat PROMPT.md | claude -p …; done
```

The canonical form in this house is **capped** and checks a result marker on
every iteration, per the adaptations below — an oracle that silently stops
checking is worse than no oracle, because it reports success:

```bash
MAX_ITER=5
for i in $(seq 1 "$MAX_ITER"); do
  OUT=$(cat PROMPT.md | claude -p --output-format text)
  echo "$OUT"
  if ! grep -q '^ITER_RESULT=' <<<"$OUT"; then
    echo "iteration $i: no ITER_RESULT= marker — exit-0-without-a-marker is FAILURE (dotfiles-cxle)" >&2
    exit 1
  fi
  grep -q '^ITER_RESULT=DONE$' <<<"$OUT" && { echo "done at iteration $i"; break; }
done
```

Durable state between iterations:

```
project/
├── PROMPT.md              # the standing instruction, re-read cold each pass
├── IMPLEMENTATION_PLAN.md # what is left; the agent picks ONE item
├── specs/                 # the observer's output — the real deliverable
├── ORACLE.md              # how to run each rung, and what a failure means
├── src/
└── tests/                 # expect these to outweigh src/ substantially
```

Adaptations that are not optional in this house:

- **The bash loop cannot tell success from failure.** Do not rely on it.
  Progress is legible only as commits, tags, and oracle verdicts.
- **Always cap iterations.** One documented case burned 50 iterations on a
  problem that needed human input by iteration 3.
- **Every harness script reports `<NAME>_RESULT=<verdict>` on every terminal
  path**, and the caller treats exit-0-without-a-marker as FAILURE
  (`dotfiles-cxle`). An oracle that silently stops checking is worse than
  no oracle, because it reports success.
- **An escape hatch.** When an iteration cannot make progress, it files a
  P1 `human:` bead and stops — it does not spin.
- **Search before implementing.** False-negative search causing the agent to
  rebuild what already exists is named by practitioners as "the Achilles'
  heel of Ralph."
- **Molt at task boundaries; do not ride to the ceiling.** A loop that
  accumulates context should cycle at each work-item boundary
  (`agents/scheduler/seat-molt.sh`) rather than drift to the 75% context guard.
  The filesystem + git + `specs/` ARE the memory layer here, so a molt between
  tasks loses nothing and resets cost (`dotfiles-it06`).

In this harness, prefer the orchestrator + worktree-subagent pattern over a
raw bash loop for anything that writes code — hooks, lint, bead tracking and
commit conventions all come along, and it is **tap-attributed**. The `claude -p`
loop shown above is not: headless `-p` draws from the *separate* monthly Agent
SDK credit pool and runs unattributed — off-book spend the tap model cannot see
(`agents/scheduler/pulse-inject.sh` header). Reach for the bash form only when
context reset is specifically the mechanism you want.

---

## 7. Sequence

1. **Recon** — `file`, `strings`, `binwalk`, entropy. *Check whether the
   answer is trivially available before building anything.* The Rovo case
   was an embedded ZIP; someone could have spent a month disassembling it.
2. **Score the target** — §1's block. Stop here if there is no oracle.
3. **Build stage-1 tooling first** — the debug surface the agent drives
   itself. Before any implementation.
4. **Build the oracle, and make it fail on purpose.** A probe that has never
   been observed failing is not known to work. Feed it a deliberately broken
   implementation and watch it report failure.
5. **Observer pass** — specs from behaviour, with worked examples.
6. **Implementer pass** — from spec only, in a worktree without the original.
7. **Run the ladder.** Every rung, every iteration.
8. **Leak detector** at the boundary — §5.
9. **`/scrutinize`** before merge, as always. An author cannot gate itself.

---

## 8. Failure modes, with numbers

- **No oracle** → the loop commits broken code and reports done. The
  default outcome, not an edge case.
- **Shared-failure-mode oracle** → passes forever, proves nothing. Ask the
  stub question.
- **Spec drift** → the Z80 demo shipped wrong tax brackets, undetected, in
  the flagship demo of the technique. A spec nothing re-derives is a rumour.
- **Bad spec, discovered late** → one report of a keyword defined twice for
  opposing cases, caught ~1 month in.
- **Stub bias** → the reward signal is *compiling* code, not *working* code.
  Agents write placeholders. Grep for them explicitly; `/scrutinize` §1.
- **False-negative search** → reimplementing what exists.
- **Unbounded spin** → 50 iterations on a 3-iteration problem.
- **Cost** → roughly \$10/hr sustained. One second-hand report of a $50k
  contract delivered for \$297 in tokens. Cheap enough that waste is easy to
  miss and easy to tolerate for far too long.

---

## 9. Anti-patterns

- ❌ **Starting the loop before the oracle exists.** The single most common
  and most expensive error. Everything downstream is unverified output
  accumulating at speed.
- ❌ **A round-trip test presented as verification.** Your reader feeding
  your writer shares a failure mode with itself.
- ❌ **One context that ingests, abstracts, and implements.** That is not a
  clean room; it is a rename.
- ❌ **Treating disposal as a prompt.** Make it structural — separate agents,
  separate directories.
- ❌ **Screenshots as the verification channel.** It is where you end up when
  you skipped the oracle, and it is how a tax bracket changes silently.
- ❌ **Claiming clean-room without running the leak detector.**
- ❌ **Picking the target by desire rather than by oracle availability.**
  Wanting it does not make it observable.
- ❌ **Citing the Rovo post as evidence the method works.** It is `unzip`.
- ❌ **An oracle you have never watched fail.** Not believed until it has
  been made to fail on purpose.

---

## 10. Reference

- `reference/tool-shelf.md` — the forensic and instrumentation shelf:
  recon, static structure, dynamic observation, controlled execution,
  differential harnesses. Verified invocations, ranked by whether an agent
  can drive them unattended.

Related skills: `/grok` (understand existing code you *do* have), `/spec`
(specs for forward work), `/research` (empirical verification harness and
the experiment protocol), `/scrutinize` (the adversarial gate), `/fix`.
