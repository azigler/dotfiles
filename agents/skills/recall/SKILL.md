---
description: Grep + expand over Claude Code transcript history (session JSONL, subagent transcripts, and tool-results) for a past decision, phrasing, or fact. Reads local ~/.claude/projects files directly, renders conversational turns, and fails LOUD on anything it cannot fully surface. Callable by other skills as a CLI.
when_to_use: User (or another skill) asks "what did we decide about X", "find where I said Y", "recall the turn where Z came up", "search my past sessions", or any lookup that needs the actual transcript text rather than curated memory. Also the read primitive the recall-driven learning loop (explore-76oc Phase 4) builds on.
---

# /recall — search transcript history

`/recall` greps the harness's own transcript firehose — the `*.jsonl` session
logs under `~/.claude/projects/<slug>/` plus their nested subagent transcripts
and `tool-results/*.txt` — and surfaces the matching turns with timestamp,
role, and rendered text. It is the read half of the claude-vault arc (spec
`explore-76oc` §4.2): memory is the tiny curated tier; transcripts are the
lossy-on-compaction firehose, and `/recall` is how you get back into them.

It reads the LIVE local files (D6), so it works today independent of any vault
and returns even not-yet-committed sessions.

## CLI

```
python3 recall.py "<query>" [--expand N] [--regex] [--all] [--slug S] [--json] [--root PATH]
```
(`recall.py` also carries a `#!/usr/bin/env python3` shebang and is executable, so `./recall.py …` works too.)

| Flag | Effect |
|---|---|
| *(none)* | substring match, current-slug scope, human-readable output |
| `--expand N` | also print ±N surrounding turns from the SAME file, in order |
| `--regex` | treat the query as a regex (ReDoS-guarded — a pathological pattern that blows past a per-line time budget **aborts the whole run loudly with exit 2**, rather than hanging) |
| `--all` | search every slug under the root, not just the current project |
| `--slug S` | restrict to one slug (bind with `=`: slugs start with `-`, e.g. `--slug=-home-ubuntu-explore`) |
| `--json` | emit a JSON array instead of text (the caller contract) |
| `--root PATH` | override the projects root (also honors `CLAUDE_PROJECTS_ROOT`; `--root` wins) |

The projects root defaults to `~/.claude/projects`. `RECALL_MAX_LINE_BYTES`
overrides the per-line byte cap.

## Scope A coverage (recursive)

Per slug, `/recall` searches the FULL corpus — never just the top-level log:

- `<slug>/**/*.jsonl` — main session logs **and** nested
  `<uuid>/subagents/**/*.jsonl` subagent transcripts (the majority of the
  corpus is delegated subagent work; a top-level-only grep would be
  structurally blind to it).
- `<slug>/**/tool-results/*.txt` — raw tool-output files, rendered as
  `role="tool-result"`.

It greps the **raw bytes first** (drift-robust), then parses.

## Type-keyed render (OQ-D1)

Records are keyed off the top-level `type`. Three outcomes:

- **Conversational turns** (`assistant` / `user`, a `message.role` + a
  `message.content` block-list or bare string) render their text — including
  `thinking` cleartext.
- **Known non-conversational types** render as searchable hits **keyed by
  `type`**, pulling text from the field where it lives (`ai-title`→`aiTitle`,
  `last-prompt`→`lastPrompt`, `custom-title`→`customTitle`, `queue-operation`/
  `system`→`content`, `attachment`, `file-history-snapshot`, `progress`, and the
  subagent-workflow `journal.jsonl` `result`/`started` records). This keeps the
  loud channel from drowning in known structural records — on the live corpus a
  common query dropped from ~2,400 loud lines to ~0.
- **Recognized-but-empty** turns (a signature-only `redacted_thinking` block,
  an empty content list) are quietly skipped — not a hit, not a false alarm.

## Fail-loud guarantee (D7)

A silently-incomplete recall would hand the harness a *false-complete* history.
So `/recall` never drops a matched line it *could* have surfaced. Any matched
line it cannot fully render is surfaced LOUDLY on **stderr** with its raw
content and a `recall[incomplete:<reason>]` marker, **and** (in `--json` mode)
as an array entry with `role="unrenderable"` — so a caller reading only the
json channel can't be handed a false-complete `[]`. The loud reasons:

- **genuine schema drift** — a valid-JSON record of a *genuinely unknown* top-level
  `type` (this is now the loud channel's core job: a real drift detector),
- a non-UTF8 decode error (the raw region is shown, not `errors='ignore'`-skipped),
- a huge line truncated at the byte cap (marked `…[truncated]`).

The known-type render map is **derived from the live corpus** — if a brand-new Claude Code
record `type` appears, it surfaces as loud drift until it's added to the map. That is the
intended early-warning behavior (a real schema change SHOULD ping the drift channel), not a
bug. Also: because matching greps the raw line but rendering shows a type-specific field
subset, a hit's rendered text does not always contain the matched term (e.g. a `system`
record matched in its `cwd`) — the match is real and never dropped, just rendered by its
canonical field.

The one tolerated exception is the ACTIVE session's trailing partial line (a
write in flight — the newest-mtime `*.jsonl` in scope): its mid-write last line
is skipped silently while every prior line still returns.

## Contract for callers

- **Exit codes:** `0` = ≥1 hit (renderable OR loud), `1` = no hits, `2` = error
  (bad/missing root, empty query, invalid regex, **or an aborted ReDoS-guard
  run**).
- **`--json`** → a JSON array of objects with EXACTLY the keys
  `{slug, session, ts, role, line, text}` (`line` is the 1-based line number in
  the file). A matched-but-unrenderable drift line appears as an entry with
  `role="unrenderable"` (same key set); loud notices also go to stderr
  regardless of `--json`.

## Known limits (v1)

- **F5 — byte cap:** a search term that appears ONLY past the per-line byte cap
  (default 256 KB, `RECALL_MAX_LINE_BYTES`) on an over-cap line is a silent miss.
  Negligible at 256 KB (only inlined-blob lines exceed it, and those are surfaced
  as truncated); raise the cap if you must search inside huge inlined tool-results.
- **F6 — active-file detection:** the tolerated live-tail partial keys off the
  single newest-mtime `*.jsonl` in scope. Under `--all` with a *second*
  concurrent live session, that other session's own in-flight partial could
  produce one spurious loud line. Cosmetic; scoped runs are unaffected.

## Callable by other skills

`recall.py` is a plain stdlib Python CLI (no daemon, no standing index — v1).
Other skills invoke it directly and parse `--json`; check the exit code to
branch on hit/no-hit/error. The recall-driven learning loop (`explore-76oc`
Phase 4) is the first such caller.
