# Asana fleet proxy — verified cheatsheet for /explore

The `/asana` skill documents the broader API. This file captures the
specific subset /explore uses, with gotchas verified during the May 2026
session that produced /explore.

## Auth + headers (every write)

```bash
FLEET_URL=http://localhost:7100
FLEET_TOKEN="$FLEET_API_TOKEN"   # exported from your env — never hardcode

# Verify fleet is up before doing anything
curl -s -m 5 "$FLEET_URL/api/health"

# Required headers on writes:
#   Authorization: Bearer $FLEET_TOKEN
#   X-Agent-Name: claude-code
#   Content-Type: application/json   (when not multipart)
```

The fleet auto-prepends `[claude-code via Marketing Fleet]\n` once per
write. Don't prepend it yourself.

## Endpoints /explore actually uses

| Method | Path | What it does |
|--------|------|--------------|
| GET | `/api/asana/tasks/<gid>` | Fetch task — read existing notes, name, assignee_section before overwriting |
| POST | `/api/asana/tasks` | Create a (sub)task |
| **POST** | **`/api/asana/tasks/<gid>/update`** | **Update task — partial patch. The path the /asana skill misdocuments as `PUT /api/asana/tasks/<gid>` (which returns 405).** |
| POST | `/api/asana/tasks/<gid>/comment` | Post comment on task |
| POST | `/api/asana/tasks/<gid>/attachments` | Upload attachment (multipart) |
| GET | `/api/asana/tasks/<gid>/subtasks` | List subtasks |
| GET | `/api/asana/tasks/<gid>/stories?comments_only=true` | List comments |

## Plaintext discipline (the load-bearing rule)

The user copy-pastes content from Asana to LinkedIn. HTML wrappers and
self-closing `<br/>` tags are noise that has to be stripped. Default to
plaintext fields:

- Task description: `notes` (NOT `html_notes`)
- Comment body: `text` (NOT `html_text`)

Real `\n` newlines in JSON strings render as line breaks in Asana plain
text. That's all u need.

The /asana skill's existing examples lean on `html_notes` for nested
structure (h1, h2, ul, li). That's the right call for receipts of work
where the task IS the deliverable. For /explore, the task description is
a research artifact and the comment is copy-paste fodder — both want
plaintext.

## Building multi-line JSON cleanly via Python

Heredocs + JSON escaping is brittle when content has quotes, em-dashes,
emoji, etc. Always use Python `json.dump`:

```bash
python3 <<'PY'
import json

content = """Multi-line content with "quotes" and — em-dashes — and
emoji 🐸 and special chars no problem."""

with open("/tmp/payload.json", "w") as f:
    json.dump({"notes": content}, f)   # or {"text": content} for comments
PY

curl -sS -X POST "$FLEET_URL/api/asana/tasks/<gid>/update" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -H "Content-Type: application/json" \
  -d @/tmp/payload.json
```

## Multipart attachments

```bash
# Image at /tmp/img.png — content-type matters for Asana rendering
curl -sS -X POST "$FLEET_URL/api/asana/tasks/<gid>/attachments" \
  -H "Authorization: Bearer $FLEET_TOKEN" \
  -H "X-Agent-Name: claude-code" \
  -F "file=@/tmp/img.png;type=image/png"
```

If the openrouter helper script saved a JPEG under a `.png` extension
(can happen — provider behavior varies), `mv` the file to the right
extension before uploading and pass the matching `;type=image/jpeg`. The
`file` command verifies actual content:

```bash
file /tmp/img.png
# => /tmp/img.png: JPEG image data, ...   ← wrong extension; rename
```

## The PUT-vs-POST-update gotcha

The /asana skill documents `PUT /api/asana/tasks/<gid>` for updates. The
fleet does NOT implement that — it returns 405. The actual handler lives
at `app/api/asana/tasks/[gid]/update/route.ts` and accepts POST only.

