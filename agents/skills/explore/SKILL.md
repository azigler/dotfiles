---
description: Multi-source research-and-compile workflow. Given a list of URLs and an Asana task, fetches everything in parallel, synthesizes a structured plaintext report into the task description. Two output shapes — **archival** (creates a `~/explore/<topic>/` folder under the explore umbrella for the compendium) or **publishing** (creates a subtask with a Zig-voice LinkedIn-ready post + randomize-driven image attachment). Bridges /zig-voice + /randomize + /openrouter + the Asana fleet proxy in one canonical flow. Distinct from /grok (in-repo code reading) — /explore is for external-topic research.
when_to_use: User says "explore [topic / list of URLs]", "research these and put it on Asana", "look into [N URLs] and tell me what to learn", "do the same treatment for [task]". Anytime the user hands over multiple sources and an Asana destination.
argument-hint: "<asana-task-gid> <url> [<url> ...]"
allowed-tools: Bash(curl *) Bash(jq *) Bash(python3 *) Bash(openssl rand *) Bash(file *) Bash(/home/ubuntu/dotfiles/agents/skills/openrouter/*) WebFetch
---

# /explore — Multi-source research + Asana compile + optional post deliverable

The pattern this session has been running. Codifies it so future sessions
don't drift, especially around the Asana plaintext discipline, the image
generation that has to stay specific (not abstract), and the cross-skill
bridges to /zig-voice + /randomize + /openrouter.

## CRITICAL: voice scope per output

This skill produces TWO kinds of artifacts. They get different voices.
Conflating them is the most common failure mode and a real one — caught
on 2026-05-07 after multiple Asana descriptions drifted into zig voice
("u" / "ur" / "w/" / "btw") that read as sloppy on work artifacts that
other humans and agents need to read.

**Asana task descriptions, research reports, comments on non-post tasks,
chat replies to the user, and any other work artifact** → CLEAN
PROFESSIONAL PROSE. "You" not "u." No deliberate stylization. Direct,
concise, neutral. These get read by hiring managers, coworkers, future
agents, and people who expect a professional register.

**The LinkedIn post deliverable in Step 6c (post comment on a subtask
named `LinkedIn post: ...`)** → FULL ZIG VOICE. This is the only place
zig voice applies. The post is content the user will publish under his
name; everything else is supporting infrastructure.

Apply the test before writing any text: "Will the user publish this
verbatim under his name?" If yes → zig voice. If no → clean prose.

See `/zig-voice` SKILL.md "SCOPE" section for the broader rule.

## Three modes

| Mode | When | Output |
|---|---|---|
| **Report-only** | User wants compiled findings, no follow-on artifact, no archive | Asana task description updated w/ structured plaintext report |
| **Archival (umbrella-folder)** | User says "explore X and put it in a folder", or the Asana task is on the personal "Vibes" board pointing at a specific topic worth archiving (e.g. Zero Native, Tolaria) | Asana task description updated **AND** a `~/explore/<topic>/` folder created with CLAUDE.md + FINDINGS.md + refs/ |
| **Report + post deliverable** | User says "do the same treatment", "make a post about it", or "put a post on a subtask" | Report on parent task + a subtask w/ LinkedIn-ready Zig-voice post (as comment) + randomize-driven specific-subject image (as attachment) |

Default to **report-only** unless the user explicitly asks for an archive or a post. The three modes can compose (an archival run can also produce a post if the topic warrants), but most invocations are one of them.

## Effort — run exploration HOT, and brainstorm HOTTER

Exploration is the canonical case for high effort (Anthropic: "start with
xhigh for exploratory tasks like repeated tool calling and detailed
search"). At baseline `high` the model scopes to what was asked and greps
the average — the opposite of what exploration is for.

- **Run the research at `xhigh`.** If `$CLAUDE_EFFORT` is below `xhigh`
  when an exploration starts, ask Andrew to bump the session (or route the
  research agents through Workflow `effort:'xhigh'`).
- **Add a divergent `max`-effort ideation pass.** Beyond cataloguing "what
  is this," every archival exploration gets a fresh, **max**-effort
  brainstorm — *"what's the novel opportunity here — an ENTIRELY NEW idea
  this sparks (tied to nothing yet); a non-obvious interlink to another
  exploration or an open-ended bead that forms a deeper context; a thing
  worth building; an application to an arc Andrew works on now; OR simply
  why this is genuinely interesting on its own terms? Lead with CURIOSITY —
  don't force a tie-back to a real project here."* — as a Workflow
  `agent(…, {effort:'max'})`, ideally a fresh unpolluted agent so it isn't
  anchored to the convergent writeup (or to the example projects already
  sitting in `~/explore`). Fold its best ideas into FINDINGS under a "Novel
  opportunities" heading. This is where the exhaustive upfront brainstorm
  Andrew wants actually lives — don't skip it for researchable topics.
  **Where that upside can land (including nowhere but a genuinely new idea)
  is governed by the next section — read it before prompting the ideation
  agent.** (For re-examining ALREADY-finished explorations, use `/elevate`.)

## Where the opportunity can land — lead with curiosity, not a tie-back

The `Novel opportunities` pass's FIRST job is to be **curious**, not to find a
home for the finding on this machine. **Over-anchoring to the real example
projects here is how novelty gets missed** (Zig, 2026-07-13): if every
opportunity has to cash out as "a move for LinearB / the harness / a live `~/`
arc," the ideation collapses to the modal tie-back and the genuinely new idea
never gets said. So the ideation agent ranges across **all** of the following
with **no default ranking** — explicitly do not privilege the active-arc one.
It mirrors the same steer in `/elevate` ("Where to apply the upside"); keep the
two in sync.

- **An entirely NEW idea.** Net-new — a thing worth building or exploring that
  this finding *sparked*, tied to nothing already here. Novelty is a
  first-class output, not a consolation prize. Say it even when it connects to
  nothing on the machine.
- **An interlink that forms a deeper context.** Connect the finding to *another
  exploration* (the Step 3.5 siblings / `Related explorations`) **and to
  open-ended beads** — proposed-but-not-done ideas in `br` (`explore:` /
  `elevate:` / `human:` threads). Two half-ideas that meet become one bigger
  opportunity; a finding that hands an open bead its missing piece is worth more
  than either alone. Interlinking the compendium into deeper contexts is the
  whole reason it lives in one place — hunt these **actively**, not just the
  nearest sibling.
- **An application to Andrew's active work — when it's real.** Some findings
  genuinely land on what he works on now (derive it by recency each run — git
  activity + mtimes across `~/`, `~/explore`, `~/linearb`, `~/explore/aaif`; the
  usual hot arcs are LinearB / `~/explore/aaif` / the harness / recently-touched
  `~/explore`). When one does, name the concrete move. But this is **one** valid
  landing, not the preferred one.
- **Interesting for its own sake.** Cool, beautiful, clarifying, or just worth
  understanding. A `Novel opportunities` section may legitimately be "no build;
  the value is comprehension" plus a genuinely-curious thread. Comprehension is
  the deliverable (see `~/explore/CLAUDE.md`); the harvest is a bonus, not a tax.

**Two guards stay hard:**

- **Don't manufacture a tie-back.** A forced connection to LinearB / the harness
  / a `~/` project is worse than an honest "this sparks a new idea with no home
  yet" or "this is here because it's interesting."
- **The build PROJECTS are tabled — the CONCEPTS are not.** The **Hermes /
  MUD-golem / local-coding-models / Hermes-local BUILD PROJECTS** are tabled
  (2026-06-29): don't frame an opportunity as advancing or reviving *them*. But
  that tabling is about those named projects + local models — **not the concepts
  they happened to touch.** An **agent-sim / simulation / agent-toy / agent-pet**
  idea, a memory idea, a loops idea is **active** even though the golem also did
  it — route it to a general harness move or a net-new build, never into the
  tabled bucket. (The tell you've over-tabled: writing "tabled *agent-sim* arc"
  or calling a sim/pet build "not a live destination." Zig flagged exactly this
  on `subterrans`, 2026-07-13.) The golem/MUD stays a *source* to reason from;
  frontier-model versions (subscription, no local model) dodge the tabling
  entirely.

The net: **always** interlink into the compendium (siblings **+ open-ended
beads** → deeper contexts), **freely** propose entirely new ideas and
interesting-for-its-own-sake threads, and land on active work **only when it's
real** — never forced, never at the tabled build projects.

## Archival mode — the umbrella-folder pattern

When the task is "research this topic and keep it as a personal archive" (recent examples: `~/explore/zero/`, `~/explore/tolaria/`), the canonical output shape is:

```
~/explore/<topic>/
├── CLAUDE.md          # orientation: what this is, why, how to navigate
├── FINDINGS.md        # the writeup — the deliverable for future-you
└── refs/              # primary source captures (one .md per source)
    ├── <source-1>.md
    ├── <source-2>.md
    └── ...
```

Workflow within archival mode:

1. Run Steps 1-3 (verify Asana, fetch URLs, search adjacent sources) as normal
2. **Run Step 3.5 (consult the compendium)** — read INDEX.md + grep prior FINDINGS for the adjacent siblings; this feeds the required `Related explorations` section
3. **Run the max-effort `Novel opportunities` ideation pass** (Effort §) — a fresh `Workflow agent(…, {effort:'max'})`; its output is the required `Novel opportunities` section
4. **`mkdir -p ~/explore/<topic>/refs`** before writing
5. Write each fetched source's distillation as a `refs/<source-slug>.md` (one per primary source) — captures the substance verbatim or paraphrased under fair use
6. Write `FINDINGS.md` as the synthesis — TL;DR, what the thing is, usability verdict, harness incorporation, **`Related explorations`** (the Step 3.5 siblings + the connection), **`Novel opportunities`** (the max-effort ideation), recommendation
7. Write `CLAUDE.md` as the orientation file pointing future-agents at the structure
8. Run Step 5 (POST to Asana) — the Asana update mirrors the FINDINGS.md content, and **ends with the back-pointer** `Archived: ~/explore/<topic>/ (FINDINGS.md)` so review can jump from the card to the brain
9. Commit the folder in the umbrella's git: `git add <topic> && git commit -m ":seedling: explore: <topic> — <one-line theme>"`
10. If `Novel opportunities` surfaced a "build/explore X" worth queueing, see the **loop-seam** note in `/elevate` (promote to a Vibes card, human-gated) — don't let it evaporate

### Folder vs submodule — when each is right

Default: **folder**. The umbrella's CLAUDE.md documents this explicitly. Folders match the `linters/` and `shell-home-assistant/` precedent.

Submodule only when the exploration **earns** its own repo. Bar:

- **Independent activity**: the topic generates ongoing commits, not just one writeup
- **Public visibility**: external audience or contributors
- **Distinct lifecycle**: own release cadence, own issue tracker

Existing submodule examples that met the bar: `autonovel`, `smalltalk`, `fragments`, `simon-willison`, `duckdb`, `afcl`. Each has its own GitHub repo + ongoing work.

Existing folder examples: `linters`, `shell-home-assistant`, `zero`, `tolaria`. Investigation/comparison artifacts, no ongoing repo activity, fine as folders.

**Submodules are the default for `~/coding-jams/`** (each jam is an atomic submitted unit). They're the exception for `~/explore/`. Don't reach for a submodule under `~/explore/` unless the criteria above are clearly met — the cost of submodule infrastructure (separate git history, distribute discipline, CI hookup) outweighs the benefit for one-off investigations.

See `~/explore/CLAUDE.md` for the children table and the naming convention (local folder drops `explore-` prefix even if remote repo keeps it).

## Inputs

1. **Asana task GID** — required. The destination for the report (description) and any subtasks.
2. **URLs** — at least 2, usually 3-6, sometimes 1 if it's a deep single source.
3. **Research question** (optional) — a specific lens. If absent, the implicit lens is "what's worth learning, what's relevant to the user's harness/research/content, what could be a social-post angle."

## Step 1: Verify the Asana target

```bash
FLEET_URL=http://localhost:7100
FLEET_TOKEN="$FLEET_API_TOKEN"   # exported from your env — never hardcode

curl -s -H "Authorization: Bearer $FLEET_TOKEN" \
  "$FLEET_URL/api/asana/tasks/<gid>" \
  | jq '{name: .data.name, current_notes: .data.notes, assignee_section: .data.assignee_section.name}'
```

Confirms the task exists and shows what's already in `notes` (the
description) so you don't accidentally overwrite something the user
populated themselves. The `assignee_section` tells you where on the
user's personal board this lives — handy context.

See [reference/asana-fleet-cheatsheet.md](reference/asana-fleet-cheatsheet.md) for the full endpoint set, the gotchas (PUT-vs-POST-update,
strict-XML, `<br/>` self-closing), and the route handlers in lb-agent-fleet.

## Step 2: Fetch all URLs in parallel via WebFetch

Always parallelize. Each WebFetch should request structured detail —
architecture, license, benchmarks, quotes, target deployment, novel claims
vs marketing. The richer the per-source extraction, the easier the
synthesis.

If a fetch fails (403, 401, 404, partial body):

- **Try a related URL** — the canonical model card on Hugging Face, the
  GitHub repo, the company's About page.
- **Note the failure honestly** in the final report. Never paper over.
- **Ask the user** if u've exhausted alternates. They may paste back the
  contents (this session: Neuron 403'd, user pasted the article body).
- **Search adjacent sources** for the same substance.

## Step 3: Search for what u're missing

A good /explore run does NOT stop at the user's URL list. After fetching,
pause and ask:

- What other models / projects / standards are *adjacent* to the named
  set? (e.g., when the user named four April-2026 open models, Qwen3 +
  Phi-4 + OLMo + Granite belonged in the picture.)
- What infrastructure layer makes the named pattern possible? (e.g., for
  on-device LLMs: Ollama, llama.cpp, MLX, MLC, llamafile.)
- What are concrete consumer-facing examples already shipping the
  pattern? (e.g., Apple Intelligence, Copilot+ PCs.)
- What's the LANEAGE — what came before, what's coming next?

Cite these as a separate "u missed these" section in the report. Add
working URLs.

## Step 3.5: Consult the compendium — what do I ALREADY know that connects?

**This is the connective-tissue step. Do not skip it** — skipping it is
the single biggest historical failure of the explore loop (audit
2026-06-28, `~/explore` bead `explore-doj`: across 40 FINDINGS only 3
inter-exploration cross-refs existed, because nothing forced a new
exploration to consult its 56 siblings). Step 3 looks OUTWARD for missing
external sources; Step 3.5 looks INWARD at the brain you've already built.

Before synthesizing:

1. **Read the map.** `~/explore/INDEX.md` is the theme-clustered
   concept-map (regenerated by /housekeeping). Find the cluster(s) this
   topic belongs to and note the siblings already there.
2. **Grep the brain** for the topic's key terms across prior findings:
   ```bash
   grep -rIl -iE "<term1>|<term2>" ~/explore --include=FINDINGS.md \
     --include=CLAUDE.md 2>/dev/null | grep -v "/.beads/"
   ```
3. **Read the 2-4 most adjacent prior FINDINGS** enough to know how this
   new topic AGREES, EXTENDS, CONTRADICTS, or REMIXES with them.
4. The synthesis (Step 4) then **must** carry a `Related explorations`
   section that links those siblings with relative links AND says, in one
   line each, what the *connection* is — not just "see also." This is what
   grows a connected brain instead of a pile of folders.

## Step 4: Synthesize into the structured report

Use the canonical section headers in [reference/report-template.md](reference/report-template.md). The shape is:

```
== TL;DR ==
== What each is ==        (per-source detail)
== Pattern across them == (cross-cuts)
== Yes/no answer ==        (if user asked a specific question)
== Models/projects you missed ==
== Related explorations ==  (REQUIRED in archival mode — the Step 3.5 siblings + the connection)
== What you should learn ==
== Novel opportunities ==   (REQUIRED in archival mode — the max-effort ideation output, see Effort §)
== Possible social-post angles ==
== Sources ==
```

Don't pad. Cite what u actually found. Leave gaps as gaps. Quote
specific numbers + named individuals where they sharpen the report.

`Related explorations` and `Novel opportunities` are **required headings in
archival mode** (report-only mode may omit them). They're the two sections
that make the double loop actually compound — the first connects the brain,
the second harvests the opportunity. Historically both were skipped (0/40
FINDINGS had `Novel opportunities`); they are now first-class, not optional.

## Step 5: POST to the Asana update endpoint (NOT PUT)

```bash
# Build the JSON payload via Python — handles multi-line escaping
python3 <<'PY'
import json
notes = """<the report content>"""
with open("/tmp/explore-update.json", "w") as f:
    json.dump({"notes": notes}, f)
PY

# POST to /update — the bare /tasks/<gid> path returns 405 (see bd-wji0)
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<gid>/update" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/explore-update.json
```

**Plaintext only.** Use `notes` (not `html_notes`). The user copy-pastes
content out and HTML wrappers + `<br/>` tags become noise. Real `\n`
newlines are how plaintext line breaks travel through JSON.

The fleet auto-prepends `[claude-code via Marketing Fleet]\n` once. Don't
prepend it yourself.

**Archival back-pointer (P5).** When the run is archival, end the Asana
report body with a final line: `Archived: ~/explore/<topic>/ (FINDINGS.md)`.
The card holds the report; the folder holds the durable brain — the
back-pointer lets a review pass jump from one to the other instead of the
two drifting apart.

## Step 6 (deliverable mode only): the post-as-deliverable pipeline

When the user asks for a post deliverable, run this 4-step pipeline.
Full mechanics in [reference/social-post-flow.md](reference/social-post-flow.md).

### 6a. Create a subtask

```bash
curl -sS -X POST "$FLEET_URL/api/asana/tasks" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/subtask.json
```

Subtask name should be specific: `LinkedIn post: <topic> — <one-line angle>`.
The `parent` field carries the GID of the task u just compiled the report
into.

### 6b. Draft the post in Zig voice

Read [/zig-voice](../zig-voice/SKILL.md) before drafting. The relevant
genre is usually **builder devlog** (~200-300 words) or **interview
field notes** (~250-350 words). Hard rules to honor:

- Specific moment opener, NOT a thesis or topic
- Casual register: u, ur, w/, btw, pls, da
- Plain text only — no markdown bold/italic, plain URLs, line breaks
- Em-dash budget ~1 per 200 words in flow prose
- Selective ALL CAPS on 2-3 words
- Crystallizing flip line at least once
- Identity stamps where they fit (🐸 ✨)
- Avoid magic adverbs: quietly, deeply, fundamentally
- Avoid scaffolding: "Here's the thing", "Let's break this down", "Plot twist"
- Avoid apology-register openers
- Trust the reader — peer frame, not pedagogical

When the post is part of a series (this session: Mycroft post → Open
Models post building on it), the SECOND post should reference the first
in its opener so the narrative thread is visible.

### 6c. Generate the image via /openrouter w/ randomize-driven prompt

**The image must depict a SPECIFIC SUBJECT, never an abstract concept.**
Past sessions have drifted toward abstract/simple imagery (neural
networks, text bubbles, glowing brains) which is exactly the AI-slop
imagery the user rejects. Force specificity through the randomize roll.

Always run the canonical randomize axes in [reference/social-post-flow.md](reference/social-post-flow.md). Generate a real seed via
`openssl rand -hex 12`, do the modulo arithmetic, and write the
provenance block before composing the prompt. NEVER skip this — the
provenance block IS what makes it a real randomize.

The "Surprise me" baseline: u (the agent) and the user should not
predict what subject the randomize roll will produce. The roll forces the
subject to be specific AND surprising. If the rolled subject feels too
on-the-nose, regenerate the seed (max once).

Cost calibration: nano-banana 2 (Gemini 3.1 Flash Image Preview) actual
cost is ~$0.05-0.07 per 1K image, NOT $0.004 as the older /openrouter
docs suggest. Always state the real cost in ur acknowledgment to the
user, and don't generate variants without explicit confirmation.

### 6d. Attach + comment

Upload the image as an attachment, then post the LinkedIn-ready text as
a plaintext comment.

```bash
# Attach
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/attachments" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -F "file=@/tmp/img.png;type=image/png"

# Post plaintext comment
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<subtask-gid>/comment" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/comment.json    # {"text": "<the post>"}
```

Use `text` (plaintext), not `html_text`. Same reasoning as the description
update — the user copy-pastes to LinkedIn.

## Step 7: Brief the user

Short summary in chat:

- Where the report landed (Asana URL)
- Headline findings — the 3-5 most punchy bullets
- For deliverable mode: the subtask URL, post angle, image style, total cost
- Any fetches that failed and what u worked around
- Any models/sources u proactively added beyond the user's list

Keep it tight. The user asked for the report; the report is the output.
The chat summary is the index.

## Anti-patterns

- ❌ **HTML in Asana fields.** Plaintext only. `notes` not `html_notes`,
  `text` not `html_text`. The user copy-pastes content — HTML is noise.
- ❌ **PUT to `/api/asana/tasks/<gid>`.** Returns 405. Use POST to the
  `/update` sub-route. (Diagnosed in `bd-wji0` in lb-agent-factory.)
- ❌ **Bare `<br>` if u ever do use HTML.** Asana strict-XML rejects it.
  Use `<br/>` self-closing. (Same gotcha caught this session.)
- ❌ **Stopping at the user's URL list.** Always proactively search for
  adjacent missing sources / models / projects.
- ❌ **Padding the report.** Cite what u found. Leave gaps as gaps.
  "Couldn't fetch X, here's what I tried" beats "Likely contains X."
- ❌ **Abstract image subjects.** Skip "neural network with text bubbles",
  "glowing brain", "futuristic city of data". Force a specific subject
  via the randomize roll — a 1990s newsroom desk, a craftsman's pegboard,
  a brass apothecary jar w/ a hand-lettered label.
- ❌ **Skipping the randomize provenance block.** No block = no randomize.
  The arithmetic is what defeats prior collapse.
- ❌ **Generic emojis on bullets.** Use thematic emojis (📓 for journalism,
  🌳 for Gemma, 🪶 for Bonsai, 🤖 for agentic, 🧠 for reasoning, ⚓ for
  Water Town). Not generic ✨🚀💡.
- ❌ **Quoting vendor-supplied stats without naming the source as
  vendor-supplied.** Be honest about where numbers come from.
- ❌ **Assuming the user wants a post.** Default mode is report-only.
  Ask if u're not sure.

## Cross-skill bridges (read these before drafting)

- [/grok](../grok/SKILL.md) — **sibling skill, different scope**.
  `/grok` is for understanding code INSIDE a repo before editing it
  (read-only walk, optional `-t study` bead summarizing findings).
  `/explore` is for compiling a report on a topic OUTSIDE the repo
  (URLs, papers, products, projects). They can compose — a `/grok`
  walk's output can land inside an `/explore` folder when the topic
  spans both code and external context — but most invocations are
  one or the other.
- [/zig-voice](../zig-voice/SKILL.md) — voice rules + format-specific
  guidance for whatever genre the post is (builder devlog / interview
  field notes / narrative-story / whimsical thesis).
- [/randomize](../randomize/SKILL.md) — mandatory protocol for the image
  prompt. Real seed, real arithmetic, real provenance block. Skip and
  u've prior-collapsed.
- [/openrouter](../openrouter/SKILL.md) — image generation via
  nano-banana 2. Cost-aware. Save outputs. Note: stated $0.004/image
  cost is stale; current ~$0.05-0.07/image. Confirm w/ user before
  generating multiple.
- [/asana](../asana/SKILL.md) — the underlying fleet proxy mechanics.
  /explore overrides /asana's PUT recommendation w/ POST-/update for
  task description updates (per bd-wji0).
- [/beads](../beads/SKILL.md) — file follow-up bugs / improvements as
  beads in the appropriate repo if u catch them mid-/explore.

## See also

- [reference/asana-fleet-cheatsheet.md](reference/asana-fleet-cheatsheet.md) — fleet endpoints, route paths, the PUT-vs-POST gotcha, plaintext discipline, multipart attachments.
- [reference/report-template.md](reference/report-template.md) — canonical section structure for the Asana description.
- [reference/social-post-flow.md](reference/social-post-flow.md) — the deliverable pipeline w/ randomize image axes baked in.
