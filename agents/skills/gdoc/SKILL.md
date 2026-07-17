---
name: gdoc
description: Read, write, format, and collaborate on Google Docs from Claude Code — the gdoc.sh shim, the Tabs API, service-account auth, and a canonical styling contract (Arial 11pt, 20/16/13pt headings). LinearB connector specifics are a separate private reference.
when_to_use: Reading, writing, formatting, or collaborating on Google Docs from the CLI; load when the user mentions shared-doc work.
---

# /gdoc — Google Docs

Read, write, format, and collaborate on Google Docs from Claude Code. Two
concerns live in this skill:

- **Mechanics** — auth, the `gdoc.sh` shim, tabs, comments, the
  inline-bun fallback for advanced ops
- **Styling contract** — the canonical font/size/spacing rules every
  doc an agent produces should follow

If you're writing a new doc, **read the styling contract first**. The
mechanics get you a doc on the page; the contract is how that doc looks
like every other doc in the fleet.

## Prerequisites

1. **A Google service account key** — set `GDOC_SA_KEY` to its path,
   or place it at `~/.config/gcloud/service-account.json`.
2. **bun** installed (the connector is TypeScript, run via bun).
3. **The target document shared** with the service account's
   `client_email` (in the key file — typically
   `*@*.iam.gserviceaccount.com`).

<!-- private-start -->
> **LinearB:** the factory connector + its service-account key
> locations are in `~/linearb/refs/gdoc-connector.md`.
<!-- private-end -->

## Quick setup (per project)

Symlink the global shim into your project so it can call out from CI / scripts:

```bash
mkdir -p scripts
ln -sf ~/.claude/skills/gdoc/gdoc.sh scripts/gdoc.sh
```

Or invoke `~/.claude/skills/gdoc/gdoc.sh` directly without copying.

---

## Styling Contract

Every Google Doc an agent produces should look like it came from the same
hand. These are the rules.

| Element | Font | Size | Spacing |
|---|---|---|---|
| Body paragraph | Arial | 11pt | lineSpacing 1.15, spaceBelow 6pt |
| Bullet item | Arial | 11pt | lineSpacing 1.15, spaceBelow 2pt |
| Heading 1 | Arial | 20pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Heading 2 | Arial | 16pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Heading 3 | Arial | 13pt | spaceAbove 12pt, spaceBelow 6pt, lineSpacing 1.15 |
| Inline hyperlink | inherit | inherit | underline, color rgb(0.06, 0.36, 0.8) |

### Why these values

- **Arial** — Google Docs' default, reads clean at all sizes, ships
  everywhere. No exotic fonts.
- **11pt body** — dense enough to fit a deal timeline without ballooning
  to five pages, light enough to skim.
- **20 / 16 / 13pt hierarchy** — distinct but not aggressive. H1 for one
  top-line title per tab; H2 for section banners; H3 for numbered
  sub-steps. If you want a fourth level, reach for bold body text, not a
  shrunken heading.
- **spaceAbove 12pt on headings** — prevents headings sitting flush
  against the previous paragraph's last line.
- **lineSpacing 1.15** — tighter than Docs default (1.5) but still
  breathable. Memo-like.
- **Bullet spaceBelow 2pt** — lets bullets breathe *as a group* without
  each item looking isolated.

### Two implementation paths

#### Path A (preferred) — a shared op emitter

If your writer takes Slack mrkdwn or markdown, drive the Docs API with
a shared op-emitter library that pre-encodes the styling contract
above, rather than re-deriving it per agent.
<!-- private-start -->
(The LinearB factory ships one — see `~/linearb/refs/gdoc-connector.md`
for the import path and call shape.)
<!-- private-end -->

#### Path B — HTML importer fallback

If your writer uses Drive's HTML importer (`drive.files.update` with
`media.mimeType = "text/html"`), inline the styles on import:

