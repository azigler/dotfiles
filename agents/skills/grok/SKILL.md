---
description: Read-only walk of an unfamiliar code area to understand it, BEFORE editing. Ends with an optional typed `study` bead summarizing what was learned, so the next agent doesn't repeat the read. Distinct from /onboard (session-level state discovery), /spec (writing a new spec), and /explore (external-topic research compile vs in-repo code reading).
when_to_use: User says "look at X and tell me what it does", "walk this area", "I need to understand the auth flow", "what does this codebase do here?". Also fire proactively when you (the orchestrator) realize you need to understand something before dispatching work on it.
argument-hint: "<area or path or topic>"
---

# /grok — Understand before editing

Read-only investigation skill. Goal: get enough context to make
informed decisions, without repeating the read in the next session.

## When this is the right skill

| Want | Skill |
|---|---|
| Understand session state to start working | `/onboard` |
| Understand a code area before editing it | **`/grok`** |
| Write a new specification | `/spec` |
| Walk decisions that need resolution | `/check` |
| Find issues across a11y/perf/theming | `/impeccable audit` |

Use `/grok` when the task is "learn what's here" — not "decide
what to build" (that's `/spec`) and not "audit quality" (that's
`/impeccable audit`).

## Step 1: Frame the question

What specifically do you need to understand? Examples:

- "How does auth flow from login → session → request?"
- "What's the data model for `<entity>` and how does it persist?"
- "Why does `<file>` exist — what's it for?"
- "How are tests organized in this repo?"

A vague "tell me about this codebase" produces vague output. The
narrower the question, the sharper the walk.

## Step 2: Gather entry points

```bash
# Source files relevant to the topic
git grep -l "<keyword>"           # files mentioning the term
fd -e ts -e py "<filename>"       # files matching a name pattern
br search "<topic>"               # related bead history

# Documentation
ls refs/                          # curated reference material
ls specs/                         # legacy file specs (if any)
br list --type spec               # bead-based specs
br list --type study              # prior /grok studies for this area
```

Read the top 5-10 most relevant files. Don't try to read the whole
repo.

## Step 3: Walk the code

Read in this order:

1. **The CLAUDE.md(s)** — repo root + any subsystem CLAUDE.md
2. **The entry point** — main.ts, index.py, lib.rs, or whatever bootstraps the area
3. **The data model** — types, schemas, structs that the area operates on
4. **The hot paths** — the 3-5 functions most central to the area's purpose
5. **The tests** — what does the codebase verify works? Tests document intent.

Don't read the implementation of every helper. Stay at the level
that answers your question.

## Step 4: Summarize (in chat first)

Give the user a concise summary:

```
## <area>: how it works

**Entry point**: <file:line> — <what it does>
**Core types**: <name> at <file>, <name> at <file>
**Hot path**: <step 1> → <step 2> → <step 3>
**Notable**: <surprising behavior worth flagging>
**Caveats**: <known gotchas>
```

Cite specific `file:line` references so the user can navigate.

## Step 5 (optional): Persist as a `-t study` bead

If this walk is going to be useful to future agents (you, a
subagent, a teammate), persist it:

```bash
br create -t study -p 3 "study: <area> overview" --silent
br update <id> --description "$(cat <<'EOF'
## Area: <name>
## Walked: 2026-MM-DD by <agent>

## How it works
<the summary you gave the user above>

## Files of interest
- <file:line> — <what>
- ...

## Open questions surfaced
- <question> — could spec a follow-up
EOF
)"
```

Future `br list --type study` shows what's been grokked. Skip the
study when:

- The walk was for one immediate decision and you won't come back
- The summary is already in CLAUDE.md or refs/

## Anti-patterns

- ❌ **Editing during a grok walk** — read-only. If you find a fix
  on the way, fire `/fix` separately; don't mix.
- ❌ **Reading every file** — the question framing should narrow
  to <10 files. If you need more, the question was too broad.
- ❌ **Skipping the summary** — if you don't summarize, the
  understanding lives only in your context window. Compaction wipes it.
- ❌ **Persisting as a `study` bead when the project owner expects
  a spec or doc** — `study` beads are scratch read-only investigation,
  not deliverables. If the area deserves a formal spec, fire `/spec`
  instead.

## See also

- [/onboard](../onboard/SKILL.md) — session-level orientation
- [/spec](../spec/SKILL.md) — formal spec writing (if grok turns
  into "we need to spec this")
- [/beads](../beads/SKILL.md) — `study` type details
- [/explore](../explore/SKILL.md) — sibling skill for **external-topic** research compile. `/grok` is for understanding code INSIDE a repo before editing it; `/explore` is for compiling a report on a topic OUTSIDE the repo (URLs, papers, products). They can compose (a `/grok` walk's output can land in an `/explore` folder when the topic spans both), but most invocations are one or the other.
- Built-in `Explore` subagent — for very large walks where you
  want to keep the orchestrator's context clean. `/grok` is for
  walks small enough to do in the main session.