Same convention as the existing `/comment` and `/delete` sub-routes
(per Spec 42 §4.2 — sub-route + POST for "verbs clients can't easily
issue").

This is filed as `bd-wji0` in `~/linearb/agent-factory`'s bead store. Two
options to resolve:
- **A**: update /asana skill docs to match (lower-blast-radius)
- **B**: add a PUT alias on the fleet (more REST-conventional)

Until the bead resolves, /explore uses POST `/update` exclusively.

## The strict-XML gotchas (relevant when you do use html_*)

Asana parses `html_notes` and `html_text` as strict XML, not loose
HTML5. The two fields have DIFFERENT supported tag sets — `html_notes`
is meaningfully stricter than `html_text` (verified 2026-05-07).

**`html_notes` (task description, on create AND update):**

- Supported: `<body>`, `<h1>`, `<h2>`, `<strong>`, `<em>`, `<u>`, `<s>`,
  `<code>`, `<pre>`, `<ul>`, `<ol>`, `<li>`, `<a href>`, `<img/>`
- NOT supported: `<br/>` (any form), `<h3>`, `<p>`. All return
  `400 Validation error: xml_parsing_error: XML is invalid`.
- For visual breaks: use `<h2>` for section headers (creates natural
  spacing) and `<ul><li>` for lists. Body text flows between them.
- Asana renders `notes` plaintext with newlines collapsed into one
  flowing paragraph, so plaintext `\n\n` does NOT render as a paragraph
  break in the UI. If you need visual structure in a description, you
  MUST use `html_notes` with the supported tags above.

**`html_text` (comments, via `/tasks/<gid>/comment`):**

- Supported tags include everything `html_notes` supports PLUS `<br/>`
  and `<h3>`. Self-closing form on `<br/>` is mandatory; bare `<br>`
  fails with the same XML parse error.

The /explore deliverable pipeline now uses `html_notes` with `<h2>` +
`<ul><li>` structure for description updates, and plaintext `text` for
comments (since the user copy-pastes them to LinkedIn).

## Personal-board limitation

The fleet's `/api/asana/projects` does NOT enumerate the user's "My
Tasks" / personal-board project. Tasks created with a `parent` field
target a known parent task GID; tasks WITHOUT a parent that are intended
for a personal-board section can't be enumerated by section through the
current fleet routes.

In practice: /explore always operates on a parent task GID provided by
the user. We never need to enumerate the personal board. If a future
flow wanted to ("list every task in 'Posts' section"), it'd require
fleet route additions.

## Idempotency

The `X-Idempotency-Key` header on `POST /api/asana/tasks` guards a
60-second retry window via fleet's Upstash Redis (if configured). Useful
for daily-bead-log automation, NOT useful for /explore — each /explore
run produces a unique deliverable.

For dedupe of "did I already create a subtask for this exploration?",
list subtasks under the parent and name-match instead:

```bash
curl -s -H "Authorization: Bearer $FLEET_TOKEN" \
  "$FLEET_URL/api/asana/tasks/<parent-gid>/subtasks" \
  | jq '.data[] | select(.name | contains("LinkedIn post:"))'
```

## Troubleshooting quick-ref

| Symptom | Cause | Fix |
|---|---|---|
| 401 on writes | Missing/wrong token | Sync `FLEET_API_TOKEN` w/ fleet's `.env.local` |
| 400 X-Agent-Name missing | Forgot the header | Add it on every write |
| 400 xml_parsing_error in html_text (comment) | Used `<br>` instead of `<br/>` | Use `<br/>` self-closing |
| 400 xml_parsing_error in html_notes (description) | Used `<br/>`, `<h3>`, or `<p>` | Restructure with `<h2>` + `<ul><li>`; those tags aren't supported in `html_notes` |
| 405 on PUT/PATCH/POST to bare `/tasks/<gid>` | Fleet doesn't support those verbs there | Use POST `/api/asana/tasks/<gid>/update` |
| 500 ASANA_ACCESS_TOKEN required | OAuth refresh expired | Mint fresh access token (see /asana SKILL Prerequisites) |
| Empty `data: []` from /search?project=<personal-board-gid> | Personal-board project not searchable through fleet | Use known parent task GID directly instead |
| Attachment uploaded but doesn't render in Asana | Wrong content-type | Match the actual file format (use `file` to verify) |

## See also

- `~/.claude/skills/asana/SKILL.md` — the underlying skill, broader scope
- `bd-wji0` in `~/linearb/agent-factory/.beads/` — the PUT-vs-POST diagnostic
- `~/linearb/agent-factory/agents/lb-agent-fleet/app/api/asana/` — the actual route handlers (when in doubt, read the source)