```html
<html>
  <body style="font-family: Arial, sans-serif; font-size: 11pt; line-height: 1.15;">
    <h1 style="font-family: Arial, sans-serif; font-size: 20pt; margin-top: 12pt; margin-bottom: 6pt;">Title</h1>
    <h2 style="font-family: Arial, sans-serif; font-size: 16pt; margin-top: 12pt; margin-bottom: 6pt;">Section</h2>
    <p style="margin-bottom: 6pt;">Body paragraph text.</p>
    <ul style="margin-bottom: 6pt;">
      <li style="margin-bottom: 2pt;">Bullet item</li>
    </ul>
  </body>
</html>
```

Or apply ops in a second pass after import (heavier; same output as Path A).

### When to deviate

Rarely. Reasons:

- **External template contract** (e.g., PMM monthly release notes
  doc has a specific typographic treatment) — respect the template,
  document the exception in the agent's CLAUDE.md.
- **Stakeholder ask** — explicit request for different styling. One-off,
  don't change the contract.
- **Medium-specific** — Gamma presentations have their own theme; this
  contract doesn't apply there.

Anything else is drift. Bring it back to the contract.

---

## Brand-styled content drops — the theme system

The styling contract above is the *default* house style. When you want a
**polished, shareable, brand-styled** drop — an internal brief, a weekly digest,
a report the editorial team will read — use the **theme system**: content
declares blocks by **role**; a **theme** (`themes/<name>.json`) maps every role
to a concrete palette color, size, and weight. Swap the theme, keep the content,
get a new look. This is a small design system, versioned as JSON, so new
palettes/designs are just a file and future projects customize on the fly.

**The anti-pattern this replaces:** a bare `insertText` of markdown renders as a
literal wall of text — the `#`, `**`, and `═` show up as characters, colons
don't stand out, headings are plain. Never hand-write markdown into a doc/tab.

**One spec → two matching outputs.** The same spec file drives both:
- `render_styled_blocks.mjs` → renders into a Google Doc **tab** (or body).
- `build_styled_docx.py` → renders a matching **.docx** (the shareable artifact;
  `--pdf` also exports a PDF via `soffice`).

```bash
# tab (SA_KEY = a service-account json with Docs write on the doc)
SA_KEY=/path/sa.json bun ~/.claude/skills/gdoc/render_styled_blocks.mjs spec.json
# shareable Word doc (+ pdf)
python3 ~/.claude/skills/gdoc/build_styled_docx.py spec.json out.docx --pdf
```

**Spec schema** (`spec.json`):
```jsonc
{
  "docId": "1AbC...",              // tab render only
  "tabId": "t.xxxx",               // OR "tabTitle": "Digest 2026-07-15" (find-or-create)
  "theme": "editorial",            // themes/editorial.json  (or inline "themeDef": {...})
  "clear": true,                   // wipe the tab first (default true)
  "blocks": [
    { "role": "kicker",   "text": "DEV INTERRUPTED  ·  RESEARCH DIGEST" },
    { "role": "title",    "text": "Research Digest" },
    { "role": "subtitle", "text": "..." },
    { "role": "sectionRule" },
    { "role": "itemTitle","runs": [ {"role":"itemNumber","text":"1.  "}, {"text":"AI Writes Faster..."} ] },
    { "role": "link",     "text": "https://...", "link": "https://..." },
    { "role": "label",    "text": "Summary" },
    { "role": "bullet",   "text": "..." },
    { "role": "body",     "text": "..." }
  ]
}
```
- A **block** is one paragraph. It picks a `role`; the theme supplies size /
  color / weight / spacing / bullet / rule. Any field can be overridden inline
  (`size`, `color`, `bold`, `italic`, `underline`, `link`, `upper`, `sa`, `sb`).
- Multi-style lines use `runs[]` (each run may carry its own `role` + overrides),
  e.g. an indigo number followed by an ink title.
- `color` is a **palette key** (`ink`/`accent`/`muted`/`link`/…) or a raw hex.

