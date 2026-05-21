# {{CONFERENCE}} {{YEAR}} — {{TITLE_OR_TRACK}}

> {{ONE_LINE_PROJECT_DESCRIPTION}}

## Goal

{{2-4 sentences: what this submission is, what venue it targets, what the
deliverable is, and any anchoring claim or thesis. Keep it tight; this is
the agent's first read on cold pickup.}}

## Hard deadline

**{{DATE}} at {{TIME}} {{TIMEZONE}}.** {{NOTIFICATION_DATE_IF_KNOWN}}.

## Locked decisions

| Field | Value |
|---|---|
| Conference | {{CONFERENCE_NAME_AND_URL}} |
| Track | {{TRACK_NAME}} |
| Format | {{TALK / POSTER / DEMO / PAPER / SANDBOX / LIGHTNING}} |
| Length | {{TIME_OR_PAGE_BUDGET}} |
| Title | *{{TITLE}}* ({{N}} chars / {{LIMIT}}) |
| Co-speaker | {{NAME_OR_NONE}} |
| Audience level | {{200 / 300 / 400 / "all"}} |
| Submission portal | {{URL}} |
| Asana planning hub | [{{TASK_NAME}}]({{TASK_URL}}) (gid `{{TASK_GID}}`) — **post progress comments here as work lands** |
| Asana parent | [{{PARENT_NAME}}]({{PARENT_URL}}) (gid `{{PARENT_GID}}`) |
| Agent name (for fleet attribution on Asana writes) | `cfp-{{slug}}-orchestrator` (or `talk-{{slug}}-orchestrator` for co-located /cfp + /talk projects) |

## Hard limits (from the form)

| Field | Limit |
|---|---|
| Title | {{N}} chars |
| Abstract | {{N}} chars |
| Session details | {{N}} chars |
| Author bio | {{N}} chars |
| {{OTHER_FIELD}} | {{N}} {{UNIT}} |

## Source of truth

| Source | Location |
|---|---|
| CFP form (binary) | `refs/{{CONFERENCE}}-form.{docx,pdf}` |
| CFP form (markdown) | `refs/{{CONFERENCE}}-form.md` |
| Conference theme / track docs | `refs/track-context.md` |
| {{ANY_PAPER_OR_PRIOR_TALK_BEING_BUILT_ON}} | `refs/{{slug}}.{md,pdf}` |
| refs/ index | `refs/INDEX.md` (only when refs/ > 10 files) |

## What this proposal teaches / argues

**The thesis.** {{ONE_SENTENCE_THESIS}}

**The framing.** {{2-3_SENTENCES_ON_THE_ANGLE_LOCKED_IN_research/angle-options.md}}

**Audience promise.** {{WHAT_DOES_AN_ATTENDEE_LEAVE_WITH}}

## Credibility stack (proof for the proposal)

What backs this submission's claim that the author is uniquely positioned:

1. {{RECEIPT_1}} — {{ONE_LINE_DETAIL}}
2. {{RECEIPT_2}} — {{ONE_LINE_DETAIL}}
3. {{RECEIPT_3}} — {{ONE_LINE_DETAIL}}
4. {{RECEIPT_4}} — {{ONE_LINE_DETAIL}}

## Author bio anchor

{{ONE_PARAGRAPH_ON_THE_BIO_FRAMING_DECISION}}

Bio assembly recipe (most-recent / most-substantial first):

1. {{LINE_1}}
2. {{LINE_2}}
3. {{LINE_3}}

## Project layout

```
~/cfp/{{slug}}/
├── CLAUDE.md                      # this file
├── .beads/                        # task tracking (see /beads)
├── refs/                          # verbatim source material
│   ├── INDEX.md                   # only if > 10 files
│   └── {{form-and-source-files}}
├── research/                      # analysis / decision artifacts
│   ├── {{conference}}-cfp-analysis.md
│   └── angle-options.md           # angles considered before locking
└── proposal.md                    # the deliverable (Shape A)
   OR
└── paper/                         # the deliverable (Shape B)
   ├── main.tex
   ├── sections/
   ├── references.bib
   ├── main.pdf                    # built artifact, committed
   └── {{class-files}}
```

`refs/` carries verbatim source material. `research/` carries analysis +
decisions. `proposal.md` (or `paper/`) is the deliverable.

## Conventions

- **Beads is on for this project.** Every meaningful chunk of work is a typed
  bead with full description / acceptance criteria. Follow-up projects
  (post-acceptance work) are deferred beads typed `task` or `epic`.
- **Voice.** {{`/zig-voice` for Andrew | other voice anchor}}
- **Char counts.** Every long field in `proposal.md` ends with the current
  char count vs. limit (e.g. `<!-- 583 / 600 -->`). Verify with `wc -m`
  minus 1 (for trailing newline) when in doubt.
- **Critic sub-agent discipline.** Every major draft is reviewed by at least
  one read-only sub-agent (`general-purpose` or `Explore`) acting as a
  critic — naive student, reviewer reading cold, voice/writing pass.
  Critics do NOT use worktree isolation; they are read-only reviews.
- **Source preservation.** `refs/` is verbatim. `research/` is our
  analysis. Never blur the line.

## Pipeline

1. **Bootstrap** — beads init, refs captured, CLAUDE.md current
2. **Bead architecture** — epic + active children + deferred follow-ups
3. **Angle exploration** — `research/angle-options.md`, lock chosen angle
4. **Draft v1** of `proposal.md` (or paper sections)
5. **Critic pass 1** — naive student / cold reader sub-agent
6. **Iterate** based on critic feedback
7. **Critic pass 2** — voice / writing sub-agent
8. **Final tightening** — char counts, voice, claim accuracy
9. **Owner reviews and submits** by {{DEADLINE}}
10. **POST-ACCEPTANCE (if accepted):**
    - Revision spec (`/spec`)
    - Reviewer-comment table → revision dispatch
    - Open Science artifact bundle (if applicable)
    - Camera-ready upload
    - arXiv preprint
    - Conference registration
    - Handoff to `/talk` (creates `~/cfp/talk-{{slug}}/`)

## Logistics

- **Headshot:** {{REQUIREMENTS_FROM_CFP_FORM}}
- **Travel:** {{COVERED_BY_CONFERENCE / EMPLOYER / SELF}}
- **Video of previous talk:** {{IF_REQUESTED}}
- **Equipment:** {{LAPTOP / SLIDES / MIC / WHATEVER}}

## See also

- `/beads` — `br` lifecycle, fields, types
- `/zig-voice` — writing voice + anti-patterns
- `/linearb-brand` — when LinearB context shows up
- `../{{closest-neighbor-cfp}}/` — closest-shape neighbor (vocabulary, layout, decisions)
- `../{{predecessor-paper-or-talk}}/` — source material to mine