**Role vocabulary** (defined per theme): `kicker`, `title`, `subtitle`,
`dateline`, `intro`, `note`, `heading`, `sectionRule`, `itemRule`, `itemTitle`,
`itemNumber`, `link`, `meta`, `label`, `body`, `bullet`. Add roles to a theme as
needed; keep the names stable across themes so content stays swappable.

**Adding a theme** — copy `themes/editorial.json`, rename, change the `palette`
(and `font`) — the roles stay identical so any existing content re-renders in the
new look. Shipped themes: `editorial` (indigo/Calibri, AZ's house brief style),
`slate` (corporate blue/Arial). This is where new project palettes live.

**Technique — insert-all-then-style.** Both renderers concatenate the full plain
text, insert it **once** (`insertText` at index 1), then batch
`updateParagraphStyle` (spacing, `borderBottom` for rules) + `updateTextStyle`
(color/size/bold/italic/underline/link) + `createParagraphBullets` over computed
char ranges. Gotchas: Docs indices are **UTF-16 code units** (JS `.length`
matches for BMP text — avoid emoji inside styled runs or offsets drift); apply
paragraph styles, then text runs, then bullets; a single insert keeps all
offsets stable.

**When to use which:** `gdoc.sh write <tabId>` for a quick markdown drop in the
standard Arial contract; the theme system when the output needs a real design
(palette, kickers, section labels) and a matching downloadable `.docx`.

---

## Shell Shim Usage

The `gdoc.sh` script (lives at `~/.claude/skills/gdoc/gdoc.sh`) wraps
all common operations:

```bash
# List tabs in a document
./scripts/gdoc.sh tabs <docId>

# Read a document (or specific tab) as markdown
./scripts/gdoc.sh read <docId>
./scripts/gdoc.sh read <docId> <tabId>

# Write markdown to a document (full replacement of doc content)
./scripts/gdoc.sh write <docId> /path/to/content.md

# Write markdown to a specific tab (fixed 2026-06-11, bd-3w8a): the
# connector's per-tab path now renders native Docs rich text (real
# headings/links/bullets per the styling contract) via
# markdownToStyledRequests. The no-tabId form still uses Drive's HTML
# importer (whole-doc replacement) — right call for single-tab docs.
./scripts/gdoc.sh write <docId> /path/to/content.md <tabId>

# Read comments on a document
./scripts/gdoc.sh comments <docId>

# Post a new comment on a document
./scripts/gdoc.sh comment <docId> "Your comment text here"

# Reply to an existing comment
./scripts/gdoc.sh reply <docId> <commentId> "Your reply text here"

# Create a new tab
./scripts/gdoc.sh add-tab <docId> "Tab Title"
```

### Extracting a Doc ID

From a Google Docs URL:
`https://docs.google.com/document/d/1wfhHghZ0hXs_6Pk_UiBN-hHoPMHVINuExgQVV9rHlOg/edit`

The doc ID is: `1wfhHghZ0hXs_6Pk_UiBN-hHoPMHVINuExgQVV9rHlOg`.

---

### Per-tab writes

Fixed 2026-06-11 (bd-3w8a): `gdoc.sh write` with a `tabId` arg now
replaces the tab's content with native Docs rich text — the connector
parses markdown into `insertText` + `updateParagraphStyle` /
`updateTextStyle` / `createParagraphBullets` requests scoped via
per-request `location.tabId` / `range.tabId`, honoring the styling
contract (Arial, 20/16/13pt headings, 11pt body, styled links). The
underlying API is `markdownToStyledRequests(markdown, insertionIndex,
tabId)` + `updateDoc(..., { tabId })` in `connectors/google/docs/`.

Use the no-tabId form for single-tab docs (the common case for blog
drafts, briefs, and single-page deliverables) — it routes through
Drive's HTML importer and replaces the whole document.

## Advanced Operations (inline bun)

For operations not covered by the shim, run bun inline against the
`googleapis` library. The examples below assume two vars you set for
your environment:

```bash
AGENT_DIR="<a directory with googleapis installed>"
SA_KEY="<path to your service-account .json>"
```
<!-- private-start -->
(LinearB factory paths: `~/linearb/refs/gdoc-connector.md`.)
<!-- private-end -->

### Create a new tab

```bash
cd "$AGENT_DIR" && bun -e "
import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/documents']
});
const docs = google.docs({ version: 'v1', auth });

const res = await docs.documents.batchUpdate({
  documentId: '<DOC_ID>',
  requestBody: {
    requests: [{
      addDocumentTab: {
        tabProperties: { title: 'My New Tab' },
      },
    }],
  },
});
console.log('Tab created:', JSON.stringify(res.data.replies, null, 2));
"
```

### Apply formatting to a tab (matches contract above)

```bash
cd "$AGENT_DIR" && bun -e "
import { readFileSync } from 'fs';
import { google } from 'googleapis';

const key = JSON.parse(readFileSync('$SA_KEY', 'utf-8'));
const auth = new google.auth.GoogleAuth({
  credentials: key,
  scopes: ['https://www.googleapis.com/auth/documents']
});
const docs = google.docs({ version: 'v1', auth });

const tabId = '<TAB_ID>';

await docs.documents.batchUpdate({
  documentId: '<DOC_ID>',
  requestBody: {
    requests: [
      // H1 — Arial 20pt
      {
        updateParagraphStyle: {
          range: { startIndex: 1, endIndex: 30, tabId },
          paragraphStyle: {
            namedStyleType: 'HEADING_1',
            spaceAbove: { magnitude: 12, unit: 'PT' },
            spaceBelow: { magnitude: 6, unit: 'PT' },
            lineSpacing: 115,
          },
          fields: 'namedStyleType,spaceAbove,spaceBelow,lineSpacing',
        },
      },
      {
        updateTextStyle: {
          range: { startIndex: 1, endIndex: 30, tabId },
          textStyle: {
            weightedFontFamily: { fontFamily: 'Arial' },
            fontSize: { magnitude: 20, unit: 'PT' },
          },
          fields: 'weightedFontFamily,fontSize',
        },
      },
    ],
  },
});
console.log('Heading formatted');
"
```

---

## Google Docs API: Tab Reference

Tabs were added to the Docs API in 2024. Key points:

- **List tabs:** `documents.get` with `includeTabsContent: true` returns
  `document.tabs[]` with `tabProperties` (id, title) and `documentTab` (body)
- **Target a tab in batchUpdate:** Add `tabId` to any `location` or `range`
  object. If omitted, defaults to the first tab.
- **Create tabs:** Use `addDocumentTab` request in batchUpdate
- **Delete tabs:** Use `deleteTab` request — child tabs are deleted along with it
- **Rename tabs:** Use `updateDocumentTabProperties` request
- **Tab content:** Access via `document.tabs[i].documentTab.body` (not
  `document.body` which only returns first tab when `includeTabsContent`
  is false)

<!-- private-start -->
## Connector API Reference

The lb-agent-di Google connector's function surface — read / write /
drive / auth — is documented in `~/linearb/refs/gdoc-connector.md`.
<!-- private-end -->

---

## Workflow Pattern

A typical editing workflow:

1. **Read** the doc to see current state
2. **Read comments** to see reviewer feedback
3. **Reply** to each comment acknowledging the feedback
4. **Edit locally** in a markdown file
5. **Write** the updated markdown back to the doc (Path A — styling
   contract is automatic)
6. **Reply** again confirming the change was made
7. Reviewer sees changes in Google Docs and leaves more comments
8. Repeat until approved

The agent can also **post comments** proactively to flag issues, ask
questions, or leave notes. Comments appear under the service account
identity.

For multi-section documents, use **tabs** to separate concerns (e.g.,
article draft in Tab 1, social media drafts in Tab 2, reviewer notes
in Tab 3).

## Updating an uploaded Office file (.docx / .pptx / .xlsx) in place

When the shared doc is an **uploaded Office file** (an `.docx` a reviewer
commented on), the Docs API rejects it ("must not be an Office file") and you
cannot edit tabs. **Do NOT create a new doc or a tab elsewhere** — update the
SAME file so the reviewer's link keeps working. The move: generate a new `.docx`
(pandoc `md -> docx`, or python-docx) and **replace the file's bytes** via Drive
`files.update({ fileId, media: { mimeType: '<docx-mime>', body: stream }, requestBody: { name } })`.
Same file ID, same URL. Caveat: replacing the content **clears the file's
existing comments** (they were anchored to the old bytes) — fine once you have
folded that feedback in, which is usually why you are updating it. Read the old
file first (download via Drive `files.get alt=media`, unzip, parse
`word/document.xml` + `word/comments.xml`) to capture the reviewer's comments and
tracked changes before you overwrite.

## Revising a native Google Doc — study the original first, verify after

When you're editing a **native Google Doc** someone already reviewed (a talk
track, a brief, a shared draft), the job is "swap the text, keep the formatting" —
and the trap is that `gdoc.sh read` (markdown) is **lossy in exactly the
ways that matter**. It silently drops:

- **Empty spacer paragraphs** — the blank lines an author put between
  items for breathing room. The reader collapses them, so a rewrite from
  that markdown loses every line break.
- **Numbering scheme** — the reader renders both a native `<ol>` and
  literal typed "1." as the same `1.`/`- ` text. You cannot tell
  native-vs-literal, or per-section-restart (1,2 / 1,2,3) vs one running
  1-N count, from the reader. Guessing wrong reformats the whole doc.

**The discipline (learned the hard way, 2026-07-16 Yishai talk track — two
rounds of author pushback):**

1. **Study the original's real structure before editing.** Export it and
   read the *raw HTML*, not the markdown:
   ```bash
   # current live version
   drive.files.export({ fileId, mimeType: 'text/html' })
   # a prior version (to see what the author actually had)
   drive.revisions.list({ fileId })            # find the revisionId
   drive.revisions.get({ fileId, revisionId, fields: 'exportLinks' })  # → text/html link
   ```
   The HTML shows the spacer `<p>` paragraphs, the literal-vs-`<ol>`
   numbering, and the exact per-run colors/weights.
2. **Preserve the author's scheme.** If numbers are literal and restart
   per section with blank lines between items, reproduce *that* — do not
   "upgrade" it to a native auto-list (a native list can't keep a blank
   line between items; the gap breaks it). Match colors, italics,
   headings, and spacer paragraphs 1:1.
3. **Emit spacer paragraphs explicitly** (`<p><span></span></p>`) — they
   survive a Drive HTML import.
4. **Verify against the doc, never the reader.** After writing, pull
   `documents.get` and check per-paragraph text/style/color and *count the
   empty paragraphs*, or re-export to HTML. The markdown reader will lie
   to you about both the spacers and the numbering.

Numbering specifically: a **native `createParagraphBullets` list** gives
auto-renumbering + hanging indent but **cannot** have blank lines between
items and continues one count across sections (unless you split it into a
separate list per section). **Literal typed numbers** give you per-section
restart *and* blank-line spacing, at the cost of manual renumbering. Pick
the one the original used — don't impose a preference.

## Guardrails

- **Don't change the styling values** without a sample doc for review.
  The point of a contract is that it's shared.
- **Don't inline hex colors or custom font sizes per agent.** If a new
  element type needs a rule (callout boxes, footnotes), extend this
  contract; don't special-case inside an agent.
- **Don't write plain `notes` or untyped HTML.** Both paths above have
  specific shapes. The deviations are unsupported.
- **Asana tickets are not Docs.** Use `/asana` for Asana — that has its
  own `html_notes` shape.
- **Gamma presentations are not Docs.** Gamma has its own theme.
